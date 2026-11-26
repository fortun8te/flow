import Foundation
import Testing
@testable import Voice

extension FlowRunLogTests {
    private func withDurableLog(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-durable-log-" + UUID().uuidString)
        let defaults = UserDefaults.standard
        let privacy = defaults.object(forKey: "voice.privacyMode")
        let preference = defaults.object(forKey: FlowRunLog.preference)
        let oldDirectory = FlowRunLog.directoryOverride
        let bytes = FlowRunLog.maxFileBytes, keep = FlowRunLog.keepRotated
        FlowRunLog.flush()
        FlowRunLog.directoryOverride = directory
        defaults.set(false, forKey: "voice.privacyMode")
        defaults.set(true, forKey: FlowRunLog.preference)
        defer {
            FlowRunLog.flush()
            FlowRunLog.directoryOverride = oldDirectory
            FlowRunLog.maxFileBytes = bytes
            FlowRunLog.keepRotated = keep
            defaults.set(privacy, forKey: "voice.privacyMode")
            defaults.set(preference, forKey: FlowRunLog.preference)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }

    @Test("Non-finite ASR metadata stays unknown without dropping the run or its words")
    func invalidASRMetadataDoesNotDropRun() throws {
        try withDurableLog { _ in
            var record = FlowRunRecord(kind: "dictation", id: "synthetic-numbers", recordedAt: Date(), input: "violet kettle")
            record.audioSeconds = .infinity
            record.asrConfidence = .nan
            record.asrWords = [
                .init(word: "violet", confidence: .nan, start: -.infinity, end: .infinity),
                .init(word: "kettle", confidence: 1.2, start: 2, end: 1),
                .init(word: "lantern", confidence: 0.25, start: 3, end: 4),
            ]
            FlowRunLog.append(record, synchronously: true)
            let saved = try #require(FlowRunLog.readAll().first)
            #expect(saved.input == record.input)
            #expect(saved.audioSeconds == nil && saved.asrConfidence == nil)
            let words = try #require(saved.asrWords)
            #expect(words.count == 3)
            #expect(words[0] == .init(word: "violet", confidence: nil, start: nil, end: nil))
            #expect(words[1] == .init(word: "kettle", confidence: nil, start: nil, end: nil))
            #expect(words[2] == record.asrWords?[2])
        }
    }

    @Test("Unknown word confidence decodes without inventing a score")
    func missingWordConfidenceDecodes() throws {
        let word = try JSONDecoder().decode(ASRWordConfidence.self, from: Data("{\"word\":\"violet\",\"start\":1,\"end\":2}".utf8))
        #expect(word.confidence == nil)
        #expect(word.start == 1 && word.end == 2)
    }

    @Test("A truncated tail is preserved separately and later complete records remain readable")
    func truncatedRunLogTail() throws {
        try withDurableLog { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let interrupted = Data("{\"id\":\"interrupted".utf8)
            try interrupted.write(to: FlowRunLog.fileURL)
            FlowRunLog.append(FlowRunRecord(kind: "dictation", id: "complete", recordedAt: Date(), input: "violet kettle"), synchronously: true)
            #expect(FlowRunLog.readAll().map(\.id) == ["complete"])
            let bytes = try Data(contentsOf: FlowRunLog.fileURL)
            #expect(bytes.starts(with: interrupted + Data([0x0A])))
        }
    }

    @Test("A redirected log file never writes into its symlink target")
    func redirectedRunLogRefusesWrite() throws {
        try withDurableLog { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("original")
            try Data("retained fixture".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: FlowRunLog.fileURL, withDestinationURL: target)
            FlowRunLog.append(FlowRunRecord(kind: "dictation", id: "refused", recordedAt: Date()), synchronously: true)
            #expect(try Data(contentsOf: target) == Data("retained fixture".utf8))
        }
    }

    @Test("Rotation orders sequences numerically beyond six digits and retains the newest run")
    func numericRotationSequence() throws {
        try withDurableLog { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fixture\n".utf8).write(to: directory.appendingPathComponent("runs-999999-20200101-000000.jsonl"))
            try Data("fixture\n".utf8).write(to: directory.appendingPathComponent("runs-1000000-20200101-000001.jsonl"))
            FlowRunLog.maxFileBytes = 1
            FlowRunLog.keepRotated = 2
            FlowRunLog.append(FlowRunRecord(kind: "dictation", id: "before", recordedAt: Date()), synchronously: true)
            FlowRunLog.append(FlowRunRecord(kind: "dictation", id: "latest", recordedAt: Date()), synchronously: true)
            let names = FlowRunLog.rotatedFiles().map(\.lastPathComponent)
            #expect(names.count == 2)
            #expect(names[0].hasPrefix("runs-1000000-"))
            #expect(names[1].hasPrefix("runs-1000001-"))
            #expect(FlowRunLog.readAll().map(\.id) == ["before", "latest"])
        }
    }
}
