import Foundation

/// Backend-neutral contract. Failure and meeting appearances are product decisions,
/// not claims about Wispr's unobserved UI. Wire only to confirmed backend events.
enum FlowPillState: Equatable {
    case resting, ready, starting, pushToTalk, handsFree, processing
    case audioFailure(recoverable: Bool), pasteFailure(recoverable: Bool), microphoneUnavailable
    case meeting(Meeting)
    enum Meeting: Equatable { case starting, active, paused, processing, failed(recoverable: Bool) }
}

enum FlowPillEvent: Equatable {
    case pointerEntered, pointerExited, hoverElapsed(Int), collapseElapsed(Int), clicked, escape
    case backend(FlowPillState)
}

enum FlowPillEffect: Equatable {
    case scheduleHover(generation: Int, milliseconds: Int), scheduleCollapse(generation: Int, milliseconds: Int), cancelHover
    case startHandsFree, finishAndPaste, cancel
}

/// A body state's size and bar count in the default skin. Pill views read the active skin;
/// this is the skin-free summary the tests and the hit testing use.
struct FlowPillPresentation: Equatable {
    let width: Double
    let height: Double
    let waveformBars: Int
    static func addingMeetingStop(to size: CGSize, side: Bool) -> CGSize {
        side ? CGSize(width: max(30, size.width), height: size.height + 38)
             : CGSize(width: size.width + 38, height: max(30, size.height))
    }
    static func forState(_ state: FlowPillState, side: Bool = false) -> Self {
        let skin = PillSkin.standard
        let size = skin.metrics.size(for: state, dock: side ? .left : .bottom)
        let bars: Int
        switch state {
        case .starting, .pushToTalk, .handsFree: bars = skin.waveform.barCount
        case .meeting: bars = skin.waveform.meetingBarCount
        default: bars = 0
        }
        return Self(width: size.width, height: size.height, waveformBars: bars)
    }
}

/// Wispr shows no words while it works: the pill is bars and a spinner, and polish has its own fill.
/// The stage and estimate types stay because the polish flow still records them.
enum FlowWorkPresentation {
    /// Not drawn any more. Kept so older callers compile; the pill shows no "Still working" text.
    static let overdueLabel = "Still working"

    enum PolishStage: Hashable {
        case editing, loadingModel, checkingDraft, applying, restoring

        var title: String {
            switch self {
            case .editing: return "Polishing"
            case .loadingModel: return "Loading model…"
            case .checkingDraft: return "Checking"
            case .applying: return "Applying"
            case .restoring: return "Restoring"
            }
        }
    }

    struct PolishEstimate: Equatable {
        static let editingCeiling = 0.94
        let stageStartedAt: ContinuousClock.Instant
        let finishAt: ContinuousClock.Instant
        let range: ClosedRange<Double>
        let continuesUntil: ContinuousClock.Instant?

        init(stageStartedAt: ContinuousClock.Instant, finishAt: ContinuousClock.Instant,
             range: ClosedRange<Double>, continuesUntil: ContinuousClock.Instant? = nil) {
            self.stageStartedAt = stageStartedAt
            self.finishAt = finishAt
            self.range = range
            self.continuesUntil = continuesUntil
        }

        func fraction(at now: ContinuousClock.Instant) -> Double {
            if now > finishAt, let continuesUntil, continuesUntil > finishAt {
                let position = min(1, finishAt.duration(to: now) / finishAt.duration(to: continuesUntil))
                return range.upperBound + (max(range.upperBound, Self.editingCeiling) - range.upperBound) * position
            }
            let duration = stageStartedAt.duration(to: finishAt)
            guard duration > .zero else { return range.lowerBound }
            let position = min(1, max(0, stageStartedAt.duration(to: now) / duration))
            return range.lowerBound + (range.upperBound - range.lowerBound) * position
        }
    }

    struct PolishProgress: Equatable {
        let title: String
        let fraction: Double?
    }

    /// The pill's polish label. It is always the transform (here "Polishing") with the spinner;
    /// the fill runs on its own 7 s clock, so no fraction is reported.
    static func polishProgress(stage: PolishStage, estimate: PolishEstimate?, at now: ContinuousClock.Instant) -> PolishProgress {
        PolishProgress(title: "Polishing", fraction: nil)
    }
}

/// Quick Polish forecasts remaining time from local wall-clock samples. Selection length
/// is retained only as input to the estimate. The profile stays in memory.
struct QuickPolishTiming {
    typealias Stage = FlowWorkPresentation.PolishStage

