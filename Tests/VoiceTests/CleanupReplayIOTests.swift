import Foundation
import XCTest
@testable import Voice

final class CleanupReplayIOTests: XCTestCase {
    private struct Job: Codable { let id: String; let text: String }
    private struct Configuration: Codable {
        var input: String? = nil
        var output: String? = nil
        var limit: Int? = nil
        var liveFinish: Bool? = nil
        var allowConcurrent: Bool? = nil
        enum CodingKeys: String, CodingKey {
            case input, output, limit
            case liveFinish = "live_finish", allowConcurrent = "allow_while_flow_running"
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flow-replay-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testJSONLUsesLFBytesAndPreservesLiteralUnicodeSeparators() throws {
        let source = "{\"id\":\"one\",\"text\":\"A\u{2028}B\u{2029}C\u{85}D\"}\r\n\t\r\n{\"id\":\"two\",\"text\":\"\\n\\n\"}\n"
        let jobs: [Job] = try CleanupReplayIO.decode(Data(source.utf8))
        XCTAssertEqual(jobs.map(\.id), ["one", "two"])
        XCTAssertEqual(jobs[0].text, "A\u{2028}B\u{2029}C\u{85}D")
        XCTAssertEqual(jobs[1].text, "\n\n")
    }

    func testMalformedInputReportsPhysicalLineWithoutTranscriptContents() throws {
        let source = "{\"id\":\"one\",\"text\":\"invented-private-phrase\"}\n\n{\"id\":\"two\","
        XCTAssertThrowsError(try CleanupReplayIO.decode(Data(source.utf8)) as [Job]) { error in
            XCTAssertTrue(error.localizedDescription.contains("line 3"))
            XCTAssertFalse(error.localizedDescription.contains("invented-private-phrase"))
        }
    }

    func testInputIdentifiersMustBePresentAndUnique() throws {
        try CleanupReplayIO.validateIDs(["one", "two"])
        XCTAssertThrowsError(try CleanupReplayIO.validateIDs(["one", "one"]))
        XCTAssertThrowsError(try CleanupReplayIO.validateIDs([" \n"]))
    }

    func testExplicitCleanupModelsAreValidatedInsteadOfFallingBackToAnotherEngine() throws {
        XCTAssertNil(try CleanupReplayIO.canonicalCleanupModel(nil))
        XCTAssertEqual(try CleanupReplayIO.canonicalCleanupModel("whispernow-tuned"), "dose1")
        for model in ["s1-mini", "qwen3", "dose1"] {
            XCTAssertEqual(try CleanupReplayIO.canonicalCleanupModel(model), model)
        }
        for model in ["", "unknown-model", "S1-mini", "qwen3 "] {
            XCTAssertThrowsError(try CleanupReplayIO.canonicalCleanupModel(model))
        }
    }

    func testReadMissingInputIsAnErrorAndMissingOutputIsAnEmptyResume() throws {
        let url = try temporaryDirectory().appendingPathComponent("missing.jsonl")
        XCTAssertThrowsError(try CleanupReplayIO.inputData(at: url))
        XCTAssertEqual(try CleanupReplayIO.completedIDs(at: url, replayKey: "same") { _ in true }, [])
    }

    func testOnlyOneReplayOwnsAnOutputAndReleaseAllowsResume() throws {
        let url = try temporaryDirectory().appendingPathComponent("run.jsonl")
        let first = try CleanupReplayIO.OutputLease(at: url)
        XCTAssertThrowsError(try CleanupReplayIO.OutputLease(at: url))
        try CleanupReplayIO.append(["id": "one", "final": "Complete."], to: url)
        first.release()
        first.release()
        let resumed = try CleanupReplayIO.OutputLease(at: url)
        resumed.release()
        XCTAssertEqual(try CleanupReplayIO.completedIDs(at: url) { _ in true }, ["one"])
    }

