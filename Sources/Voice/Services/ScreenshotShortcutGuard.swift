import AppKit
import Foundation

/// Companion takes over the Mac's screenshot shortcuts (⌘⇧3/4/5) while it runs, and puts them back when it quits.
/// If Companion crashes or is force-quit, nobody puts them back. Flow is always running, so it does: whenever Companion is
/// not running, it restores the originals Companion stored (`shot.savedSymbolicHotkeys` in Companion's defaults) and
/// clears that copy, exactly as Companion's own restore does. When Companion starts again it takes them over afresh.
@MainActor
enum ScreenshotShortcutGuard {
    static let pureBundleID = "local.jordan.pcmonitor.sender"
    private static let savedKey = "shot.savedSymbolicHotkeys" as CFString
    private static let hotkeysDomain = "com.apple.symbolichotkeys" as CFString
    private static let hotkeysKey = "AppleSymbolicHotKeys" as CFString
    /// The symbolic hotkey ids Companion switches off (same list as Companion's ShotSymbolicHotkeys.keys).
    static let ids = [28, 29, 30, 31, 184, 181, 182]
    private static var observer: NSObjectProtocol?

    static func start() {
        restoreIfPureIsNotRunning(after: 3)
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == pureBundleID else { return }
            // A normal quit restores them itself; give it a moment, then cover a crash.
            MainActor.assumeIsolated { restoreIfPureIsNotRunning(after: 2) }
        }
    }

    private static func restoreIfPureIsNotRunning(after seconds: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard NSRunningApplication.runningApplications(withBundleIdentifier: pureBundleID).isEmpty else { return }
            restoreNow()
        }
    }

    /// Puts the stored originals back. No-op when Companion left nothing stored (it restored them itself).
    static func restoreNow() {
        let domain = pureBundleID as CFString
        CFPreferencesAppSynchronize(domain)
        guard let data = CFPreferencesCopyAppValue(savedKey, domain) as? Data,
              let saved = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return }
        CFPreferencesAppSynchronize(hotkeysDomain)
        let current = CFPreferencesCopyValue(hotkeysKey, hotkeysDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String: Any] ?? [:]
        let restored = merged(current, saved: saved)
        CFPreferencesSetValue(hotkeysKey, restored as CFDictionary, hotkeysDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(hotkeysDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        for id in ids { setLive(id, enabled: isEnabled(id, in: restored)) }
        reload()
        CFPreferencesSetAppValue(savedKey, nil, domain)
        CFPreferencesAppSynchronize(domain)
        Telemetry.log("screenshot.shortcuts_restored", properties: ["by": "flow"])
    }

    /// Same rule as Companion: a stored "absent" marker removes the entry, anything else is put back as stored.
    static func merged(_ hotkeys: [String: Any], saved: [String: Any]) -> [String: Any] {
        var out = hotkeys
        for (id, value) in saved {
            if let marker = value as? String, marker == "absent" { out.removeValue(forKey: id) } else { out[id] = value }
        }
        return out
    }

    static func isEnabled(_ id: Int, in hotkeys: [String: Any]) -> Bool {
        guard let entry = hotkeys[String(id)] as? [String: Any] else { return true }
        if let b = entry["enabled"] as? Bool { return b }
        if let n = entry["enabled"] as? NSNumber { return n.boolValue }
        return true
    }

    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private static let setEnabled: SetEnabled? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(lib, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(sym, to: SetEnabled.self)
    }()

    private static func setLive(_ id: Int, enabled: Bool) { _ = setEnabled?(Int32(id), enabled) }

    private static func reload() {
        let tool = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-u"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
