// Flow: counts for the Fn key, so a failure can be measured instead of guessed.
//
// Only numbers are kept: how many Fn presses were swallowed by the tap, how often macOS
// disabled the tap, how often the tap was (re)installed, and how often secure input was on.
// The tap callback only increments an in-memory count. The file is written from the 5 s health check.

import Foundation
import Carbon.HIToolbox

/// True while macOS secure input is on (password fields, Secure Keyboard Entry). Taps go blind then.
func fnSecureInputOn() -> Bool { IsSecureEventInputEnabled() }

enum FnKeyEvent: String, CaseIterable, Sendable {
    case tapInstalled
    case swallowedFnPress
    case disabledByTimeout
    case disabledByUserInput
    case secureInputSample
    case retriedTapCreation
}

final class FnKeyStats: @unchecked Sendable {
    static let shared = FnKeyStats()

    /// Folder for the stats file. Overridable in tests.
    nonisolated(unsafe) static var directoryOverride: URL?

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var lastWritten: [String: Int]?

    func note(_ event: FnKeyEvent) {
        lock.lock()
        counts[event.rawValue, default: 0] += 1
        lock.unlock()
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        var out = Dictionary(uniqueKeysWithValues: FnKeyEvent.allCases.map { ($0.rawValue, 0) })
        for (key, value) in counts { out[key] = value }
        return out
    }

    static var fileURL: URL {
        let base = directoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("VOICE", isDirectory: true)
        return base.appendingPathComponent("fn-key-stats.json")
    }

    /// Writes the counts. Best effort; never throws into the hotkey path.
    func write(now: Date = Date()) {
        let counts = snapshot()
        lock.lock()
        let unchanged = lastWritten == counts
        if !unchanged { lastWritten = counts }
        lock.unlock()
        if unchanged { return }
        let payload: [String: Any] = ["updated": ISO8601DateFormatter().string(from: now), "counts": counts]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: [.atomic])
    }
}
