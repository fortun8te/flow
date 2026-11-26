import Foundation
import Testing
@testable import Voice

// A dictation into a secure (password) field must never leave its text in the run log (runs.jsonl),
// and an ordinary dictation must still keep its text.
// Share the serialized suite that owns FlowRunLog.directoryOverride.
extension FlowRunLogTests {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("secure-run-log-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A run finished as secure writes no input, output, stage text, changes or ASR words to disk")
    func secureRunHasNoText() throws {
        let dir = scratchDirectory()
        FlowRunLog.directoryOverride = dir
        defer { FlowRunLog.directoryOverride = nil; try? FileManager.default.removeItem(at: dir) }

        let secret = "zxqPassphrase9 correcthorse"
        let run = FlowRunCollector(kind: "dictation", id: "secure-run-1", app: "com.example.login", input: secret)
        run.stage("cleanup", text: secret + " typed twice")
        run.update { record in
            record.asrWords = [ASRWordConfidence(word: "zxqPassphrase9", confidence: 0.4, start: nil, end: nil)]
            record.suspectWords = ["zxqPassphrase9"]
            record.timingsMs["modelMs"] = 120
            record.decisions = [FlowRunDecision(stage: "tinynext", verdict: "zxqPassphrase9 -> corrected", reason: secret)]
            record.fallbackReason = secret
            record.settings["graniteTranscript"] = secret
            record.settings["moonshineTranscript"] = secret
            record.audioPath = "/private/" + secret
        }
        run.finish(outcome: "secure-field", output: secret, fallback: nil, secureField: true)
        FlowRunLog.flush()

        let onDisk = try String(contentsOf: FlowRunLog.fileURL, encoding: .utf8)
        #expect(!onDisk.contains("zxqPassphrase9"))
        #expect(!onDisk.contains("correcthorse"))

        let records = FlowRunLog.readAll()
        #expect(records.count == 1)
        let saved = try #require(records.first)
        #expect(saved.outcome == "secure-field")
        #expect(saved.input == nil)
        #expect(saved.output == nil)
        #expect(saved.asrWords == nil)
        #expect(saved.suspectWords == nil)
        #expect(saved.settings.isEmpty)
        #expect(saved.audioPath == nil && saved.fallbackReason == nil)
        #expect(saved.stages.allSatisfy { $0.text == nil && $0.changes == nil && $0.detail == nil })
        // Labels and timings stay, so the run is still countable.
        #expect(saved.timingsMs["modelMs"] == 120)
        #expect(saved.timingsMs["totalMs"] != nil)
    }

    @Test("An ordinary run keeps its input, stage text and output")
    func ordinaryRunKeepsText() throws {
        let dir = scratchDirectory()
        FlowRunLog.directoryOverride = dir
        defer { FlowRunLog.directoryOverride = nil; try? FileManager.default.removeItem(at: dir) }

        let run = FlowRunCollector(kind: "dictation", id: "plain-run-1", app: "com.example.notes", input: "hello there")
        run.stage("cleanup", text: "Hello there.")
        run.finish(outcome: "landed", output: "Hello there.")
        FlowRunLog.flush()

        let saved = try #require(FlowRunLog.readAll().first)
        #expect(saved.input == "hello there")
        #expect(saved.output == "Hello there.")
        #expect(saved.stages.first?.text == "Hello there.")
    }

    @Test("withoutText keeps stage labels and timings but scrubs decisions that may contain words")
    func withoutTextKeepsLabels() {
        var record = FlowRunRecord(kind: "dictation", id: "scrub-1", recordedAt: Date(), app: "com.example",
                                   input: "secret", output: "secret")
        record.editedText = "secret edit"
        record.stages = [FlowRunStage(name: "cleanup", text: "secret", ms: 5, changes: ["a -> b"], detail: ["k": "v"])]
        record.timingsMs["totalMs"] = 42
        record.models["cleanup"] = "dose1-t4"
        record.decisions = [FlowRunDecision(stage: "guard", verdict: "kept", reason: nil)]

        let clean = FlowRunLog.withoutText(record)
        #expect(clean.input == nil && clean.output == nil && clean.editedText == nil)
        #expect(clean.stages.first?.name == "cleanup")
        #expect(clean.stages.first?.ms == 5)
        #expect(clean.stages.first?.text == nil && clean.stages.first?.changes == nil)
        #expect(clean.timingsMs["totalMs"] == 42)
        #expect(clean.models["cleanup"] == "dose1-t4")
        #expect(clean.decisions.first?.verdict == "redacted")
        #expect(clean.decisions.first?.reason == nil)
        // The original is untouched.
        #expect(record.input == "secret")
    }

    @Test("Privacy and run-record opt-out apply even to an overridden destination")
    func optedOutRecordsAreNotWritten() throws {
        let defaults = UserDefaults.standard
        let oldPrivacy = defaults.object(forKey: "voice.privacyMode")
        let oldPreference = defaults.object(forKey: FlowRunLog.preference)
        let dir = scratchDirectory()
        FlowRunLog.directoryOverride = dir
        defer {
            FlowRunLog.flush()
            FlowRunLog.directoryOverride = nil
            defaults.set(oldPrivacy, forKey: "voice.privacyMode")
            defaults.set(oldPreference, forKey: FlowRunLog.preference)
            try? FileManager.default.removeItem(at: dir)
        }
        let run = FlowRunCollector(kind: "dictation", id: "opt-out", app: nil, input: "the blue kettle")
        defaults.set(true, forKey: "voice.privacyMode")
        defaults.set(true, forKey: FlowRunLog.preference)
        run.finish(outcome: "landed", output: "The blue kettle.")
        FlowRunLog.flush()
        #expect(!FileManager.default.fileExists(atPath: FlowRunLog.fileURL.path))
        defaults.set(false, forKey: "voice.privacyMode")
        defaults.set(false, forKey: FlowRunLog.preference)
        FlowRunLog.append(FlowRunRecord(kind: "dictation", id: "opt-out-2", recordedAt: Date(), input: "the blue kettle"),
                          synchronously: true)
        #expect(!FileManager.default.fileExists(atPath: FlowRunLog.fileURL.path))
    }

    @Test("Scoped correction observations retain their provenance without claiming approval")
    func correctionFollowupProvenance() throws {
        let dir = scratchDirectory()
        FlowRunLog.directoryOverride = dir
        defer { FlowRunLog.flush(); FlowRunLog.directoryOverride = nil; try? FileManager.default.removeItem(at: dir) }
        FlowRunLog.followup(id: "span-1", kind: "dictation", followup: "edited", editedText: "The blue kettle.",
                            feedbackSource: "observed-edit", targetScope: "pasted-span")
        FlowRunLog.flush()
        let record = try #require(FlowRunLog.readAll().first)
        #expect(record.schemaVersion == 2)
        #expect(record.editedText == "The blue kettle.")
        #expect(record.feedbackSource == "observed-edit" && record.targetScope == "pasted-span")
    }

    @Test("Version one records decode with absent new provenance fields")
    func legacyRunDecoding() throws {
        var original = FlowRunRecord(kind: "dictation", id: "legacy-1", recordedAt: Date(), input: "the blue kettle")
        original.schemaVersion = 1
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FlowRunRecord.self, from: data)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.feedbackSource == nil && decoded.targetScope == nil)
        #expect(decoded.sourceSHA256 == nil && decoded.pipelineVersion == nil)
    }
}
