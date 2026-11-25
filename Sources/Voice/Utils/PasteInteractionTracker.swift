// PasteInteractionTracker.swift
// ============================================================
// Counts the moments the user may have moved to another spot: a mouse-down anywhere, or an app
// becoming active. CursorPaster stores the count at each paste. If the count is unchanged at the
// next dictation, nothing moved, so the same spot is still the place to insert (22 Nov 2026: T3
// Code, an Electron app, glued dictations together because its field could not be identified).
// Global monitors see clicks in other apps; no keyboard events are read.
// ============================================================

import AppKit

final class PasteInteractionTracker {
    static let shared = PasteInteractionTracker()

    /// Increases on every mouse-down or app activation seen since startup.
    private(set) var serial = 0
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        _ = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.bump()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.bump()
        }
    }

    private func bump() { serial &+= 1 }
}
