import CoreAudio
import Foundation

// MARK: - Quiet other audio while dictating (Wispr Flow parity)
//
// When a dictation starts, the default output is MUTED so speakers don't bleed
// music, a video or a call back into the mic. The mute is undone when the
// dictation ends, is cancelled, errors, or the app quits.
//
// What this deliberately does NOT do:
//   * No media-remote play/pause. Those commands resumed paused music on every
//     dictation (see AudioCaptureService, "MEDIA-RESUME FIX").
//   * No output work during meeting capture: the other side must still hear the call.
//   * No ducking when system audio is the capture source, because it would
//     silence the audio being recorded.
//   * No ducking on headphones or Bluetooth outputs: there is no speaker bleed.
//   * No restore of a value the user changed during the dictation.

// MARK: - Pure decisions (unit-tested)

enum DictationDuckingPolicy {
    /// UserDefaults key for the user setting. A missing key means off: music keeps playing, as in Wispr.
    static let settingKey = "voice.quietMediaWhileDictating"

    static func isEnabled(storedValue: Bool?) -> Bool { storedValue ?? false }

    /// Duck only when a speaker-to-mic bleed is possible and the output mute can be set.
    static func shouldDuck(enabled: Bool,
                           meetingActive: Bool,
                           outputIsHeadphones: Bool,
                           outputMuteSettable: Bool) -> Bool {
        enabled && !meetingActive && !outputIsHeadphones && outputMuteSettable
    }

    /// Headphone-like outputs: Bluetooth transports (headphones and earbuds) and the
    /// built-in headphone jack ('hdpn' data source). These cannot bleed into the mic.
    static func isHeadphoneOutput(transport: UInt32, dataSource: UInt32?) -> Bool {
        if transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }
        return dataSource == fourCC("hdpn")
    }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// Restore only while the device still holds the value we set. If the user
    /// changed it during the dictation, leave their choice alone.
    static func shouldRestore(valueWeSet: Bool, currentValue: Bool) -> Bool {
        currentValue == valueWeSet
    }
}

// MARK: - CoreAudio wrapper

/// Thin CoreAudio wrapper around DictationDuckingPolicy. Main actor only.
@MainActor
final class DictationAudioDucker {

    private struct Engaged {
        let device: AudioDeviceID
        let previousMuted: Bool
    }

    private var engaged: Engaged?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    /// Crash safety: while we hold the mute, the device and the previous state are
    /// stored here, so an interrupted app can restore the mute on its next launch.
    private static let pendingKey = "voice.duckingPending"

    /// Mute the default output for a dictation, if the policy allows it.
    func duckForDictation(meetingActive: Bool) {
        guard engaged == nil else { return }
        let enabled = DictationDuckingPolicy.isEnabled(
            storedValue: UserDefaults.standard.object(forKey: DictationDuckingPolicy.settingKey) as? Bool)
        guard enabled else { return }

        let device = Self.defaultOutputDevice()
        guard device != 0 else { return }
        let transport = Self.readUInt32(device, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        let dataSource = Self.readUInt32(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        let headphones = DictationDuckingPolicy.isHeadphoneOutput(transport: transport, dataSource: dataSource)
        let settable = Self.isMuteSettable(device)

        guard DictationDuckingPolicy.shouldDuck(enabled: enabled,
                                                meetingActive: meetingActive,
                                                outputIsHeadphones: headphones,
                                                outputMuteSettable: settable) else {
            vlog("[VOICE-DUCK] skipped — meeting=\(meetingActive) headphones=\(headphones) muteSettable=\(settable)")
            return
        }
        guard let previous = Self.readUInt32(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) else {
            return
        }
        // Already muted by the user: nothing to do, and nothing to restore later.
        guard previous == 0 else { return }
        guard Self.setMuted(device, true) else {
            vlog("[VOICE-DUCK] could not mute default output")
            return
        }

        engaged = Engaged(device: device, previousMuted: false)
        UserDefaults.standard.set(["device": Int(device), "previousMuted": false], forKey: Self.pendingKey)
        installDefaultDeviceListener()
        vlog("[VOICE-DUCK] output muted for dictation (device=\(device))")
    }

    /// Restore the output we changed. Safe to call on every exit path and when
    /// nothing was changed.
    func restore() {
        guard let state = engaged else { return }
        engaged = nil
        removeDefaultDeviceListener()
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)

        // The device may have been unplugged. Then there is nothing to restore.
        guard let current = Self.readUInt32(state.device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) else {
            vlog("[VOICE-DUCK] restore skipped — device unavailable")
            return
        }
        guard DictationDuckingPolicy.shouldRestore(valueWeSet: true, currentValue: current == 1) else {
            vlog("[VOICE-DUCK] restore skipped — user changed mute during dictation")
            return
        }
        _ = Self.setMuted(state.device, state.previousMuted)
        vlog("[VOICE-DUCK] output restored (device=\(state.device))")
    }

    /// Run at launch: undo a mute left behind by an app that quit or crashed mid-dictation.
    func recoverInterruptedMute() {
        guard let pending = UserDefaults.standard.dictionary(forKey: Self.pendingKey),
              let deviceValue = pending["device"] as? Int else { return }
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        let device = AudioDeviceID(deviceValue)
        let previousMuted = pending["previousMuted"] as? Bool ?? false
        if let current = Self.readUInt32(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput),
           DictationDuckingPolicy.shouldRestore(valueWeSet: true, currentValue: current == 1) {
            _ = Self.setMuted(device, previousMuted)
            vlog("[VOICE-DUCK] recovered output mute left by an interrupted dictation")
        }
    }

    // MARK: Default-output change: restore the device we changed

    private func installDefaultDeviceListener() {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.restore() }
        }
        defaultDeviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListener else { return }
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        defaultDeviceListener = nil
    }

    // MARK: Probes

    /// True while any app is running audio through the default output. Used by the
    /// media-leak guard. Muting does not stop the device, so this stays true while
    /// ducked.
    static func mediaPlayingOnOutput() -> Bool {
        let device = defaultOutputDevice()
        guard device != 0 else { return false }
        return (readUInt32(device, kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioObjectPropertyScopeGlobal) ?? 0) != 0
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr ? device : 0
    }

    private static func readUInt32(_ object: AudioObjectID,
                                   _ selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope) -> UInt32? {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func isMuteSettable(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    private static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
