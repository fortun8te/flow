import FluidAudio
import Foundation
import Testing
@testable import Voice

@Suite("Pill glow progress: honest, smooth, never backwards")
struct PillGlowTrackTests {
    @Test("Time-based progress reaches 90 % at the estimate and keeps moving, slower, without reaching full")
    func timeCurve() {
        let track = PillGlowTrack(kind: .dictation, start: 100, expected: 2)
        #expect(track.value(at: 100) == 0)
        #expect(abs(track.value(at: 102) - PillGlowTrack.knee) < 1e-9)
        var last = 0.0
        var lastStep = Double.infinity
        for i in 1...200 {
            let v = track.value(at: 100 + Double(i) * 0.05)
            #expect(v >= last)
            #expect(v < 1)
            if i > 45 { #expect(v - last <= lastStep + 1e-9) }   // past the estimate: each step no bigger than the last
            lastStep = v - last
            last = v
        }
        // Overrunning 3x: still below the ceiling but clearly past the knee, so it never sits still at 99 %.
        let late = track.value(at: 106)
        #expect(late > PillGlowTrack.knee && late < PillGlowTrack.ceiling)
        #expect(track.value(at: 106.5) > late)
    }

    @Test("Token progress eases toward streamed / expected and never moves back")
    func tokens() {
        var track = PillGlowTrack(kind: .polish, start: 0, expected: 3)
        track.report(fraction: 0.5, at: 0.4)
        let target = PillGlowTrack.tokenValue(0.5)
        let soon = track.value(at: 0.45)
        #expect(soon < target)
        #expect(abs(track.value(at: 2.0) - target) < 0.01)
        let before = track.value(at: 2.0)
        track.report(fraction: 0.2, at: 2.0)     // a lower report must not pull the bar back
        #expect(track.value(at: 2.5) >= before)
        // At the token ceiling the bar keeps creeping instead of freezing.
        track.report(fraction: TypoFixProgress.ceiling, at: 3)
        #expect(track.value(at: 8) > track.value(at: 4))
        #expect(track.value(at: 60) <= PillGlowTrack.ceiling)
    }

    @Test("A cold model holds the bar low, and the model coming up continues from where it was")
    func loading() {
        var track = PillGlowTrack(kind: .polish, start: 0, expected: 1)
        track.setLoading(true, at: 0)
        #expect(track.value(at: 5) <= PillGlowTrack.loadingCap)
        let held = track.value(at: 5)
        track.setLoading(false, at: 5)
        #expect(abs(track.value(at: 5) - held) < 0.01)
        #expect(track.value(at: 5.5) > held)
    }

    @Test("Completion sweeps to full in 160 ms with a flash, then the pill may move on")
    func completion() {
        var track = PillGlowTrack(kind: .dictation, start: 0, expected: 1)
        track.complete(at: 0.5)
        let from = track.value(at: 0.5)
        #expect(track.frame(at: 0.5).fill == from)
        #expect(abs(track.frame(at: 0.5 + PillGlowTrack.sweepSeconds).fill - 1) < 1e-9)
        #expect(track.frame(at: 0.5 + PillGlowTrack.sweepSeconds).flash > 0.9)
        #expect(track.frame(at: 0.75).flash < 0.5)
        #expect(!track.isFinished(at: 0.6))
        #expect(!track.isFinished(at: 0.5 + PillGlowTrack.holdSeconds - 0.01))
        #expect(track.isFinished(at: 0.5 + PillGlowTrack.holdSeconds + 0.001))
        #expect(PillGlowTrack.holdSeconds <= 0.2)
    }

    @Test("Learned timings: a robust line by words, words per second, and the token ratio")
    func timings() throws {
        let suite = "flow.glow.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = PillWorkTiming.dictationSeconds(audioSeconds: 10, defaults: defaults)
        #expect(fresh > 0.25 && fresh < 2)
        for words in stride(from: 10, through: 120, by: 10) {
            PillWorkTiming.recordDictation(words: words, audioSeconds: Double(words) / 3,
                                           seconds: 0.4 + 0.01 * Double(words), defaults: defaults)
        }
        PillWorkTiming.recordDictation(words: 50, audioSeconds: 16, seconds: 9, defaults: defaults)   // one outlier
        let line = PillWorkTiming.fit(PillWorkTiming.samples(PillWorkTiming.dictationKey, defaults: defaults), fallback: (0.35, 0.012))
        #expect(abs(line.b - 0.01) < 0.004)
        #expect(abs(PillWorkTiming.wordsPerSecond(PillWorkTiming.samples(PillWorkTiming.dictationKey, defaults: defaults)) - 3) < 0.2)
        let estimate = PillWorkTiming.dictationSeconds(audioSeconds: 20, defaults: defaults)   // about 60 words
        #expect(abs(estimate - 1.0) < 0.25)

        #expect(PillWorkTiming.tokenRatio(defaults: defaults) == 1)
        for _ in 0..<30 { PillWorkTiming.recordTokenRatio(input: 100, output: 120, defaults: defaults) }
        #expect(abs(PillWorkTiming.tokenRatio(defaults: defaults) - 1.2) < 0.01)
    }

    @Test("The token meter expects input tokens times the learned ratio")
    func meterRatio() {
        let meter = TypoFixProgress(chunks: 1, ratio: 1.5, report: { _ in })
        meter.expect(0, tokens: 10)
        for _ in 0..<15 { meter.streamed(0) }
        #expect(meter.totals().input == 10)
        #expect(meter.totals().streamed == 15)
        #expect(TypoFixProgress.fraction(streamed: [15], expected: [15]) == TypoFixProgress.ceiling)
    }

    @Test("The bar runs along the long side: left to right, or bottom to top on a tall body")
    func geometry() {
        let wide = PillGlowGeometry.fillRect(CGSize(width: 100, height: 30), fill: 0.5)
        #expect(wide.minX == 3 && abs(wide.width - 47) < 1e-9 && wide.height == 24)
        let tall = PillGlowGeometry.fillRect(CGSize(width: 30, height: 100), fill: 0.25)
        #expect(tall.maxY == 97 && abs(tall.height - 23.5) < 1e-9 && tall.width == 24)
    }
}

@Suite("Flow run records for training", .serialized)
struct FlowRunLogTests {
    private func withTempLog(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flow-runs-" + UUID().uuidString)
        FlowRunLog.directoryOverride = dir
        let (bytes, keep) = (FlowRunLog.maxFileBytes, FlowRunLog.keepRotated)
        defer {
            FlowRunLog.directoryOverride = nil
            FlowRunLog.maxFileBytes = bytes
            FlowRunLog.keepRotated = keep
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    @Test("A dictation record keeps input, ASR words, each stage with its changes, decisions and the output")
    func dictationRecord() throws {
        try withTempLog { dir in
            let run = FlowRunCollector(kind: "dictation", id: "s1", app: "com.apple.Notes", input: nil)
            run.update {
                $0.input = "um so i think their going"
                $0.asrWords = [ASRWordConfidence(word: "their", confidence: 0.41, start: 1.2, end: 1.4)]
            }
            run.setBaseline("um so i think their going")
            run.stage("rules", text: "Um so I think their going.", ms: 1)
            run.stage("cleanup", text: "I think their going.", ms: 220, detail: ["route": "local"])
            run.decision("tinynext", "their -> they're", reason: "score margin 0.400")
            run.stage("tinynext", text: "I think they're going.")
            run.model("cleanup", "dose1-t4")
            let written = run.finish(outcome: "verified", output: "I think they're going.", fallback: nil)
            #expect(written != nil)
            #expect(run.finish(outcome: "again", output: nil) == nil)   // written once
            FlowRunLog.flush()
            let all = FlowRunLog.readAll()
            #expect(all.count == 1)
            let record = try #require(all.first)
            #expect(record.kind == "dictation" && record.id == "s1" && record.app == "com.apple.Notes")
            #expect(record.asrWords?.first?.confidence == 0.41)
            #expect(record.stages.map(\.name) == ["rules", "cleanup", "tinynext"])
            #expect(record.stages[2].changes == ["their -> they're"])
            #expect(record.decisions.first?.stage == "tinynext")
            #expect(record.models["cleanup"] == "dose1-t4")
            #expect(record.output == "I think they're going.")
            #expect(record.timingsMs["totalMs"] != nil)
            // Excluded from backups (iCloud and Time Machine).
            let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
        }
    }

    @Test("Follow-ups link back by id, and the task-local collector catches deep stages")
    func followupsAndTaskLocal() async throws {
        try await withTempLogAsync {
            let run = FlowRunCollector(kind: "opt1", id: "op1", app: nil, input: "teh cat")
            await FlowRunCollector.$current.withValue(run) {
                await Task.yield()
                FlowRunCollector.stage("opt1.model", text: "the cat", ms: 80)
                FlowRunCollector.decision("opt1.referee", "kept-typed", reason: "x")
            }
            FlowRunCollector.stage("outside", text: "ignored")   // no run: nothing happens
            run.finish(outcome: "applied", output: "the cat")
            FlowRunLog.followup(id: "op1", kind: "opt1", followup: "undo")
            FlowRunLog.flush()
            let all = FlowRunLog.readAll()
            try #require(all.count == 2)
            #expect(all[0].stages.first?.changes == ["teh -> the"])
            #expect(all[1].kind == "followup" && all[1].id == "op1" && all[1].followup == "undo")
        }
    }

    private func withTempLogAsync(_ body: () async throws -> Void) async rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flow-runs-" + UUID().uuidString)
        FlowRunLog.directoryOverride = dir
        defer { FlowRunLog.directoryOverride = nil; try? FileManager.default.removeItem(at: dir) }
        try await body()
    }

    @Test("The file rotates at its cap and keeps only the newest rotated files")
    func rotation() throws {
        try withTempLog { _ in
            FlowRunLog.maxFileBytes = 600
            FlowRunLog.keepRotated = 2
            for i in 0..<12 {
                FlowRunLog.append(FlowRunRecord(kind: "opt1", id: "r\(i)", recordedAt: Date(), input: String(repeating: "x", count: 200)),
                                  synchronously: true)
            }
            #expect(FlowRunLog.rotatedFiles().count <= 2)
            let ids = FlowRunLog.readAll().map(\.id)
            #expect(ids.last == "r11")
            #expect(!ids.contains("r0"))
        }
    }

    @Test("Word changes group runs of replaced words")
    func diff() {
        #expect(FlowRunDiff.changes(from: "a b c d", to: "a x c d") == ["b -> x"])
        #expect(FlowRunDiff.changes(from: "um so a b", to: "a b") == ["um so -> "])
        #expect(FlowRunDiff.changes(from: "a b", to: "a b") == [])
        #expect(FlowRunDiff.changes(from: "a b", to: "a\nb") == ["(spacing or line breaks)"])
    }

    @Test("ASR pieces become words with the lowest confidence of their pieces")
    func asrWords() {
        let timings = [
            TokenTiming(token: "\u{2581}hel", tokenId: 0, startTime: 0.1, endTime: 0.2, confidence: 0.9),
            TokenTiming(token: "lo", tokenId: 1, startTime: 0.2, endTime: 0.3, confidence: 0.5),
            TokenTiming(token: "\u{2581}there", tokenId: 2, startTime: 0.4, endTime: 0.6, confidence: 0.97),
        ]
        let words = TranscriptionService.wordConfidences(from: timings)
        #expect(words?.map(\.word) == ["hello", "there"])
        #expect(words?.first?.confidence == 0.5)
        #expect(words?.first?.start == 0.1 && words?.first?.end == 0.3)
    }
}

@Suite("The pill follows the pointer between screens")
struct PillScreenFollowerTests {
    let left = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let right = CGRect(x: 1512, y: -200, width: 2560, height: 1440)