    struct Sample {
        let stage: Stage
        let words: Int
        let duration: Duration
    }

    struct History {
        private var ratios: [Stage: [Double]] = [:]

        mutating func record(_ samples: [Sample]) {
            for sample in samples {
                let value = sample.duration.components
                let seconds = Double(value.seconds) + Double(value.attoseconds) / 1e18
                guard seconds >= 0.05, let baseline = Self.baseline(sample.stage, words: sample.words) else { continue }
                let ratio = max(0.35, min(3, seconds / baseline))
                ratios[sample.stage] = Array(((ratios[sample.stage] ?? []) + [ratio]).suffix(7))
            }
        }

        private static func baseline(_ stage: Stage, words: Int) -> Double? {
            let length = Double(words)
            switch stage {
            // Seed the estimate from local replay. A cold first run took about six
            // seconds, and warm edits and second passes ranged from 0.26 to 1.9 s.
            case .loadingModel: return 4.8
            case .editing: return min(1.9, 0.25 + 0.014 * length)
            case .checkingDraft: return min(6.5, 0.75 + 0.032 * length)
            case .applying, .restoring: return nil
            }
        }

        func expectedSeconds(_ stage: Stage, words: Int) -> Double {
            guard let baseline = Self.baseline(stage, words: words) else { return 0 }
            let recent = (ratios[stage] ?? []).sorted()
            let midpoint = recent.count / 2
            let adjustment: Double
            if recent.isEmpty {
                adjustment = 1
            } else if recent.count.isMultiple(of: 2) {
                adjustment = (recent[midpoint - 1] + recent[midpoint]) / 2
            } else {
                adjustment = recent[midpoint]
            }
            let limit: Double
            switch stage {
            case .editing: limit = 2
            case .loadingModel: limit = 6
            default: limit = 7.5
            }
            return min(limit, baseline * adjustment)
        }
    }

    private let words: Int
    private let startedAt: ContinuousClock.Instant
    private var stageStarted: ContinuousClock.Instant
    private var stage: Stage = .editing
    private var completed: [Sample] = []

    init(words: Int, at now: ContinuousClock.Instant) {
        self.words = words
        startedAt = now
        stageStarted = now
    }

    mutating func enter(_ next: Stage, at now: ContinuousClock.Instant) {
        guard stage != next else { return }
        completed = samples(endingAt: now)
        stage = next
        stageStarted = now
    }

    func samples(endingAt now: ContinuousClock.Instant) -> [Sample] {
        completed + [Sample(stage: stage, words: words, duration: stageStarted.duration(to: now))]
    }

    func estimate(using history: History) -> FlowWorkPresentation.PolishEstimate {
        typealias Estimate = FlowWorkPresentation.PolishEstimate
        let deadline = startedAt + .seconds(PolishTransaction.shortcutBudgetSeconds)
        func segment(_ stage: Stage, from fraction: Double, at start: ContinuousClock.Instant) -> FlowWorkPresentation.PolishEstimate {
            let limit: Double
            switch stage {
            case .loadingModel: limit = 0.44
            case .editing: limit = 0.76
            case .checkingDraft: limit = 0.90
            case .applying, .restoring: limit = 0.96
            }
            let finish = max(start, min(deadline, start + .seconds(history.expectedSeconds(stage, words: words))))
            let remaining = start.duration(to: deadline)
            let elapsedShare = remaining > .zero ? start.duration(to: finish) / remaining : 0
            let linear = fraction + (Estimate.editingCeiling - fraction) * elapsedShare
            return .init(stageStartedAt: start, finishAt: finish,
                         range: fraction...max(fraction, limit, linear), continuesUntil: deadline)
        }
        // Carry forward each phase's actual progress, so a new estimate cannot send the bar backward.
        var previousStart = startedAt
        let fraction = completed.reduce(0.08) { fraction, sample in
            let end = previousStart + sample.duration
            let progress = segment(sample.stage, from: fraction, at: previousStart).fraction(at: end)
            previousStart = end
            return progress
        }
        return segment(stage, from: fraction, at: stageStarted)
    }
}

