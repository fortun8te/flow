import Foundation
import CoreAudio
import AVFoundation
import Accelerate

/// Silent-start failover: when the selected microphone is near-silent for the first 300 ms of a recording,
/// another connected microphone that shows signal takes over for the rest of the recording, and is remembered.
/// Found 22 Nov 2026: 11 of 43 recorded runs ended empty, with a built-in capture peak near 0.003.
enum MicrophoneFailover {
    /// Audio after the first buffer that decides whether the selected microphone is silent.
    static let probeSeconds: TimeInterval = 0.3
    /// Peak sample magnitude under which a window counts as near-silent (about -46 dBFS). Speech peaks sit well above.
    static let silentPeak: Float = 0.005
    /// UserDefaults key for the microphone UID the failover last switched to.
    static let rememberedKey = "voice.failoverMicrophoneUID"

    static func isSilent(peak: Float) -> Bool { peak < silentPeak }

    /// Only the built-in mic and wired or USB mics may be probed. Opening a Bluetooth or AirPods input switches the
    /// headphones into call-quality mode, so they are never opened for a probe.
    static func isProbeSafe(_ input: MicrophonePreference.Input) -> Bool {
        input.transport == kAudioDeviceTransportTypeBuiltIn || input.transport == kAudioDeviceTransportTypeUSB
    }

    /// Other microphones worth trying, best first. The current device and any mic that is not probe-safe never qualify.
    static func candidates(current: AudioDeviceID, inputs: [MicrophonePreference.Input],
                           excluding tried: Set<AudioDeviceID> = []) -> [MicrophonePreference.Input] {
        inputs
            .filter { input in
                input.deviceID != current && input.deviceID != 0 && !tried.contains(input.deviceID)
                    && isProbeSafe(input)
            }
            .enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (rank(lhs.element), rank(rhs.element))
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Physical external inputs first (AT20, USB, Bluetooth), then other built-in inputs, then anything else.
    static func rank(_ input: MicrophonePreference.Input) -> Int {
        if input.isPhysicalExternal { return 0 }
        if input.transport == kAudioDeviceTransportTypeBuiltIn { return 1 }
        return 2
    }

    /// The first candidate, in order, whose probe showed signal. Nil when none did, so the selection stays put.
    static func firstAudibleCandidate(_ probes: [(input: MicrophonePreference.Input, peak: Float)]) -> MicrophonePreference.Input? {
        probes.first { !isSilent(peak: $0.peak) }?.input
    }

    /// Microphone UID remembered by the last successful failover, or "".
    static func rememberedUID(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: rememberedKey) ?? ""
    }

    static func remember(uid: String, defaults: UserDefaults = .standard) {
        guard !uid.isEmpty else { return }
        defaults.set(uid, forKey: rememberedKey)
    }

    /// Reads a microphone for `seconds` on its own short-lived engine and returns the loudest sample magnitude.
    /// Runs off the main thread; it never changes the system input device or the recording engine.
    static func probePeak(_ input: MicrophonePreference.Input, seconds: TimeInterval = probeSeconds) -> Float {
        // Defence in depth: a Bluetooth or AirPods input is never opened here.
        guard isProbeSafe(input) else { return 0 }
        let deviceID = input.deviceID
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        guard let unit = inputNode.audioUnit else { return 0 }
        var device = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return 0 }
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return 0 }
        let lock = NSLock()
        var peak: Float = 0
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var value: Float = 0
            vDSP_maxmgv(data, 1, &value, vDSP_Length(buffer.frameLength))
            lock.lock(); peak = max(peak, value); lock.unlock()
        }
        defer {
            inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        do { try engine.start() } catch { return 0 }
        Thread.sleep(forTimeInterval: seconds)
        lock.lock(); defer { lock.unlock() }
        return peak
    }
}
