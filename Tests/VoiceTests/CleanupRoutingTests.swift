import Foundation
import Testing
@testable import Voice

@Suite("Cleanup polish context and the replay trace")
struct CleanupRoutingTests {
    @Test("Code apps get the polish context .code, as live")
    func codeContext() {
        for bundle in ["dev.warp.Warp-Stable", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal",
                       "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.jetbrains.pycharm", "dev.zed.Zed"] {
            #expect(CursorPaster.polishContext(forBundleID: bundle) == .code, "\(bundle)")
        }
        #expect(CursorPaster.polishContext(forBundleID: "com.tinyspeck.slackmacgap") == .messaging)
        #expect(CursorPaster.polishContext(forBundleID: "com.apple.mail") == .email)
        #expect(CursorPaster.polishContext(forBundleID: "com.t3tools.t3code") == .default)
        #expect(CursorPaster.polishContext(forBundleID: nil) == .default)
    }

    @Test("The S1 guard still protects literal code spans and paths")
    func codeSpansProtected() {
        let source = "run git status in /Users/example/Projects/flow and check `swift build` on getUserName"
        #expect(S1MiniPolisher.assess(candidate: "Run git status in the flow project and check swift build on getUserName.",
                                      original: source) == .rejected(.protectedContentChanged))
        #expect(S1MiniPolisher.assess(candidate: "Run git status in /Users/example/Projects/flow and check `swift build` on get user name.",
                                      original: source) == .rejected(.protectedContentChanged))
        if case .accepted = S1MiniPolisher.assess(
            candidate: "Run git status in /Users/example/Projects/flow and check `swift build` on getUserName.",
            original: source) {} else { Issue.record("a faithful cleanup must be accepted") }
    }

    @Test("Observer records the control line S1 got and derives the route")
    func observerRoute() {
        let observer = ShadowCleanupObserver()
        #expect(observer.route == nil)
        observer.s1(input: "so um hi", result: .accepted("Hi."), guardRefused: false,
                    controlLine: S1MiniPolisher.Options().controlLine)
        #expect(observer.route == "s1")
        #expect(observer.controlLine == "[Styling: semi-formal] [Structure: prose] [Context: general]")
        #expect(observer.result == "accepted")

        observer.s1(input: "hallo daar", result: .unavailable(.unsupportedLanguage), guardRefused: false)
        #expect(observer.route == "skip:unsupportedLanguage")

        observer.s1(input: "x y z w", result: .accepted("X."), guardRefused: true)
        #expect(observer.route == "s1")
        #expect(observer.result == "rejected:output_guard")

        observer.skipped(input: "ls -la", reason: "code-context")
        #expect(observer.route == "skip:code-context")
        #expect(observer.controlLine == nil)

        #expect(ShadowCleanupObserver.route(engine: "local:qwen3", result: "accepted") == "skip:engine-local:qwen3")
        #expect(ShadowCleanupObserver.route(engine: "rules", result: "unavailable:short_clip") == "skip:short_clip")
    }

    @Test("Shadow record carries route and s1_control_line as optional schema-1 keys")
    func shadowRecordKeys() throws {
        var record = ShadowRecord(
            id: "0b3d2c4e-1111-4222-8333-944455556666", startedAt: "2026-11-13T14:38:21.512Z",
            endedAt: "2026-11-13T14:38:43.020Z", durationS: 21.51, gesture: "hold", frontApp: "dev.warp.Warp-Stable",
            audio: "audio/2026-11-13/x.wav", audioSHA256: String(repeating: "a", count: 64),
            asrModel: "parakeet-ultra@95eaa59a", parakeetRaw: "so um list the files", asrMs: 300,
            cleanupInput: "So list the files", cleanupEngine: "local:s1-mini", cleanupResult: "accepted",
            cleanupMs: 90, flowCleaned: "List the files.", languageGuess: "en", flowBuild: "e2470c0406",
            route: "s1", s1ControlLine: "[Styling: semi-formal] [Structure: prose] [Context: general]")
        var object = try #require(JSONSerialization.jsonObject(with: record.jsonLine()) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(object["route"] as? String == "s1")
        #expect(object["s1_control_line"] as? String == "[Styling: semi-formal] [Structure: prose] [Context: general]")
        #expect(try JSONDecoder().decode(ShadowRecord.self, from: record.jsonLine()) == record)

        record.route = "skip:non-english"
        record.s1ControlLine = nil
        object = try #require(JSONSerialization.jsonObject(with: record.jsonLine()) as? [String: Any])
        #expect(object["route"] as? String == "skip:non-english")
        #expect(!object.keys.contains("s1_control_line"))

        // Lines written before 13 Nov 2026 have neither key and still decode.
        let old = #"{"schema":1,"id":"a","started_at":"s","ended_at":"e","duration_s":1,"gesture":"hold","front_app":null,"audio":"a.wav","audio_sha256":"x","sample_rate":16000,"asr_model":"m","parakeet_raw":"r","asr_ms":1,"cleanup_input":"r","cleanup_engine":"rules","cleanup_result":"unavailable:code-context","cleanup_ms":0,"flow_cleaned":"r","language_guess":"en","flow_build":"b"}"#
        let decoded = try JSONDecoder().decode(ShadowRecord.self, from: Data(old.utf8))
        #expect(decoded.route == nil && decoded.s1ControlLine == nil)
    }

    @Test("Replay outcome labels follow the --cleanup-run vocabulary")
    func runLabels() {
        let skipped = CleanupReplayHarness.Outcome(final: "x", route: "skip:non-english", input: "x", controlLine: nil,
                                                   result: "unavailable:non-english", engine: "rules", cleanupMs: 1)
        #expect(skipped.runResultLabel == "skipped:non-english")
        let off = CleanupReplayHarness.Outcome(final: "x", route: "skip:polish-off", input: nil, controlLine: nil,
                                               result: nil, engine: nil, cleanupMs: 0)
        #expect(off.runResultLabel == "skipped:polish-off")
        let accepted = CleanupReplayHarness.Outcome(final: "X.", route: "s1", input: "x", controlLine: "c",
                                                    result: "accepted", engine: "local:s1-mini", cleanupMs: 80)
        #expect(accepted.runResultLabel == "accepted")
    }
}