/// Wispr's hover timing (spec gap 9): the bar opens 150 ms after the pointer enters and rests
/// 120 ms after it leaves. Enter and leave are one timer each: moving in and out again inside the
/// window cancels it, so rapid pointer moves never queue a series of changes.
struct FlowPillMachine {
    static let enterMilliseconds = 60  // snappier than Wispr's 150 (Jordan, 22 Nov 2026: hover felt laggy)
    static let exitMilliseconds = 120
    private(set) var state: FlowPillState = .resting
    /// Each scheduled timer carries the generation it was made in; stale timers do nothing.
    private(set) var generation = 0
    private var pending: Pending?
    private var pointerInside = false

    private enum Pending: Equatable { case enter, exit }

    private mutating func schedule(_ next: Pending) -> [FlowPillEffect] {
        generation += 1
        pending = next
        return [.scheduleCollapse(generation: generation,
                                  milliseconds: next == .enter ? Self.enterMilliseconds : Self.exitMilliseconds)]
    }

    private mutating func cancelPending() {
        generation += 1
        pending = nil
    }

    mutating func send(_ event: FlowPillEvent) -> [FlowPillEffect] {
        switch event {
        case .pointerEntered:
            pointerInside = true
            if state == .ready {
                // Back before the exit timer ran out: keep the bar open.
                if pending == .exit { cancelPending() }
                return []
            }
            guard state == .resting, pending != .enter else { return [] }
            return schedule(.enter)
        case .pointerExited:
            pointerInside = false
            if pending == .enter { cancelPending(); return [] }
            guard state == .ready, pending != .exit else { return [] }
            return schedule(.exit)
        case .hoverElapsed:
            return []
        case .collapseElapsed(let token):
            guard token == generation, let due = pending else { return [] }
            pending = nil
            switch due {
            case .enter: if pointerInside, state == .resting { state = .ready }
            case .exit: if !pointerInside, state == .ready { state = .resting }
            }
            return []
        case .backend(let next):
            generation += 1; pending = nil; pointerInside = false; state = next
            return [.cancelHover]
        case .clicked:
            switch state {
            case .ready: return [.startHandsFree]
            case .pushToTalk, .handsFree: return [.finishAndPaste]
            default: return []
            }
        case .escape:
            switch state {
            case .starting, .pushToTalk, .handsFree: return [.cancel]
            default: return []
            }
        }
    }
}

/// A real backend notice. Actions expose only capabilities actually available.
struct FlowPillNotice: Equatable, Identifiable {
    enum Kind: String {
        case microphone, paste, transcription, recoveredAudio, preparing, modelUnavailable, noSpeech
        /// Any other message, with its own title, status and look (see `FlowPillNotice.wispr`).
        case general
        /// Wispr's TranscriptCancelledDetailed: Undo and Open History.
        case cancelled

        /// Messages posted without a kind: pick the card Wispr would show for that situation.
        static func inferred(from message: String) -> Kind {
            let m = message.lowercased()
            if m.contains("finishing previous") || m.contains("not ready") || m.contains("getting ready") { return .preparing }
            if m.contains("model") && (m.contains("not supported") || m.contains("could not load")) { return .modelUnavailable }
            if m.contains("clipboard") || m.contains("paste") { return .paste }
            if m.contains("microphone") || m.contains("mic ") || m.hasPrefix("mic") || m.contains("recording") && m.contains("start") { return .microphone }
            return .transcription
        }

        /// Wispr's notification status for the equivalent card, which picks its sound.
        var status: SoundEffects.NoticeStatus {
            switch self {
            case .paste, .recoveredAudio, .general: return .info
            case .cancelled: return .alert
            case .microphone, .transcription, .preparing, .modelUnavailable, .noSpeech: return .error
            }
        }
    }
    /// Wispr's notification looks: `standard` cards grow out of the pill; `mini` is a one-line
    /// black capsule floating above it.
    enum Variant: Equatable { case standard, mini }
    let id = UUID()
    let createdAt = Date()
    let kind: Kind
    let message: String
    /// The failed delivery's own text. Keep it out of error messages and telemetry.
    var recoveryText: String? = nil
    var hidesRecoveryPreview = false
    var recordingID: UUID? = nil
    var title: String? = nil
    var variant: Variant = .standard
    var status: SoundEffects.NoticeStatus? = nil
    var timeout: Double? = nil
    /// Wispr's `playSound: false`.
    var quiet = false
    /// Wispr's small badge in an info card's header ("Tip" with a zap).
    var badge: String? = nil
    /// Buttons beyond the kind's own. An empty notification name only closes the card.
    struct Action: Equatable {
        let title: String
        let notification: String

