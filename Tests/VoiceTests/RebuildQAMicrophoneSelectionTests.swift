import CoreAudio
import Testing
@testable import Voice

@Suite("Microphone selection")
struct RebuildQAMicrophoneSelectionTests {
    private let inputs = [
        MicrophonePreference.Input(uid: "synthetic-usb", name: "USB", deviceID: 42),
        MicrophonePreference.Input(uid: "synthetic-built-in", name: "Built-in", deviceID: 11)
    ]

    @Test("Uses the saved microphone when connected")
    func preferredConnected() {
        #expect(MicrophonePreference.resolve(preferredUID: "synthetic-usb", inputs: inputs, defaultDeviceID: 11) == 42)
    }

    @Test("Uses the current system default when the saved microphone is disconnected")
    func preferredDisconnected() {
        #expect(MicrophonePreference.resolve(preferredUID: "synthetic-missing", inputs: inputs, defaultDeviceID: 11) == 11)
    }

    @Test("Empty preference follows the system default")
    func noPreference() {
        #expect(MicrophonePreference.resolve(preferredUID: "", inputs: inputs, defaultDeviceID: 11) == 11)
        #expect(MicrophonePreference.resolve(preferredUID: "", inputs: inputs, defaultDeviceID: 42) == 42)
    }

    @Test("Reconnected device is selected by stable UID after its device ID changes")
    func reconnect() {
        let reconnected = [MicrophonePreference.Input(uid: "synthetic-usb", name: "USB", deviceID: 99)]
        #expect(MicrophonePreference.resolve(preferredUID: "synthetic-usb", inputs: reconnected, defaultDeviceID: 11) == 99)
    }

    @Test("Unknown default stays unknown rather than selecting an arbitrary device")
    func unavailableDefault() {
        #expect(MicrophonePreference.resolve(preferredUID: "synthetic-missing", inputs: inputs, defaultDeviceID: 0) == 0)
    }
    @Test("Auto prefers the AT20, then a connected physical input")
    func automaticExternalSelection() {
        let builtIn = MicrophonePreference.Input(uid: "built", name: "Built-in", deviceID: 11,
            transport: kAudioDeviceTransportTypeBuiltIn)
        let usb = MicrophonePreference.Input(uid: "usb", name: "USB microphone", deviceID: 42,
            transport: kAudioDeviceTransportTypeUSB)
        let at = MicrophonePreference.Input(uid: "at", name: "AT2020USB+", deviceID: 49,
            transport: kAudioDeviceTransportTypeUSB)
        #expect(MicrophonePreference.resolve(preferredUID: "", inputs: [builtIn, usb, at], defaultDeviceID: 11) == 49)
        #expect(MicrophonePreference.resolve(preferredUID: "at", inputs: [builtIn, usb], defaultDeviceID: 11) == 42)
        #expect(MicrophonePreference.resolve(preferredUID: "built", inputs: [builtIn, usb, at], defaultDeviceID: 49) == 11)
    }

    @Test("Auto tries ranked UIDs in order and restores a returning device")
    func rankedSelection() {
        let ranked = ["returning", "synthetic-usb", "synthetic-built-in"]
        #expect(MicrophonePreference.resolve(preferredUID: "", priorityUIDs: ranked,
            inputs: inputs, defaultDeviceID: 11) == 42)
        let returning = MicrophonePreference.Input(uid: "returning", name: "USB changed ID", deviceID: 99)
        #expect(MicrophonePreference.resolve(preferredUID: "", priorityUIDs: ranked,
            inputs: inputs + [returning], defaultDeviceID: 11) == 99)
        #expect(MicrophonePreference.resolve(preferredUID: "synthetic-built-in", priorityUIDs: ranked,
            inputs: inputs + [returning], defaultDeviceID: 11) == 11)
    }

    @Test("Disconnected priorities persist and bad preferences fall back safely")
    func rankPreferenceDecoding() {
        let data = #"[{"uid":"disconnected","name":"Remember me"},{"uid":"synthetic-usb"},{"uid":"disconnected"},{"uid":""}]"#
        #expect(MicrophonePreference.priorityUIDs(encoded: data) == ["disconnected", "synthetic-usb"])
        #expect(MicrophonePreference.priorityUIDs(encoded: "invalid") == [])
        #expect(MicrophonePreference.resolve(preferredUID: "", priorityUIDs: ["gone"],
            inputs: inputs, defaultDeviceID: 11) == 11)
    }

    @Test("A virtual input requires an explicit choice when the built-in mic is available")
    func virtualInput() {
        let builtIn = MicrophonePreference.Input(uid: "built", name: "Built-in", deviceID: 11,
            transport: kAudioDeviceTransportTypeBuiltIn)
        let virtual = MicrophonePreference.Input(uid: "virtual", name: "Virtual", deviceID: 15,
            transport: kAudioDeviceTransportTypeVirtual)
        #expect(MicrophonePreference.resolve(preferredUID: "", inputs: [builtIn, virtual], defaultDeviceID: 15) == 11)
        #expect(MicrophonePreference.resolve(preferredUID: "virtual", inputs: [builtIn, virtual], defaultDeviceID: 11) == 15)
    }
}
