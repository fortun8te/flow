// VOICE — Cursor Paster
// ============================================================
// Pastes transcribed text at the current cursor position,
// Superwhisper-style. Works in any app that supports Cmd+V.
//
// UNDO GUARANTEE
//   After VOICE pastes, the user can hit Cmd+Z (or the target app's
//   undo equivalent) to remove the pasted text in one step.
//
//   How this works:
//     * The paste is delivered as a real Cmd+V key event via
//       CGEvent.post(tap: .cghidEventTap), which target apps register
//       in their undo stack exactly the same as a user-typed Cmd+V.
//     * Only ONE paste method fires per call (CGEvent OR AppleScript,
//       never both) — so the target app sees a single undoable paste.
//     * Clipboard restoration (when enabled) is deferred 0.6s AFTER
//       the paste, so it cannot race with the target app reading the
//       clipboard. The restore only mutates clipboard contents — it
//       does NOT affect the target app's internal undo stack, which
//       was recorded the moment Cmd+V was delivered.
//     * The AppleScript fallback uses `keystroke "v" using command down`
//       which is also a real synthesized keystroke → also undoable.
//
//   If you change paste mechanics, preserve these invariants or the
//   single-press undo will silently break.
//
// Flow:
//   1. Read the current selection and the text on either side
//   2. Adjust dictation spacing at the edit boundary
//   3. Save current clipboard contents
//   4. Write adjusted text to clipboard
//   5. Simulate Cmd+V via CGEvent (if Accessibility granted)
//      OR AppleScript / System Events (if not)
//   6. Restore original clipboard after a delay
//
// Insertion context rules (Wispr Flow / SuperWhisper approach):
//   fresh / startOfLine  → no leading space, keep capitalization
//   afterTerminal (.!?)  → add space, keep capitalization, keep period
//   midSentence          → add space, lowercase first word (not "I"),
//                          strip formatter's trailing period
//   Messaging apps       → strip trailing period in all contexts
//   Code editors         → strip trailing period, lowercase first char after .!?
//                          (matches `foo.bar` natural code patterns)
//
// WHY NOT changeCount:
//   NSPasteboard.changeCount only increments on WRITES — it does NOT
//   increment when an app READS the clipboard to paste. The old code
//   misread it as a "was the paste received" signal → AppleScript always
//   fired on top of CGEvent → double paste in Terminal, Chrome, VS Code,
//   Slack, and every Electron app.
//
// Requires Accessibility permission (System Settings → Privacy
// → Accessibility) for the CGEvent path. Falls back to AppleScript
// (System Events → Automation permission) automatically.
// ============================================================

import Foundation
import AppKit
import Carbon
import ApplicationServices

class CursorPaster {
    enum PasteDispatchResult { case eventSent, skipped, failed }
    /// `notConfirmed`: the paste was sent but the field did not confirm it, or nothing focused
    /// accepted it. The text is on the clipboard and the caller shows the calm "Copied" notice.
    enum PasteFailure: Equatable { case unavailable, secureField, notConfirmed }
    // TWEAK: Delay before simulating paste (seconds).
    // 0.2s covers Electron apps (VS Code, Slack, Discord, Notion) that need
    // slightly longer to regain focus after the hotkey releases.
    // Kept as a documented fallback; live value comes from currentPrePasteDelay().
    private let prePasteDelay: TimeInterval = 0.2

    // Bundle-ID substrings for apps that genuinely need ~200ms before paste.
    // Mostly Electron / Chromium-based shells whose focus restoration after a
    // global hotkey release is sluggish. Everyone else gets ~80ms.
    private static let slowPasteAppHints: [String] = [
        "slack", "discord", "notion", "vscode", "code", "figma", "obsidian",
        "linear", "chrome", "safari", "firefox", "arc", "electron",
        "whatsapp", "telegram", "teams", "cursor", "atom", "spotify"
    ]

    /// The user's clipboard, held while our own text is still on the pasteboard.
    /// A second paste that starts before the restore reuses it instead of
    /// saving our previous dictation as if it were the user's clipboard.
    private var pendingClipboardRestore: (contents: ClipboardContents, changeCount: Int)? = nil

    /// The last text Flow pasted: app, field and its final character. Used only when the field
    /// cannot be read, so back-to-back dictations get a space between them.
    private struct RecentPaste {
        let bundleId: String?
        let element: AXUIElement?
        let windowTitle: String?
        let interactionSerial: Int
        let lastCharacter: Character
        let at: Date
    }
    private var recentPaste: RecentPaste?

    init() {
        PasteInteractionTracker.shared.start()
    }

    private func rememberedPasteEnd(for target: PasteTargetSnapshot, now: Date = Date()) -> Character? {
        guard let recent = recentPaste else { return nil }
        var sameField: Bool? = nil
        if let a = recent.element, let b = target.focusedElement { sameField = CFEqual(a, b) }
        var sameTitle: Bool? = nil
        if let title = recent.windowTitle, let current = Self.windowTitle(of: target.focusedElement) {
            sameTitle = title == current
        }
        guard Self.rememberedPasteApplies(
            recordedBundle: recent.bundleId, currentBundle: target.bundleId,
            age: now.timeIntervalSince(recent.at), sameField: sameField, sameWindowTitle: sameTitle,
            interactionSincePaste: PasteInteractionTracker.shared.serial != recent.interactionSerial) else { return nil }
        return recent.lastCharacter
    }

    /// Title of the window that holds the element, nil when the app exposes none.
    private static func windowTitle(of element: AXUIElement?) -> String? {
        guard let element,
              let window = AccessibilityBudget.copyAttribute(element, kAXWindowAttribute),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return AccessibilityBudget.copyAttribute(window as! AXUIElement, kAXTitleAttribute) as? String
    }

    /// Per-app paste delay. Most native apps regain focus in <50ms, so 0.08s
    /// is more than enough. Electron/Chromium apps need the full 0.20s.
    /// Falls back to 0.20s when the frontmost app can't be identified.
    private func currentPrePasteDelay() -> TimeInterval {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else {
            return 0.20  // unknown: be safe
        }
        if Self.slowPasteAppHints.contains(where: { id.contains($0) }) { return 0.20 }
        return 0.08
    }

    // TWEAK: Delay before restoring original clipboard (seconds).
    private let clipboardRestoreDelay: TimeInterval = 0.6

    // TWEAK: Whether to restore the original clipboard after paste.
    private let shouldRestoreClipboard: Bool = false

    // TWEAK: Maximum clipboard content size to save/restore (bytes).
    private let maxClipboardSaveSize: Int = 50_000_000 // 50MB

    // Cache for AXIsProcessTrusted() — re-checked at most every 10s to avoid
    // OS daemon round-trips on every paste while preventing stale reads.
    private var cachedTrust: Bool? = nil
    private var trustCheckedAt: Date? = nil
    private var submissionGeneration = 0

    func cancelPendingSubmission() { submissionGeneration &+= 1 }

    // MARK: - Public API

