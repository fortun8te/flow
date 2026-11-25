import Foundation

/// A deliberately small compatibility migration. Run only after ownership is
/// acquired, before services read preferences. Never read Companion's domain here.
enum FlowDefaultsMigration {
    static let marker = "flow.defaultsMigrationV1"
    static let allowedKeys = [
        "autoCopy", "autoPaste", "polishEnabled", "llmPolishEnabled",
        "cleanupLevel", "personalityStyle", "myStyleLevel", "polishPreset",
        "voice.cleanupModel", "voice.speechModelID", "voice.preferredMicrophoneUID",
        "voice.pillPosition", "voice.pillSideFraction", "voice.doubleTapWindowMs",
        "voice.userName", "voice.wakeWordPhrase", "soundEffectsEnabled",
        "hotkeys.captured.ptt", "hotkeys.captured.lock", "userProperNouns",
        "voice.userDictionary", "recentDictations", "voice.wisprContextStylesEnabled",
        "voice.privacyMode", "voice.hotkey", "voice.handsFreeHotkey", "voice.polishHotkey"
    ]

    static func migrate(into destination: UserDefaults, legacy: [String: Any]) {
        guard !destination.bool(forKey: marker) else { return }
        for key in allowedKeys where destination.object(forKey: key) == nil {
            if let value = legacy[key] { destination.set(value, forKey: key) }
        }
        // Auto-capture requires a fresh, explicit Flow opt-in.
        for key in ["voice.enableMeetingDetection", "voice.wakeWordEnabled"] where destination.object(forKey: key) == nil {
            destination.set(false, forKey: key)
        }
        if destination.object(forKey: "voice.wakeWordMode") == nil {
            destination.set("off", forKey: "voice.wakeWordMode")
        }
        destination.set(true, forKey: marker)
    }
}
