import SwiftUI
import AppKit

// MARK: - What the pill looks like right now
//
// The pill is ONE shape. Every state is a `PillLook`: what it shows (`PillFace`), how big it is
// and how round. `PillLookBuilder` turns the engine's state into a look (pure, unit-tested), and
// `PillMorphBody` animates one look into the next: size and corner radius move, the content
// cross-fades inside. Notices and cards are looks too: they grow out of the same body.
//
// Wispr's set (spec section 3): processing shows bars and a spinner with no words; polishing shows
// the transform name and a spinner; the only words are "Done. See changes", "Cleaned up!", the
// Undo states and the notices of Appendix A. No countdowns, no "Writing 4s", no "Still working".

/// The parts of the open idle pill.
enum PillReadySegment: String, CaseIterable, Equatable {
    case dictate, note, wand, wandOptions
}

enum PillFace: Equatable {
    case resting
    case ready(hovered: PillReadySegment?)
    /// Mic is being opened: bars, not yet live.
    case starting
    /// Dictation in progress.
    case listening
    case handsFree
    /// Writing the dictation: resting bars and the spinner. No words.
    case processing
    /// Polishing a selection: the transform name (or "Polishing") and the spinner, over a fill that sweeps for 7 s.
    case polishing(title: String)
    /// Polish finished: "Done. See changes", or "Cleaned up!" for the cleanup nudge.
    case polished(autoCleanup: Bool)
    case cancelled
    case pasted
    case hiddenForHour
    /// One short line: notices, hints, errors.
    case line(text: String, tone: PillTone)
    /// A notice card. The card's own model is built from the notice.
    case card(FlowPillNotice)
    /// "See changes" clicked: the pill grows into the Changes card (polished text, or the original).
    case changes(PolishDiff, original: Bool)
    case meeting(paused: Bool)
    /// A failure: the pill keeps its resting bars in a red edge (Wispr's error pill).
    case error

    /// Content identity: a change of key cross-fades the content.
    var key: String {
        switch self {
        case .resting: return "resting"
        case .ready: return "ready"
        case .starting, .listening: return "capture"
        case .handsFree: return "handsFree"
        case .processing: return "processing"
        case .polishing: return "polishing"
        case .polished(let auto): return "polished-\(auto)"
        case .cancelled: return "cancelled"
        case .pasted: return "pasted"
        case .hiddenForHour: return "hidden"
        case .line(let text, _): return "line-\(text)"
        case .card(let notice): return "card-\(notice.id)"
        case .changes(let diff, _): return "changes-\(diff.id)"
        case .meeting: return "meeting"
        case .error: return "error"
        }
    }

    var isResting: Bool { self == .resting }
    var isCard: Bool {
        switch self {
        case .card, .changes: return true
        default: return false
        }
    }
}

struct PillLook: Equatable {
    var face: PillFace
    var size: CGSize
    var radius: CGFloat
    /// Replaces the plate's edge (meetings, errors).
    var tint: Color?
    /// A short label that buds off the body (hover tips).
    var tip: PillTipText?
    /// Round pieces that bud off the body: before it and after it along the edge.
    var lead: PillBud?
    var trail: PillBud?
    /// Blend radius of the metaball field; nil uses the skin's.
    var blend: CGFloat?
}

/// Wispr's sizes and timings for the pill's own states (spec section 3 and Appendix A).
enum PillWispr {
    static let thickness: CGFloat = 30
    static let processingWidth: CGFloat = 98
    static let polishingWidth: CGFloat = 136
    static let doneWidth: CGFloat = 152
    static let errorWidth: CGFloat = 91
    /// Content changes: 100 ms on Wispr's curve.
    static let contentDuration = 0.1
    static let contentCurve = Animation.timingCurve(0.05, 0.6, 0.4, 0.95, duration: contentDuration)
    /// Size changes: 250 ms.
    // 23 Nov 2026: 0.25 s -> 0.18 s (nothing over about 0.2 s for pill size changes).
    static let sizeDuration = 0.18
    static let sizeCurve = Animation.timingCurve(0.4, 0, 0.2, 1, duration: sizeDuration)
    /// The polish fill runs left to right over this many seconds.
    static let polishFillSeconds = 7.0
    /// "Done. See changes" hides after 5 s; the cleanup nudge after 7 s for its first three showings.
    static func changesSeconds(autoCleanup: Bool, earlierShowings: Int) -> Double {
        autoCleanup && earlierShowings < 3 ? 7 : 5
    }
}

