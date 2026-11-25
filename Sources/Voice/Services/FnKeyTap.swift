// VOICE — Fn Key Event Tap
// ============================================================
// THE PROBLEM
//
// `NSEvent.addGlobalMonitorForEvents` is a PASSIVE monitor. It can observe
// events but cannot consume them. So when the user taps the `fn` key alone,
// macOS still fires its built-in "Press fn key to: Show Emoji & Symbols /
// Start Dictation" action. A passive monitor cannot stop that.
//
// THE FIX
//
// A CGEventTap installed at `.cghidEventTap` (the lowest level, before the
// window server interprets fn) CAN consume events. The `fn` key arrives as a
// `.flagsChanged` CGEvent carrying the `CGEventFlags.maskSecondaryFn` bit.
// Returning `nil` from the tap callback for a clean fn-only flagsChanged
// swallows it, so the emoji/dictation picker never sees a clean fn tap.
//
// WHAT THIS WRAPPER DOES
//
//   * Detects fn via `event.flags.contains(.maskSecondaryFn)`.
//   * Detects the Space keyCode (49) for the fn+Space hands-free combo.
//   * Maintains fn-down latch state and emits high-level events through
//     `FnKeyTapDelegate`:
//        - fnPressed / fnReleased  → drives push-to-talk
//        - fnSpacePressed          → drives hands-free toggle
//   * SWALLOWS clean fn-only flagsChanged events (returns nil) so the emoji
//     picker is suppressed. fn+other-key combos that aren't ours pass through
//     unchanged so the rest of the system (and other apps) behave normally.
//   * Re-enables itself if the tap is disabled by timeout / user input.
//   * Falls back gracefully: if `CGEvent.tapCreate` returns nil (e.g. no
//     Accessibility permission), `start()` returns false and the caller can
//     fall back to a passive NSEvent monitor so the app still works.
//
// THREADING
//
// The C callback runs on whatever run loop the tap source is attached to:
// `KeyTapThread`, Flow's own key thread (21 Nov 2026; it was the main run loop,
// which froze the whole keyboard whenever Flow's main thread was busy). The
// delegate is always called on the main queue (it touches RecordingState / UI).
// ============================================================

import Foundation
import CoreGraphics
import AppKit

// MARK: - Delegate

/// High-level fn-key events emitted by the tap. All callbacks are delivered on
/// the main thread.
protocol FnKeyTapDelegate: AnyObject {
    /// fn pressed alone (no other modifiers, no key chord). Push-to-talk down.
    func fnKeyDown()
    /// fn released. Push-to-talk up.
    func fnKeyUp()
    /// fn + Space pressed together. Hands-free toggle.
    func fnSpacePressed()
    /// Listen-only taps only: another key (not Space) went down while fn was
    /// held, e.g. fn+Delete. Shadow mode uses it to drop a capture Wispr ignores.
    func fnChordKeyPressed()
}

extension FnKeyTapDelegate {
    func fnChordKeyPressed() {}
    func fnKeyDown(at eventTime: TimeInterval?) { fnKeyDown() }
    func fnKeyUp(at eventTime: TimeInterval?) { fnKeyUp() }
}

extension FnKeyTap {
    /// When the key event really happened, in `ProcessInfo.systemUptime` seconds.
    ///
    /// The delegate runs on the main queue, so a busy main thread (cold audio-engine start, a
    /// route change) delivers fn up late. Measuring the hold at delivery made a quick double-tap
    /// look like a 300 ms hold: Flow committed an empty push-to-talk and the second tap was thrown
    /// away (events.jsonl, 21 Nov 2026 02:10:29 and 14:57:02: hold 280-302 ms right after
    /// `audio.engine_lifecycle started`). The event's own timestamp is not delayed.
    /// CGEvent timestamps are documented as nanoseconds since boot but are mach ticks on some
    /// Macs, so accept whichever reading is a moment in the recent past, else nil.
    static func eventUptime(rawTimestamp: UInt64, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                            timebase: (numer: UInt32, denom: UInt32) = machTimebase) -> TimeInterval? {
        guard rawTimestamp > 0 else { return nil }
        let asNanos = Double(rawTimestamp) / 1e9
        let asTicks = Double(rawTimestamp) * Double(timebase.numer) / Double(max(timebase.denom, 1)) / 1e9
        for candidate in [asNanos, asTicks] {
            let age = now - candidate
            if age >= -0.05 && age <= 5 { return min(candidate, now) }
        }
        return nil
    }

