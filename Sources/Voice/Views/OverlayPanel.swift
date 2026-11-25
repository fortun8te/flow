// The floating dictation pill's window.
//
// OverlayPanel owns placement (active screen, Dock edge, side docks), the click-through policy
// and moving the pill. What the pill draws lives in Views/Pill/:
//   PillSkin.swift          every colour, size, font, waveform and motion value (skins)
//   PillStateMachine.swift  PillPhase, how flags resolve to a phase, every transition
//   PillRootView.swift      OverlayPillView: body, attached lines and cards
//   PillSurfaces.swift      capture surface, status pills, one-line notices, tooltip
//   PillIdleBar.swift       the resting sliver, the ready pill and its buttons
//   PillNotices.swift       cards and notice wording
//   PillPrimitives.swift    waveform, spinner, glyphs, hit-area and attachment helpers

import SwiftUI
import AppKit
import CoreVideo
import ApplicationServices
import os

// MARK: - Pure pill logic (unit-tested in PillOverlayLogicTests)

/// Timing constants for the pill. The toast durations must match the
/// dismiss timers in VoiceApp.swift (`showCancelledToast`, `showUndoPasteToast`)
/// or the draining bar disagrees with the toast's real lifetime.
enum PillTiming {
    /// Delay before collapsing to idle so a short processing flash stays visible.
    static let idleSettleDelay: TimeInterval = 0   // Wispr rests the moment status goes idle
    static let cancelToastSeconds: TimeInterval = 3.0
    static let undoPasteToastSeconds: TimeInterval = 3.5
    static let engineToastSeconds: TimeInterval = 2.0
    /// Animated frame moves (reposition, screen change). Zero with Reduce Motion.
    static func frameMoveDuration(heightChanged: Bool, reduceMotion: Bool) -> TimeInterval {
        // 23 Nov 2026: 0.20 s trimmed to 0.18 s; the pill should settle within a fifth of a second.
        reduceMotion ? 0 : (heightChanged ? 0.18 : 0.008)
    }
}
/// Where the pill's panel sits on a screen. The panel is pinned at the dock's place (an edge or a
/// corner) and stays inside the usable screen area, so nothing it shows reaches another display.
enum PillLayout {
    /// One size for every state: room for the widest card, its shadow, and buds beside the pill.
    static let panelSize = CGSize(width: 460, height: 300)
    /// Space between the panel and the screen edge (or the Dock) on the pinned side.
    static let edgeGap: CGFloat = 2
    /// Widest one-line notice next to a side dock.
    static let sideAttachMaxWidth: CGFloat = 300
    /// Widest card on a side dock.
    static let sideCardMaxWidth: CGFloat = 400

    static func clampedFraction(_ raw: CGFloat?) -> CGFloat {
        guard let raw, raw.isFinite else { return 0.5 }
        return min(1, max(0, raw))
    }

    /// Bottom-left origin of the panel. `bottomY` is where the usable area starts above the Dock;
    /// `sideFraction` places left and right docks along their edge.
    static func panelOrigin(dock: PillDockEdge, sideFraction: CGFloat?, visible: CGRect, bottomY: CGFloat,
                            size: CGSize = panelSize) -> CGPoint {
        let pin = dock.pin
        var x: CGFloat
        switch pin.x {
        case 0: x = visible.minX + edgeGap
        case 1: x = visible.maxX - size.width - edgeGap
        default: x = visible.midX - size.width / 2
        }
        var y: CGFloat
        switch pin.y {
        case 1: y = max(visible.minY, bottomY) + edgeGap
        case 0: y = visible.maxY - size.height - edgeGap
        default: y = visible.minY + clampedFraction(sideFraction) * visible.height - size.height / 2
        }
        x = min(max(visible.minX, visible.maxX - size.width), max(visible.minX, x))
        y = min(max(visible.minY, visible.maxY - size.height), max(visible.minY, y))
        return CGPoint(x: x, y: y)
    }
}

extension PillLayout {
    /// The usable area for the pill on a screen: the visible frame, kept below the camera notch when the
    /// menu bar hides (then the visible frame reaches the top of a notched screen).
    static func usableFrame(visible: CGRect, frame: CGRect, notchInset: CGFloat) -> CGRect {
        guard notchInset > 0 else { return visible }
        let top = min(visible.maxY, frame.maxY - notchInset)
        return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: max(0, top - visible.minY))
    }

    /// An origin on whole device pixels of a screen with `scale` (2 on Retina, 1 on most external displays),
    /// so the pill's hairlines stay crisp after moving between screens of different scaling.
    static func pixelAligned(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        let s = max(1, scale)
        return CGPoint(x: (point.x * s).rounded() / s, y: (point.y * s).rounded() / s)
    }
}

/// The quick switch between screens: the window fades out on the old screen and in on the new one while
/// the pill shrinks a little toward its dock and grows back (`OverlayPillView` scales on these notices).
enum PillScreenSwitch {
    static let notification = Notification.Name("flow.pillScreenSwitch")
    static let phaseKey = "phase"
    // 23 Nov 2026: out 0.07 s + in 0.11 s = 0.18 s in total (was 0.06 + 0.16 = 0.22 s).
    static let outSeconds = 0.07
    static let inSeconds = 0.11
    static let shrink: CGFloat = 0.92
}

/// Which screen the pill lives on. It follows the pointer: a new screen wins once the pointer has stayed
/// on it for `dwell` (70 ms), so a quick pass across a screen edge does not move the pill. Going back to
/// the screen it just left, within `cooldown` of a switch, needs `returnDwell`, so a pointer resting on a
/// boundary cannot make it ping-pong. Pure: screens are display ids, time is seconds.
struct PillScreenFollower: Equatable {
    // 23 Nov 2026: returnDwell 0.35 s made going back to the screen just left feel stuck; now 0.12 s, still
    // enough to stop a pointer resting on a boundary from ping-ponging.
    static let dwell: TimeInterval = 0.07
    static let returnDwell: TimeInterval = 0.12
    static let cooldown: TimeInterval = 0.8

    private(set) var current: Int?
    private(set) var previous: Int?
    private(set) var switchedAt: TimeInterval = -.infinity
    private(set) var candidate: Int?
    private(set) var candidateSince: TimeInterval = 0

