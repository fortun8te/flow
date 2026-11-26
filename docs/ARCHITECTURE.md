# Architecture

This document describes how Flow turns speech into pasted text, how Opt+1 polishes a selection, and how meetings are captured. Every stage names the file that implements it. Where a number is a deadline or threshold, the value comes from the code at the time of writing; check the file before relying on it.

The Swift module is called `Voice` for compatibility with older builds; the product is `Flow` (`Package.swift`).

## Components

| Layer | Main files |
|---|---|
| App shell, menus, settings, pill | `Sources/Voice/App/VoiceApp.swift`, `Sources/Voice/Views/` |
| Hotkeys and fn key | `Sources/Voice/Services/HotkeyService.swift`, `FnKeyTap.swift` |
| Audio capture | `Sources/Voice/Services/AudioCaptureService.swift`, `CaptureDSP.swift`, `MicrophoneFailover.swift` |
| Recording coordination | `Sources/Voice/Services/RecordingCoordinator.swift` |
| Speech recognition | `TranscriptionService.swift`, `TranscriptionEngine.swift`, `SpeechModelCatalog.swift`, `SpeechModelLoader.swift`, `GraniteTranscriber.swift`, `MoonshineTranscriber.swift` |
| Text preparation | `DictationTextPreparation.swift`, `DictationFinalPass.swift`, `Sources/Voice/Utils/TextFormatter.swift`, `DictationParagraphs.swift` |
| Cleanup models | `Qwen3Polisher.swift`, `S1MiniPolisher.swift`, `WhisperNowTunedPolisher.swift` (DOSE1), `GeneralCleanupModel.swift`, `CerebrasPolisher.swift`, `GroqPolisher.swift`, `HyperbolicPolisher.swift`, `NVIDIAPolisher.swift`, `RemoteCleanup.swift` |
| Guards and referees | see [DECISION-MODELS.md](DECISION-MODELS.md) |
| Rule passes | `RealWordFixer.swift`, `TypoRepair.swift`, `LowConfidenceRecheck.swift`, `TinyNextScorer.swift`, `PolishPostprocessor.swift`, `RestartCorrectionPreprocessor.swift`, `EntityFreezer.swift` |
| Paste | `Sources/Voice/Utils/CursorPaster.swift`, `PasteReadback.swift`, `PasteSafety.swift` |
| Opt+1 | `PolishTransaction.swift`, `OptOneReferee.swift`, `OptOneLayout.swift` |
| Meetings | `MeetingCaptureService.swift`, `SpeakerDiarizer.swift`, `MeetingCalendarService.swift`, `MeetingRecoveryService.swift`, `MeetingExporter.swift`, `MeetBridgeServer.swift` |
| Storage | `StorageService.swift` (GRDB, SQLite, FTS5) |
| Local logs | `FlowRunLog.swift`, `DictationTrace.swift`, `Telemetry.swift` (see [DATA.md](DATA.md)) |

## Dictation pipeline

1. **Start.** A hotkey press starts `RecordingCoordinator`. Audio goes to a file through `AudioCaptureService`. A short press that is released before the hold threshold is discarded silently (`HotkeyService.swift`).
2. **Recognition.** `TranscriptionService` runs the selected recogniser on the finished file. The default is Parakeet TDT 0.6B v3 through FluidAudio. It returns timed segments with per-word confidence (`TranscriptionService.swift`, `TranscriptionEngine.swift`).
3. **Preparation.** `DictationTextPreparation.prepare` joins the segments, repairs sentences broken by the recogniser (`DictationFinalPass.joinBrokenSentences`), and formats the text with `TextFormatter.formatSegments`. It rejects empty input and text that is mostly non-Latin script. It also reads a trailing "press Enter" command (`TrailingPressEnter.swift`). A trailing stop word is removed only when the spoken stop word ended the recording.
4. **Restart and entity protection.** `RestartCorrectionPreprocessor` resolves spoken self-corrections ("two, no wait, one") before the model sees the text. `EntityFreezer` swaps emails, URLs, code, contractions and domains for sentinel tokens before the model sees the text, and restores them verbatim afterwards.
5. **Cleanup.** The cleanup model runs on the text in sections, with a shared deadline (see below). A section's output is used only if `WhisperNowContentGuard.trip` returns no failure, the output is not shortened beyond the coverage rule, and `Qwen3Polisher.reviewIdentifiersPreserved` finds the identifiers unchanged. Otherwise that section keeps its source text. The route is chosen in `Qwen3Polisher.effectiveAutomaticCleanupModel`: DOSE1 by default, S1-mini if DOSE1 is not installed, or the Qwen3 or general model the user picked.
6. **Finalise.** `DictationTextPreparation.finalize` runs `DictationFinalPass.apply` (fillers, stutters, list markup), the user's own replacements (`WisprImportService.applyReplacements`), American spelling (`AmericanSpelling.swift`), and restores the case of filenames that appear once in the source.
7. **Rule repair.** `RecordingCoordinator` runs `RealWordFixer` (homophones such as their/there). `LowConfidenceRecheck` then looks at words the recogniser flagged below confidence 0.6, and `DictationReferee` records the judgement of each check.
8. **Layout.** `TextFormatter` and `DictationParagraphs` apply list and paragraph layout.
9. **Paste.** `CursorPaster` sends the text at the cursor and `PasteReadback` reads the field back to decide whether it landed. An unknown result never triggers a second paste.
10. **Record.** The run is written to the local run log and the trace, with numbers and labels only in the trace (see [DATA.md](DATA.md)).

