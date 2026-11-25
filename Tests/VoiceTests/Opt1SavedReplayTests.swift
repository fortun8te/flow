import Foundation
import XCTest
@testable import Voice

final class Opt1SavedReplayTests: XCTestCase {
    private struct Draft: Decodable {
        let id: String
        let input: String
    }

    private struct Result: Encodable {
        let id: String
        let delivered: String?
        let preview: Bool
        let routedMs: UInt64
        let rejection: String?
    }

    /// Opt-in local replay. Exercises the actual shortcut router and locally
    /// installed models without opening the application or recording audio.
    @MainActor
    func testSavedDrafts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["FLOW_OPT1_SAVED_REPLAY_INPUT"],
              let output = environment["FLOW_OPT1_SAVED_REPLAY_OUTPUT"] else {
            throw XCTSkip("Set both saved replay paths to run the local benchmark.")
        }
        let drafts = try JSONDecoder().decode([Draft].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        guard (1...6).contains(drafts.count), drafts.allSatisfy({
            !$0.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !PolishTransaction.isTooLong($0.input)
        }) else {
            XCTFail("Expected one to six valid drafts.")
            return
        }
        let file = URL(fileURLWithPath: output)
        let parent = file.deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        let mode = attributes[.posixPermissions] as? NSNumber
        guard let mode, mode.intValue & 0o077 == 0 else {
            XCTFail("Choose a private output directory with mode 0700.")
            return
        }

        var results: [Result] = []
        for draft in drafts {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = await Qwen3Polisher.shared.polishShortcut(draft.input)
            let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            results.append(Result(id: draft.id, delivered: result.text, preview: result.preview,
                routedMs: elapsed, rejection: result.text == nil ? Qwen3Polisher.lastSelectedRejection : nil))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