    /// The index of the screen frame holding `point` (AppKit's rule: left and bottom edges inclusive of
    /// the pixel row inside, right and top edges as `NSMouseInRect` treats them).
    static func screenIndex(for point: CGPoint, frames: [CGRect]) -> Int? {
        if let hit = frames.firstIndex(where: { point.x >= $0.minX && point.x < $0.maxX && point.y > $0.minY && point.y <= $0.maxY }) {
            return hit
        }
        // Exactly on an outer edge (or in a gap between screens): the nearest screen.
        return frames.indices.min { a, b in distance(point, frames[a]) < distance(point, frames[b]) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// How long the pointer must stay on `screen` before the pill follows it.
    func requiredDwell(for screen: Int, at now: TimeInterval) -> TimeInterval {
        screen == previous && now - switchedAt < Self.cooldown ? Self.returnDwell : Self.dwell
    }

    /// Feed where the pointer is. Returns the screen to switch to now, or nil to stay.
    mutating func observe(pointerScreen: Int?, at now: TimeInterval) -> Int? {
        guard let screen = pointerScreen else { candidate = nil; return nil }
        guard let current else { force(screen, at: now); return screen }
        if screen == current { candidate = nil; return nil }
        if candidate != screen { candidate = screen; candidateSince = now }
        guard now - candidateSince >= requiredDwell(for: screen, at: now) else { return nil }
        previous = current
        self.current = screen
        switchedAt = now
        candidate = nil
        return screen
    }

    /// Seconds until a waiting candidate can be decided, or nil when nothing waits.
    func pendingDelay(at now: TimeInterval) -> TimeInterval? {
        guard let candidate else { return nil }
        return max(0, requiredDwell(for: candidate, at: now) - (now - candidateSince))
    }

    /// Put the pill on `screen` at once (first placement, a drop after a drag, a screen going away).
    mutating func force(_ screen: Int, at now: TimeInterval) {
        if current != screen { previous = current; switchedAt = now }
        current = screen
        candidate = nil
    }
}

/// Click-through: the panel takes clicks only on what the pill draws (`OverlayPillView` reports
/// it). Everything else falls through to the app underneath.
enum PillHitBand {
    /// The open idle pill (its clickable resting target), shared with the skins.
    static let idlePillSize = CGSize(width: PillSkin.standard.metrics.readyLength, height: PillSkin.standard.metrics.thickness)
    static let pickerButtonSize: CGFloat = PillSkin.standard.metrics.pickerSize
    static let pickerGap: CGFloat = PillSkin.standard.metrics.pickerGap
    /// Room around the resting sliver that still opens it, and around the open pill that keeps it open.
    static let restingHalo: CGFloat = 12
    static let openHalo: CGFloat = 12

    /// A clickable area (top-left coordinates) as a bottom-based band with a margin, or nil when
    /// nothing was measured.
    static func measured(_ area: CGRect, boundsHeight: CGFloat, margin: CGFloat = 4) -> CGRect? {
        guard !area.isNull, !area.isEmpty, area.width.isFinite, area.height.isFinite else { return nil }
        let grown = area.insetBy(dx: -margin, dy: -margin)
        return CGRect(x: grown.minX, y: boundsHeight - grown.maxY, width: grown.width, height: grown.height)
    }

    static func bottomPoint(_ point: CGPoint, height: CGFloat, flipped: Bool) -> CGPoint {
        flipped ? CGPoint(x: point.x, y: height - point.y) : point
    }
}

class OverlayPanel: NSPanel {
    private let recordingState: RecordingState
    /// What is behind the panel, for glass skins.
    let backdrop = PillBackdrop()

    var onTap: (() -> Void)?
    /// Polish closure carries the cleanup level: "light" / "medium" / "heavy".
    var onPolish: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onUndoCancel: (() -> Void)?
    var onUndoPaste: (() -> Void)?
    /// Called when the companion meeting dot is tapped during dictation,
    /// or when any meeting-stop affordance in the pill fires.
    var onStopMeeting: (() -> Void)?

    // Mouse-motion callbacks only update the input band. They never perform
    // active-screen selection, AX reads, or keyboard monitoring.

    /// User pref: hide pill from screen capture / screen recording.
    @objc dynamic private var hidePillFromScreenCapture: Bool {
        UserDefaults.standard.bool(forKey: "hidePillFromScreenCapture")
    }

    /// Debug toggle — painted red border + verbose logging.
    private var debugEnabled: Bool {
        UserDefaults.standard.bool(forKey: "voicePillDebug")
    }

    /// User-selected horizontal anchor: "bottomLeft" | "bottomCenter" | "bottomRight".
    /// Read live from UserDefaults so changes via the settings picker take effect
    /// immediately (we observe didChangeNotification and reposition).
    private var pillAnchor: String {
        UserDefaults.standard.string(forKey: "voice.pillPosition") ?? "bottomCenter"
    }

    /// True while the pill is being moved (`runPillMove`): the window keeps receiving events.
    fileprivate var pillDragActive = false

    // MARK: - Active-screen tracking

    /// Recent app-activation screen (set when another app activates). Mouse + key-window
    /// signals are polled live in resolveActiveScreen().
    private var lastAppActivationScreen: NSScreen?
    private var lastAppActivationAt: TimeInterval = 0

    /// Which screen the pill is on: follows the pointer with a short dwell and a guard against ping-pong.
    private var screenFollower = PillScreenFollower()
    /// The frame of the screen the pill is on, so a pointer move costs one rect test until it leaves.
    private var followedScreenFrame: CGRect = .null
    private var screenCheckScheduled = false
    /// Bumped by every screen switch, so an older switch's fade-in never lands after a newer one.
    private var screenSwitchGeneration = 0
    /// The frame a running switch is heading for: the same move asked again does not restart it.
    private var switchingTo: NSRect?

    /// True while the idle pill shows its hover bar. Posted by IdlePill so the
    /// hit-test band can grow to cover the bar and shrink back to just the bar.
    var idleExpanded = false

    // MARK: - DisplayLink

    private var displayLink: CVDisplayLink?
    private var currentTargetFrame: NSRect = .zero
    private var lastDockHiddenLogged: Bool? = nil

    // Display-link frame counter: dispatches to the main thread every `linkDivisor` refreshes.
    private var displayLinkFrameCounter: Int = 0
    /// Set on the main thread each tick: true while the pill rests with nothing happening.
    private var displayLinkIdle = false
    /// Frames per callback dispatch: 1 (every refresh) while the pill is active, 15 (about 4 Hz at 60 Hz)
    /// only once it has rested. Written on the main thread, read on the display-link thread, hence the lock.
    private let linkDivisor = OSAllocatedUnfairLock(initialState: 15)
    /// The link stays at full refresh until this time. Every change the eye should see at once pushes it out.
    private var fullRateUntil: TimeInterval = 0
    private let fullRateLinger: TimeInterval = 1.0
    /// Main-thread display-link ticks so far (a measurement seam for the tests).
    private(set) var tickCount = 0
    /// How far beyond the clickable pill the pointer still counts as near (full-rate link, instant reaction).
    private let pointerNearHalo: CGFloat = 80

    /// Set true by phase-change notifications so the display link does a full
    /// target-frame check on the next tick even while idle. Cleared after the check.
    private var needsReposition: Bool = false

    // Cached dock top edge — re-read at most every 3s (AX call is expensive at vsync rate).
    private var cachedDockTopEdge: CGFloat? = nil
    private weak var cachedDockScreen: NSScreen?
    private var dockEdgeCachedAt: TimeInterval = 0
    private let dockEdgeCacheTTL: TimeInterval = 3.0

    // Cached screen list — refreshed only on NSApplication.didChangeScreenParametersNotification.
    // NSScreen.screens is a property that allocates a new array every call; calling it multiple
    // times per display-link tick at 30 Hz produces measurable churn. One cached copy covers
    // resolveActiveScreen(), computeTargetFrame(), and the intersects-any-screen guard.
    private var cachedScreens: [NSScreen] = NSScreen.screens

    /// Periodic re-assert of front-most order while recording. Other apps
    /// occasionally push panels back even at high window levels — a cheap
    /// 5s tick keeps the pill on top without burning cycles when idle.
    private var topmostReassertTimer: Timer?

    /// Periodic poll (every 3 s) that detects meeting apps even when the user
    /// navigates to Meet/Zoom/Teams inside an already-frontmost browser window.
    /// App-activation notifications only fire on an app switch, so we need this
    /// to catch in-browser navigation (Chrome → new tab → meet.google.com).
    private var meetingPollTimer: Timer?
    private var observesCapturePreference = false

    /// Inspection panels use the real pointer policy without polling other apps or moving onscreen.
    init(recordingState: RecordingState, observesSystemChanges: Bool = true) {
        self.recordingState = recordingState

        let contentRect = NSRect(x: 0, y: 0, width: 180, height: 56)

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configure(positionOnScreen: observesSystemChanges)
        setupContent()
        observePillNotifications()
        if observesSystemChanges {
            observeScreenChanges()
            seedActiveScreenSignals()
        }
    }

    private func configure(positionOnScreen: Bool) {
        // CGShieldingWindowLevel sits above .screenSaver and is the highest
        // documented window level — used by the lock screen / shielding UIs.
        // Empirically beats other floating panels in Slack / Notion / VS Code
        // that occasionally render at .screenSaver themselves.
        level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // The pointer policy enables only the band containing real controls.
        ignoresMouseEvents = true

        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        animationBehavior = .utilityWindow

        applyScreenCapturePolicy()
        if positionOnScreen { repositionImmediate(animated: false) }
    }

    // MARK: - Topmost re-assert

    /// Start the 5s tick that re-issues orderFrontRegardless. Only ticks while
    /// the pill is in `recording` or `locked` — idle/transcribing/cancelled
    /// don't need the reassert. The tick self-cancels when state leaves
    /// recording/locked, so callers can fire-and-forget on phase change.
    func beginTopmostReassert() {
        guard topmostReassertTimer == nil else { return }
        topmostReassertTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.recordingState.isRecording || self.recordingState.isLocked {
                self.orderFrontRegardless()
            } else {
                timer.invalidate()
                self.topmostReassertTimer = nil
            }
        }
    }

    func endTopmostReassert() {
        topmostReassertTimer?.invalidate()
        topmostReassertTimer = nil
    }

    // MARK: - Meeting detection poll

    /// Start the 5 s poll. Fires immediately so the first detection doesn't
    /// wait a full interval. Called once from `observeScreenChanges()`.
    ///
    /// 5 s vs the previous 3 s: the AX window-title check (used to detect
    /// Google Meet / Zoom inside a browser tab) dispatches to a background
    /// queue so it never blocks the main thread, but the GCD scheduling and
    /// background work still consume CPU + power ~20 times per minute. At 5 s
    /// that drops to 12 times per minute. Detection latency goes from ≤3 s to
    /// ≤5 s — imperceptible for a "you just joined a meeting" trigger.
    private func startMeetingPollTimer() {
        guard meetingPollTimer == nil else { return }
        meetingPollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.pollMeetingDetection()
        }
        // First check right now, don't wait 5 s.
        pollMeetingDetection()
    }