/// A piece that buds off the body.
enum PillBud: Equatable {
    case cancel, finish, note, wand

    func size(_ m: PillSkin.Metrics) -> CGSize {
        switch self {
        case .cancel, .finish: return CGSize(width: m.budSize, height: m.budSize)
        case .note: return CGSize(width: m.thickness, height: m.thickness)
        case .wand: return CGSize(width: m.thickness + m.readyOptions, height: m.thickness)
        }
    }
}

struct PillTipText: Equatable {
    var label: String
    var key: String = ""
}

/// Everything the look depends on, gathered from the engine and the hover state.
struct PillLookInput: Equatable {
    var phase: PillPhase = .idle
    var dock: PillDockEdge = .bottom
    var hovered = false
    var hoveredSegment: PillReadySegment?
    var tipVisible = false
    var notice: FlowPillNotice?
    /// No longer drawn: Wispr shows no words while the mic opens or the mic changes.
    var micHint: String?
    var showingError = false
    var hiddenForHour = false
    var meeting = false
    var meetingPaused = false
    var meetingDetected = false
    /// No longer drawn: processing shows no words (see `PillFace.processing`).
    var thinkingCaption: String?
    var polishTitle = "Polishing"
    /// No longer drawn: the polish fill runs on its own 7 s clock (`PillWispr.polishFillSeconds`).
    var polishProgress: Double?
    var autoCleanup = false
    var wandLabel = "Grammar"
    /// The finished polish whose Changes card is open, and whether it shows the original text.
    var changes: PolishDiff?
    var changesOriginal = false
}

enum PillLookBuilder {
    static func look(_ input: PillLookInput, skin: PillSkin) -> PillLook {
        let face = face(input)
        let size = size(of: face, input: input, skin: skin)
        let radius: CGFloat
        switch face {
        case .resting: radius = skin.metrics.restingCornerRadius
        case .card, .changes: radius = skin.surface.cardCornerRadius
        default:
            switch skin.surface.corners {
            case .capsule: radius = min(size.width, size.height) / 2
            case .rounded(let r): radius = min(r, min(size.width, size.height) / 2)
            }
        }
        var tint: Color?
        if face == .error { tint = skin.palette.danger }
        else if case .meeting(let paused) = face { tint = paused ? skin.surface.edgeHover : skin.palette.live }
        var look = PillLook(face: face, size: size, radius: radius, tint: tint, tip: tip(face, input: input))
        switch face {
        case .ready: look.lead = .note; look.trail = .wand
        case .handsFree: look.lead = .cancel; look.trail = .finish
        default: break
        }
        return look
    }

    /// Priority: a card, then the moment of a failure, then what the engine is doing (which no
    /// line covers), then a one-line notice over an idle pill, then rest.
    static func face(_ input: PillLookInput) -> PillFace {
        // A card takes the pill's place, except over a hands-free dictation (its Cancel and Finish
        // must stay reachable, see `PillPhaseResolver`) and over a running meeting (its face and
        // Stop must stay reachable, so the card waits until the meeting ends).
        if let notice = input.notice, notice.isCard, input.phase != .locked, !input.meeting { return .card(notice) }
        if input.hiddenForHour { return .hiddenForHour }
        switch input.phase {
        case .starting: return .starting
        case .recording: return .listening
        case .locked: return .handsFree
        case .transcribing: return .processing
        case .polishingSelection: return .polishing(title: input.polishTitle)
        case .polishDone:
            if let diff = input.changes { return .changes(diff, original: input.changesOriginal) }
            return .polished(autoCleanup: input.autoCleanup)
        case .cancelled: return .cancelled
        case .undoPaste: return .pasted
        case .idle:
            // A running meeting keeps its face and Stop button: failure flashes, lines and hover never cover them.
            if input.meeting { return .meeting(paused: input.meetingPaused) }
            if input.showingError { return .error }
            if let line = lineFace(input) { return line }
            if input.hovered { return .ready(hovered: input.hoveredSegment) }
            return .resting
        }
    }

    private static func lineFace(_ input: PillLookInput) -> PillFace? {
        guard let notice = input.notice, !notice.isCard else { return nil }
        return .line(text: notice.line, tone: notice.tone)
    }