    static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()
}

// MARK: - Key tap thread

/// One background thread with its own run loop for Flow's active keyboard taps (21 Nov 2026).
///
/// An active tap (`.defaultTap`) holds every key on the Mac until its callback returns. On the main
/// run loop that meant any busy moment in Flow (audio engine start, AX reads, the Opt+1 copy wait)
/// froze typing everywhere, and macOS then switched the tap off (`hotkey.eventtap_dead` 17 times
/// since 20 Nov in events.jsonl). Jordan: "Sometimes it kicks me off of my keyboard". Here the
/// callback only ever waits for its own small decision.
final class KeyTapThread: Thread, @unchecked Sendable {
    static let shared: KeyTapThread = {
        let thread = KeyTapThread()
        thread.name = "Flow key taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        thread.ready.wait()
        return thread
    }()

    private let ready = DispatchSemaphore(value: 0)
    private var loop: CFRunLoop?

    override func main() {
        loop = CFRunLoopGetCurrent()
        // A port keeps the run loop alive while no tap is attached.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while true { autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) } }
    }

    var runLoop: CFRunLoop { loop! }

    func add(_ source: CFRunLoopSource) {
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }

    func remove(_ source: CFRunLoopSource) {
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs after any callback already in progress on the tap thread.
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    var isCurrent: Bool { Thread.current === self }
}

/// What the tap callback reaches through `userInfo`. Retained by the tap and released on the tap
/// thread after the tap is gone, so a callback in flight never touches a freed object.
private final class FnKeyTapBox {
    weak var owner: FnKeyTap?
    init(_ owner: FnKeyTap) { self.owner = owner }
}

// MARK: - FnKeyTap

final class FnKeyTap {

    weak var delegate: FnKeyTapDelegate?

    /// Shadow mode: observe fn without consuming anything. The tap is created
    /// with `.listenOnly`, every event is forwarded unchanged, and the macOS
    /// fn/emoji binding is left alone, so another app (Wispr Flow) that owns
    /// fn keeps working exactly as before.
    let listenOnly: Bool

    init(listenOnly: Bool = false) {
        self.listenOnly = listenOnly
    }

    /// Space virtual key code.
    private static let spaceKeyCode: Int64 = 49

    /// Pure pass-through decision for an ordinary key-down. Flow consumes only its own
    /// fn+Space chord. Every other key (letters, Delete, arrows, fn+Delete, Cmd/Shift chords)
    /// reaches the focused app untouched, so typing and deleting keep working while recording.
    static func consumesKeyDown(keyCode: Int64, fnDown: Bool, fnBit: Bool, hasOtherModifier: Bool) -> Bool {
        fnDown && fnBit && !hasOtherModifier && keyCode == spaceKeyCode
    }

    /// Pure pass-through decision for a key-up. Only the key-up that ends our own fn+Space chord is consumed.
    static func consumesKeyUp(keyCode: Int64, fnSpaceDown: Bool) -> Bool {
        fnSpaceDown && keyCode == spaceKeyCode
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var box: Unmanaged<FnKeyTapBox>?
    /// Guards the latch: the callback runs on `KeyTapThread`, start/stop on the main thread.
    private let stateLock = NSLock()

    /// True while fn is physically held (after a clean fn-only flagsChanged on).
    private var fnDown = false
    private var fnSpaceDown = false

    // Only an actual Fn release belonging to our press may be swallowed.
    static func consumesFnRelease(keyCode: Int64, fnIsDown: Bool, fnFlag: Bool, otherModifiers: Bool) -> Bool {
        keyCode == 63 && fnIsDown && !fnFlag && !otherModifiers
    }

    // MARK: Lifecycle

    /// Installs the event tap on `KeyTapThread` (never the main run loop: see there).
    /// Returns true on success, false if the tap could not be created (caller
    /// should fall back to a passive NSEvent monitor in that case).
    /// `carryingLatch` is the fn latch of the tap this one replaces, so a rebuild
    /// while fn is held does not lose the press (see `latchAfterInstall`).
    @discardableResult
    func start(carryingLatch wasDown: Bool = false) -> Bool {
        stop()

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        // Bridge `self` into the C callback through a retained box with a weak owner. The box is
        // released on the tap thread after the tap is removed (see stop()).
        let box = Unmanaged.passRetained(FnKeyTapBox(self))
        let userInfo = box.toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: listenOnly ? .listenOnly : .defaultTap,
            eventsOfInterest: mask,
            callback: fnKeyTapCallback,
            userInfo: userInfo
        ) else {
            box.release()
            print("[VOICE-HK] CGEventTap creation failed — falling back to passive monitor")
            return false
        }

        // Reconcile the latch with the physical key before the first event can arrive, so a release
        // that happened while no tap was listening is not lost.
        let latch = Self.latchAfterInstall(wasDown: wasDown, heldNow: Self.physicalFnHeld())
        // The tap thread reads `eventTap` and `box` inside `route`, so every write takes the lock too.
        stateLock.lock()
        self.eventTap = tap
        self.box = box
        fnDown = latch.down; fnSpaceDown = false
        stateLock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        if let source { KeyTapThread.shared.add(source) }
        CGEvent.tapEnable(tap: tap, enable: true)
        if latch.commitRelease { dispatchMain { [weak self] in self?.delegate?.fnKeyUp() } }
        FnKeyStats.shared.note(.tapInstalled)
        print(listenOnly ? "[VOICE-HK] listen-only CGEventTap installed — fn events pass through untouched"
                         : "[VOICE-HK] CGEventTap installed at kCGHIDEventTap — fn suppression active")
        return true
    }

