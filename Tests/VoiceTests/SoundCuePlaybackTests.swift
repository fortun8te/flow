import Testing
@testable import Voice

@Suite("Sound output recovery")
struct SoundCuePlaybackTests {
    private final class Output {
        var running = false
        var starts = 0
        var rebuilds = 0
        var played: [String] = []
        var completions: [() -> Void] = []
        var timeouts: [() -> Void] = []
        var failStart = false
        enum Failure: Error { case unavailable }

        func queue() -> SoundCuePlaybackQueue<String> {
            SoundCuePlaybackQueue(
                isRunning: { self.running },
                start: {
                    if self.failStart { throw Failure.unavailable }
                    self.starts += 1
                    self.running = true
                },
                play: { cue, complete in self.played.append(cue); self.completions.append(complete) },
                rebuild: { self.rebuilds += 1; self.running = false },
                duration: { _ in 0.2 },
                scheduleTimeout: { _, callback in self.timeouts.append(callback) }
            )
        }
    }

    @Test("A stopped output without a completion does not block the next sound")
    func lostCompletionAfterInterruption() {
        let output = Output()
        let playback = output.queue()
        playback.enqueue("start")
        output.running = false
        playback.enqueue("stop")
        #expect(output.starts == 2)
        #expect(output.rebuilds == 1)
        #expect(output.played == ["start", "stop"])
    }

    @Test("Output changes advance waiting sounds, and old callbacks cannot end the new sound")
    func configurationChangeAndStaleCallbacks() {
        let output = Output()
        let playback = output.queue()
        playback.enqueue("start")
        playback.enqueue("stop")
        output.running = false
        playback.outputChanged()
        playback.enqueue("done")
        #expect(output.played == ["start", "stop"])
        output.completions[0]()
        output.timeouts[0]()
        #expect(output.played == ["start", "stop"])
        output.completions[1]()
        #expect(output.played == ["start", "stop", "done"])
    }

    @Test("A missing completion recovers even when the device still reports running")
    func watchdogRecoversHungDevice() {
        let output = Output()
        let playback = output.queue()
        playback.enqueue("start")
        playback.enqueue("stop")
        output.timeouts[0]()
        #expect(output.rebuilds == 1)
        #expect(output.starts == 2)
        #expect(output.played == ["start", "stop"])
        playback.enqueue("done")
        output.completions[0]()
        #expect(output.played == ["start", "stop"])
        output.completions[1]()
        #expect(output.played == ["start", "stop", "done"])
    }

    @Test("Normal rapid cues stay ordered without rebuilding the output")
    func cueOrder() {
        let output = Output()
        let playback = output.queue()
        playback.enqueue("start")
        playback.enqueue("lock")
        playback.enqueue("stop")
        playback.enqueue("done")
        #expect(output.played == ["start"])
        for index in 0..<4 { output.completions[index]() }
        #expect(output.played == ["start", "lock", "stop", "done"])
        #expect(output.starts == 1)
        #expect(output.rebuilds == 0)
        for timeout in output.timeouts { timeout() }
        #expect(output.rebuilds == 0)
    }

    @Test("A failed output start can recover on the next request")
    func startFailureDoesNotLatchBusy() {
        let output = Output()
        let playback = output.queue()
        output.failStart = true
        playback.enqueue("start")
        #expect(output.played.isEmpty)
        output.failStart = false
        playback.enqueue("stop")
        #expect(output.played == ["stop"])
        #expect(output.starts == 1)
    }
}