    /// Paste at the current selection. Preformatted text keeps its casing and
    /// punctuation, while spacing at the live field boundary is resolved here.
    func pasteAtCursor(_ text: String, restoreClipboard: Bool = false, preFormatted: Bool = false,
                       expectedTarget: PasteTargetSnapshot? = nil, requireCapturedTarget: Bool = false,
                       submitAfterVerifiedPaste: Bool = false, maySubmit: (() -> Bool)? = nil,
                       mayDeliver: (() -> Bool)? = nil,
                       completion: ((PasteDispatchResult) -> Void)? = nil,
                       onReadback: ((PasteVerdict) -> Void)? = nil,
                       onFailure: ((PasteFailure) -> Void)? = nil) {
        submissionGeneration &+= 1
        let submissionID = submissionGeneration
        guard !text.isEmpty else { completion?(.skipped); return }

        // A caller that owns the result can present its own recovery UI. Legacy
        // callers still get the existing notice, without putting the result in it.
        func notifyFailure(_ message: String, reason: PasteFailure = .unavailable) {
            if let onFailure {
                onFailure(reason)
            } else {
                NotificationCenter.default.post(name: .voiceError, object: nil,
                    userInfo: ["flowKind": "paste", "message": message])
            }
        }

        // When recording has a captured destination, refusing an unknown target
        // is safer than guessing which field the user intended.
        if requireCapturedTarget && (expectedTarget?.bundleId == nil || expectedTarget?.focusedElement == nil) {
            // Text is never lost: a paste that cannot land leaves the dictation on the clipboard.
            Self.keepForManualPaste(text)
            notifyFailure("Couldn't find the original field. Text copied so you can paste it.")
            completion?(.skipped)
            return
        }

        // Standardized paste-lifecycle logging. Grep for `[VOICE-PASTE]` to
        // reconstruct what happened on any given paste.
        let targetBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        print("[VOICE-PASTE] start: textLength=\(text.count) target=\(targetBundle) preFormatted=\(preFormatted)")

        // SECURITY: never paste into a password field. macOS exposes the
        // subrole `AXSecureTextField` on focused secure inputs (1Password,
        // Keychain, login forms, sudo prompts). If we'd be pasting into one,
        // ABORT — write to clipboard only and toast the user. This MUST run
        // before we touch the system pasteboard so we don't poison it on
        // accident (we still write the polished text below so the user can
        // Cmd+V manually if they confirm they actually want it there).
        if isFocusedElementSecure() {
            Self.keepForManualPaste(text)
            print("[VOICE] ⚠️ refusing to paste into AXSecureTextField — text copied to clipboard")
            notifyFailure("Skipped password field. Text is on your clipboard.", reason: .secureField)
            completion?(.skipped)
            return
        }

        // Capture the intended application before scheduling the system-wide paste.
        let targetSnapshot = expectedTarget ?? currentPasteTargetSnapshot()

        let willUseCGEvent = isAccessibilityTrusted()
        let delay = currentPrePasteDelay()
        let pasteboard = NSPasteboard.general

        // All context-sensitive work (AX read, text adjustment, clipboard write, keystrokes)
        // happens inside the dispatch block. By the time this fires, the pre-paste delay has
        // elapsed and the target app's focus is settled — so AX reads return valid results.
        // Previously, the AX read ran immediately at call-time (before focus was restored),
        // returning nil and falling back to .afterTerminalWS (no space added). Moving it here
        // fixes back-to-back dictations that were jamming words together without spaces.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { notifyFailure("Couldn’t paste."); completion?(.failed); return }
            // Escape or a cancel during the delay stops this paste before the clipboard
            // or any keystroke changes (sol/01 finding 6). The session check is made here, not earlier.
            if let mayDeliver, !mayDeliver() {
                print("[VOICE-PASTE] cancelled during the pre-paste delay — nothing pasted")
                completion?(.skipped)
                return
            }

            // A new AX element can represent the same editor in Electron. Keep
            // ordinary pastes in the original app and require exact field identity
            // when an automatic Enter command is verified below.
            func targetAppStillActive(preparedFor bundleId: String? = nil) -> Bool {
                let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                return Self.canPasteInApp(captured: targetSnapshot.bundleId, current: current)
                    && Self.canPasteInApp(captured: bundleId, current: current)
            }
            func skipChangedApp() {
                self.pendingClipboardRestore = nil
                let copied = Self.keepForManualPaste(text, pasteboard: pasteboard)
                Telemetry.signal("paste.skipped", "target_app_changed")
                notifyFailure(copied ? "You switched apps. Dictation copied." : "You switched apps. Dictation is in history.")
                completion?(.skipped)
            }
            guard targetAppStillActive() else { skipChangedApp(); return }
            let liveTarget = self.currentPasteTargetSnapshot()
            if self.isSecureField(liveTarget.focusedElement) {
                Self.keepForManualPaste(text, pasteboard: pasteboard)
                notifyFailure("Skipped password field. Text is on your clipboard.", reason: .secureField)
                completion?(.skipped)
                return
            }

            // Read the live selection once for both spacing and paste verification.
            // A field/range captured at key-down can be stale by the time cleanup ends.
            let receiptValue = self.currentText(of: liveTarget).flatMap { $0.utf16.count <= 1_048_576 ? $0 : nil }
            let receiptRange = self.selectedRange(of: liveTarget)
            let pasteText = Self.resolvedInsertion(text, field: receiptValue, selection: receiptRange,
                                                   preFormatted: preFormatted, bundleID: liveTarget.bundleId,
                                                   rememberedEnd: self.rememberedPasteEnd(for: liveTarget))
            guard !pasteText.isEmpty else {
                Self.keepForManualPaste(text, pasteboard: pasteboard)
                notifyFailure("Couldn’t paste. Text is on your clipboard."); completion?(.skipped); return
            }
            let originalFieldMatches = Self.samePasteField(targetSnapshot, liveTarget)

            // A prior Flow paste may restore the clipboard during our delay.
            // Save what the user actually has when this paste takes ownership.
            let originalChangeCount = pasteboard.changeCount
            let savedContents = restoreClipboard
                ? self.clipboardToRestore(pasteboard, changeCount: originalChangeCount) : nil
            guard targetAppStillActive() else { skipChangedApp(); return }
            if restoreClipboard && (pasteboard.changeCount != originalChangeCount || savedContents == nil) {
                Telemetry.signal("paste.skipped", "clipboard_snapshot_unavailable")
                Self.keepForManualPaste(text, pasteboard: pasteboard)
                notifyFailure("Couldn’t paste. Text is on your clipboard.")
                completion?(.skipped)
                return
            }
            let wroteText = DictationPasteboard.write(pasteText, to: pasteboard)
            let ownedChangeCount = pasteboard.changeCount
            func ownsWrittenClipboard() -> Bool {
                guard pasteboard.changeCount == ownedChangeCount,
                      let observed = pasteboard.string(forType: .string),
                      observed.utf16.elementsEqual(pasteText.utf16) else { return false }
                return pasteboard.changeCount == ownedChangeCount
            }
            func restoreIfOwned() {
                if let savedContents, ownsWrittenClipboard() {
                    self.restoreClipboard(pasteboard, from: savedContents)
                }
            }
            func skipWrittenPaste(_ message: String, detail: String, reason: PasteFailure = .unavailable) {
                // Leave the dictation on the clipboard (it is already there) unless someone else
                // wrote to it meanwhile; never put the old clipboard back over the only copy.
                if !ownsWrittenClipboard() && detail != "clipboard_changed" { Self.keepForManualPaste(text, pasteboard: pasteboard) }
                Telemetry.signal("paste.skipped", detail)
                notifyFailure(message, reason: reason)
                completion?(.skipped)
            }
            guard wroteText else {
                print("[VOICE-PASTE] result: failed reason=clipboard-write-failed")
                restoreIfOwned()
                Telemetry.signal("paste.failure", "clipboard_write_failed")
                notifyFailure("Paste failed — could not write to clipboard.")
                completion?(.failed)
                return
            }

            // Clipboard I/O can give another app time to change focus or claim
            // the clipboard. Recheck after writing, before sending any keys.
            if self.isFocusedElementSecure() {
                skipWrittenPaste("Skipped password field. Find your text in Recent Dictations.",
                                 detail: "secure_field", reason: .secureField)
                return
            }
            guard targetAppStillActive(preparedFor: liveTarget.bundleId) else {
                skipWrittenPaste("You switched apps. Dictation copied.", detail: "target_app_changed")
                return
            }
            guard ownsWrittenClipboard() else {
                skipWrittenPaste("The clipboard changed. Dictation wasn’t pasted.", detail: "clipboard_changed")
                return
            }
            if mayDeliver?() == false {
                restoreIfOwned()
                Telemetry.signal("paste.skipped", "cancelled")
                completion?(.skipped)
                return
            }

            // Spacing travels with the text in one paste. A separate space key
            // can replace the selected text before the paste and leave a stray edit.
            let dispatched = willUseCGEvent ? self.simulatePaste() : self.pasteViaSystemEvents()
            if dispatched, let landedEnd = pasteText.last {
                // Remember where this paste ended, for the next dictation in the same field.
                self.recentPaste = RecentPaste(bundleId: liveTarget.bundleId, element: liveTarget.focusedElement,
                                               windowTitle: Self.windowTitle(of: liveTarget.focusedElement),
                                               interactionSerial: PasteInteractionTracker.shared.serial,
                                               lastCharacter: landedEnd, at: Date())
            }
            if dispatched {
                if let savedContents {
                    self.scheduleClipboardRestore(pasteboard, from: savedContents, ownedCount: ownedChangeCount,
                                                  delay: self.clipboardRestoreDelay)
                }
                // One paste only. The readback may type the text once if it clearly did not land.
                self.readBackPaste(before: PasteFieldLook(value: receiptValue, caret: receiptRange, sameTarget: true),
                    expected: liveTarget, inserted: pasteText, range: receiptRange,
                    firstVerdict: nil, editableAtPaste: self.isEditableTextElement(liveTarget.focusedElement),
                    mayType: { [weak self] in
                        self?.submissionGeneration == submissionID && mayDeliver?() != false
                            && targetAppStillActive(preparedFor: liveTarget.bundleId)
                    }, onVerdict: { onReadback?(originalFieldMatches ? $0 : .unknown) }, onFailure: { [weak self] in
                        // Cancelled or expired deliveries must not overwrite a newer clipboard.
                        guard mayDeliver?() != false else { return }
                        // The restore may already have put the old clipboard back: copy the text again.
                        self?.pendingClipboardRestore = nil
                        Self.keepForManualPaste(text, pasteboard: pasteboard)
                        notifyFailure("Copied — press ⌘V", reason: .notConfirmed)
                    })
            } else {
                Self.keepForManualPaste(text, pasteboard: pasteboard)
                onReadback?(.unknown)
                notifyFailure("Copied — press ⌘V", reason: .notConfirmed)
            }
            if submitAfterVerifiedPaste {
                if dispatched, originalFieldMatches, let original = receiptValue, let range = receiptRange {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard let self else { return }
                        let now = self.currentPasteTargetSnapshot()
                        let sameTarget = Self.samePasteField(targetSnapshot, now)
                        guard self.submissionGeneration == submissionID, maySubmit?() == true, !self.isFocusedElementSecure(),
                              let observed = self.currentText(of: now), let caret = self.selectedRange(of: now),
                              TrailingPressEnter.insertionVerified(original: original, replacedRange: range,
                                  inserted: pasteText, observed: observed, caret: caret, sameTarget: sameTarget),
                              let down = CGEvent(keyboardEventSource: self.makeIsolatedEventSource(), virtualKey: 36, keyDown: true),
                              let up = CGEvent(keyboardEventSource: self.makeIsolatedEventSource(), virtualKey: 36, keyDown: false) else {
                            NotificationCenter.default.post(name: .voiceError, object: nil,
                                userInfo: ["flowKind": "paste", "message": "Enter skipped. Check the text before sending."])
                            return
                        }
                        down.post(tap: .cghidEventTap)
                        up.post(tap: .cghidEventTap)
                    }
                } else {
                    NotificationCenter.default.post(name: .voiceError, object: nil,
                        userInfo: ["flowKind": "paste", "message": "Enter skipped because the field could not be verified."])
                }
            }
            // Sending an event is not proof that the target accepted it.
            completion?(dispatched ? .eventSent : .failed)
        }
    }

    static func canPasteInApp(captured: String?, current: String?) -> Bool {
        captured == nil || current == captured
    }

    /// A dictation that could not be pasted stays on the clipboard so Cmd-V still works
    /// (it is also in history). This wins over keeping the user's old clipboard.
    @discardableResult
    static func keepForManualPaste(_ text: String, pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if pasteboard.string(forType: .string) == text { return true }
        return DictationPasteboard.write(text, to: pasteboard)
    }

    /// Which app a dictation goes to. The field captured at the start, unless a different app
    /// was in front when recording stopped: hands-free users start, then click into the field
    /// they want (events.jsonl 21 Nov 2026 15:00: a 51 s dictation skipped as
    /// `target_app_changed`). Flow's own windows never count as the new target.
    static func targetForDelivery(started: PasteTargetSnapshot?, stopped: PasteTargetSnapshot?,
                                  ownBundleID: String? = Bundle.main.bundleIdentifier) -> PasteTargetSnapshot? {
        guard let stopped, let stoppedApp = stopped.bundleId, stoppedApp != ownBundleID else { return started }
        guard let started, let startedApp = started.bundleId else { return stopped }
        return startedApp == stoppedApp ? started : stopped
    }

    private static func samePasteField(_ first: PasteTargetSnapshot, _ second: PasteTargetSnapshot) -> Bool {
        guard let bundleID = first.bundleId, bundleID == second.bundleId,
              let a = first.focusedElement, let b = second.focusedElement else { return false }
        return CFEqual(a, b)
    }

    /// Paste with the TextFormatter applied first.
    func pasteFormatted(_ text: String, formatter: TextFormatter, restoreClipboard: Bool = false) {
        let formatted = formatter.format(text)
        pasteAtCursor(formatted, restoreClipboard: restoreClipboard)
    }

    // MARK: - Cursor context reading

    /// Sample the text before the actual selection at recording start.
    func sampleFieldContextBeforeCursor(length: Int = 24) -> String? {
        let target = currentPasteTargetSnapshot()
        guard let element = target.focusedElement, !isSecureField(element) else { return nil }
        guard let range = selectedRange(of: target) else {
            return currentText(of: target) == "" ? "" : nil
        }
        let readLength = min(max(0, length), range.location)
        guard readLength > 0 else { return "" }

        var before = CFRange(location: range.location - readLength, length: readLength)
        if let rangeValue = AXValueCreate(.cfRange, &before) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element,
                kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value) == .success,
                let text = value as? String {
                return text
            }
        }
        guard let value = currentText(of: target), let edit = Range(range, in: value) else { return nil }
        return String(value[..<edit.lowerBound].suffix(readLength))
    }

    // MARK: - Spacing at the live edit boundary

    /// `rememberedEnd`: the last character Flow itself pasted into this app and field, used only
    /// when the field or caret cannot be read (no readback, e.g. Electron). Back-to-back dictations
    /// were glued together ("ASAP!The term") in exactly that case.
    static func resolvedInsertion(_ text: String, field: String?, selection: NSRange?,
                                  preFormatted: Bool, bundleID: String?, rememberedEnd: Character? = nil) -> String {
        let code = bundleID.map(isCodeEditor(bundleID:)) ?? false
        let messaging = bundleID.map(isMessagingApp(bundleID:)) ?? false
        func withoutFinalPeriod(_ value: String) -> String {
            value.hasSuffix(".") && !value.hasSuffix("..") ? String(value.dropLast()) : value
        }
        let edit = field.flatMap { value in
            selection.flatMap { Range($0, in: value) } ?? (value.isEmpty ? value.startIndex..<value.endIndex : nil)
        }
        guard let field, let edit else {
            let base = !preFormatted && (code || messaging) ? withoutFinalPeriod(text) : text
            return boundarySpaced(base, after: rememberedEnd)
        }

        let before = field[..<edit.lowerBound]
        let after = field[edit.upperBound...]
        let selected = field[edit]
        let left = before.last
        let right = after.first
        let opening = "([{“‘«‹"
        let closing = ".,!?;:%)]}”’»›"
        let connector = "-_@/\\"
        let sentenceEnd = ".!?…"

        // Horizontal padding from the model may describe an earlier field.
        // Leave intentional line breaks and tab indentation in the payload.
        func isSpace(_ character: Character) -> Bool { character.isWhitespace && !character.isNewline && character != "\t" }
        let leadingTrimmed = text.drop(while: isSpace)
        var body = String(leadingTrimmed.reversed().drop(while: isSpace).reversed())
        guard !body.isEmpty else { return body }

        func tokenCharacter(_ character: Character?) -> Bool {
            character.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
        }
        // Preserve a deliberate insertion or partial selection inside an existing word.
        let joinsLeft = tokenCharacter(left) && tokenCharacter(selected.first ?? right)
        let joinsRight = tokenCharacter(right) && tokenCharacter(selected.last ?? left)
        let lastMeaningful = before.reversed().drop(while: { isSpace($0) || "”’'\")]}»›".contains($0) }).first
        let continuesSentence = lastMeaningful.map { !$0.isNewline && !sentenceEnd.contains($0) } ?? false
        if !preFormatted {
            if messaging || code || continuesSentence { body = withoutFinalPeriod(body) }
            if edit.isEmpty && !joinsLeft && (continuesSentence || (code && lastMeaningful != nil)),
               let first = body.first, first.isUppercase {
                let rest = body.dropFirst()
                let isI = first == "I" && (rest.first.map { $0.isWhitespace || "'’,.!?".contains($0) } ?? true)
                let hasInternalCapital = rest.prefix(while: { $0.isLetter }).contains(where: \.isUppercase)
                if !isI && !hasInternalCapital { body = first.lowercased() + rest }
            }
        }
        guard let first = body.first, let last = body.last else { return body }
        if right == last, sentenceEnd.contains(last), body.dropLast().last != last {
            body.removeLast()
        }
        guard let actualLast = body.last else { return body }
        let prefix = left.map {
            !$0.isWhitespace && !first.isWhitespace && !opening.contains($0) && !closing.contains(first)
                && !connector.contains($0) && !connector.contains(first) && !joinsLeft
                && !(code && $0 == ".")
        } ?? false
        let suffix = right.map {
            !$0.isWhitespace && !actualLast.isWhitespace && !opening.contains(actualLast) && !closing.contains($0)
                && !connector.contains(actualLast) && !connector.contains($0) && !joinsRight
        } ?? false
        return (prefix ? " " : "") + body + (suffix ? " " : "")
    }

    /// Pure rule for inserting after text Flow cannot read. A single space goes between an
    /// ending of sentence punctuation (. ! ? : ;) or a letter/digit and new text that starts with a
    /// letter or digit. No space if either side is already whitespace or the new text starts with punctuation.
    static func boundarySpaced(_ text: String, after previousEnd: Character?) -> String {
        guard let previousEnd, let first = text.first else { return text }
        let endsWordOrSentence = previousEnd.isLetter || previousEnd.isNumber || ".!?:;".contains(previousEnd)
        guard endsWordOrSentence, !previousEnd.isWhitespace, !first.isWhitespace, !first.isPunctuation, !first.isSymbol else {
            return text
        }
        return " " + text
    }

    /// The remembered paste applies only within this window, in the same app.
    static let rememberedPasteWindow: TimeInterval = 60

    /// A known identical field always counts. Otherwise (Electron re-wraps the editor, or no readback)
    /// the same window title counts, but only if no click or app switch happened since the paste.
    static func rememberedPasteApplies(recordedBundle: String?, currentBundle: String?, age: TimeInterval,
                                       sameField: Bool?, sameWindowTitle: Bool?,
                                       interactionSincePaste: Bool) -> Bool {
        guard let recordedBundle, recordedBundle == currentBundle, age >= 0, age <= rememberedPasteWindow else { return false }
        if sameField == true { return true }
        return !interactionSincePaste && sameWindowTitle == true
    }

    // MARK: - Messaging app detection

    // Bundle IDs and substrings for apps where trailing periods look wrong
    // (chat bubbles, comments). Keep the list narrow — false positives add
    // periods where they're wanted (email, document editors).
    private static let messagingBundleIds: Set<String> = [
        "com.apple.MobileSMS",          // Messages
        "com.tinyspeck.slackmacgap",    // Slack
        "com.discord.discord",           // Discord
        "com.hnc.Discord",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.whatsapp.desktop",
        "com.facebook.archon",          // Messenger
        "com.telegram.desktop",
        "ru.keepcoder.Telegram",
        "com.linear.app",
    ]

    static func isMessagingApp(bundleID id: String) -> Bool {
        if messagingBundleIds.contains(id) { return true }
        return id.contains("slack") || id.contains("discord") ||
               id.contains("telegram") || id.contains("whatsapp") ||
               id.contains("teams")
    }

    // Bundle IDs for code editors / terminals where dictation usually goes into
    // comments or shells — neither wants auto-capitalized sentences ending with periods.
    private static let codeEditorBundleIds: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.todesktop.230313mzl4w4u92.cursor",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.AppCode",
        "com.jetbrains.goland",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.github.atom",
        "com.panic.Nova",
        "com.zedindustries.zed",
    ]

    /// Detect the polish context for the frontmost app so the LLM polisher
    /// can bias its cleanup (or skip entirely for code).
    func currentPolishContext() -> LLMPolisher.PolishContext {
        Self.polishContext(forBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Pure form of `currentPolishContext()` for a known bundle ID. Also used
    /// by the headless `--cleanup-prepare` / `--cleanup-run` replay.
    static func polishContext(forBundleID id: String?) -> LLMPolisher.PolishContext {
        guard let id else { return .default }
        if isCodeEditor(bundleID: id) { return .code }
        if isMessagingApp(bundleID: id) { return .messaging }
        let lower = id.lowercased()
        if lower.contains("mail") || lower.contains("spark") || lower.contains("outlook") {
            return .email
        }
        return .default
    }

    static func isCodeEditor(bundleID id: String) -> Bool {
        if codeEditorBundleIds.contains(id) { return true }
        let lower = id.lowercased()
        return lower.contains("xcode") || lower.contains("vscode") ||
               lower.contains("cursor") || lower.contains("terminal") ||
               lower.contains("iterm") || lower.contains("jetbrains") ||
               lower.contains("sublime") || lower.contains("zed")
    }

    // MARK: - Accessibility check (cached)

    private func isAccessibilityTrusted() -> Bool {
        let now = Date()
        if let cached = cachedTrust,
           let checkedAt = trustCheckedAt,
           now.timeIntervalSince(checkedAt) < 10 {
            return cached
        }
        let trusted = AXIsProcessTrusted()
        cachedTrust = trusted
        trustCheckedAt = now
        return trusted
    }

    // MARK: - Clipboard Save/Restore

    struct ClipboardContents: Equatable {
        var items: [[NSPasteboard.PasteboardType: Data]]
    }

    /// Every item and every type on the pasteboard, or nil when it is too large to put back.
    static func snapshotPasteboard(_ pasteboard: NSPasteboard, maxBytes: Int = 50_000_000) -> ClipboardContents? {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        var totalSize = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // A promised or empty type must not make the whole dictation unpasteable.
                guard let data = item.data(forType: type) else { continue }
                totalSize += data.count
                guard totalSize <= maxBytes else { return nil }
                types[type] = data
            }
            items.append(types)
        }
        return ClipboardContents(items: items)
    }

    static func restorePasteboard(_ pasteboard: NSPasteboard, from saved: ClipboardContents) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Reads a selection by asking the app to copy it, then puts the clipboard back exactly as it was.
    /// `prior` is what the user had before (taken by the caller). Nil when the app copied nothing,
    /// the selection was only whitespace, or the scope changed while waiting.
    /// Chromium and Electron may write in more than one step, so any change counts as the copy
    /// and the clipboard is given a moment to settle before it is read.
    static func copySelectionText(pasteboard pb: NSPasteboard, prior: ClipboardContents,
                                  timeout: TimeInterval = 0.6, settle: TimeInterval = 0.03,
                                  sendCopy: () -> Bool, stillInScope: () -> Bool = { true },
                                  sleep: (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) }) -> String? {
        let priorCount = pb.changeCount
        guard sendCopy() else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, pb.changeCount == priorCount { sleep(0.01) }
        guard pb.changeCount != priorCount else { return nil }
        if settle > 0 { sleep(settle) }
        let copied = pb.string(forType: .string)
        let inScope = stillInScope()
        // The change was caused by this copy: always put the user's clipboard back.
        restorePasteboard(pb, from: prior)
        guard inScope, let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return copied
    }

    private func clipboardToRestore(_ pasteboard: NSPasteboard, changeCount: Int) -> ClipboardContents? {
        if let pending = pendingClipboardRestore, pending.changeCount == changeCount {
            return pending.contents
        }
        return saveClipboard(pasteboard)
    }

    private func scheduleClipboardRestore(_ pasteboard: NSPasteboard, from saved: ClipboardContents,
                                          ownedCount: Int, delay: TimeInterval) {
        pendingClipboardRestore = (saved, ownedCount)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if self.pendingClipboardRestore?.changeCount == ownedCount { self.pendingClipboardRestore = nil }
            guard pasteboard.changeCount == ownedCount else { return }
            self.restoreClipboard(pasteboard, from: saved)
        }
    }

    private func saveClipboard(_ pasteboard: NSPasteboard) -> ClipboardContents? {
        Self.snapshotPasteboard(pasteboard, maxBytes: maxClipboardSaveSize)
    }

    private func restoreClipboard(_ pasteboard: NSPasteboard, from saved: ClipboardContents) {
        Self.restorePasteboard(pasteboard, from: saved)
    }

    // MARK: - Simulate Paste (Cmd+V)

    /// Build a CGEventSource that does NOT inherit the user's currently-held
    /// physical modifier flags. We use `.privateState` (fresh state pool not
    /// shared with the system input state) so when the user is still holding
    /// the hotkey's modifier keys at paste time, our synthesized Cmd+V is
    /// pure Cmd+V — not Cmd+Opt+V / Cmd+Fn+V / Cmd+Space etc. Without this,
    /// the global hotkey's release race produced phantom Cmd+Opt+V combos in
    /// apps like Chrome, Cursor, and any electron shell with a debug shortcut
    /// on those bindings. Also explicitly zero local-mod suppression flags so
    /// the OS doesn't merge held modifiers into our keystrokes.
    ///
    /// 21 Nov 2026: the source no longer mutes the real keyboard. It used to keep local
    /// keyboard events out for 0.25 s after every synthetic Cmd-V / Cmd-C / Cmd-Z / Return /
    /// typed chunk (the default suppression interval, with a filter that let only mouse and
    /// system keys through), so keys Jordan typed right after a paste or an Opt+1 copy were
    /// dropped ("it kicks me off of my keyboard"). The private state pool and the explicit
    /// flags on each event already keep held modifiers out of our keystrokes.
    private func makeIsolatedEventSource() -> CGEventSource? { Self.isolatedEventSource() }

    static func isolatedEventSource() -> CGEventSource? {
        guard let src = CGEventSource(stateID: .privateState) else { return nil }
        src.localEventsSuppressionInterval = 0
        for state in [CGEventSuppressionState.eventSuppressionStateSuppressionInterval,
                      .eventSuppressionStateRemoteMouseDrag] {
            src.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: state)
        }
        return src
    }

    private func simulatePaste() -> Bool {
        let source = makeIsolatedEventSource()
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        guard let keyDown, let keyUp else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Synthesize Cmd+Z to undo the most recent text insertion. Used by the
    /// optimistic-paste swap path: after pasting unpolished TextFormatter
    /// output, we Cmd+Z it and paste the polished version.
    /// Falls back to AppleScript when Accessibility isn't granted.
    /// Virtual key 6 = Z.
    func undoLastPaste() {
        if isAccessibilityTrusted() {
            let source = makeIsolatedEventSource()
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags   = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        } else {
            let script = """
            tell application "System Events"
                keystroke "z" using command down
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    print("[VOICE] AppleScript undo error: \(error)")
                }
            }
        }
    }

    /// AppleScript paste — requires Automation permission for System Events.
    /// When AppleScript fails (most commonly: user denied Automation
    /// permission for System Events, or Accessibility is also denied),
    /// we surface a `voiceError` toast — otherwise the user has no idea
    /// why their text didn't appear. The polished text is still on the
    /// clipboard, so Cmd+V manually still works.
    private func pasteViaSystemEvents() -> Bool {
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            print("[VOICE-PASTE] result: failed reason=applescript-compile-failed")
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["flowKind": "paste", "message": "Paste failed. Text copied — press Cmd+V to paste."]
            )
            return false
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error = error {
            print("[VOICE-PASTE] result: failed reason=applescript error=\(error)")
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["flowKind": "paste", "message": "Paste failed (Automation permission missing?). Text copied — press Cmd+V to paste."]
            )
            return false
        }
        return true
    }

    // MARK: - Accessibility Permission

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Paste verification & secure-field detection

    /// Snapshot of (frontmost app bundle id, focused AX element identity)
    /// taken just before paste, so we can detect mid-flight focus loss.
    /// Exposed (not private) so the CorrectionLearner can re-read the same
    /// element's text value a few seconds after paste to detect user fixes.
    struct PasteTargetSnapshot {
        let bundleId: String?
        let focusedElement: AXUIElement?
    }

    /// Public snapshot of the current paste target. Call this right after a
    /// successful auto-paste so the learner can re-read the same element later.
    /// Mirrors `currentPasteTargetSnapshot()` (which is taken pre-paste); a
    /// post-paste sample is what we want for correction tracking because the
    /// focus is settled and the element identity matches what the user edits.
    func captureTargetSnapshot() -> PasteTargetSnapshot {
        return currentPasteTargetSnapshot()
    }

    /// Re-read the current full text value of a previously-snapshotted element
    /// via kAXValueAttribute. Returns nil when AX is not trusted, the snapshot
    /// has no element, or the element is stale / doesn't expose a string value.
    /// Reuses the exact attribute read used everywhere else in this file.
    func currentText(of snapshot: PasteTargetSnapshot) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard let element = snapshot.focusedElement else { return nil }
        guard let text = AccessibilityBudget.copyAttribute(element, kAXValueAttribute, app: snapshot.bundleId) as? String else { return nil }
        return text
    }

    private func selectedRange(of snapshot: PasteTargetSnapshot) -> NSRange? {
        guard AXIsProcessTrusted(), let element = snapshot.focusedElement else { return nil }
        guard let ref = AccessibilityBudget.copyAttribute(element, kAXSelectedTextRangeAttribute, app: snapshot.bundleId),
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func currentPasteTargetSnapshot() -> PasteTargetSnapshot {
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var focused: AXUIElement? = nil
        if AXIsProcessTrusted() {
            let sys = AccessibilityBudget.bind(AXUIElementCreateSystemWide())
            if let r = AccessibilityBudget.copyAttribute(sys, kAXFocusedUIElementAttribute, app: bundleId) {
                focused = AccessibilityBudget.bind(r as! AXUIElement)
            }
        }
        return PasteTargetSnapshot(bundleId: bundleId, focusedElement: focused)
    }

    /// Reads the field after a dispatched paste: at most two looks, and at most one
    /// typed insertion, only when the text clearly did not land. The paste is never
    /// repeated. A verified or unknown result types nothing.
    private func readBackPaste(before: PasteFieldLook, expected: PasteTargetSnapshot, inserted: String,
                               range: NSRange?, firstVerdict: PasteVerdict?, editableAtPaste: Bool,
                               mayType: @escaping () -> Bool,
                               onVerdict: ((PasteVerdict) -> Void)?, onFailure: @escaping () -> Void) {
        // Look 1 at 0.2 s after the paste, look 2 at 0.3 s (end of the 300 ms confirmation window).
        let delay = firstVerdict == nil
            ? PasteReadback.firstLookDelay
            : PasteReadback.secondLookDelay - PasteReadback.firstLookDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let now = self.currentPasteTargetSnapshot()
            let sameTarget = Self.samePasteField(expected, now)
            // Focus moved away: another app, or no focused element any more. An element swap inside
            // the same app is not counted, since Electron re-wraps the same editor.
            let focusAway = now.bundleId != expected.bundleId || now.focusedElement == nil
            let after = PasteFieldLook(value: sameTarget ? self.currentText(of: now) : nil,
                                       caret: sameTarget ? self.selectedRange(of: now) : nil, sameTarget: sameTarget)
            let verdict = PasteReadback.verdict(before: before, after: after, inserted: inserted, replacing: range)
            // Checked only when a typed fallback could actually run.
            let canType = firstVerdict == .notLanded && verdict == .notLanded
                && PasteReadback.canType(inserted) && !self.isFocusedElementSecure() && mayType()
            let step = PasteReadback.nextStep(verdict: verdict, firstVerdict: firstVerdict, canType: canType)
            switch step {
            case .lookAgain:
                print("[VOICE-PASTE] readback: \(verdict) at first look, looking again")
                self.readBackPaste(before: before, expected: expected, inserted: inserted, range: range,
                                   firstVerdict: verdict, editableAtPaste: editableAtPaste, mayType: mayType,
                                   onVerdict: onVerdict, onFailure: onFailure)
            case .typeOnce:
                // Typing does not write the clipboard, so the restore timer is not affected.
                let typed = self.typeText(inserted)
                print("[VOICE-PASTE] readback: not landed after two looks; typed once ok=\(typed)")
                Telemetry.signal("paste.readback", "typed_fallback", ["typed": typed, "chars": inserted.count])
                // A typed insertion is not verified, so nothing is learned from it.
                onVerdict?(.unknown)
                if !typed { onFailure() }
            case .finish(let final):
                print("[VOICE-PASTE] readback: \(final)")
                Telemetry.signal("paste.readback", "\(final)")
                onVerdict?(final)
                let appVerifiedBefore = PasteReadback.appHasVerified(bundleID: expected.bundleId)
                if final == .verified { PasteReadback.recordVerified(bundleID: expected.bundleId) }
                // Say so, once, only when the outcome is a likely failure (see needsCopiedNotice).
                if PasteReadback.needsCopiedNotice(final: final, typed: false, editableAtPaste: editableAtPaste,
                                                   focusAway: focusAway, appVerifiedBefore: appVerifiedBefore) {
                    onFailure()
                }
            }
        }
    }

    /// Types text as keystrokes without the clipboard. Used once, as the fallback
    /// after a paste that clearly did not land. Returns false if an event could not be made.
    private func typeText(_ text: String) -> Bool {
        let source = makeIsolatedEventSource()
        for chunk in PasteReadback.typingChunks(text) {
            let units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    // MARK: - Selection Read / Replace

    /// Read the currently selected text from the frontmost app via AX API.
    /// Returns nil if nothing is selected, AX is unavailable, or the frontmost
    /// app doesn't expose selected text.
    func getSelectedText() -> String? {
        guard AXIsProcessTrusted() else {
            print("[VOICE-CP] getSelectedText: AX not trusted")
            return nil
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            print("[VOICE-CP] getSelectedText: no frontmost app")
            return nil
        }
        print("[VOICE-CP] getSelectedText: app=\(app.bundleIdentifier ?? "?")")

        // Each AX read is budgeted: a slow app times out here and we take the Cmd+C fallback.
        let bundle = app.bundleIdentifier
        let axApp = AccessibilityBudget.bind(AXUIElementCreateApplication(app.processIdentifier))
        guard let focusedRef = AccessibilityBudget.copyAttribute(axApp, kAXFocusedUIElementAttribute, app: bundle) else {
            print("[VOICE-CP] getSelectedText: no focused element (AX empty or timed out)")
            return nil
        }
        let focused = AccessibilityBudget.bind(focusedRef as! AXUIElement)  // swiftlint:disable:this force_cast

        if let txt = AccessibilityBudget.copyAttribute(focused, kAXSelectedTextAttribute, app: bundle) as? String, !txt.isEmpty {
            print("[VOICE-CP] getSelectedText AX → \(txt.count) chars")
            return txt
        }
        print("[VOICE-CP] getSelectedText: AX returned empty — falling back to copy-via-Cmd+C")

        // Fallback: copy via Cmd+C then read clipboard.
        let pb = NSPasteboard.general
        let priorChangeCount = pb.changeCount
        guard let prior = saveClipboard(pb), pb.changeCount == priorChangeCount else { return nil }

        // Use isolated source so held hotkey modifiers don't pollute Cmd+C.
        let src = makeIsolatedEventSource()
        let cDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)   // C = 8
        let cUp   = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        cDown?.flags = .maskCommand
        cUp?.flags   = .maskCommand
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)

        // Wait for clipboard to update (max 250ms, poll every 15ms).
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            if pb.changeCount != priorChangeCount { break }
            usleep(15_000)
        }

        // If copy did not change the clipboard, never return stale content or
        // rewrite the pasteboard. Keep all original representations, not just text.
        let copiedChangeCount = pb.changeCount
        guard copiedChangeCount != priorChangeCount else { return nil }
        let copied = pb.string(forType: .string)
        let captured: String? = copied?.isEmpty == false ? copied : nil
        if pb.changeCount == copiedChangeCount {
            restoreClipboard(pb, from: prior)
        }

        print("[VOICE-CP] getSelectedText Cmd+C fallback → \(captured?.count ?? 0) chars")
        return captured
    }

    /// Replace the current selection in the frontmost app with newText.
    /// Writes newText to the clipboard, sends Cmd+V (paste-over-selection),
    /// then restores the prior clipboard contents after a short delay.
    ///
    /// Assumes the frontmost app has a text selection active — the selection
    /// will be replaced by the paste. If there is no selection the text is
    /// inserted at the cursor instead (standard paste behavior).
    struct SelectionSnapshot {
        let target: PasteTargetSnapshot
        let text: String
        let fullText: String
        let range: CFRange
        /// Copy-only selections have no verifiable replacement range.
        var viaCopy: Bool = false
        /// How the text was read, for telemetry: ax, ax_text, edit_menu or cmd_c.
        var method: String = "ax"
        /// The app process that held the selection, for the paste-over check.
        var pid: pid_t = 0

        func expectedFullText(replacingWith text: String) -> String? {
            guard !viaCopy else { return nil }
            return PolishTransaction.expectedFullText(before: fullText,
                range: NSRange(location: range.location, length: range.length), replacement: text)
        }
    }

    func captureSelection() -> SelectionSnapshot? {
        let target = currentPasteTargetSnapshot()
        guard target.bundleId != nil, let element = target.focusedElement,
              !isFocusedElementSecure(), let fullText = currentText(of: target) else { return nil }
        guard let text = AccessibilityBudget.copyAttribute(element, kAXSelectedTextAttribute, app: target.bundleId) as? String,
              !text.isEmpty,
              let rangeRef = AccessibilityBudget.copyAttribute(element, kAXSelectedTextRangeAttribute, app: target.bundleId),
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length > 0 else { return nil }
        let utf16 = fullText as NSString
        guard range.location >= 0, range.location <= utf16.length,
              range.length <= utf16.length - range.location,
              utf16.substring(with: NSRange(location: range.location, length: range.length)) == text else { return nil }
        return SelectionSnapshot(target: target, text: text, fullText: fullText, range: range)
    }

    static func selectionMatches(originalText: String, currentText: String, originalRange: CFRange, currentRange: CFRange, originalSelection: String, currentSelection: String) -> Bool {
        originalText == currentText && originalRange.location == currentRange.location &&
            originalRange.length == currentRange.length && originalSelection == currentSelection
    }

    /// Prefer Accessibility. Chrome, Electron and web editors often expose no selected text (or a
    /// value that does not line up with the range), so fall back to the app's own copy: first
    /// Edit > Copy, then a synthetic Cmd-C. Both put the whole clipboard back afterwards.
    func captureSelectionForPolish() -> SelectionSnapshot? {
        guard !fnSecureInputOn() else { return nil }
        if let viaAX = captureSelection() {
            Telemetry.log("polish.selection_read", properties: ["method": "ax", "app": viaAX.target.bundleId ?? "unknown"])
            return viaAX
        }
        guard let read = readSelectionWithoutRange() else {
            Telemetry.log("polish.selection_read", properties: [
                "method": "none", "app": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"])
            return nil
        }
        Telemetry.log("polish.selection_read", properties: ["method": read.method, "app": read.target.bundleId ?? "unknown"])
        return SelectionSnapshot(target: read.target, text: read.text, fullText: "",
                                 range: CFRange(location: -1, length: 0), viaCopy: true,
                                 method: read.method, pid: read.pid)
    }

    /// The frontmost app and its focused field, when it is safe to copy from. The field may be
    /// missing (Electron without an accessibility tree); a password field never qualifies.
    private func looseCopyScope() -> (target: PasteTargetSnapshot, pid: pid_t)? {
        guard AXIsProcessTrusted(), !fnSecureInputOn(),
              let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != nil,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let target = currentPasteTargetSnapshot()
        guard target.bundleId == front.bundleIdentifier, !isSecureField(target.focusedElement) else { return nil }
        // An explicit empty selection means there is nothing to copy (Cmd-C would copy a whole line in code editors).
        if target.focusedElement != nil, selectedRange(of: target)?.length == 0 { return nil }
        return (target, front.processIdentifier)
    }

    /// Selected text without a replacement range: the AX selected-text attribute on its own,
    /// then Edit > Copy, then Cmd-C.
    private func readSelectionWithoutRange() -> (text: String, method: String, target: PasteTargetSnapshot, pid: pid_t)? {
        guard let scope = looseCopyScope() else { return nil }
        if let element = scope.target.focusedElement,
           let text = AccessibilityBudget.copyAttribute(element, kAXSelectedTextAttribute, app: scope.target.bundleId) as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (text, "ax_text", scope.target, scope.pid)
        }
        // Code editors copy the whole line when nothing is selected; without a known non-empty
        // range there, a copy could polish (and paste over) text that was never selected.
        if let id = scope.target.bundleId, Self.isCodeEditor(bundleID: id),
           (selectedRange(of: scope.target)?.length ?? 0) == 0 { return nil }
        if let menuScope = copySelectionScope(), let copied = copySelectionViaEditMenu(in: menuScope) {
            return (copied, "edit_menu", scope.target, scope.pid)
        }
        if let copied = copySelectionViaKeystroke(pid: scope.pid) {
            return (copied, "cmd_c", scope.target, scope.pid)
        }
        return nil
    }

    /// Synthetic Cmd-C into the frontmost app. The clipboard is snapshotted first (every item and
    /// type) and restored exactly afterwards.
    private func copySelectionViaKeystroke(pid: pid_t) -> String? {
        let pb = NSPasteboard.general
        guard let prior = clipboardToRestore(pb, changeCount: pb.changeCount) else { return nil }
        let stillFront = { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && !fnSecureInputOn() }
        // Opt+1 fires on key-down, so Option is usually still held here, and some apps (Electron) then see
        // Opt-Cmd-C and copy nothing. Wait a moment for the keys to come up first.
        let released = Self.waitForModifiersUp(flags: { CGEventSource.flagsState(.hidSystemState) })
        if !released { print("[VOICE-CP] Cmd+C fallback: modifiers still held, sending anyway") }
        let text = Self.copySelectionText(pasteboard: pb, prior: prior, sendCopy: { [weak self] in
            guard let self, stillFront(),
                  let down = CGEvent(keyboardEventSource: self.makeIsolatedEventSource(), virtualKey: 8, keyDown: true),
                  let up = CGEvent(keyboardEventSource: self.makeIsolatedEventSource(), virtualKey: 8, keyDown: false) else { return false }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }, stillInScope: stillFront)
        print("[VOICE-CP] polish selection Cmd+C fallback → \(text?.count ?? 0) chars")
        return text
    }

    /// True once Option, Shift, Control, Command and fn are all up, or false after `timeout`.
    static func waitForModifiersUp(timeout: TimeInterval = 0.4, flags: () -> CGEventFlags,
                                   sleep: (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) }) -> Bool {
        let held: CGEventFlags = [.maskAlternate, .maskShift, .maskControl, .maskCommand, .maskSecondaryFn]
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flags().intersection(held).isEmpty { return true }
            if Date() >= deadline { return false }
            sleep(0.01)
        }
    }

    /// Paste-over for a selection read without a range (Chrome, Electron, web editors).
    /// The selection is read again first and must still be exactly the original text in the
    /// same app, so a click elsewhere during polish can never receive the text.
    func replaceUnverifiedSelection(with newText: String, expected: SelectionSnapshot) -> Bool {
        guard expected.viaCopy, !newText.isEmpty,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid,
              let again = readSelectionWithoutRange(), again.pid == expected.pid,
              Self.sameSelectionText(expected.text, again.text) else { return false }
        submissionGeneration &+= 1
        let pb = NSPasteboard.general
        let initialCount = pb.changeCount
        guard let prior = clipboardToRestore(pb, changeCount: initialCount), pb.changeCount == initialCount,
              DictationPasteboard.write(newText, to: pb) else { return false }
        let ownedCount = pb.changeCount
        usleep(20_000)
        guard pb.changeCount == ownedCount,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid,
              simulatePaste() else {
            if pb.changeCount == ownedCount { restoreClipboard(pb, from: prior) }
            return false
        }
        scheduleClipboardRestore(pb, from: prior, ownedCount: ownedCount, delay: 0.8)
        return true
    }

    /// Copy can normalise line endings and a trailing newline; compare without those.
    static func sameSelectionText(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .newlines)
        }
        return norm(a) == norm(b)
    }

    private struct CopySelectionScope {
        let target: PasteTargetSnapshot
        let app: AXUIElement
        let pid: pid_t
        let window: AXUIElement
    }

    /// The field may be missing: Electron apps (T3 Code, Slack, Discord) expose no focused element until an
    /// assistive app asks for their web tree, but their Edit menu and focused window are native and readable.
    /// 21 Nov 2026: requiring a field here skipped Edit > Copy in T3 Code, so Opt+1 fell to a Cmd-C sent while
    /// Option was still held and showed "Couldn't read selected text" (events.jsonl 17:38Z, method none).
    private func copySelectionScope() -> CopySelectionScope? {
        guard AXIsProcessTrusted(), !fnSecureInputOn(),
              let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let target = currentPasteTargetSnapshot()
        guard target.bundleId == bundleID, !isSecureField(target.focusedElement) else { return nil }
        var fieldPID: pid_t = front.processIdentifier
        if let field = target.focusedElement {
            guard AXUIElementGetPid(field, &fieldPID) == .success, fieldPID == front.processIdentifier else { return nil }
        }
        let app = AccessibilityBudget.bind(AXUIElementCreateApplication(fieldPID))
        guard let windowRef = AccessibilityBudget.copyAttribute(app, kAXFocusedWindowAttribute, app: bundleID),
              CFGetTypeID(windowRef) == AXUIElementGetTypeID(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == fieldPID,
              !fnSecureInputOn() else { return nil }
        return CopySelectionScope(target: target, app: app, pid: fieldPID, window: windowRef as! AXUIElement)
    }

    private func copySelectionStillInScope(_ expected: CopySelectionScope) -> Bool {
        guard let current = copySelectionScope(), current.pid == expected.pid,
              CFEqual(current.window, expected.window) else { return false }
        return Self.sameOptionalField(current.target.focusedElement, expected.target.focusedElement, equal: { CFEqual($0, $1) })
    }

    /// Both missing (an Electron window without its web tree) counts as the same place; one missing does not.
    static func sameOptionalField<T>(_ a: T?, _ b: T?, equal: (T, T) -> Bool) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return equal(x, y)
        default: return false
        }
    }

    /// Copies the selection through the frontmost app's Edit > Copy item, reads it, then puts the clipboard
    /// back when this copy changed it. Returns nil when there is no such item, nothing was copied, or the
    /// clipboard could not be saved first (too large to restore), so an old clipboard is never reused.
    private func copySelectionViaEditMenu(in scope: CopySelectionScope) -> String? {
        let bundleId = scope.target.bundleId
        guard let barRef = AccessibilityBudget.copyAttribute(scope.app, kAXMenuBarAttribute, app: bundleId),
              CFGetTypeID(barRef) == AXUIElementGetTypeID(),
              let copyItem = Self.findMenuItem(in: AccessibilityBudget.bind(barRef as! AXUIElement), menuTitle: "Edit", itemTitle: "Copy", bundleId: bundleId),
              (AccessibilityBudget.copyAttribute(copyItem, kAXEnabledAttribute, app: bundleId) as? Bool) != false else { return nil }

        let pb = NSPasteboard.general
        let priorCount = pb.changeCount
        guard let prior = clipboardToRestore(pb, changeCount: priorCount),
              selectedRange(of: scope.target)?.length != 0,
              copySelectionStillInScope(scope),
              pb.changeCount == priorCount else { return nil }
        guard AXUIElementPerformAction(copyItem, kAXPressAction as CFString) == .success else { return nil }

        let deadline = ContinuousClock.now + .milliseconds(600)
        while ContinuousClock.now < deadline, pb.changeCount == priorCount { usleep(10_000) }
        guard pb.changeCount != priorCount else { return nil }
        // Chromium can write in two steps; let it settle before reading.
        usleep(30_000)
        let copied = pb.string(forType: .string)
        let inScope = copySelectionStillInScope(scope)
        restoreClipboard(pb, from: prior)
        guard inScope, let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return copied
    }

    /// Walks menu bar > menu > item by title. Titles are matched exactly, as English app menus show them.
    private static func findMenuItem(in bar: AXUIElement, menuTitle: String, itemTitle: String, bundleId: String?) -> AXUIElement? {
        func title(_ element: AXUIElement) -> String? {
            AccessibilityBudget.copyAttribute(element, kAXTitleAttribute, app: bundleId) as? String
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            AccessibilityBudget.copyAttribute(element, kAXChildrenAttribute, app: bundleId) as? [AXUIElement] ?? []
        }
        guard let menu = children(bar).first(where: { title($0) == menuTitle }),
              let submenu = children(menu).first else { return nil }
        return children(submenu).first(where: { title($0) == itemTitle })
    }

    /// Puts the Accessibility selection on `range` of the target's field. False when the field refuses it.
    func selectRange(_ range: CFRange, in target: PasteTargetSnapshot) -> Bool {
        let current = currentPasteTargetSnapshot()
        guard AXIsProcessTrusted(), current.bundleId == target.bundleId,
              let element = target.focusedElement, let focused = current.focusedElement, CFEqual(element, focused),
              !isFocusedElementSecure() else { return false }
        var value = range
        guard let axValue = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }

    /// Undo for an applied polish. Writes `original` back over `candidateRange`, but only when the field still
    /// holds exactly `expectedFullText` (what Flow wrote) and the same field has focus. Otherwise nothing changes.
    func restorePolish(target: PasteTargetSnapshot, original: String, candidate: String,
                       candidateRange: CFRange, expectedFullText: String) -> Bool {
        let now = currentPasteTargetSnapshot()
        guard now.bundleId == target.bundleId, let a = now.focusedElement, let b = target.focusedElement, CFEqual(a, b),
              let full = currentText(of: target),
              PolishTransaction.mayUndo(currentFullText: full, expectedAfterPolish: expectedFullText),
              selectRange(candidateRange, in: target) else { return false }
        let selection = SelectionSnapshot(target: target, text: candidate, fullText: expectedFullText, range: candidateRange)
        return replaceSelection(with: original, expected: selection)
    }

    /// The Accessibility route's check: same app, field, full text, range and selected text.
    private func axSelectionStillMatches(_ expected: SelectionSnapshot) -> Bool {
        guard !fnSecureInputOn(), let current = captureSelection(),
              current.target.bundleId == expected.target.bundleId,
              let a = current.target.focusedElement, let b = expected.target.focusedElement,
              CFEqual(a, b),
              Self.selectionMatches(originalText: expected.fullText, currentText: current.fullText,
                  originalRange: expected.range, currentRange: current.range,
                  originalSelection: expected.text, currentSelection: current.text) else { return false }
        return true
    }

    func canReviewPolishSelection(_ expected: SelectionSnapshot) -> Bool {
        !expected.viaCopy && axSelectionStillMatches(expected)
    }

    /// Read the original field even if the user switched apps while the paste settled.
    /// Check sooner in responsive editors and give slower editors time to apply the event.
    @MainActor
    func waitForPolishText(_ expectedFullText: String, in target: PasteTargetSnapshot) async -> Bool {
        guard target.focusedElement != nil else { return false }
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .milliseconds(500))
        for milliseconds in [35, 90, 170, 290, 450] {
            do { try await clock.sleep(until: started.advanced(by: .milliseconds(milliseconds))) }
            catch { return false }
            guard !Task.isCancelled, clock.now < deadline else { return false }
            if currentText(of: target) == expectedFullText { return true }
        }
        return false
    }

    func replaceSelection(with newText: String, expected: SelectionSnapshot) -> Bool {
        guard !expected.viaCopy, axSelectionStillMatches(expected) else { return false }
        // A newer edit supersedes delayed typing fallback or automatic Enter from dictation.
        submissionGeneration &+= 1
        print("[VOICE-CP] replaceSelection: \(newText.count) chars")
        let pb = NSPasteboard.general
        let initialCount = pb.changeCount
        guard let prior = clipboardToRestore(pb, changeCount: initialCount),
              pb.changeCount == initialCount else { return false }
        let clearedCount = pb.clearContents()
        guard pb.setString(newText, forType: .string) else {
            if pb.changeCount == clearedCount { restoreClipboard(pb, from: prior) }
            return false
        }
        let ownedCount = pb.changeCount

        // Tiny delay so target app's run loop sees the new pasteboard before Cmd+V.
        usleep(20_000)

        let stillSame = axSelectionStillMatches(expected)
        guard pb.string(forType: .string) == newText, pb.changeCount == ownedCount else { return false }
        guard stillSame else {
            if pb.changeCount == ownedCount { restoreClipboard(pb, from: prior) }
            return false
        }

        // Use isolated source so held hotkey modifiers don't pollute Cmd+V.
        let src = makeIsolatedEventSource()
        guard let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false),
              Self.canPasteInApp(captured: expected.target.bundleId,
                                 current: NSWorkspace.shared.frontmostApplication?.bundleIdentifier),
              pb.changeCount == ownedCount else {
            if pb.changeCount == ownedCount { restoreClipboard(pb, from: prior) }
            return false
        }
        vDown.flags = .maskCommand
        vUp.flags   = .maskCommand
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)

        scheduleClipboardRestore(pb, from: prior, ownedCount: ownedCount, delay: 0.8)
        return true // Event dispatched, not proof the application accepted it.
    }

    /// Returns true when the currently focused AX element is a secure text
    /// input (password field). Uses kAXSubroleAttribute — value
    /// `AXSecureTextField` is the standard macOS marker. When AX isn't
    /// trusted we conservatively return false (can't tell, don't block).
    private func isFocusedElementSecure() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        return isSecureField(currentPasteTargetSnapshot().focusedElement)
    }

    /// Whether a focused element takes typed text: a text role, or a settable value or selection.
    /// Used before a paste in apps whose readback never works (Electron, T3 Code and similar).
    private func isEditableTextElement(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        if let role = AccessibilityBudget.copyAttribute(element, kAXRoleAttribute) as? String,
           textRoles.contains(role) { return true }
        for attribute in [kAXValueAttribute, kAXSelectedTextRangeAttribute] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success,
               settable.boolValue { return true }
        }
        return false
    }

    private func isSecureField(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        // Check subrole first — that's where AXSecureTextField appears.
        if let subrole = AccessibilityBudget.copyAttribute(element, kAXSubroleAttribute) as? String,
           subrole == (kAXSecureTextFieldSubrole as String) {
            return true
        }
        // Some Electron / web apps don't set the subrole; fall through.
        return false
    }
}