    func testResumeOnlyAcceptsMatchingIdentityAndCompletedRows() throws {
        let url = try temporaryDirectory().appendingPathComponent("run.jsonl")
        try CleanupReplayIO.append(["id": "one", "replay_key": "same", "status": "error"], to: url)
        try CleanupReplayIO.append(["id": "one", "replay_key": "same", "status": "ok", "text": "A\u{2028}B"], to: url)
        try CleanupReplayIO.append(["id": "two", "replay_key": "same", "status": "error"], to: url)
        XCTAssertEqual(try CleanupReplayIO.completedIDs(at: url, replayKey: "same") { $0["status"] as? String == "ok" }, ["one"])
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try CleanupReplayIO.completedIDs(at: url, replayKey: "changed") { _ in true })
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testLegacyOutputAndRepeatedSuccessfulIDsCannotBeSilentlyResumed() throws {
        let url = try temporaryDirectory().appendingPathComponent("run.jsonl")
        try CleanupReplayIO.append(["id": "one", "final": "Text."], to: url)
        XCTAssertThrowsError(try CleanupReplayIO.completedIDs(at: url, replayKey: "new") { _ in true })
        try CleanupReplayIO.append(["id": "one", "final": "Other text."], to: url)
        XCTAssertThrowsError(try CleanupReplayIO.completedIDs(at: url) { _ in true })
    }

    func testCorruptResumeIsRefusedWithoutDestroyingTheOriginalBytes() throws {
        let url = try temporaryDirectory().appendingPathComponent("run.jsonl")
        let broken = Data("{\"id\":\"one\",\"final\":\"Good\"}\n{\"id\":\"two\",".utf8)
        try broken.write(to: url)
        XCTAssertThrowsError(try CleanupReplayIO.completedIDs(at: url) { _ in true })
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testAppendSeparatesCrashTailAndTightensExistingPermissions() throws {
        let folder = try temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let url = folder.appendingPathComponent("run.jsonl")
        let broken = Data("{\"id\":\"interrupted\",".utf8)
        try broken.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try CleanupReplayIO.append(["id": "new", "final": "\n\n"], to: url)
        let contents = try Data(contentsOf: url)
        XCTAssertEqual(contents.prefix(broken.count), broken)
        XCTAssertEqual(contents[broken.count], 0x0A)
        XCTAssertEqual(contents.last, 0x0A)
        let lines = contents.split(separator: 0x0A)
        let tail = try JSONSerialization.jsonObject(with: Data(lines.last!)) as? [String: String]
        XCTAssertEqual(tail?["id"], "new")
        XCTAssertEqual(tail?["final"], "\n\n")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int, 0o755)
    }