### Deadlines and fallbacks

| Limit | Value | Behaviour when hit | Where |
|---|---|---|---|
| Short dictation budget | 1.5 s from key release | Cleanup for the remaining sections is skipped; each timed-out section keeps its source text | `DictationTrace.swift` header, `DictationTextPreparation.swift` |
| Per-section model time | the model's own request time (4 s + 30 ms per word, for DOSE1), capped by what remains of the deadline | Section keeps its source text | `DictationTextPreparation.swift`, `WhisperNowTunedPolisher.timeout(for:)` |
| Minimum useful remainder | 50 ms | Treated as timed out | `DictationTextPreparation.swift` |
| Draft second opinion | 150 ms | Maximum wait for the local meaning check (`DraftDecisionGate.swift`) |
| Remote cleanup health check | 0.5 s | A failed check means the local path runs (`RemoteCleanup.swift`) |
| Accessibility messaging | 0.6 s | A slow read falls back to the other outcome (`AccessibilityBudget.swift`) |
| Opt+1 shortcut budget | 8 s | Time budget for the shortcut (`PolishTransaction.swift`) |
| Opt+1 selection size | 6,000 characters | Refused | `PolishTransaction.swift` |
| Failed model load | not retried for 10 minutes | Dictation goes through DOSE1 | `GeneralCleanupModel.swift` |

A dictation is never lost because a model failed. If every cleanup step fails, the formatted transcript is pasted.

On every dictation start, Flow begins optional TinyFix, TinyNext/lexicon and D1 warmups while audio is being captured. A long recording refreshes the idle D1 worker without extending any pending request's watchdog. The CTC encoder is shared between batch and live recognition; a cold live preview starts without vocabulary rescoring rather than waiting for a download. On sectioned dictation, deterministic validation precedes D1 review, and review of one section overlaps cleanup of the next. The original section remains the fallback on a veto. TinyNext low-confidence contexts are scored in bounded batches rather than one model call per suspect.

## Opt+1 polish

`PolishTransaction` describes one polish. It captures the selection, asks the local model once, and replaces the selection once. It reports one of five outcomes: `changed`, `noChangesNeeded`, `couldNotImprove(reason:)`, `unavailable(reason:)` or `textChangedWhilePolishing`. If the selection changed while the model was thinking, nothing is replaced.

`OptOneReferee` aligns the model's edit with the typed text, group by group. Spelling, casing, apostrophes and splits pass. A changed number, link, name or negation, an added or dropped word, or a reworded phrase is reverted to the typed words, and each revert carries a reason. The deterministic repair then fixes what the model left. Undo restores the original only if the text still matches what Flow wrote.

## Meeting pipeline

- `MeetingCaptureService` records meeting audio. `CallAppDetector` recognises call applications.
- `MeetBridgeServer` listens on `localhost:59423`. The Chrome extension in `Extension/` posts to it when a `meet.google.com` call starts or ends, so capture can start and stop automatically. It starts only when meeting detection is enabled (`VoiceApp.swift`, `BackgroundActivityGate.meetingDetectionEnabled`).
- `SpeakerDiarizer` assigns speakers with a clustering threshold of 0.62 (`SpeakerDiarizer.swift`).
- `MeetingRecoveryService` scans for orphaned meeting audio on launch and surfaces it for recovery.
- Transcripts, speakers and summaries are stored by `StorageService` in a local SQLite database with an FTS5 index (`voice.db`). `MeetingExporter` writes exports.

## Companion integration (optional)

A companion app can drive Flow over distributed notifications and read Flow's status keys (`FlowCommandListener.swift`, `FlowBroadcast`). Flow runs without it. The companion is not part of this repository, and the notification names and `Companion` labels in the code are placeholders from the public export.

## Storage and privacy switches

- `voice.privacyMode` is the master switch. When it is on, run records are not written and the other local helpers stop (`VoiceApp.swift`, `BackgroundActivityGate`).
- Run records have their own switch, `flow.saveRunRecords` (default on). See [DATA.md](DATA.md).
- API keys live in the Keychain (`SecretStore.swift`, `KeychainAccess`).
- The database and audio files live under `~/Library/Application Support/Voice/`, with audio pruned by size (`StorageService.pruneAudioBySize`).