    /// fn latch as this tap sees it. HotkeyService passes it to the replacement tap.
    var latchedDown: Bool { stateLock.lock(); defer { stateLock.unlock() }; return fnDown }

    /// What to do with the fn latch when a tap is installed.
    /// - wasDown: the replaced tap thought fn was held. heldNow: fn is physically held now.
    /// Returns the new latch, and whether a release must be delivered now (the key came up while no tap listened).
    static func latchAfterInstall(wasDown: Bool, heldNow: Bool) -> (down: Bool, commitRelease: Bool) {
        (down: heldNow, commitRelease: wasDown && !heldNow)
    }

    static func physicalFnHeld() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
    }

    func stop() {
        // Detach under the lock: a callback already running on the tap thread may still read `eventTap`.
        stateLock.lock()
        let tap = eventTap, source = runLoopSource, box = self.box
        eventTap = nil
        runLoopSource = nil
        self.box = nil
        fnDown = false
        fnSpaceDown = false
        stateLock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            KeyTapThread.shared.remove(source)
        }
        if let box {
            // After any callback already running on the tap thread.
            KeyTapThread.shared.perform { box.release() }
        }
    }

    deinit { stop() }

    /// True if the tap CFMachPort exists AND macOS still has it enabled.
    /// Used by HotkeyService's health watchdog: if this returns false while
    /// the service believes the tap is active, the tap is recreated.
    func isAlive() -> Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Re-enable the tap in place without tearing it down. Cheap recovery
    /// path for cases where macOS disabled the tap but the CFMachPort is
    /// still valid (the common timeout / brief-disable case).
    func rearm() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: Tap callback (called from the C trampoline below)

    /// Core event handling. Returns the (possibly nil) event to forward.
    /// Returning nil consumes the event; returning the passed event forwards it.
    fileprivate func handle(proxy: CGEventTapProxy,
                            type: CGEventType,
                            event: CGEvent) -> Unmanaged<CGEvent>? {
        stateLock.lock()
        let decision = route(type: type, event: event)
        stateLock.unlock()
        // A listen-only tap may never swallow anything. macOS ignores the
        // return value of a .listenOnly tap anyway; forwarding explicitly keeps
        // the contract obvious and safe if the options ever change.
        return listenOnly ? Unmanaged.passUnretained(event) : decision
    }

    private func route(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

        // Re-enable the tap if the system disabled it (slow callback or user input).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            FnKeyStats.shared.note(type == .tapDisabledByTimeout ? .disabledByTimeout : .disabledByUserInput)
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("[VOICE-HK] CGEventTap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            }
            // RECOVERY: a tap-disable is the OS pausing the tap (slow callback
            // under load) — NOT the user lifting fn. Earlier we blindly
            // synthesized fnKeyUp here, which fired mid-HOLD and silently
            // discarded push-to-talk recordings (the "hold doesn't work, only
            // double-tap" bug). Instead, reconcile against the ACTUAL physical
            // fn state: only commit a release if fn is genuinely no longer held
            // (its real key-up was dropped while the tap was paused). If fn is
            // still physically down, keep the recording alive — the real fn-up
            // flagsChanged will arrive now that the tap is re-enabled and drive
            // the commit. A genuinely-stuck recording is still bounded by the
            // max-duration watchdog, so we lose no safety.
            if fnDown {
                let fnStillHeld = CGEventSource.flagsState(.combinedSessionState)
                    .contains(.maskSecondaryFn)
                if !fnStillHeld {
                    fnDown = false
                    print("[VOICE-HK] tap re-enable: fn genuinely released during pause — committing fnKeyUp")
                    dispatchMain { [weak self] in self?.delegate?.fnKeyUp() }
                } else {
                    print("[VOICE-HK] tap re-enable while fn still physically held — keeping recording; real fn-up will commit")
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let fnBit = flags.contains(.maskSecondaryFn)

        // Other "real" modifiers (cmd/ctrl/alt/shift). fn itself is excluded.
        let otherModifiers: CGEventFlags = [
            .maskCommand, .maskControl, .maskAlternate, .maskShift,
        ]
        let hasOtherModifier = !flags.intersection(otherModifiers).isEmpty

        switch type {

        case .flagsChanged:
            // We only act on the fn bit transitioning. A *clean* fn-only change
            // (fn bit set, no other modifiers) is the emoji-trigger event we
            // must consume.
            let isFnEvent = event.getIntegerValueField(.keyboardEventKeycode) == 63
            if isFnEvent && fnBit && !hasOtherModifier {
                if !fnDown {
                    fnDown = true
                    let at = Self.eventUptime(rawTimestamp: event.timestamp)
                    dispatchMain { [weak self] in self?.delegate?.fnKeyDown(at: at) }
                }
                // Swallow — this is the exact event macOS would turn into the
                // emoji / dictation popup on a clean fn tap.
                FnKeyStats.shared.note(.swallowedFnPress)
                return nil
            }

            if isFnEvent && !fnBit && fnDown {
                let consumeRelease = Self.consumesFnRelease(
                    keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                    fnIsDown: fnDown, fnFlag: fnBit, otherModifiers: hasOtherModifier)
                // fn lifted (regardless of other modifiers still held).
                if fnDown {
                    fnDown = false
                    // A Space key-up lost to a tap timeout must not block the next fn+Space.
                    fnSpaceDown = false
                    // Always deliver fnKeyUp — no suppression even after fn+Space.
                    // The state machine's (.locked, .keyUp) no-op handles it safely,
                    // and clearing hotkeyIsDown here is essential for the third-tap
                    // lock-exit to work (fnKeyDown guards on !hotkeyIsDown).
                    let at = Self.eventUptime(rawTimestamp: event.timestamp)
                    dispatchMain { [weak self] in self?.delegate?.fnKeyUp(at: at) }
                }
                // If the fn-up flagsChanged is otherwise clean, swallow it too so
                // the release half of a clean fn tap never reaches the emoji
                // handler. If other modifiers remain, forward it untouched.
                return consumeRelease ? nil : Unmanaged.passUnretained(event)
            }

            // fn is set but combined with another modifier (e.g. user pressed
            // Cmd while holding fn). Keep our latch but DON'T swallow — let the
            // combo flow to the system so app shortcuts keep working.
            return Unmanaged.passUnretained(event)

        case .keyDown:
            if listenOnly, fnDown, event.getIntegerValueField(.keyboardEventKeycode) != Self.spaceKeyCode {
                dispatchMain { [weak self] in self?.delegate?.fnChordKeyPressed() }
            }
            if Self.consumesKeyDown(keyCode: event.getIntegerValueField(.keyboardEventKeycode), fnDown: fnDown,
                                    fnBit: fnBit, hasOtherModifier: hasOtherModifier) {
                if !fnSpaceDown {
                    fnSpaceDown = true
                    dispatchMain { [weak self] in self?.delegate?.fnSpacePressed() }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            if Self.consumesKeyUp(keyCode: event.getIntegerValueField(.keyboardEventKeycode), fnSpaceDown: fnSpaceDown) {
                fnSpaceDown = false
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Always hands the work to the main queue, even on the main thread. The tap callback
    /// then does only the swallow decision, and the delegate runs after the callback returns,
    /// so a slow delegate can no longer make macOS disable the tap.
    private func dispatchMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}

// MARK: - C trampoline

// CGEventTap requires a C function pointer (a closure that captures context is
// not allowed). We recover the FnKeyTap instance from the userInfo pointer.
private func fnKeyTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    guard let tap = Unmanaged<FnKeyTapBox>.fromOpaque(userInfo).takeUnretainedValue().owner else {
        return Unmanaged.passUnretained(event)
    }
    return tap.handle(proxy: proxy, type: type, event: event)
}
