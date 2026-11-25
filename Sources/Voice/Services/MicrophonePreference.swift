import Foundation
import CoreAudio
import AudioToolbox

/// A preference for this app only; never changes the system input device.
enum MicrophonePreference {
    struct Input: Identifiable {
        let uid: String
        let name: String
        let deviceID: AudioDeviceID
        var transport: UInt32? = nil
        var id: String { uid }

        var isPhysicalExternal: Bool {
            switch transport {
            case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
                 kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                 kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeHDMI:
                return true
            default: return false
            }
        }
    }
    static let key = "voice.preferredMicrophoneUID"
    static let priorityKey = "voice.microphonePriority"

    private struct RankedInput: Decodable { let uid: String }

    static func savedPriorityUIDs(defaults: UserDefaults = .standard) -> [String] {
        guard let text = defaults.string(forKey: priorityKey) else { return [] }
        return priorityUIDs(encoded: text)
    }

    static func priorityUIDs(encoded: String) -> [String] {
        guard let list = try? JSONDecoder().decode([RankedInput].self, from: Data(encoded.utf8)) else { return [] }
        var seen = Set<String>()
        return list.map(\.uid).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func inputs() -> [Input] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        func property(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &n, &value) == noErr else { return nil }
            return value?.takeRetainedValue() as String?
        }
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n) == noErr, n > 0,
                  let uid = property(id, kAudioDevicePropertyDeviceUID), let name = property(id, kAudioObjectPropertyName) else { return nil }
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
            return Input(uid: uid, name: name, deviceID: id, transport: status == noErr ? transport : nil)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func defaultDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : 0
    }

    /// Resolve against one device snapshot; a missing preference stays saved.
    /// `rememberedUID` is the microphone a silent-start failover last found working (see MicrophoneFailover).
    static func resolve(preferredUID: String, priorityUIDs: [String] = [], rememberedUID: String = "",
                        inputs: [Input], defaultDeviceID: AudioDeviceID) -> AudioDeviceID {
        if !preferredUID.isEmpty, let match = inputs.first(where: { $0.uid == preferredUID }) {
            return match.deviceID
        }
        if preferredUID.isEmpty, !rememberedUID.isEmpty, let match = inputs.first(where: { $0.uid == rememberedUID }) {
            return match.deviceID
        }
        for uid in priorityUIDs {
            if let match = inputs.first(where: { $0.uid == uid }) {
                return match.deviceID
            }
        }
        let external = inputs.filter(\.isPhysicalExternal)
        if let at = external.first(where: { $0.name.localizedCaseInsensitiveContains("AT20") }) {
            return at.deviceID
        }
        if let systemExternal = external.first(where: { $0.deviceID == defaultDeviceID }) {
            return systemExternal.deviceID
        }
        if let wired = external.first(where: { $0.transport == kAudioDeviceTransportTypeUSB }) {
            return wired.deviceID
        }
        if let other = external.first { return other.deviceID }
        if defaultDeviceID != 0, let current = inputs.first(where: { $0.deviceID == defaultDeviceID }),
           current.transport != kAudioDeviceTransportTypeVirtual && current.transport != kAudioDeviceTransportTypeAggregate {
            return defaultDeviceID
        }
        return inputs.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn })?.deviceID ?? defaultDeviceID
    }
}
