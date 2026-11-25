import CoreAudio
import Testing
@testable import Voice

@Suite("Dictation output ducking decisions")
struct DictationAudioDuckingTests {
    @Test("Setting defaults to off when unset, and respects an explicit value")
    func settingDefault() {
        #expect(!DictationDuckingPolicy.isEnabled(storedValue: nil))
        #expect(DictationDuckingPolicy.isEnabled(storedValue: true))
        #expect(!DictationDuckingPolicy.isEnabled(storedValue: false))
    }

    @Test("Ducks only on speakers, outside meetings, with a settable mute")
    func shouldDuckMatrix() {
        #expect(DictationDuckingPolicy.shouldDuck(enabled: true, meetingActive: false,
                                                  outputIsHeadphones: false, outputMuteSettable: true))
        #expect(!DictationDuckingPolicy.shouldDuck(enabled: false, meetingActive: false,
                                                   outputIsHeadphones: false, outputMuteSettable: true))
        #expect(!DictationDuckingPolicy.shouldDuck(enabled: true, meetingActive: true,
                                                   outputIsHeadphones: false, outputMuteSettable: true))
        #expect(!DictationDuckingPolicy.shouldDuck(enabled: true, meetingActive: false,
                                                   outputIsHeadphones: true, outputMuteSettable: true))
        #expect(!DictationDuckingPolicy.shouldDuck(enabled: true, meetingActive: false,
                                                   outputIsHeadphones: false, outputMuteSettable: false))
    }

    @Test("Bluetooth transports and the headphone jack count as headphones")
    func headphoneDetection() {
        #expect(DictationDuckingPolicy.isHeadphoneOutput(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil))
        #expect(DictationDuckingPolicy.isHeadphoneOutput(transport: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil))
        #expect(DictationDuckingPolicy.isHeadphoneOutput(transport: kAudioDeviceTransportTypeBuiltIn,
                                                         dataSource: DictationDuckingPolicy.fourCC("hdpn")))
        #expect(!DictationDuckingPolicy.isHeadphoneOutput(transport: kAudioDeviceTransportTypeBuiltIn,
                                                          dataSource: DictationDuckingPolicy.fourCC("ispk")))
        #expect(!DictationDuckingPolicy.isHeadphoneOutput(transport: kAudioDeviceTransportTypeUSB, dataSource: nil))
    }

    @Test("FourCC encodes the four characters big-endian")
    func fourCC() {
        #expect(DictationDuckingPolicy.fourCC("hdpn") == 0x6864_706E)
    }

    @Test("Restore only when the mute is still the value we set")
    func restoreOnlyWhenUnchanged() {
        #expect(DictationDuckingPolicy.shouldRestore(valueWeSet: true, currentValue: true))
        // The user unmuted during the dictation: leave their choice alone.
        #expect(!DictationDuckingPolicy.shouldRestore(valueWeSet: true, currentValue: false))
    }
}
