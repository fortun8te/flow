import Foundation
import Testing
@testable import Voice

// The serialized suite owns run-log paths and privacy preferences.
extension FlowRunLogTests {
    private func withWordEvidenceLog(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let privacy = defaults.object(forKey: "voice.privacyMode")
        let preference = defaults.object(forKey: FlowRunLog.preference)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("word-evidence-\(UUID().uuidString)")
        FlowRunLog.directoryOverride = directory
        defaults.set(false, forKey: "voice.privacyMode")
        defaults.set(true, forKey: FlowRunLog.preference)
        defer {
            FlowRunLog.flush()
            FlowRunLog.directoryOverride = nil
            defaults.set(privacy, forKey: "voice.privacyMode")
            defaults.set(preference, forKey: FlowRunLog.preference)
            try? FileManager.default.removeItem(at: directory)
        }
        try body()
    }

    private func wordEvidence() throws -> WordDecisionEvidence {
        let source = "their moon is square"
        return try #require(WordDecisionEvidence.make(stage: "tinyfix", mode: "dictation", source: source,
            range: NSRange(location: 0, length: 5), contextRange: NSRange(location: 0, length: source.utf16.count),
            candidates: [.init(text: "their", rawScore: -2), .init(text: "there", rawScore: -3)],
            chosenIndex: 0, margin: -1, threshold: 5, modelID: "tinyfix-fixture"))
    }

    @Test("Scorer evidence includes KEEP and is bounded before constructing more contexts")
    func boundedWordDecisions() throws {
        try withWordEvidenceLog {
            let run = FlowRunCollector(kind: "dictation", id: "bounded-evidence", app: nil, input: "their moon is square")
            let evidence = try wordEvidence()
            #expect(run.canCollectWordDecision)
            for _ in 0..<(WordDecisionEvidence.maxPerRun + 10) { run.wordDecision(evidence) }
            #expect(!run.canCollectWordDecision)
            #expect(run.snapshot.wordDecisions?.count == WordDecisionEvidence.maxPerRun)
            run.finish(outcome: "verified", output: "their moon is square")
            FlowRunLog.flush()
            let saved = try #require(FlowRunLog.readAll().first)
            #expect(saved.wordDecisions?.count == WordDecisionEvidence.maxPerRun)
            #expect(saved.wordDecisions?.first?.chosenIndex == 0)
        }
    }

    @Test("Malformed or late scorer evidence never enters a finished run")
    func invalidAndLateWordDecisions() throws {
        try withWordEvidenceLog {
            let run = FlowRunCollector(kind: "dictation", id: "late-evidence", app: nil, input: "their moon is square")
            var evidence = try wordEvidence()
            evidence.candidates[1].rawScore = .nan
            run.wordDecision(evidence)
            #expect(run.snapshot.wordDecisions == nil)
            run.wordDecision(try wordEvidence())
            let finished = try #require(run.finish(outcome: "verified", output: "their moon is square"))
            #expect(!run.canCollectWordDecision)
            run.wordDecision(try wordEvidence())
            #expect(run.snapshot == finished)
        }
    }

    @Test("Privacy and run-record opt-out stop collection as well as disk writes")
    func optedOutWordDecisions() throws {
        try withWordEvidenceLog {
            let run = FlowRunCollector(kind: "dictation", id: "private-evidence", app: nil, input: "their moon is square")
            let evidence = try wordEvidence()
            UserDefaults.standard.set(true, forKey: "voice.privacyMode")
            #expect(!run.canCollectWordDecision)
            run.wordDecision(evidence)
            #expect(run.snapshot.wordDecisions == nil)
            UserDefaults.standard.set(false, forKey: "voice.privacyMode")
            UserDefaults.standard.set(false, forKey: FlowRunLog.preference)
            #expect(!run.canCollectWordDecision)
            run.wordDecision(evidence)
            #expect(run.snapshot.wordDecisions == nil)
            run.finish(outcome: "verified", output: "their moon is square")
            FlowRunLog.flush()
            #expect(!FileManager.default.fileExists(atPath: FlowRunLog.fileURL.path))
        }
    }

    @Test("A directly constructed record cannot write unbounded or non-finite scorer observations")
    func writerBoundsWordEvidence() throws {
        try withWordEvidenceLog {
            var record = FlowRunRecord(kind: "dictation", id: "direct-evidence", recordedAt: Date(), input: "their moon is square")
            var invalid = try wordEvidence()
            invalid.margin = .infinity
            record.wordDecisions = [invalid] + Array(repeating: try wordEvidence(), count: WordDecisionEvidence.maxPerRun + 10)
            FlowRunLog.append(record, synchronously: true)
            let saved = try #require(FlowRunLog.readAll().first)
            #expect(saved.input == record.input)
            #expect(saved.wordDecisions?.count == WordDecisionEvidence.maxPerRun - 1)
            #expect(saved.wordDecisions?.allSatisfy(\.isValid) == true)
        }
    }
}
