import Foundation

/// Aligns already-resampled mono streams against one monotonic clock.
/// The caller serializes access, converts both input timestamps to seconds on
/// the same host clock, and drains behind real time to allow callback jitter.
/// It does not perform clock conversion, resampling, gain or clipping.
struct MeetingAudioTimelineMixer {
    enum Source { case microphone, system }
    struct InputResult: Equatable {
        var accepted = 0
        var late = 0
        var beyondWindow = 0
    }
    struct Output {
        let startFrame: Int64
        let microphone: [Float]
        let system: [Float]
    }

    let sampleRate: Double
    let origin: Double
    private let capacity: Int
    private(set) var nextFrame: Int64 = 0
    private(set) var latestFrameExclusive: Int64 = 0
    var bufferedEndTime: Double { origin + Double(latestFrameExclusive) / sampleRate }
    private var mic: [Float]
    private var sys: [Float]
    private var micStamp: [Int64]
    private var sysStamp: [Int64]

    init(origin: Double, sampleRate: Double = 16_000, windowSeconds: Double = 3) {
        precondition(origin.isFinite && sampleRate.isFinite && sampleRate > 0 && windowSeconds.isFinite && windowSeconds > 0)
        self.origin = origin
        self.sampleRate = sampleRate
        self.capacity = max(1, Int((sampleRate * windowSeconds).rounded(.up)))
        self.mic = Array(repeating: 0, count: capacity)
        self.sys = Array(repeating: 0, count: capacity)
        self.micStamp = Array(repeating: -1, count: capacity)
        self.sysStamp = Array(repeating: -1, count: capacity)
    }

    /// Input timestamp is the host-clock time of the first sample, not arrival
    /// time. Duplicate/overlapping frames replace earlier values for that source.
    /// Out-of-window counts must be surfaced; missing samples render as silence.
    mutating func append(_ samples: [Float], source: Source, startTime: Double) -> InputResult {
        guard startTime.isFinite else { return InputResult(accepted: 0, late: 0, beyondWindow: samples.count) }
        let offset = (startTime - origin) * sampleRate
        guard offset.isFinite, abs(offset) < Double(Int64.max) / 2 else {
            return InputResult(accepted: 0, late: 0, beyondWindow: samples.count)
        }
        let start = Int64(offset.rounded())
        var result = InputResult()
        for (i, value) in samples.enumerated() {
            let frame = start + Int64(i)
            if frame < nextFrame { result.late += 1; continue }
            if frame - nextFrame >= Int64(capacity) { result.beyondWindow += 1; continue }
            let index = Int(frame % Int64(capacity))
            switch source {
            case .microphone: mic[index] = value; micStamp[index] = frame
            case .system: sys[index] = value; sysStamp[index] = frame
            }
            latestFrameExclusive = max(latestFrameExclusive, frame + 1)
            result.accepted += 1
        }
        return result
    }

    /// Emits frames strictly before the given common-clock time, in bounded
    /// batches. Call repeatedly for long gaps. Drain only after the caller's
    /// chosen lateness allowance; once emitted, late frames cannot be restored.
    mutating func drain(before time: Double) -> Output {
        guard time.isFinite else { return Output(startFrame: nextFrame, microphone: [], system: []) }
        let offset = (time - origin) * sampleRate
        guard offset.isFinite, offset > Double(nextFrame) else {
            return Output(startFrame: nextFrame, microphone: [], system: [])
        }
        let amount = Int(min(Double(capacity), (offset - Double(nextFrame)).rounded(.down)))
        let start = nextFrame
        var outMic = [Float](); outMic.reserveCapacity(amount)
        var outSys = [Float](); outSys.reserveCapacity(amount)
        for _ in 0..<amount {
            let index = Int(nextFrame % Int64(capacity))
            outMic.append(micStamp[index] == nextFrame ? mic[index] : 0)
            outSys.append(sysStamp[index] == nextFrame ? sys[index] : 0)
            nextFrame += 1
        }
        return Output(startFrame: start, microphone: outMic, system: outSys)
    }
}