    /// Check the current frontmost app for meeting activity.
    /// Posts `voiceAutoStartMeeting` on a false → true transition only.
    /// We do NOT auto-stop when the user switches windows — if they tab away
    /// from Chrome while still in the meeting we'd kill the capture. The user
    /// taps the pill (or the meeting ends deliberately) to stop.
    ///
    /// LATENCY FIX: The accessibility query inside `checkForMeetingApp` (used to
    /// detect Meet/Zoom/Teams running inside a browser tab) is a synchronous
    /// cross-process call that can take 50–300+ ms when the target app is busy.
    /// Running that on the main thread every 3 s stalls hotkey events and pill
    /// updates. We hop to a background queue for the AX read, then come back to
    /// the main actor only to apply the state delta. The fast path (frontmost
    /// app's bundleID is in the known meeting-app set) needs no AX call.
    private func pollMeetingDetection() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // When Voice's own pill is frontmost, frontmostApplication returns Voice.
        // Don't let that clear a previously-detected meeting app.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        // Capture pid + bundleID off the NSRunningApplication so the background
        // queue doesn't have to touch it (NSRunningApplication is thread-safe
        // for these properties but we avoid races by snapshotting).
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let (isMeeting, source) = self.detectMeetingForBundle(bundleID, pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recordingState.isMeetingAppActive = isMeeting
                self.recordingState.meetingSourceBundleID = isMeeting ? source : nil
                // Poll only updates tint state — auto-start is NOT triggered here.
                // No auto-stop: user controls the end of the capture explicitly.
            }
        }
    }

    /// Background-safe meeting detection. Does the bundle-ID match (fast) and,
    /// if `pid` belongs to a known browser, the AX window-title check (slow).
    /// Returns (isMeeting, sourceBundleID).
    nonisolated private func detectMeetingForBundle(_ bundleID: String?, pid: pid_t) -> (Bool, String?) {
        let meetBundleIDs: Set<String> = [
            "com.google.meet",
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.microsoft.teams",
            "com.apple.FaceTime",
            "com.cisco.webex.meetings",
        ]
        if let bundleID, meetBundleIDs.contains(bundleID) {
            return (true, bundleID)
        }
        let browserBundles: Set<String> = [
            "com.google.Chrome",
            "com.apple.Safari",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser",
        ]
        guard let bundleID, browserBundles.contains(bundleID), AXIsProcessTrusted() else {
            return (false, nil)
        }
        let axApp = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else { return (false, nil) }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else { return (false, nil) }
        let meetKeywords = ["Google Meet", "meet.google.com", "Zoom Meeting", "Microsoft Teams"]
        return (meetKeywords.contains(where: { title.contains($0) }) ? (true, bundleID) : (false, nil))
    }

    private func applyScreenCapturePolicy() {
        sharingType = hidePillFromScreenCapture ? .none : .readWrite
    }

    /// A phase or notice changed: recompute which part of the window takes clicks right away
    /// (not at the next pointer tick, which let a click land on transparent canvas in between).
    private func applyClickThroughPolicy(phase: PillPhase) {
        needsReposition = true
        wakeDisplayLink()
        if phase != .idle { idleExpanded = false; displayLinkIdle = false }
        switch phase {
        case .starting, .recording, .locked: beginTopmostReassert()
        default: endTopmostReassert()
        }
        updatePointerPolicy()
        updateBackdrop()
        // The dictation ended with the pointer on another screen: follow it now, not at its next move.
        if isVisible, !pillDragActive, !followedScreenFrame.isNull, !followedScreenFrame.contains(NSEvent.mouseLocation) {
            followPointerScreen()
        }
    }

    /// Frames a second of the live glass backdrop while the pill is open or working.
    static let liveBackdropFps = 30

    /// Glass skins see what is behind the panel: a live stream while the pill is open or working;
    /// while it rests, no stream, just the last frame (one fresh frame if it has none or it is stale).
    /// Flat skins and a hidden pill run nothing. Rules live in `PillBackdropPolicy`.
    private func updateBackdrop() {
        let skin = PillSkin.named(UserDefaults.standard.string(forKey: "pillSkin"))
        let resting = isIdlePhase && !idleExpanded && recordingState.flowNotice == nil
        switch PillBackdropPolicy.mode(isGlass: skin.isGlass, isShown: isVisible && alphaValue > 0.01,
                                       resting: resting, hasFrame: backdrop.frame != nil,
                                       frameAge: backdrop.frameAge) {
        case .off: backdrop.stop()
        case .live: backdrop.follow(window: self, fps: Self.liveBackdropFps)
        case .hold: backdrop.hold()
        case .snapshot: backdrop.snapshot(window: self)
        }
    }

    // MARK: - Notifications

    private func observeScreenChanges() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleScreenParametersChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(handleSpaceChanged),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        wc.addObserver(self, selector: #selector(handleAppActivation(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(handleAppHideUnhide),
                       name: NSWorkspace.didHideApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(handleAppHideUnhide),
                       name: NSWorkspace.didUnhideApplicationNotification, object: nil)

        // Fullscreen transitions on ANY window.
        nc.addObserver(self, selector: #selector(handleFullscreenChange),
                       name: NSWindow.didEnterFullScreenNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleFullscreenChange),
                       name: NSWindow.didExitFullScreenNotification, object: nil)

        UserDefaults.standard.addObserver(self,
                                          forKeyPath: "hidePillFromScreenCapture",
                                          options: [.new],
                                          context: nil)
        observesCapturePreference = true

        // Start polling for meeting apps (catches in-browser navigation without
        // an app-switch notification, e.g. Chrome → meet.google.com tab).
        startMeetingPollTimer()

        // Reposition when the user changes "voice.pillPosition" in Settings.
        // UserDefaults.didChangeNotification fires for ANY default change — we
        // accept that cost (it's cheap) rather than KVO each individual key.
        nc.addObserver(self,
                       selector: #selector(handlePillAnchorChanged),
                       name: UserDefaults.didChangeNotification,
                       object: nil)

        // The panel docks at eight places (PillDockEdge), chosen by dragging the pill.
    }

    private func observePillNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleIdleHover(_:)),
                       name: Notification.Name("voice.pillIdleHover"),
                       object: nil)
    }

    @objc private func handleIdleHover(_ note: Notification) {
        idleExpanded = (note.userInfo?["expanded"] as? Bool) ?? false
        wakeDisplayLink()
        if let lastPointerLocation { updatePointerPolicy(at: lastPointerLocation) }
        updateBackdrop()
    }

    @objc private func handlePillAnchorChanged() {
        // Cheap early-out: only reposition if we're not in the middle of a drag.
        guard !pillDragActive else { return }
        DispatchQueue.main.async { [weak self] in
            self?.repositionImmediate(animated: true)
            self?.updateBackdrop()
        }
    }

    // MARK: Bar menu (right-click)

    /// While set, the bar is hidden and lets every click through. Dictating brings it back.
    private var hiddenUntil: Date?

    /// Wispr's bar menu, in its order: Hide for 1 hour, Settings, Microphone, Transcript history,
    /// Paste last transcript. (Its reminder entries have no Flow equivalent.)
    func makeBarMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, to target: NSMenu = menu) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            target.addItem(item)
        }
        add("Hide for 1 hour", #selector(menuHide))
        add("Voice settings", #selector(menuSettings))
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let mics = NSMenu()
        let chosen = UserDefaults.standard.string(forKey: MicrophonePreference.key) ?? ""
        let auto = NSMenuItem(title: "Automatic", action: #selector(menuChooseMic(_:)), keyEquivalent: "")
        auto.target = self; auto.representedObject = ""; auto.state = chosen.isEmpty ? .on : .off
        mics.addItem(auto)
        for input in MicrophonePreference.inputs() {
            let item = NSMenuItem(title: input.name, action: #selector(menuChooseMic(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = input.uid; item.state = input.uid == chosen ? .on : .off
            mics.addItem(item)
        }
        micItem.submenu = mics
        menu.addItem(micItem)
        add("Dictation history", #selector(menuHistory))
        add("Paste last dictation", #selector(menuPasteLast))
        return menu
    }

    @objc private func menuChooseMic(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String ?? ""
        if uid.isEmpty { UserDefaults.standard.removeObject(forKey: MicrophonePreference.key) }
        else { UserDefaults.standard.set(uid, forKey: MicrophonePreference.key) }
    }

    @objc private func menuPasteLast() {
        NotificationCenter.default.post(name: .voicePasteLastTranscriptPressed, object: nil)
    }
    @objc private func menuHistory() {
        NotificationCenter.default.post(name: Notification.Name("flow.openHistory"), object: nil)
    }
    @objc private func menuSettings() {
        NotificationCenter.default.post(name: Notification.Name("flow.openSettings"), object: nil)
    }
    /// True while the "hidden for an hour" card is up: the window stays visible for its Undo.
    private var hideCardShowing = false
    private var undoHideObserver: NSObjectProtocol?
    @objc private func menuHide() {
        hiddenUntil = Date().addingTimeInterval(3600)
        idleExpanded = false
        hideCardShowing = true
        undoHideObserver.map(NotificationCenter.default.removeObserver)
        undoHideObserver = NotificationCenter.default.addObserver(forName: Notification.Name("flow.undoBarHide"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.undoHide() }
        }
        NotificationCenter.default.post(name: Notification.Name("flow.pillPointerExited"), object: nil)
        NotificationCenter.default.post(name: Notification.Name("flow.barHiddenCard"), object: nil, userInfo: ["show": true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.hideCardShowing else { return }
            self.hideCardShowing = false
            NotificationCenter.default.post(name: Notification.Name("flow.barHiddenCard"), object: nil, userInfo: ["show": false])
            guard self.hiddenUntil != nil else { return }
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.1; self.animator().alphaValue = 0 }
        }
    }
    /// Undo from the "hidden for an hour" card.
    func undoHide() {
        hideCardShowing = false
        hiddenUntil = nil
        alphaValue = 1
        NotificationCenter.default.post(name: Notification.Name("flow.barHiddenCard"), object: nil, userInfo: ["show": false])
    }

    /// The pill can be moved whenever it is showing something to grab. Notices are not movable.
    /// Wispr lets notices be dragged too (their buttons still click: a move needs 5 pt of travel).
    var canStartPillMove: Bool { true }

    /// Hide the pill, run the drop-zone overlay, then dock on the chosen edge.
    func runPillMove() {
        pillDragActive = true
        idleExpanded = false
        NotificationCenter.default.post(name: Notification.Name("flow.pillPointerExited"), object: nil)
        let previousAlpha = alphaValue
        alphaValue = 0
        dragDock = nil
        let snapSampler = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleDragDock() }
        }
        RunLoop.main.add(snapSampler, forMode: .eventTracking)
        let dropped = PillDragSession.run(from: self)
        snapSampler.invalidate()
        dragDock = nil
        PillDebugLog.write("move dropped=\(dropped?.rawValue ?? "cancelled")")
        let finish = { [weak self] in
            guard let self else { return }
            if let dropped {
                UserDefaults.standard.set(dropped.anchor, forKey: "voice.pillPosition")
                UserDefaults.standard.set(0.5, forKey: "voice.pillSideFraction")
                if let screen = self.cachedScreens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
                    self.screenFollower.force(Self.displayID(screen), at: CACurrentMediaTime())
                    self.followedScreenFrame = screen.frame
                }
            }
            self.pillDragActive = false
            self.repositionImmediate(animated: false)
            self.alphaValue = previousAlpha
        }
        // The pill reappears on its new edge as the ghost lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + (dropped == nil ? 0 : 0.3), execute: finish)
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == "hidePillFromScreenCapture" {
            applyScreenCapturePolicy()
        }
    }

    @objc private func handleScreenParametersChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.cachedScreens = NSScreen.screens  // refresh screen list cache
            self?.cachedDockTopEdge = nil           // force re-read after screen change
            self?.restartDisplayLink()
            self?.repositionImmediate(animated: true)
        }
    }

    @objc private func handleSpaceChanged() {
        // Settle delay — space transitions animate ~0.5s.
        DispatchQueue.main.async { [weak self] in
            self?.orderFrontRegardless()
            self?.repositionImmediate(animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.orderFrontRegardless()
            self?.repositionImmediate(animated: true)
        }
    }

    @objc private func handleFullscreenChange() {
        DispatchQueue.main.async { [weak self] in
            self?.repositionImmediate(animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.repositionImmediate(animated: true)
        }
    }

    @objc private func handleAppActivation(_ note: Notification) {
        // Record which screen the activated app sits on.
        let now = CACurrentMediaTime()
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            if let screen = screenForFrontmostWindow(of: app) {
                lastAppActivationScreen = screen
                lastAppActivationAt = now
            }
            // Hop off-main for the AX-touching meeting detection — see
            // pollMeetingDetection() for rationale.
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let (isMeeting, source) = self.detectMeetingForBundle(bundleID, pid: pid)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.recordingState.isMeetingAppActive = isMeeting
                    self.recordingState.meetingSourceBundleID = isMeeting ? source : nil
                }
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.repositionImmediate(animated: true)
        }
    }

    @objc private func handleAppHideUnhide() {
        DispatchQueue.main.async { [weak self] in
            self?.repositionImmediate(animated: true)
        }
    }

    // MARK: - Signal seeding

    /// Polls NSEvent.mouseLocation on demand — cheap, no global monitor needed.
    /// Uses `cachedScreens` to avoid allocating a new array per call.
    private func currentMouseScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return cachedScreens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
    }

    private func seedActiveScreenSignals() {
        // App activation seed — keeps the first computeTargetFrame from picking
        // a stale screen on launch. Mouse + key-window are polled live each tick.
        if let s = NSScreen.main {
            lastAppActivationScreen = s
            lastAppActivationAt = CACurrentMediaTime()
        }
    }

    /// Frontmost window of a given app via CGWindowList (layer 0, ordered).
    private func screenForFrontmostWindow(of app: NSRunningApplication) -> NSScreen? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let pid = app.processIdentifier
        for w in info {
            guard let wpid = w[kCGWindowOwnerPID as String] as? Int32, wpid == pid else { continue }
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = bounds["X"] ?? 0
            let y = bounds["Y"] ?? 0
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            // CG coords are top-left origin in the global display space.
            // Convert to NS coords (bottom-left) by flipping against the
            // total screen-space height.
            let primary = cachedScreens.first?.frame ?? .zero
            let nsY = primary.maxY - (y + height)
            let center = CGPoint(x: x + width / 2, y: nsY + height / 2)
            if let s = cachedScreens.first(where: { NSMouseInRect(center, $0.frame, false) }) {
                return s
            }
        }
        return nil
    }

    // MARK: - Active screen resolution

    static func displayID(_ screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? screen.hash
    }

    /// The screen the pill is on. Wispr follows the cursor only, not the app that became active;
    /// `PillScreenFollower` adds the dwell and the ping-pong guard.
    private func resolveActiveScreen() -> NSScreen? {
        let now = CACurrentMediaTime()
        let attached = cachedScreens
        // While a dictation runs the pill stays where it started, so it never jumps mid-sentence.
        if !dictationHoldsScreen {
            let mouse = PillScreenFollower.screenIndex(for: NSEvent.mouseLocation, frames: attached.map(\.frame))
                .map { Self.displayID(attached[$0]) }
            _ = screenFollower.observe(pointerScreen: mouse, at: now)
        }
        if let id = screenFollower.current, let screen = attached.first(where: { Self.displayID($0) == id }) {
            followedScreenFrame = screen.frame
            return screen
        }
        // The followed screen went away (unplugged, lid closed): the pointer's screen, else the main one.
        guard let chosen = currentMouseScreen() ?? NSScreen.main ?? cachedScreens.first ?? NSScreen.screens.first else {
            return nil
        }
        screenFollower.force(Self.displayID(chosen), at: now)
        followedScreenFrame = chosen.frame
        return chosen
    }

    /// True from the hotkey until the text lands: the pill does not follow the pointer to another screen
    /// then (it moves on afterwards, the dwell already served).
    private var dictationHoldsScreen: Bool {
        switch resolvedPhase {
        case .starting, .recording, .locked, .transcribing, .polishingSelection: return true
        case .idle, .polishDone, .cancelled, .undoPaste: return false
        }
    }

    /// A pointer move left the pill's screen: decide now, or check again once the dwell has passed.
    private func followPointerScreen() {
        guard !dictationHoldsScreen else { return }
        let now = CACurrentMediaTime()
        let attached = cachedScreens
        let mouse = PillScreenFollower.screenIndex(for: NSEvent.mouseLocation, frames: attached.map(\.frame))
            .map { Self.displayID(attached[$0]) }
        let before = screenFollower.current
        if let to = screenFollower.observe(pointerScreen: mouse, at: now), to != before {
            if let screen = attached.first(where: { Self.displayID($0) == to }) { followedScreenFrame = screen.frame }
            if let target = computeTargetFrame() { moveToScreen(target) }
            return
        }
        if let delay = screenFollower.pendingDelay(at: now), !screenCheckScheduled {
            screenCheckScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.002) { [weak self] in
                guard let self else { return }
                self.screenCheckScheduled = false
                if !self.followedScreenFrame.contains(NSEvent.mouseLocation) { self.followPointerScreen() }
            }
        }
    }

    /// Moves the panel to a frame on another screen: the pill fades and shrinks a little toward its dock
    /// on the old screen (60 ms), then appears on the new one and grows back as it fades in. It never
    /// slides across the gap between screens.
    private func moveToScreen(_ target: NSRect) {
        guard !pillDragActive, switchingTo != target else { return }
        screenSwitchGeneration += 1
        let generation = screenSwitchGeneration
        currentTargetFrame = target
        let animate = isVisible && alphaValue > 0.99 && hiddenUntil == nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate else {
            // A switch still fading when this one lands has lost its fade-in (the generation moved on):
            // bring the pill back at once, or it would stay invisible on the new screen.
            let interrupted = isVisible && hiddenUntil == nil && alphaValue < 0.99
            switchingTo = nil
            setFrame(target, display: true)
            if interrupted {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0
                    self.animator().alphaValue = 1
                }
                alphaValue = 1
                NotificationCenter.default.post(name: PillScreenSwitch.notification, object: nil,
                                                userInfo: [PillScreenSwitch.phaseKey: "in"])
            }
            orderFrontRegardless()
            updateBackdrop()
            return
        }
        switchingTo = target
        NotificationCenter.default.post(name: PillScreenSwitch.notification, object: nil, userInfo: [PillScreenSwitch.phaseKey: "out"])
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PillScreenSwitch.outSeconds
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.screenSwitchGeneration else { return }
                self.switchingTo = nil
                self.setFrame(self.currentTargetFrame, display: true)
                self.orderFrontRegardless()
                self.updateBackdrop()
                NotificationCenter.default.post(name: PillScreenSwitch.notification, object: nil,
                                                userInfo: [PillScreenSwitch.phaseKey: "in"])
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = PillScreenSwitch.inSeconds
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.animator().alphaValue = 1
                }
            }
        })
    }

    // MARK: - Dock detection

    /// Try Accessibility API for the Dock's actual frame. Returns the top
    /// edge of the dock in NS coords, or nil if AX denied / Dock hidden.
    private func dockTopEdge(on screen: NSScreen) -> CGFloat? {
        // Find Dock process.
        guard let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else { return nil }

        let axApp = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return nil }

        // Look for the dock list (first child usually).
        for kid in kids {
            var posValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(kid, kAXPositionAttribute as CFString, &posValue) == .success,
                  AXUIElementCopyAttributeValue(kid, kAXSizeAttribute as CFString, &sizeValue) == .success else {
                continue
            }
            var pos = CGPoint.zero
            var size = CGSize.zero
            guard let pv = posValue, CFGetTypeID(pv) == AXValueGetTypeID(),
                  let sv = sizeValue, CFGetTypeID(sv) == AXValueGetTypeID() else { continue }
            let axPos = unsafeBitCast(pv, to: AXValue.self)
            let axSize = unsafeBitCast(sv, to: AXValue.self)
            AXValueGetValue(axPos, .cgPoint, &pos)
            AXValueGetValue(axSize, .cgSize, &size)

            if size.width <= 0 || size.height <= 0 { continue }

            // Convert CG (top-left) → NS (bottom-left) using primary screen height.
            let primaryFrame = NSScreen.screens.first?.frame ?? screen.frame
            let nsBottom = primaryFrame.maxY - (pos.y + size.height)
            let nsTop = nsBottom + size.height

            // Only consider if the dock is on the same screen.
            let dockRect = NSRect(x: pos.x, y: nsBottom, width: size.width, height: size.height)
            if screen.frame.intersects(dockRect) {
                return nsTop
            }
        }
        return nil
    }

    // MARK: - Target frame computation

    private func computeTargetFrame() -> NSRect? {
        guard let screen = resolveActiveScreen() else { return nil }
        // One panel size for every state, pinned at the dock's place; the pill is pinned inside it
        // at the same point, so it never slides while it changes shape.
        let dockHidden = screen.visibleFrame.size == screen.frame.size
        // The Dock's top edge (AX, cached for 3 s), or the usable area's bottom.
        var bottomY = screen.visibleFrame.minY
        if !dockHidden {
            let now = CACurrentMediaTime()
            if cachedDockScreen !== screen || cachedDockTopEdge == nil || (now - dockEdgeCachedAt) > dockEdgeCacheTTL {
                cachedDockScreen = screen
                cachedDockTopEdge = dockTopEdge(on: screen)
                dockEdgeCachedAt = now
            }
            if let dockTop = cachedDockTopEdge { bottomY = dockTop }
        } else {
            cachedDockTopEdge = nil
        }
        let storedFraction: CGFloat? = UserDefaults.standard.object(forKey: "voice.pillSideFraction") == nil
            ? nil : CGFloat(UserDefaults.standard.double(forKey: "voice.pillSideFraction"))
        let notch: CGFloat
        if #available(macOS 12.0, *) { notch = screen.safeAreaInsets.top } else { notch = 0 }
        let usable = PillLayout.usableFrame(visible: screen.visibleFrame, frame: screen.frame, notchInset: notch)
        let origin = PillLayout.pixelAligned(
            PillLayout.panelOrigin(dock: PillDockEdge.from(anchor: pillAnchor), sideFraction: storedFraction,
                                   visible: usable, bottomY: bottomY),
            scale: screen.backingScaleFactor)
        if debugEnabled, lastDockHiddenLogged != dockHidden {
            print("[VOICE/dbg] screen=\(screen.localizedName) dockHidden=\(dockHidden) origin=\(origin)")
            lastDockHiddenLogged = dockHidden
        }
        return NSRect(origin: origin, size: PillLayout.panelSize)
    }

    /// True when the pill is in the idle phase — mirrors `rawPhase` from OverlayPillView
    /// but computed directly from RecordingState so the panel can check it without
    /// touching any SwiftUI state. Used to throttle the display link at idle AND
    /// to shrink the hit-test band so the idle dot doesn't intercept clicks
    /// across a wide invisible strip.
    var isIdlePhase: Bool {
        // A one-line notice floats beside the pill; the pill underneath is still the resting bar.
        if recordingState.isCapturingMeeting || recordingState.flowNotice?.isCard == true || hideCardShowing { return false }
        return resolvedPhase == .idle
    }

    private var resolvedPhase: PillPhase {
        PillPhaseResolver.phase(
            isRecording: recordingState.isRecording,
            isLocked: recordingState.isLocked,
            pendingStart: recordingState.pendingRecordingStart,
            isTranscribing: recordingState.isTranscribing,
            isPolishingSelection: recordingState.isPolishingSelection,
            showingCancelled: recordingState.showingCancelledToast,
            showingUndoPaste: recordingState.showingUndoPasteToast,
            showingPolishDone: recordingState.polishDiff != nil
        )
    }

    /// Immediate reposition — used for notifications. Bypasses display-link
    /// throttle and animates if requested.
    private func repositionImmediate(animated: Bool) {
        // Signal the display link to do a full frame check on the next tick
        // even if we're currently throttled (idle rate). This covers cases
        // like space-change or screen-parameter-change where the pill needs
        // to snap to a new position even while idle.
        needsReposition = true
        guard let target = computeTargetFrame() else { return }

        let intersectsAnyScreen = cachedScreens.contains { $0.frame.intersects(target) }
        guard intersectsAnyScreen else {
            if debugEnabled { print("[VOICE/dbg] target offscreen, skip: \(target)") }
            return
        }

        // Another screen: the quick fade-and-grow switch.
        let fromScreen = cachedScreens.first { $0.frame.intersects(frame) }
        let toScreen = cachedScreens.first { $0.frame.intersects(target) }
        if let fromScreen, let toScreen, fromScreen !== toScreen, isVisible {
            moveToScreen(target)
            return
        }

        currentTargetFrame = target

        // The bar never slides across the screen. It used to glide from its old place to the new one (after a
        // drag to another edge, a screen or space change, an app unhiding), which read as the pill flying in
        // from the centre. Now it is simply at the new place; a long jump gets a short fade so it does not pop.
        _ = animated
        let far = hypot(target.midX - frame.midX, target.minY - frame.minY) > 40
        let shown = alphaValue > 0.99
        if far, shown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 0
            setFrame(target, display: true)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        } else {
            setFrame(target, display: true)
        }

        // Re-lift window order after every reposition — some apps temporarily
        // push panels back even at .screenSaver level when they activate.
        orderFrontRegardless()
        updateBackdrop()
    }

    /// Display-link tick — called on vsync. Compares target to current frame,
    /// animates if delta exceeds 0.5pt.
    ///
    /// Frame mutation is deferred to the next runloop tick to ensure we never
    /// call setFrame from inside a CA transaction commit. The display link
    /// dispatches us to main, but main can land mid-transaction during a
    /// SwiftUI re-render — directly calling setFrame from there crashes with
    /// `_postWindowNeedsUpdateConstraints` on macOS 26.
    fileprivate func displayLinkTick() {
        tickCount &+= 1
        displayLinkIdle = isIdlePhase && !idleExpanded
        // Full refresh whenever anything is happening (recording, working, hover, a recent change).
        // The link drops to about 4 Hz only after `fullRateLinger` of true rest.
        let rest = displayLinkIdle && CACurrentMediaTime() >= fullRateUntil
        linkDivisor.withLock { $0 = rest ? 15 : 1 }
        // At rest the display link itself still woke the process at the screen's refresh rate (about 120 times
        // a second on ProMotion) just to be divided down. Park it: a slack 2 Hz timer covers the resting pill, and
        // wakeDisplayLink brings the link straight back (23 Nov 2026).
        if rest, displayLink != nil { parkDisplayLink() }
        // The pointer monitors deliver every move, so the tick only backstops them when they are missing.
        if !pointerMonitorsInstalled { updatePointerPolicy() }
        // IDLE EARLY-EXIT: the CVDisplayLink callback already throttles dispatch
        // to ~4Hz when idle. But if we're here AND idle, do a cheap short-circuit:
        // if the frame hasn't moved, skip all the downstream work immediately.
        // This costs one frame-comparison per 4Hz tick instead of the full
        // resolveActiveScreen + computeTargetFrame path.
        if isIdlePhase {
            let forced = needsReposition
            needsReposition = false
            let cur = self.frame
            // Only run the full target computation if we don't already know the frame is current.
            // currentTargetFrame is updated by repositionImmediate so it tracks the last known good position.
            let cached = currentTargetFrame
            if !forced && cached != .zero &&
               abs(cached.minX - cur.minX) < 0.5 &&
               abs(cached.minY - cur.minY) < 0.5 &&
               abs(cached.height - cur.height) < 0.5 {
                return
            }
        } else {
            needsReposition = false
        }

        guard let target = computeTargetFrame() else { return }
        let cur = self.frame
        let dx = abs(target.minX - cur.minX)
        let dy = abs(target.minY - cur.minY)
        let dh = abs(target.height - cur.height)
        if dx < 0.5 && dy < 0.5 && dh < 0.5 { return }

        let intersectsAnyScreen = cachedScreens.contains { $0.frame.intersects(target) }
        guard intersectsAnyScreen else { return }

        currentTargetFrame = target

        // Defer onto the next runloop pass to escape any active CA transaction.
        // 0.0s asyncAfter is equivalent to "schedule for the next event loop turn"
        // and is the cheapest way to guarantee we're outside layoutSubtreeIfNeeded.
        let duration = PillTiming.frameMoveDuration(
            heightChanged: dh > 1,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        DispatchQueue.main.asyncAfter(deadline: .now()) { [weak self] in
            guard let self else { return }
            // Re-check the target — by the time this fires the screen / state
            // may have moved on. Recomputing is cheap (dock edge is cached).
            guard let now = self.computeTargetFrame() else { return }
            let stillNeedsMove =
                abs(now.minX - self.frame.minX) >= 0.5 ||
                abs(now.minY - self.frame.minY) >= 0.5 ||
                abs(now.height - self.frame.height) >= 0.5
            guard stillNeedsMove else { return }
            // Wispr hides the bar and shows it again on the new display; it never slides across.
            let fromScreen = self.cachedScreens.first { $0.frame.intersects(self.frame) }
            let toScreen = self.cachedScreens.first { $0.frame.intersects(now) }
            if let fromScreen, let toScreen, fromScreen !== toScreen {
                self.moveToScreen(now)
                return
            }

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.animator().setFrame(now, display: true)
            }
        }
    }

    // MARK: - CVDisplayLink

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        let err = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard err == kCVReturnSuccess, let link else {
            print("[VOICE] CVDisplayLinkCreate failed (\(err)) — falling back to Timer")
            startFallbackTimer()
            return
        }
        displayLink = link

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, ctx) -> CVReturn in
            guard let ctx else { return kCVReturnSuccess }
            let panel = Unmanaged<OverlayPanel>.fromOpaque(ctx).takeUnretainedValue()
            panel.displayLinkFrameCounter &+= 1
            // Every refresh while the pill is active; ~4 Hz only while it rests (see displayLinkTick).
            let every = panel.linkDivisor.withLock { $0 }
            guard panel.displayLinkFrameCounter % every == 0 else { return kCVReturnSuccess }
            // Keep cheap input-region checks responsive. The main-thread
            // tick still skips expensive positioning/AX work while idle.
            DispatchQueue.main.async { panel.displayLinkTick() }
            return kCVReturnSuccess
        }, opaque)

        // Bind to the current active display.
        if let screen = NSScreen.main,
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            CVDisplayLinkSetCurrentCGDisplay(link, CGDirectDisplayID(displayID))
        }

        CVDisplayLinkStart(link)
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
    }

    private func restartDisplayLink() {
        stopDisplayLink()
        startDisplayLink()
    }

    /// Fallback only if CVDisplayLink fails to create.
    private var fallbackTimer: Timer?
    private func startFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.displayLinkTick()
        }
    }

    // MARK: - Content / lifecycle

    private var pointerWasInsideBand = false
    private var pointerWasInsideIdleHotArea = false
    private var lastPointerLocation: NSPoint?
    /// Common entry for pointer events and the polling backstop.
    func handlePointerMotion(at mouse: NSPoint) {
        // The pointer left the pill's screen: follow it (one rect test per move until then).
        if isVisible, !pillDragActive, !followedScreenFrame.isNull, !followedScreenFrame.contains(mouse) {
            followPointerScreen()
        }
        // Most movement is nowhere near the pill. Do not read observed state,
        // convert view coordinates, or inspect screens on that path.
        guard isVisible, pointerWasInsideBand || pillDragActive || frame.contains(mouse) else { return }
        updatePointerPolicy(at: mouse)
    }
    /// Where the window takes clicks, measured from the bottom of the hosting view: what the pill
    /// draws, with a halo while idle so the pointer can find and keep the small pill.
    func interactiveBand(in bounds: CGSize) -> CGRect {
        let margin: CGFloat = isIdlePhase ? (idleExpanded ? PillHitBand.openHalo : PillHitBand.restingHalo) : 4
        return PillHitBand.measured(measuredHitArea, boundsHeight: bounds.height, margin: margin) ?? .zero
    }

    /// Clickable views' union in the hosting view's top-left coordinates (`OverlayPillView`).
    private var measuredHitArea = CGRect.null
    func updateMeasuredHitArea(_ area: CGRect) {
        guard area != measuredHitArea else { return }
        measuredHitArea = area
        updatePointerPolicy()
    }
    func updatePointerPolicy(at mouse: NSPoint = NSEvent.mouseLocation) {
        guard isVisible, let view = contentView else { return }
        lastPointerLocation = mouse
        if let until = hiddenUntil, !hideCardShowing {
            if Date() < until && isIdlePhase {
                if !ignoresMouseEvents { ignoresMouseEvents = true }
                if alphaValue != 0 { alphaValue = 0 }
                return
            }
            hiddenUntil = nil
            alphaValue = 1
        }
        let interactive = hideCardShowing || recordingState.flowNotice != nil || recordingState.isCapturingMeeting
            || recordingState.isRecording || recordingState.isLocked || recordingState.showingCancelledToast
            || recordingState.showingUndoPasteToast || recordingState.polishDiff != nil || isIdlePhase
        let local = view.convert(convertPoint(fromScreen: mouse), from: nil)
        let point = PillHitBand.bottomPoint(local, height: view.bounds.height, flipped: view.isFlipped)
        // During a drag the pill moves away from the cursor, so the band check
        // alone would make the window click-through mid-drag and lose the mouse-up.
        // On a side dock the transparent window reaches past the screen edge. Wispr's bar lives
        // inside its display, so the pointer on a neighbouring display never opens or holds it.
        let pillPoint = NSPoint(x: frame.midX, y: frame.midY)
        let pillScreen = cachedScreens.first { NSMouseInRect(pillPoint, $0.frame, false) }
        let onPillScreen = pillScreen.map { NSMouseInRect(mouse, $0.frame, false) } ?? true
        let inside = pillDragActive
            || (interactive && onPillScreen && interactiveBand(in: view.bounds.size).contains(point))
        // Near the pill the link runs at full rate, so the pill reacts within a frame of the pointer.
        let band = interactiveBand(in: view.bounds.size)
        if onPillScreen, band != .zero, band.insetBy(dx: -pointerNearHalo, dy: -pointerNearHalo).contains(point) {
            noteNearPointer()
        }
        // WindowServer, not just NSView hit testing, must ignore transparent
        // canvas outside the controls so clicks reach the app underneath.
        if ignoresMouseEvents == inside {
            ignoresMouseEvents = !inside
            PillDebugLog.write("policy inside=\(inside) interactive=\(interactive) idle=\(isIdlePhase) point=\(point) band=\(interactiveBand(in: view.bounds.size)) bounds=\(view.bounds.size)")
        }
        let leftBand = pointerWasInsideBand && !inside
        pointerWasInsideBand = inside
        let insideIdleHotArea = interactive && onPillScreen && isIdlePhase && interactiveBand(in: view.bounds.size).contains(point)
        if pointerWasInsideIdleHotArea != insideIdleHotArea {
            pointerWasInsideIdleHotArea = insideIdleHotArea
            PillDebugLog.write("hover.area inside=\(insideIdleHotArea)")
            NotificationCenter.default.post(name: Notification.Name("flow.pillPointerChanged"), object: nil,
                                            userInfo: ["inside": insideIdleHotArea])
        }
        if leftBand {
            NotificationCenter.default.post(name: Notification.Name("flow.pillPointerExited"), object: nil)
        }
    }

    private func setupContent() {
        let hostingView = PillHostingView(
            rootView: OverlayPillView(
                state: recordingState,
                onTap: { [weak self] in self?.onTap?() },
                onPolish: { [weak self] level in self?.onPolish?(level) },
                onCancel: { [weak self] in self?.onCancel?() },
                onConfirm: { [weak self] in self?.onConfirm?() },
                onUndoCancel: { [weak self] in self?.onUndoCancel?() },
                onUndoPaste: { [weak self] in self?.onUndoPaste?() },
                onStopMeeting: { [weak self] in self?.onStopMeeting?() },
                onPhaseChange: { [weak self] phase in
                    self?.applyClickThroughPolicy(phase: phase)
                },
                onHitAreaChange: { [weak self] area in
                    self?.updateMeasuredHitArea(area)
                },
                backdropSource: backdrop
            )
        )

        if debugEnabled {
            hostingView.wantsLayer = true
            hostingView.layer?.borderColor = NSColor.red.cgColor
            hostingView.layer?.borderWidth = 1
        }

        contentView = hostingView
    }

    /// Motion events make the click-through panel receptive before the next click.
    /// The timer remains a backstop for missed releases and stationary state changes.
    private var pointerTimer: Timer?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?

    private var pointerMonitorsInstalled: Bool { globalPointerMonitor != nil && localPointerMonitor != nil }

    /// The pointer is near the pill: run the display link at full rate now, not at the next tick.
    private func noteNearPointer() {
        wakeDisplayLink()
    }

    /// Full refresh now and for `fullRateLinger` after. The divisor is set here, not left to the next tick,
    /// because a resting link ticks only every 15 frames and would delay the reaction by up to 250 ms.
    private func wakeDisplayLink() {
        fullRateUntil = CACurrentMediaTime() + fullRateLinger
        linkDivisor.withLock { $0 = 1 }
        if restTimer != nil {
            restTimer?.invalidate(); restTimer = nil
            startDisplayLink()
        }
    }

    /// The resting pill's only clock while the display link is parked.
    private var restTimer: Timer?
    private func parkDisplayLink() {
        stopDisplayLink()
        restTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.isIdlePhase || self.idleExpanded || CACurrentMediaTime() < self.fullRateUntil {
                self.restTimer?.invalidate(); self.restTimer = nil
                self.startDisplayLink()
            } else {
                self.displayLinkTick()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        restTimer = timer
    }

    /// Dock the dragged pill would land on, sampled while the drag loop runs (its events never reach
    /// the monitors). Changing dock is a snap and gets a tap.
    private var dragDock: PillDockEdge?
    private func sampleDragDock() {
        let mouse = NSEvent.mouseLocation
        guard let screen = cachedScreens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        let area = screen.visibleFrame
        let dock = PillDockEdge.nearest(to: CGPoint(x: mouse.x - area.minX, y: area.maxY - mouse.y), in: area.size)
        if let dragDock, dragDock != dock { PillHaptics.dockSnap() }
        dragDock = dock
    }

    private func startPointerMonitoring() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if globalPointerMonitor == nil {
            globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.handlePointerMotion(at: NSEvent.mouseLocation) }
            }
        }
        if localPointerMonitor == nil {
            acceptsMouseMovedEvents = true
            localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.handlePointerMotion(at: NSEvent.mouseLocation) }
                return event
            }
        }
    }

    func showPersistent() {
        repositionImmediate(animated: false)
        orderFrontRegardless()
        startDisplayLink()
        startPointerMonitoring()
        if pointerTimer == nil {
            // With both monitors the pointer is handled on every move; the timer only backstops missed events.
            let interval = pointerMonitorsInstalled ? 0.5 : 1.0 / 30.0
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePointerPolicy() }
            }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        }
        if debugEnabled {
            let f = self.frame
            print("[VOICE/dbg] Pill positioned at x=\(Int(f.minX)) y=\(Int(f.minY)) on \(resolveActiveScreen()?.localizedName ?? "no screen")")
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    deinit {
        stopDisplayLink()
        restTimer?.invalidate()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        pointerTimer?.invalidate()
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        topmostReassertTimer?.invalidate()
        topmostReassertTimer = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if observesCapturePreference {
            UserDefaults.standard.removeObserver(self, forKeyPath: "hidePillFromScreenCapture")
        }
    }
}

