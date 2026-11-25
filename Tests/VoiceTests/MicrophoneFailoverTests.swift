import CoreAudio
import Foundation
import Testing
@testable import Voice

@Suite("Silent-start microphone failover")
struct MicrophoneFailoverTests {
    private let builtIn = MicrophonePreference.Input(uid: "built", name: "MacBook Pro Microphone", deviceID: 11,
                                                     transport: kAudioDeviceTransportTypeBuiltIn)
    private let airpods = MicrophonePreference.Input(uid: "airpods", name: "AirPods Pro", deviceID: 21,
                                                     transport: kAudioDeviceTransportTypeBluetooth)
    private let usb = MicrophonePreference.Input(uid: "usb", name: "USB mic", deviceID: 42,
                                                 transport: kAudioDeviceTransportTypeUSB)
    private let virtual = MicrophonePreference.Input(uid: "virtual", name: "Loopback", deviceID: 77,
                                                     transport: kAudioDeviceTransportTypeVirtual)

    @Test("A window at or above the silence floor is audible; the 0.003 silent built-in capture is not")
    func silenceThreshold() {
        #expect(MicrophoneFailover.isSilent(peak: 0.003))
        #expect(MicrophoneFailover.isSilent(peak: 0.0004))
        #expect(!MicrophoneFailover.isSilent(peak: 0.02))
        #expect(MicrophoneFailover.probeSeconds == 0.3)
    }

    @Test("Candidates exclude the silent device, virtual inputs and devices already tried, external first")
    func candidateOrder() {
        let all = [builtIn, airpods, virtual, usb]
        let ids = MicrophoneFailover.candidates(current: 11, inputs: all).map(\.deviceID)
        #expect(ids == [42])  // only the built-in (current here) and USB are probe-safe; AirPods and the loopback never are
        #expect(MicrophoneFailover.candidates(current: 11, inputs: all, excluding: [42]).isEmpty)
        #expect(MicrophoneFailover.candidates(current: 11, inputs: [builtIn]).isEmpty)
    }

    @Test("The first candidate with signal wins; when none has signal the selection stays")
    func firstAudibleWins() {
        let probes: [(input: MicrophonePreference.Input, peak: Float)] = [(usb, 0.001), (airpods, 0.04), (builtIn, 0.3)]
        #expect(MicrophoneFailover.firstAudibleCandidate(probes)?.uid == "airpods")
        let silent: [(input: MicrophonePreference.Input, peak: Float)] = [(usb, 0.0), (airpods, 0.002)]
        #expect(MicrophoneFailover.firstAudibleCandidate(silent) == nil)
        #expect(MicrophoneFailover.firstAudibleCandidate([]) == nil)
    }

    @Test("A remembered failover mic is used for later recordings, unless a mic is chosen explicitly")
    func rememberedSelection() {
        let inputs = [builtIn, airpods]
        #expect(MicrophonePreference.resolve(preferredUID: "", rememberedUID: "airpods", inputs: inputs,
                                             defaultDeviceID: 11) == 21)
        #expect(MicrophonePreference.resolve(preferredUID: "built", rememberedUID: "airpods", inputs: inputs,
                                             defaultDeviceID: 21) == 11)
        // A remembered mic that is no longer connected falls through to the normal choice (external first).
        #expect(MicrophonePreference.resolve(preferredUID: "", rememberedUID: "gone", inputs: inputs,
                                             defaultDeviceID: 11) == 21)
    }

    @Test("The remembered UID persists in defaults and an empty UID is never stored")
    func rememberPersists() {
        let suite = "MicrophoneFailoverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MicrophoneFailover.rememberedUID(defaults: defaults) == "")
        MicrophoneFailover.remember(uid: "", defaults: defaults)
        #expect(MicrophoneFailover.rememberedUID(defaults: defaults) == "")
        MicrophoneFailover.remember(uid: "airpods", defaults: defaults)
        #expect(MicrophoneFailover.rememberedUID(defaults: defaults) == "airpods")
    }

    @Test("Bluetooth and AirPods inputs are never probed, even when silent; built-in and USB are")
    func neverProbeBluetooth() {
        #expect(!MicrophoneFailover.isProbeSafe(airpods))
        #expect(!MicrophoneFailover.isProbeSafe(virtual))
        #expect(MicrophoneFailover.isProbeSafe(builtIn))
        #expect(MicrophoneFailover.isProbeSafe(usb))
        #expect(MicrophoneFailover.probePeak(airpods) == 0)
        let ids = MicrophoneFailover.candidates(current: 42, inputs: [airpods, builtIn, usb]).map(\.deviceID)
        #expect(ids == [11])
    }
}
