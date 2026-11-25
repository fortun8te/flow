// Flow: where API keys live. macOS Keychain, never UserDefaults.
//
// Before 14 Nov 2026 the cloud keys sat in UserDefaults (a plain plist in the
// app's container). This store moves them into the login Keychain. An old value
// found in UserDefaults is copied across on the next read and then removed from
// UserDefaults, so no copy is left behind.

import Foundation
import KeychainAccess

enum SecretName: String, CaseIterable, Sendable {
    case cerebras
    case nvidia
    case groq
    case hyperbolic

    /// Key the value used under UserDefaults before the move. Used only to migrate.
    var legacyDefaultsKey: String {
        switch self {
        case .cerebras: return "cerebrasAPIKey"
        case .nvidia: return "voice.nvidiaAPIKey"
        case .groq: return "voice.groqAPIKey"
        case .hyperbolic: return "voice.hyperbolicAPIKey"
        }
    }
}

struct SecretStore {
    static let shared = SecretStore(keychain: Keychain(service: "com.example.flow.voice.keys")
        .accessibility(.afterFirstUnlockThisDeviceOnly))

    let keychain: Keychain
    /// Injected in tests so the real defaults are never touched.
    var defaults: UserDefaults = .standard

    /// Current value, or "" when none is stored. Migrates a legacy UserDefaults value once.
    func read(_ name: SecretName) -> String {
        if let stored = try? keychain.get(name.rawValue), !stored.isEmpty {
            // A stale legacy copy can still exist if an old build wrote it after the move.
            defaults.removeObject(forKey: name.legacyDefaultsKey)
            return stored
        }
        guard let legacy = defaults.string(forKey: name.legacyDefaultsKey), !legacy.isEmpty else { return "" }
        do {
            try keychain.set(legacy, key: name.rawValue)
            defaults.removeObject(forKey: name.legacyDefaultsKey)
            return legacy
        } catch {
            // Keychain refused. Leave the legacy value where it is and report nothing stored.
            return ""
        }
    }

    /// Stores a value, or removes it when the value is empty. Also clears any legacy copy.
    func write(_ name: SecretName, _ value: String) {
        defaults.removeObject(forKey: name.legacyDefaultsKey)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? keychain.remove(name.rawValue)
        } else {
            try? keychain.set(trimmed, key: name.rawValue)
        }
    }
}