// MARK: - Pill diagnostics

/// Off by default. `defaults write com.example.flow voicePillDebug -bool true` writes pointer
/// and click decisions to ~/Library/Logs/Flow-pill.log so a dead pill can be diagnosed.
enum PillDebugLog {
    static let enabled = UserDefaults.standard.bool(forKey: "voicePillDebug")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Flow-pill.log")
    static func write(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let text = "\(Date().timeIntervalSince1970) \(line())\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - PillHostingView

/// NSHostingView subclass that only captures mouse events inside the actual
/// visible pill region. The 180×56 panel has substantial empty padding around
/// the capsule; without this override, AppKit consumes clicks anywhere in the
/// panel rect (even when SwiftUI's `.contentShape(Capsule())` ignores them),
/// silently swallowing the user's click on whatever app is underneath.
///
/// We approximate the visible region as a horizontally-centered band at the
/// bottom of the panel matching the largest possible pill bounds (160×34).
/// Points outside that band return nil → AppKit forwards the click to the
/// window below.
private final class PillHostingView<Content: View>: NSHostingView<Content> {
    // Bottom-anchored band that contains every pill phase (idle dot, recording
    // capsule, locked capsule, transcribing dot, cancelled toast). Generous
    // enough to never clip a real interactive control, tight enough that all
    // the click-through padding goes to the app below.

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // CRITICAL: disable constraint-based layout for this hosting view. The
        // panel uses explicit setFrame() calls from the display link; without
        // this, NSHostingView's internal constraints fight setFrame during the
        // CA transaction commit phase, triggering an exception in
        // `_postWindowNeedsUpdateConstraints` (observed crash on live-partial
        // expand on macOS 26+).
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("not implemented")
    }

    // Pin safe-area insets to zero. SwiftUI's auto safe-area handling on a
    // borderless overlay panel triggers `invalidateSafeAreaInsets` during
    // layout, which schedules `setNeedsUpdateConstraints`, which throws if
    // it lands inside a CA transaction commit. Zeroing eliminates the path.
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let bounds = self.bounds
        let panel = self.window as? OverlayPanel
        let isIdle = panel?.isIdlePhase ?? false
        // Only what the pill draws takes clicks (see PillHitBand); the rest of the panel is
        // transparent and click-through.
        let expanded = panel?.idleExpanded ?? false
        let band = panel?.interactiveBand(in: bounds.size) ?? .zero
        // `point` arrives in the superview's coordinates. Convert it before measuring from
        // the bottom, or every click on the pill lands outside the band and falls through.
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        let bottomPoint = PillHitBand.bottomPoint(localPoint, height: bounds.height, flipped: isFlipped)
        // A stale "expanded" flag (hover-exit missed after a reposition) heals
        // as soon as the pointer is demonstrably outside the expanded band.
        if expanded, isIdle, !band.contains(bottomPoint) { panel?.idleExpanded = false }
        // Quick reject — point is in the dead padding. AppKit will forward the
        // click to whatever window is underneath.
        guard band.contains(bottomPoint) else {
            PillDebugLog.write("hitTest reject point=\(bottomPoint) band=\(band)")
            return nil
        }
        let hit = super.hitTest(point)
        PillDebugLog.write("hitTest accept point=\(bottomPoint) view=\(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        return hit
    }

    /// A press on the pill is a click until the pointer travels 5 pt, then it is a move.
    /// SwiftUI gets the press at once so clicks feel immediate. When the press turns into a
    /// move, SwiftUI is sent a release far outside the pill, which drops its pending click.
    private var pressStart: NSPoint?

    override func mouseDown(with event: NSEvent) {
        PillDebugLog.write("mouseDown at \(event.locationInWindow)")
        pressStart = NSEvent.mouseLocation
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStart, let panel = window as? OverlayPanel, panel.canStartPillMove else {
            super.mouseDragged(with: event)
            return
        }
        let now = NSEvent.mouseLocation
        guard hypot(now.x - start.x, now.y - start.y) > PillDragSession.threshold else {
            super.mouseDragged(with: event)
            return
        }
        pressStart = nil
        if let cancel = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -5000, y: -5000),
                                           modifierFlags: [], timestamp: event.timestamp,
                                           windowNumber: event.windowNumber, context: nil,
                                           eventNumber: event.eventNumber, clickCount: 0, pressure: 0) {
            super.mouseUp(with: cancel)
        }
        panel.runPillMove()
    }

    override func mouseUp(with event: NSEvent) {
        pressStart = nil
        super.mouseUp(with: event)
    }

    /// Right-click on the resting or ready bar opens the bar's own menu.
    override func rightMouseDown(with event: NSEvent) {
        // Wispr opens the menu only on the ready bar, which stays open while the menu is up.
        guard let panel = window as? OverlayPanel, panel.isIdlePhase, panel.idleExpanded else {
            super.rightMouseDown(with: event)
            return
        }
        NotificationCenter.default.post(name: Notification.Name("flow.pillMenu"), object: nil, userInfo: ["open": true])
        NSMenu.popUpContextMenu(panel.makeBarMenu(), with: event, for: self)
        NotificationCenter.default.post(name: Notification.Name("flow.pillMenu"), object: nil, userInfo: ["open": false])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

