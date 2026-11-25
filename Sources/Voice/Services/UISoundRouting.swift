// UISoundRouting.swift
//
// Picks the output device for Flow's start, stop, done and notice earcons.
//
// WHY: the earcons used to go to the default output. When that output is AirPlay
// (AcmeAudio speakers) or Bluetooth, the signal takes about 2 s to arrive, so the
// earcon sounds late. UI sounds belong on the system alert output
// (kAudioHardwarePropertyDefaultSystemOutputDevice). If that device is itself a
// high-latency one, the built-in speakers take the sound instead.

import CoreAudio
import Foundation

struct UISoundDevice: Equatable {
    let id: AudioDeviceID
    let transport: UInt32
}

enum UISoundRouting {
    /// AirPlay and Bluetooth add enough delay that an earcon lands audibly late.
    static func isHighLatency(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeAirPlay
            || transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The device UI sounds play on.
    /// - Parameters:
    ///   - systemOutput: the system alert output. Used first when present.
    ///   - defaultOutput: the main output. Used only when there is no system output.
    ///   - builtIn: the built-in speakers. Used in place of a high-latency target.
    static func target(systemOutput: UISoundDevice?, defaultOutput: UISoundDevice?,
                       builtIn: UISoundDevice?) -> UISoundDevice? {
        guard let base = systemOutput ?? defaultOutput else { return nil }
        if isHighLatency(base.transport), let builtIn, builtIn.id != base.id { return builtIn }
        return base
    }

    /// The live target from CoreAudio. Nil when the system reports no output device.
    static func currentTarget() -> UISoundDevice? {
        let system = outputDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let main = outputDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let base = system ?? main
        // The built-in lookup is only needed when the target is high latency.
        let builtIn = base.map { isHighLatency($0.transport) } == true ? builtInOutputDevice() : nil
        return target(systemOutput: system, defaultOutput: main, builtIn: builtIn)
    }

    // MARK: - CoreAudio reads

    private static func outputDevice(_ selector: AudioObjectPropertySelector) -> UISoundDevice? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return UISoundDevice(id: id, transport: transport(of: id))
    }

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr ? transport : 0
    }

    private static func builtInOutputDevice() -> UISoundDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return nil
        }
        for id in ids {
            let transport = transport(of: id)
            guard transport == kAudioDeviceTransportTypeBuiltIn, hasOutputStreams(id) else { continue }
            return UISoundDevice(id: id, transport: transport)
        }
        return nil
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }
}