        static let speechSettings = Self(title: "Speech settings", notification: "flow.openSpeechModels")
    }
    var actions: [Action] = []

    var effectiveStatus: SoundEffects.NoticeStatus { status ?? kind.status }

    static func pasteRecovery(_ text: String, unconfirmed: Bool = false, secureField: Bool = false) -> Self? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let title = secureField ? "Skipped password field" : unconfirmed ? "Paste not confirmed" : "Couldn’t paste"
        return Self(kind: .paste, message: "", recoveryText: text, hidesRecoveryPreview: secureField,
                    title: title,
                    status: .alert, timeout: 8, quiet: true)
    }

    func resumedTimeout(remaining: Double?) -> Double? {
        guard let timeout else { return nil }
        guard recoveryText != nil, let remaining else { return timeout }
        return min(timeout, max(2, remaining))
    }

    enum Permission {
        case microphone, accessibility, screenRecording
    }

    static func permission(_ permission: Permission) -> Self {
        let title: String
        let message: String
        let notification: String
        switch permission {
        case .microphone:
            title = "Allow microphone access"
            message = "Turn on microphone access to dictate."
            notification = "flow.openMicrophonePrivacy"
        case .accessibility:
            title = "Allow Accessibility access"
            message = "Turn on Accessibility to paste and polish text."
            notification = "flow.openAccessibilityPrivacy"
        case .screenRecording:
            title = "Allow system audio access"
            message = "Enable screen and system audio recording to capture calls."
            notification = "flow.openScreenRecordingPrivacy"
        }
        return Self(kind: .general, message: message, title: title, status: .error, timeout: 10,
                    actions: [.init(title: "Open System Settings", notification: notification)])
    }

    /// Matches legacy permission messages from both dictation and meeting capture.
    static func permissionNotice(for message: String) -> Self? {
        let text = message.lowercased()
        if text.hasPrefix("accessibility access required") || text.hasPrefix("enable voice under privacy → accessibility")
            || text.hasPrefix("enable flow under privacy → accessibility") {
            return permission(.accessibility)
        }
        if text.hasPrefix("microphone access required") || text.hasPrefix("enable voice under privacy → microphone")
            || text.hasPrefix("enable flow under privacy → microphone") {
            return permission(.microphone)
        }
        if text.hasPrefix("screen recording access required") || text.hasPrefix("screen recording permission denied")
            || text.hasPrefix("enable flow under privacy → screen recording")
            || (text.hasPrefix("allow flow in system settings") && text.contains("screen recording")) {
            return permission(.screenRecording)
        }
        return nil
    }

    static func appSwitchNotice(for message: String) -> Self? {
        switch message {
        case "You switched apps. Dictation copied.":
            return Self(kind: .general, message: "", title: "You switched apps. Dictation copied.",
                        variant: .mini, status: .info, timeout: 6, quiet: true)
        case "You switched apps. Dictation is in history.":
            return Self(kind: .general, message: "You switched apps. Your text is in Dictations.",
                        title: "Dictation saved", status: .info, timeout: 8, quiet: true,
                        actions: [.init(title: "Open Dictations", notification: "flow.openHistory")])
        default:
            return nil
        }
    }

    /// The card Wispr shows for the same situation as one of Flow's older messages, or nil
    /// when Wispr shows nothing (spec Appendix A; audit 2026-11-13).
    static func wispr(forToast message: String) -> FlowPillNotice? {
        if let notice = appSwitchNotice(for: message) { return notice }
        if let notice = permissionNotice(for: message) { return notice }
        let m = message.lowercased()
        func card(_ title: String, _ body: String = "", _ status: SoundEffects.NoticeStatus, timeout: Double, quiet: Bool = false) -> FlowPillNotice {
            FlowPillNotice(kind: .general, message: body, title: title, variant: .standard, status: status, timeout: timeout, quiet: quiet)
        }
        func mini(_ text: String, timeout: Double = 3, quiet: Bool = true) -> FlowPillNotice {
            FlowPillNotice(kind: .general, message: "", title: text, variant: .mini, status: .info, timeout: timeout, quiet: quiet)
        }
        if m.hasPrefix("no speech was transcribed") { return nil }
        // Appendix A: PolishTextNoChanges (mini, info, 3 s, quiet).
        if m.hasPrefix("already looks great") { return mini("Your text looks good!", timeout: 3) }
        if m.hasPrefix("transcript saved to clipboard") { return mini("Flow can't paste right now. Text saved to clipboard", timeout: 6) }
        if m.hasPrefix("you have <1 minute left") {
            return FlowPillNotice(kind: .general, message: "", title: message, variant: .mini, status: .alert, timeout: 3)
        }
        // The "Done. See changes" pill already says this; no second line.
        if m.hasPrefix("polished text sent") { return nil }
        // Opt+1 found nothing to polish: one short line with the error mark, not a paragraph.
        // Appendix A: PolishTextNoSelection (mini here, alert, 6 s, quiet).
        if m.hasPrefix("select text in a supported field") || m.hasPrefix("select text first")
            || m.hasPrefix("couldn't read selected text") || m.hasPrefix("couldn’t read selected text")
            || m.hasPrefix("select text to polish") {
            return FlowPillNotice(kind: .general, message: "", title: "Select text to apply a transform", variant: .mini,
                                  status: .alert, timeout: 6, quiet: true)
        }
        if m.hasPrefix("selection changed") {
            return mini("Selection changed. Select the text again.", timeout: 6)
        }
        if m.hasPrefix("couldn't improve this text") || m.hasPrefix("couldn’t improve this text") {
            // Not in Appendix A: a rejected edit keeps the original, and the line says so.
            return mini("Kept your text as written.", timeout: 4)
        }
        if m.hasPrefix("polish unavailable") {
            return card("Polish is busy", "The local model isn't ready yet. Try again in a moment.", .alert, timeout: 3)
        }
        if m.hasPrefix("transcription took too long") {
            if UserDefaults.standard.bool(forKey: FlowNoticeRules.processingDelayOffKey) { return nil }
            var notice = card("Taking longer than usual…", "Your audio is saved for retrying", .alert, timeout: 8, quiet: true)
            notice.actions = [.init(title: "Don't show again", notification: "flow.processingDelayOff")]
            return notice
        }
        if m.hasPrefix("couldn’t paste") || m.hasPrefix("couldn't paste") {
            return FlowPillNotice(kind: .general, message: "Your text is in Dictations.",
                                  title: "Couldn’t paste", status: .alert, timeout: 8,
                                  actions: [.init(title: "Open Dictations", notification: "flow.openHistory")])
        }
        if m.hasPrefix("recording reached") {
            let minutes = message.split(whereSeparator: { !$0.isNumber }).first.map(String.init) ?? "20"
            return card("Transcription session ended.", "Flow supports up to \(minutes) minutes per session.", .alert, timeout: 10)
        }
        if m.hasPrefix("cancelled. audio saved") { return mini("Transcript cancelled") }
        if m.hasPrefix("use undo in the original app") { return mini("Use Undo in the app you pasted into") }
        // A meeting start is confirmed by the meeting face itself; keep the line short so Stop is reachable.
        if m.hasPrefix("meeting recording started") { return mini("Taking notes", timeout: 1.5) }
        // Everything else (meetings, updates, recoveries) stays a short line at the pill.
        return mini(message.replacingOccurrences(of: " — ", with: ". "), timeout: 4, quiet: true)
    }
    static func speechNotReady(_ state: ModelState) -> Self {
        switch state {
        case .loading, .ready:
            return Self(kind: .preparing, message: "Getting speech recognition ready…", timeout: 6, quiet: true)
        case .downloading:
            return Self(kind: .preparing, message: "Downloading speech model…", timeout: 6, quiet: true)
        case .notDownloaded:
            return Self(kind: .modelUnavailable, message: "Choose an installed speech model to dictate.",
                        title: "Speech model needed", timeout: 10, actions: [.speechSettings])
        case .error:
            return Self(kind: .modelUnavailable, message: "Try again or choose a different installed model.",
                        title: "Speech model couldn’t load", timeout: 10, actions: [.speechSettings])
        }
    }
}

enum FlowWindowDestination: Equatable { case dictations, recordings, settings }
struct FlowWindowRequest: Equatable {
    let id = UUID()
    let destination: FlowWindowDestination
    var recordingID: UUID? = nil
}

/// Include unfinished audio in history even when it is too short for a meeting.
enum FlowHistoryVisibility {
    static func includes(isMeeting: Bool, duration: Double, hasAudio: Bool, segmentCount: Int) -> Bool {
        (isMeeting && duration >= 300) || (hasAudio && segmentCount == 0)
    }
}

