// PasteInteractionTracker.swift
// ============================================================
// Counts external input that can invalidate an unreadable caret: mouse-down,
// app activation, or key-down. Only counters are retained; key characters and
// modifier values are never stored or logged. Flow's own events and recording
// hotkeys do not count. No content is collected by this tracker.
// ============================================================

import AppKit

final class PasteInteractionTracker {
    static let shared = PasteInteractionTracker()

    /// Increases on every external key, mouse-down or app activation.
    private(set) var serial = 0
    /// Keyboard activity evidence for correction learning, not proof of authorship.
    private(set) var editSerial = 0
    private var started = false
    private var recordingBindings: [CapturedHotkey] = []
    private var eventMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var hotkeyObserver: NSObjectProtocol?

    func start() {
        guard !started else { return }
        started = true
        refreshBindings()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return }
            if event.type == .keyDown {
                let sourcePID = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)
                guard sourcePID != Int64(ProcessInfo.processInfo.processIdentifier),
                      !self.recordingBindings.contains(where: { $0.keyCode != nil && $0.matches(event, hotkeyIsDown: false) }) else { return }
                self.editSerial &+= 1
            }
            self.bump()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                               object: nil, queue: .main) { [weak self] _ in
            self?.bump()
        }
        hotkeyObserver = NotificationCenter.default.addObserver(forName: .voiceHotkeyChanged,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.refreshBindings()
        }
    }

    private func refreshBindings() { recordingBindings = HotkeyRole.allCases.flatMap { $0.loadBindings() } }
    private func bump() { serial &+= 1 }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let hotkeyObserver { NotificationCenter.default.removeObserver(hotkeyObserver) }
    }
}