    func testNewReplayDirectoryIsPrivateWithoutChangingItsExistingParent() throws {
        let parent = try temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        let folder = parent.appendingPathComponent("new-output")
        let url = folder.appendingPathComponent("run.jsonl")
        let lease = try CleanupReplayIO.OutputLease(at: url)
        defer { lease.release() }
        try CleanupReplayIO.append(["id": "one"], to: url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    func testReplayReadAndWriteNeverFollowAnOutputSymlink() throws {
        let folder = try temporaryDirectory()
        let source = folder.appendingPathComponent("original.jsonl")
        let link = folder.appendingPathComponent("link.jsonl")
        let original = Data("{\"id\":\"original\",\"text\":\"Keep me.\"}\n".utf8)
        try original.write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try CleanupReplayIO.inputData(at: link))
        XCTAssertThrowsError(try CleanupReplayIO.completedIDs(at: link) { _ in true })
        XCTAssertThrowsError(try CleanupReplayIO.append(["id": "replacement"], to: link))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testResumeIdentityIgnoresOperationalCapsButBindsTheExperiment() throws {
        func identity(config: String = "{\"input\":\"one\",\"output\":\"two\",\"limit\":5,\"live_finish\":true}",
                      input: String = "input-hash", settings: [String: Any] = ["fmt_breaks": true],
                      executable: String = "executable-hash", artifacts: [String: String] = ["audio": "bytes-hash"]) throws -> Data {
            let configuration = try JSONDecoder().decode(Configuration.self, from: Data(config.utf8))
            return try CleanupReplayIO.identityData(mode: "run", configuration: configuration, inputHash: input,
                settings: settings, executableHash: executable, artifacts: artifacts)
        }
        let original = try identity()
        XCTAssertEqual(original, try identity(config: "{\"live_finish\":true,\"input\":\"elsewhere\",\"output\":\"new\",\"limit\":50,\"allow_while_flow_running\":false}"))
        XCTAssertNotEqual(original, try identity(config: "{\"live_finish\":false}"))
        XCTAssertNotEqual(original, try identity(input: "changed-input"))
        XCTAssertNotEqual(original, try identity(settings: ["fmt_breaks": false]))
        XCTAssertNotEqual(original, try identity(executable: "new-build"))
        XCTAssertNotEqual(original, try identity(artifacts: ["audio": "replaced-bytes"]))
    }

    func testPreferenceIdentityRetainsBinaryAndDateValuesCanonically() throws {
        let first: [String: Any] = ["data": Data([0, 1, 2]), "date": Date(timeIntervalSince1970: 123),
                                   "nested": ["b": 2, "a": 1]]
        let second: [String: Any] = ["nested": ["a": 1, "b": 2], "date": Date(timeIntervalSince1970: 123),
                                    "data": Data([0, 1, 2])]
        func encoded(_ settings: [String: Any]) throws -> Data {
            try CleanupReplayIO.identityData(mode: "run", configuration: Configuration(), inputHash: "input",
                settings: settings, executableHash: "build")
        }
        XCTAssertEqual(try encoded(first), try encoded(second))
        XCTAssertNotEqual(try encoded(first), try encoded(["data": Data([0, 1, 3]), "date": first["date"]!]))
        XCTAssertNotEqual(try encoded(["value": Data([1])]), try encoded(["value": ["$data": "AQ=="]]))
        XCTAssertNotEqual(try encoded(["value": Date(timeIntervalSince1970: 123)]), try encoded(["value": ["$date": 123]]))
        XCTAssertNotEqual(try encoded(["value": [1, 2]]), try encoded(["value": ["$array": [1, 2]]]))
    }

    func testConfigurationIdentityUsesTheDecodedBehaviorForDuplicateKeys() throws {
        let source = Data("{\"live_finish\":true,\"live_finish\":false}".utf8)
        let decoded = try JSONDecoder().decode(Configuration.self, from: source)
        func identity(_ config: Configuration) throws -> Data {
            try CleanupReplayIO.identityData(mode: "run", configuration: config, inputHash: "input",
                settings: [:], executableHash: "build")
        }
        let executed = try identity(decoded)
        let expected = try identity(Configuration(liveFinish: decoded.liveFinish))
        let different = try identity(Configuration(liveFinish: !(decoded.liveFinish ?? false)))
        XCTAssertEqual(executed, expected)
        XCTAssertNotEqual(executed, different)
    }

    func testStateIdentityDetectsFilePreferenceLearningAndExactSpellingChanges() throws {
        let url = try temporaryDirectory().appendingPathComponent("replacements.json")
        func snapshot(settings: [String: Any] = ["polishEnabled": true], revision: Int = 1,
                      vocabulary: [String] = ["Caf\u{e9}"]) throws -> Data {
            try CleanupReplayIO.stateIdentity(settings: settings, learnedRevision: revision,
                                               vocabulary: vocabulary, files: [url])
        }
        let missing = try snapshot()
        try Data("[]".utf8).write(to: url)
        let present = try snapshot()
        XCTAssertNotEqual(missing, present)
        XCTAssertEqual(present, try snapshot())
        XCTAssertNotEqual(present, try snapshot(settings: ["polishEnabled": false]))
        XCTAssertNotEqual(present, try snapshot(revision: 2))
        XCTAssertNotEqual(present, try snapshot(vocabulary: ["Cafe\u{301}"]))
        try Data("{}".utf8).write(to: url, options: .atomic)
        XCTAssertNotEqual(present, try snapshot())
    }
}
