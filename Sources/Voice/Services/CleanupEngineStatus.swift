// Flow: which cleanup engine actually runs, and whether it is ready.
//
// Settings and the dictation trace both use this, so they can never name different engines.

import Foundation

struct CleanupEngineStatus: Equatable {
    /// Short name shown to Jordan: "DOSE1 T1", "S1-mini", "Qwen3" or "Off".
    let name: String
    let ready: Bool
    /// One plain line for Settings.
    let detail: String

    /// The engine a dictation would use right now, from the saved settings and what is installed.
    /// - Parameters:
    ///   - level: the cleanup level (`none` means Off).
    ///   - polishEnabled: the user's polish switch.
    ///   - s1MiniReady: whether S1-mini is cached or loaded (checked by the caller, it is async).
    @MainActor static func current(level: String = CleanupLevel.current.rawValue,
                        polishEnabled: Bool = UserDefaults.standard.object(forKey: "polishEnabled") == nil
                            ? true : UserDefaults.standard.bool(forKey: "polishEnabled"),
                        s1MiniReady: Bool = false) -> CleanupEngineStatus {
        if level == CleanupLevel.none.rawValue || !polishEnabled {
            return CleanupEngineStatus(name: "Off", ready: true,
                                       detail: "Cleanup is off. Your words are pasted as spoken, with rules only.")
        }
        switch Qwen3Polisher.effectiveAutomaticCleanupModel {
        case WhisperNowTunedPolisher.settingValue:
            let installed = WhisperNowTunedPolisher.isInstalled
            if WhisperNowTunedPolisher.usesT2Contracts && !WhisperNowTunedPolisher.supportsCleanupControls {
                return CleanupEngineStatus(name: "DOSE1 T2", ready: false,
                                           detail: "Cleanup controls unavailable. Your words stay unchanged.")
            }
            if WhisperNowTunedPolisher.usesT2Contracts {
                let validSetup = WhisperNowTunedPolisher.activeChatProfile != nil
                return CleanupEngineStatus(name: "DOSE1 T2", ready: false,
                    detail: validSetup ? "Installed. Readiness is checked when you dictate."
                                       : "Setup could not be verified. Your words stay unchanged.")
            }
            return CleanupEngineStatus(name: WhisperNowTunedPolisher.displayName, ready: installed,
                                       detail: installed ? "Installed. Loads when you dictate."
                                                         : "Not installed. Rules-only text is pasted.")
        case "s1-mini":
            return CleanupEngineStatus(name: "S1-mini", ready: s1MiniReady,
                                       detail: s1MiniReady ? "Installed. Loads when needed."
                                                           : "Not ready yet. Rules-only text is pasted.")
        default:
            let ready = Qwen3Polisher.isAvailable
            return CleanupEngineStatus(name: "Qwen3", ready: ready,
                                       detail: ready ? "Ready. Runs on this Mac."
                                                     : "Not ready yet. Rules-only text is pasted.")
        }
    }
}
