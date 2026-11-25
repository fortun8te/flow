import Testing
@testable import Voice

@Suite("Meeting audio timeline")
struct MeetingAudioTimelineMixerTests {
    @Test func overlappingSourcesAndGaps() {
        var mixer = MeetingAudioTimelineMixer(origin: 100, sampleRate: 4, windowSeconds: 3)
        #expect(mixer.append([1, 2, 3, 4], source: .microphone, startTime: 100).accepted == 4)
        #expect(mixer.append([5, 6], source: .system, startTime: 100.5).accepted == 2)
        let out = mixer.drain(before: 101.5)
        #expect(out.microphone == [1, 2, 3, 4, 0, 0])
        #expect(out.system == [0, 0, 5, 6, 0, 0])
        #expect(out.startFrame == 0)
    }

    @Test func boundedAndLateInputs() {
        var mixer = MeetingAudioTimelineMixer(origin: 0, sampleRate: 2, windowSeconds: 1)
        let result = mixer.append([1, 2, 3], source: .system, startTime: 0)
        #expect(result.accepted == 2 && result.beyondWindow == 1)
        #expect(mixer.drain(before: 1).system == [1, 2])
        #expect(mixer.append([9, 10], source: .system, startTime: 0.5).late == 1)
        #expect(mixer.drain(before: 2).system == [10, 0])
    }

    @Test func bufferedEndIncludesLastAcceptedFrame() {
        var mixer = MeetingAudioTimelineMixer(origin: 10, sampleRate: 4, windowSeconds: 2)
        _ = mixer.append([1, 2], source: .system, startTime: 10.5)
        #expect(mixer.bufferedEndTime == 11)
        #expect(mixer.drain(before: mixer.bufferedEndTime).system == [0, 0, 1, 2])
    }

    @Test func longGapIsDrainedInBoundedBatches() {
        var mixer = MeetingAudioTimelineMixer(origin: 0, sampleRate: 2, windowSeconds: 1)
        #expect(mixer.drain(before: 4).microphone == [0, 0])
        #expect(mixer.drain(before: 4).startFrame == 2)
        #expect(mixer.nextFrame == 4)
    }
}