    private static func tip(_ face: PillFace, input: PillLookInput) -> PillTipText? {
        guard input.tipVisible else { return nil }
        switch face {
        case .ready(let segment?):
            switch segment {
            case .dictate: return PillTipText(label: "Dictate", key: FlowShortcutName.dictation)
            case .note: return PillTipText(label: input.meetingDetected ? "Take notes" : "New note")
            case .wand: return PillTipText(label: input.wandLabel)
            case .wandOptions: return PillTipText(label: "Polish options")
            }
        case .handsFree: return PillTipText(label: "Press", key: FlowShortcutName.dictation + " to finish")
        case .listening: return nil
        case .meeting: return PillTipText(label: "Show notes")
        default: return nil
        }
    }

    static func size(of face: PillFace, input: PillLookInput, skin: PillSkin) -> CGSize {
        let m = skin.metrics, t = skin.type
        let h = m.thickness
        func text(_ s: String, _ role: PillSkin.TypeScale.Role = .label) -> CGFloat { t.width(s, role) }
        let lineMax = input.dock.isSide ? PillLayout.sideAttachMaxWidth : m.noticeMaxWidth
        switch face {
        case .resting:
            return input.dock.resting(m.resting)
        case .ready:
            return CGSize(width: m.readyLength, height: h)
        case .starting, .listening:
            return CGSize(width: m.pushToTalkLength, height: h)
        case .handsFree:
            return CGSize(width: m.handsFreeLength, height: h)
        case .processing:
            return CGSize(width: PillWispr.processingWidth, height: h)
        case .polishing(let title):
            let required = text(title, .button) + 13 + 8 + m.statusPadding * 2 + 4
            return CGSize(width: min(lineMax, max(PillWispr.polishingWidth, required)), height: h)
        case .polished(let auto):
            // Reserve the success check before it animates in; otherwise the
            // final label suddenly overflows the capsule.
            let first = auto ? "Cleaned up!" : "Done."
            let second = auto ? "  See what's changed" : " See changes"
            let required = text(first, .button) + text(second, .button) + 12 + 5 + m.statusPadding * 2 + 4
            return CGSize(width: min(lineMax, max(auto ? 0 : PillWispr.doneWidth, required)), height: h)
        case .cancelled:
            return CGSize(width: min(lineMax, m.statusPadding + text("Transcript cancelled") + m.statusGap + undoWidth(skin) + 5 + 4), height: h)
        case .pasted:
            return CGSize(width: min(lineMax, m.statusPadding + 13 + m.statusGap + text("Pasted") + m.statusGap + undoWidth(skin) + 5 + 4), height: h)
        case .hiddenForHour:
            return CGSize(width: min(lineMax, m.statusPadding + text("The Flow Bar will be hidden for an hour") + m.statusGap + undoWidth(skin) + 5 + 4), height: h)
        case .line(let words, let tone):
            let mark: CGFloat = tone == .info ? 0 : m.noticeIcon + 7
            let width = m.noticePadding * 2 + mark + text(words)
            return CGSize(width: min(lineMax, max(h * 2, width)), height: h)
        case .card(let notice):
            return PillCardModel(notice: notice).size(skin: skin, dock: input.dock)
        case .changes(let diff, let original):
            return PillChangesText.cardSize(diff, original: original, skin: skin, dock: input.dock)
        case .meeting:
            return CGSize(width: m.meetingLength, height: h)
        case .error:
            return CGSize(width: PillWispr.errorWidth, height: h)
        }
    }

    static func undoWidth(_ t: PillSkin.TypeScale) -> CGFloat { t.width("Undo", .button) + 20 }
    static func undoWidth(_ skin: PillSkin) -> CGFloat {
        PillCardText.chipWidth("Undo", skin: skin)
    }
}

extension PillSkin.TypeScale {
    /// The width a single line of text needs in this skin, rounded up. Measured once per text and
    /// role: the pill re-builds its look on every hover and phase change, so measuring again each time
    /// would make those changes wait on text layout.
    func width(_ text: String, _ role: Role) -> CGFloat {
        let font = nsFont(role)
        let key = "\(role)|\(font.fontName)|\(font.pointSize)|\(text)"
        return PillTextMeasure.cached(key) {
            ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
        }
    }
}

/// A small memo for text widths and heights. Only the main thread builds looks, but a lock keeps
/// tests and previews that build them elsewhere safe.
enum PillTextMeasure {
    private static let lock = NSLock()
    private static var values: [String: CGFloat] = [:]

    static func cached(_ key: String, _ measure: () -> CGFloat) -> CGFloat {
        lock.lock()
        if let value = values[key] { lock.unlock(); return value }
        lock.unlock()
        let value = measure()
        lock.lock()
        if values.count > 2_000 { values.removeAll() }
        values[key] = value
        lock.unlock()
        return value
    }
}
