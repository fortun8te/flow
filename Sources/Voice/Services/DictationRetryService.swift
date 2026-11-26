// Flow — transcribe a saved dictation again
// ============================================================
// Given a dictation's id: read its saved audio with the speech model in use
// now, clean the text up the normal way, and store the result on the same
// row. Nothing is pasted, typed or put on the clipboard.
// ============================================================

import Foundation

@MainActor
enum DictationRetryService {
    enum Failure: Error, Equatable {
        case notFound, notADictation, audioMissing, modelNotReady, noSpeech, notRecognised
        case transcription(String), storage(String)

        /// Plain wording; this is what Companion shows.
        var message: String {
            switch self {
            case .notFound: return "That dictation no longer exists"
            case .notADictation: return "That recording is a meeting, not a dictation"
            case .audioMissing: return "Audio is no longer saved"
            case .modelNotReady: return "The speech model is still loading. Try again in a moment"
            case .noSpeech: return "No speech was found in the saved audio"
            case .notRecognised: return "The saved audio could not be read as text"
            case .transcription(let reason): return "Could not transcribe the saved audio: \(reason)"
            case .storage(let reason): return "Could not save the new text: \(reason)"
            }
        }
    }

    /// The saved audio of a dictation row, or why it cannot be retried.
    /// No model is touched here, so callers can check cheaply and tests can run it.
    static func audioURL(for id: UUID, storage: StorageService) -> Result<URL, Failure> {
        let row: Meeting?
        do { row = try storage.fetchMeeting(id: id) } catch { return .failure(.storage(error.localizedDescription)) }
        guard let row else { return .failure(.notFound) }
        guard row.kind == .dictation else { return .failure(.notADictation) }
        guard let path = row.audioFilePath, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return .failure(.audioMissing) }
        return .success(URL(fileURLWithPath: path))
    }

    /// Returns the new cleaned text on success. The row keeps its id, date,
    /// title and audio; its segments and `finalText` are replaced together.
    static func retry(id: UUID, storage: StorageService, transcription: TranscriptionService,
                      formatter: TextFormatter) async -> Result<String, Failure> {
        let url: URL
        switch audioURL(for: id, storage: storage) {
        case .success(let found): url = found
        case .failure(let failure): return .failure(failure)
        }

        // Prepare the independent models while the recognizer loads/decodes audio.
        let cleanupLevel = CleanupLevel.current
        let polishEnabled = UserDefaults.standard.object(forKey: "polishEnabled") as? Bool ?? true
        let useAssistants = cleanupLevel != .none && polishEnabled
        if useAssistants {
            RealWordFixer.shared.prewarm()
            TypoRepair.shared.prewarm()
            Task(priority: .utility) { await DraftDecisionGate.prewarmIfEnabled() }
        }

        // Same patience as "Transcribe now" on a meeting: up to about 10 s.
        var waited = 0
        while !transcription.isReady && waited < 20 {
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return .failure(.transcription("Cancelled")) }
            waited += 1
        }
        guard transcription.isReady else { return .failure(.modelNotReady) }

        let segments: [TranscriptSegment]
        do { segments = try await transcription.transcribeFile(url: url) }
        catch { return .failure(.transcription(error.localizedDescription)) }

        // The normal cleanup, minus everything that belongs to pasting: no
        // "press enter" command, no target app, no clipboard.
        let prepared = DictationTextPreparation.prepare(segments: segments, formatter: formatter,
                                                        pressEnterEnabled: false, autoPaste: false)
        switch prepared.rejection {
        case .empty?: return .failure(.noSpeech)
        case .nonLatin?: return .failure(.notRecognised)
        case nil: break
        }
        let formatted = prepared.command.text
        var finalText = formatted
        if useAssistants {
            let suspects = Array(Set(segments.compactMap(\.suspectWords).flatMap { $0 }
                                     + TextFormatter.suspectsForPolish(formatted)))
            let preferred = ProperNounVocabulary.preferredSpellingTerms()
            let vocabulary = Array(Set(preferred + ProperNounVocabulary.current() + CombinedDictionary.terms()))
            finalText = await Qwen3Polisher.shared.polish(
                formatted,
                suspectWords: suspects.isEmpty ? nil : suspects,
                userVocabulary: vocabulary.isEmpty ? nil : vocabulary,
                cleanupLevel: cleanupLevel.rawValue,
                personalityStyle: PersonalityStyle.current.rawValue)
            if await DraftDecisionGate.shouldKeepOriginal(formatted, edited: finalText) {
                finalText = formatted
            }
            finalText = DictationTextPreparation.finalize(polished: finalText, formatted: formatted)
            let preparedText = finalText
            let repaired = await DictationReferee.background {
                let fixed = DictationReferee.dictationPass(preparedText, isCode: false)
                return LowConfidenceRecheck.recheck(fixed, suspects: suspects, protectedTerms: vocabulary).text
            }
            finalText = ProperNounVocabulary.applyPreferredSpelling(repaired, terms: preferred)
        } else {
            finalText = DictationTextPreparation.finalize(polished: finalText, formatted: formatted)
        }
        guard !Task.isCancelled else { return .failure(.transcription("Cancelled")) }
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.noSpeech) }

        do {
            // Saving also tells Companion that dictations changed (StorageService.onChange).
            guard try storage.replaceDictationTranscript(id: id, segments: segments, finalText: finalText)
            else { return .failure(.notFound) }
        } catch { return .failure(.storage(error.localizedDescription)) }
        return .success(finalText)
    }
}