    @Test("The screen under the pointer, with the nearest screen for a point on an outer edge")
    func screenChoice() {
        #expect(PillScreenFollower.screenIndex(for: CGPoint(x: 100, y: 100), frames: [left, right]) == 0)
        #expect(PillScreenFollower.screenIndex(for: CGPoint(x: 1600, y: 1000), frames: [left, right]) == 1)
        #expect(PillScreenFollower.screenIndex(for: CGPoint(x: 1512, y: 500), frames: [left, right]) == 1)
        #expect(PillScreenFollower.screenIndex(for: CGPoint(x: -3, y: 500), frames: [left, right]) == 0)
        #expect(PillScreenFollower.screenIndex(for: CGPoint(x: 0, y: 0), frames: []) == nil)
    }

    @Test("A quick pass across the edge does not move the pill; staying 70 ms does")
    func debounce() {
        var f = PillScreenFollower()
        #expect(f.observe(pointerScreen: 1, at: 0) == 1)            // first placement
        #expect(f.observe(pointerScreen: 2, at: 1.00) == nil)
        #expect(f.pendingDelay(at: 1.00) == PillScreenFollower.dwell)
        #expect(f.observe(pointerScreen: 1, at: 1.04) == nil)       // back within 40 ms: no switch
        #expect(f.current == 1)
        #expect(f.observe(pointerScreen: 2, at: 2.00) == nil)
        #expect(f.observe(pointerScreen: 2, at: 2.08) == 2)         // stayed 70 ms: switch
        #expect(f.current == 2)
    }

