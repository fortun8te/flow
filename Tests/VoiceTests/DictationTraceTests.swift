import Foundation
import Testing
@testable import Voice

@Suite("Dictation trace and the 1.5 s cleanup deadline")
struct DictationTraceTests {
    @Test("The deadline gives the model what is left of 1.8 s since key release")
    func remainingBudget() {
        #expect(DictationDeadline.remainingSeconds(sinceKeyRelease: 0.2) == 1.6)
        #expect(DictationDeadline.remainingSeconds(sinceKeyRelease: 0) == 1.8)
        // Never zero or negative: a model that is already late still gets a moment, then the rules win.
        #expect(DictationDeadline.remainingSeconds(sinceKeyRelease: 2.0) == 0.05)
    }

    @Test("A fast answer is returned")
    func fastAnswerWins() async {
        let value = await DictationDeadline.run(seconds: 1.0) { "polished" }
        #expect(value == "polished")
    }

    @Test("A slow answer is dropped at the deadline, without waiting for it")
    func slowAnswerLoses() async {
        let started = Date()
        let value: String? = await DictationDeadline.run(seconds: 0.1) {
            // Ignores cancellation, like a stuck decoder. The deadline must still return on time.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return "late"
        }
        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test("A missed deadline cancels work so the cleanup engine can take the next request")
    func deadlineCancelsWork() async {
        let (events, reporter) = AsyncStream<Bool>.makeStream()
        let result = await DictationDeadline.run(seconds: 0.04) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch {}
            reporter.yield(Task.isCancelled)
            reporter.finish()
            return "late"
        }
        var next = events.makeAsyncIterator()
        #expect(result == nil)
        #expect(await next.next() == true)
    }

    @Test("Each trace event is one JSON line with stage times and no text")
    func traceRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        DictationTraceLog.directoryOverride = folder
        defer {
            DictationTraceLog.directoryOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let first = DictationTrace(engine: "dose1-t1", engineReady: true, fallbackReason: nil,
                                   level: "light", style: "excited",
                                   stagesMs: ["transcriptAtMs": 300, "rulesMs": 2, "modelMs": 210, "pasteSentAtMs": 540],
                                   pasteVerdict: nil, recordedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DictationTrace(engine: "off", engineReady: false, fallbackReason: "deadline",
                                    level: "none", style: "neutral", stagesMs: ["pasteSentAtMs": 120],
                                    pasteVerdict: "landed", recordedAt: Date(timeIntervalSince1970: 1_800_000_100))
        DictationTraceLog.append(first)
        DictationTraceLog.append(second)

        let raw = try String(contentsOf: DictationTraceLog.fileURL, encoding: .utf8)
        #expect(raw.split(separator: "\n").count == 2)
        #expect(!raw.contains("transcript\""))
        #expect(DictationTraceLog.readAll().map(\.engine) == ["dose1-t1", "off"])
        #expect(DictationTraceLog.readAll().last?.fallbackReason == "deadline")
    }
}