    @Test("Going straight back to the screen just left needs a longer stay, so it cannot ping-pong")
    func pingPong() {
        var f = PillScreenFollower()
        _ = f.observe(pointerScreen: 1, at: 0)
        _ = f.observe(pointerScreen: 2, at: 1)
        #expect(f.observe(pointerScreen: 2, at: 1.08) == 2)
        #expect(f.observe(pointerScreen: 1, at: 1.10) == nil)
        #expect(f.observe(pointerScreen: 1, at: 1.20) == nil)       // 100 ms back: still waits
        #expect(f.observe(pointerScreen: 1, at: 1.24) == 1)         // 140 ms back: switches
        // Long after the switch, the short dwell applies again.
        _ = f.observe(pointerScreen: 2, at: 5)
        #expect(f.observe(pointerScreen: 2, at: 5.08) == 2)
    }

    @Test("Docks stay below the notch and on whole pixels of each screen")
    func notchAndScaling() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // Menu bar hidden: the visible frame reaches the top, the notch does not.
        let usable = PillLayout.usableFrame(visible: frame, frame: frame, notchInset: 32)
        #expect(usable.maxY == 950)
        #expect(PillLayout.usableFrame(visible: frame, frame: frame, notchInset: 0) == frame)
        let top = PillLayout.panelOrigin(dock: .top, sideFraction: nil, visible: usable, bottomY: 0)
        #expect(top.y + PillLayout.panelSize.height <= 950)
        #expect(PillLayout.pixelAligned(CGPoint(x: 10.3, y: 4.74), scale: 2) == CGPoint(x: 10.5, y: 4.5))
        #expect(PillLayout.pixelAligned(CGPoint(x: 10.3, y: 4.74), scale: 1) == CGPoint(x: 10, y: 5))
    }
}
