import SwiftUI
import AppKit

// MARK: - Notices
//
// A notice is either one short line (`PillFace.line`) or a card (`PillFace.card`). Both are looks
// of the one pill body: it grows into them and shrinks back. `PillCardModel` holds a card's words
// and actions and measures it, so the body knows its size before the content appears.
//
// One card system for every card, notice and the Changes view (see `PillCardStyle`):
// - Type: title 13 semibold, body 12 regular at 62% white, meta 12 at 50%, chips 11.5 semibold.
// - Notice: 300 wide content, 14 padding, 11 gap, 28 pt circle icon, title, body, chips (6 gap, 7 top).
// - Chips: one component. Primary is white with black text; secondary is white 12% with a 0.5 pt edge.
// - Close: an 18 pt ring that drains over the card's timeout, with the cross inside it.

extension FlowPillNotice {
    /// Cards take the pill's place; everything else is one line.
    var isCard: Bool { variant == .standard && kind != .preparing }

    var tone: PillTone {
        if kind == .preparing { return .info }
        switch effectiveStatus {
        case .error: return .error
        case .alert: return .warning
        case .info: return .info
        }
    }

    /// The words a one-line notice shows.
    var line: String { FlowPillNotice.compactLine(title ?? message) }

    /// One short line from any message: a plain short form for known wordy messages, otherwise
    /// the first sentence without its full stop.
    static func compactLine(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " — ", with: ". ")
        let lower = text.lowercased()
        if lower.hasPrefix("couldn't read selected text") || lower.hasPrefix("couldn’t read selected text")
            || lower.hasPrefix("select text to polish") || lower.hasPrefix("select text first")
            || lower.hasPrefix("select text in a supported field") {
            return "Select some text first"
        }
        if lower.hasPrefix("you have <1 minute left") { return "Less than a minute left" }
        let sentences = text.split(separator: ".", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard sentences.count > 1, let first = sentences.first else {
            return text.hasSuffix(".") && !text.hasSuffix("...") ? String(text.dropLast()) : text
        }
        return first
    }
}

/// The tone of a line or card: errors and warnings carry a small tinted mark.
enum PillTone: Equatable { case info, success, warning, error }

// MARK: - The card system

/// Every number a card uses, in points. Cards, the one-line error and the Changes view all read these.
enum PillCardStyle {
    /// Corner radius of every card.
    static let radius: CGFloat = 22
    static let padding: CGFloat = 14
    static let gap: CGFloat = 11
    /// Content width of a notice and of the Changes view.
    static let noticeWidth: CGFloat = 300
    static let changesWidth: CGFloat = 340
    /// Leading circle icon.
    static let icon: CGFloat = 28
    /// Chips: 6 pt apart, 7 pt below the text.
    static let chipGap: CGFloat = 6
    static let chipTop: CGFloat = 7
    static let chipHeight: CGFloat = 24
    /// Gap between title and body.
    static let textGap: CGFloat = 3
    /// Countdown ring around the close cross, and the room the title leaves for it.
    static let ring: CGFloat = 18
    static let ringRoom: CGFloat = 26
    /// Line heights.
    static let titleLine: CGFloat = 17
    static let bodyLine: CGFloat = 16
    static let changesLine: CGFloat = 19.5
    /// Changes text scrolls once it passes this many lines.
    static let changesMaxLines = 5
    /// A one-line error mark.
    static let errorMark: CGFloat = 15
    /// Meeting dot.
    static let meetingDot: CGFloat = 7
}

/// The card type: one family from the skin, five sizes and weights.
enum PillCardType {
    static func font(_ skin: PillSkin, _ size: CGFloat, _ weight: Font.Weight) -> Font {
        skin.type.family == .figtree ? .flowBar(size, weight: weight) : .system(size: size, weight: weight)
    }

    static func nsFont(_ skin: PillSkin, _ size: CGFloat, _ weight: Font.Weight) -> NSFont {
        if skin.type.family == .figtree, let font = Font.flowBarNSFont(size, weight: weight) { return font }
        let ns: NSFont.Weight = weight == .semibold ? .semibold : weight == .medium ? .medium : .regular
        return NSFont.systemFont(ofSize: size, weight: ns)
    }

    static func title(_ skin: PillSkin) -> Font { font(skin, 13, .semibold) }
    static func body(_ skin: PillSkin) -> Font { font(skin, 12, .regular) }
    static func meta(_ skin: PillSkin) -> Font { font(skin, 12, .regular) }
    static func chip(_ skin: PillSkin) -> Font { font(skin, 11.5, .semibold) }
    static func changes(_ skin: PillSkin) -> Font { font(skin, 13, .regular) }

    /// Extra space between lines so a line takes `line` points in total.
    static func leading(_ font: NSFont, line: CGFloat) -> CGFloat {
        max(0, line - (font.ascender - font.descender + font.leading))
    }
}

/// Measures wrapped text in lines, memoised like the rest of the pill's measuring.
enum PillCardText {
    static func lines(_ text: String, _ font: NSFont, width: CGFloat, maximum: Int = .max) -> Int {
        guard !text.isEmpty, width > 0 else { return 0 }
        let key = "lines|\(font.fontName)|\(font.pointSize)|\(Int(width))|\(text)"
        let count = PillTextMeasure.cached(key) {
            let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: 10_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            let natural = font.ascender - font.descender + font.leading
            return CGFloat(max(1, Int((rect.height / natural).rounded())))
        }
        return min(maximum, Int(count))
    }
}

/// A card's words and actions, decided once from the notice.
struct PillCardModel: Equatable {
    struct Action: Equatable {
        enum Kind: Equatable { case post(String, recordingID: UUID?), copy, close }
        let title: String
        var primary = false
        let kind: Kind
    }

    let notice: FlowPillNotice
    let title: String
    let body: String
    let tone: PillTone
    let timeout: Double
    let actions: [Action]

    init(notice: FlowPillNotice) {
        self.notice = notice
        let title = Self.title(notice)
        self.title = title
        self.body = Self.body(notice, title: title)
        self.tone = Self.tone(notice)
        self.timeout = Self.timeout(notice, title: title)
        self.actions = Self.actions(notice, title: title)
    }

    // MARK: Size

    /// A notice is 300 wide plus its padding, never wider than the dock allows.
    func width(skin: PillSkin, dock: PillDockEdge) -> CGFloat {
        let maxWidth = dock.isSide ? min(skin.metrics.cardMaxWidth, PillLayout.sideCardMaxWidth) : skin.metrics.cardMaxWidth
        return min(maxWidth, PillCardStyle.noticeWidth + PillCardStyle.padding * 2)
    }

    func size(skin: PillSkin, dock: PillDockEdge) -> CGSize {
        let width = width(skin: skin, dock: dock)
        let textWidth = width - PillCardStyle.padding * 2 - PillCardStyle.icon - PillCardStyle.gap
        let titleLines = PillCardText.lines(title, PillCardType.nsFont(skin, 13, .semibold),
                                            width: textWidth - PillCardStyle.ringRoom, maximum: 2)
        var text = CGFloat(titleLines) * PillCardStyle.titleLine
        if notice.badge != nil { text += PillCardStyle.textGap + PillCardStyle.bodyLine }
        if !body.isEmpty {
            let bodyLines = PillCardText.lines(body.trimmingCharacters(in: .whitespacesAndNewlines), PillCardType.nsFont(skin, 12, .regular), width: textWidth, maximum: 4)
            text += PillCardStyle.textGap + CGFloat(bodyLines) * PillCardStyle.bodyLine
        }
        if !actions.isEmpty { text += PillCardStyle.chipTop + PillCardStyle.chipHeight }
        // A little slack: the estimate must never come out shorter than the laid-out text, or the words
        // spill outside the glass (21 Nov 2026: "reconnected it" drawn above the card).
        let height = PillCardStyle.padding * 2 + max(PillCardStyle.icon, text) + 6
        return CGSize(width: width, height: ceil(height))
    }

    // MARK: Words

    private static func title(_ notice: FlowPillNotice) -> String {
        if let custom = notice.title { return custom }
        switch notice.kind {
        case .general, .cancelled: return notice.message
        case .microphone:
            let m = notice.message.lowercased()
            if m.contains("too quiet") { return "Microphone is too quiet" }
            if m.contains("no sound") || m.contains("silence") || m.contains("muted") { return "Is your microphone muted?" }
            if m.contains("disconnect") || m.contains("device changed") { return "Microphone disconnected" }
            if m.contains("not responding") || m.contains("permission") { return "Unable to access mic" }
            if m.contains("unavailable") || m.contains("not found") || m.contains("no microphone") { return "No microphone detected" }
            return "Microphone error"
        case .paste:
            return notice.message.lowercased().contains("password") ? "Skipped password field" : "Click a text box and press ⌘V"
        case .transcription: return "Something's not right"
        case .recoveredAudio: return "Recording recovered"
        case .preparing: return "Getting speech recognition ready…"
        case .modelUnavailable: return "Speech model unavailable"
        case .noSpeech: return "We couldn't hear you"
        }
    }

    private static func tone(_ notice: FlowPillNotice) -> PillTone {
        if notice.kind == .general || notice.status != nil { return notice.tone }
        switch notice.kind {
        case .preparing, .recoveredAudio, .paste: return .info
        default: return .error
        }
    }

    private static func body(_ notice: FlowPillNotice, title: String) -> String {
        if let text = notice.recoveryText {
            return notice.hidesRecoveryPreview ? "Copy the text if you need it." : text
        }
        switch notice.kind {
        case .paste where !notice.message.lowercased().contains("password"): return ""
        case .transcription: return "Check dictation history for the recording."
        case .noSpeech: return "No speech came through your microphone."
        case .microphone:
            switch title {
            case "No microphone detected": return "Connect one, or pick an input in Sound settings."
            case "Unable to access mic", "Microphone disconnected": return "Reconnect it or choose another input."
            case "Microphone error": return "Flow couldn't start your microphone. Try reconnecting it."
            case "Is your microphone muted?":
                let mic = UserDefaults.standard.string(forKey: "flow.lastMicName") ?? "your microphone"
                return "No audio came through \(mic)."
            default: break
            }
        default: break
        }
        let prefix = title + ". "
        return notice.message.hasPrefix(prefix) ? String(notice.message.dropFirst(prefix.count)) : notice.message
    }

    private static func timeout(_ notice: FlowPillNotice, title: String) -> Double {
        if let custom = notice.timeout { return custom }
        switch notice.kind {
        case .general: return 6
        case .cancelled: return 8
        case .preparing, .transcription, .noSpeech, .paste, .modelUnavailable: return 6
        case .microphone: return title == "No microphone detected" || title == "Microphone error" ? 10 : 6
        case .recoveredAudio: return 10
        }
    }

    private static func actions(_ notice: FlowPillNotice, title: String) -> [Action] {
        let selectMic = Action(title: "Select microphone", kind: .post("flow.selectMicrophone", recordingID: nil))
        let soundSettings = Action(title: "Sound settings", kind: .post("flow.openSoundSettings", recordingID: nil))
        let speech = FlowPillNotice.Action.speechSettings
        var list: [Action]
        switch notice.kind {
        case .transcription: list = [Action(title: "Open history", kind: .post("flow.openHistory", recordingID: nil))]
        case .noSpeech: list = [selectMic, soundSettings]
        case .modelUnavailable:
            list = notice.actions.isEmpty ? [Action(title: speech.title, kind: .post(speech.notification, recordingID: nil))] : []
        case .microphone:
            switch title {
            case "Is your microphone muted?", "Microphone is too quiet", "Unable to access mic", "Microphone disconnected":
                list = [selectMic, soundSettings]
            default: list = [soundSettings]
            }
        default: list = []
        }
        list += notice.actions.map {
            Action(title: $0.title, kind: $0.notification.isEmpty ? .close : .post($0.notification, recordingID: nil))
        }
        if notice.recoveryText != nil { list.append(Action(title: "Copy text", primary: true, kind: .copy)) }
        if notice.kind == .cancelled {
            list.append(Action(title: "Open history", kind: .post("flow.openHistory", recordingID: nil)))
            list.append(Action(title: "Undo", primary: true, kind: .post("flow.undoCancel", recordingID: nil)))
        }
        if notice.kind == .recoveredAudio {
            list.append(Action(title: "Open", primary: true, kind: .post("flow.openHistory", recordingID: notice.recordingID)))
        }
        return list
    }
}

/// A notice card's content, drawn inside the pill body. Its timer closes it; hovering pauses the timer.
struct PillCardContent: View {
    let model: PillCardModel
    let size: CGSize
    let dismiss: () -> Void
    let copy: (UUID) -> Bool
    @Environment(\.pillSkin) private var skin
    @State private var remaining: CGFloat = 1
    @State private var deadline: ContinuousClock.Instant?
    @State private var pausedRecoverySeconds: Double?
    @State private var timer: Task<Void, Never>?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: PillCardStyle.gap) {
            PillNoticeIcon(tone: model.tone)
            VStack(alignment: .leading, spacing: PillCardStyle.textGap) {
                Text(model.title).font(PillCardType.title(skin)).foregroundStyle(skin.palette.ink)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, PillCardStyle.ringRoom)
                if let badge = model.notice.badge {
                    Text(badge).font(PillCardType.meta(skin)).foregroundStyle(skin.palette.ink.opacity(0.5))
                }
                if !model.body.isEmpty {
                    Text(model.body.trimmingCharacters(in: .whitespacesAndNewlines)).font(PillCardType.body(skin)).foregroundStyle(skin.onBrightGlass ? Color.black.opacity(0.6) : Color.white.opacity(0.62))
                        .lineSpacing(PillCardType.leading(PillCardType.nsFont(skin, 12, .regular), line: PillCardStyle.bodyLine))
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
                if !model.actions.isEmpty {
                    HStack(spacing: PillCardStyle.chipGap) {
                        ForEach(Array(model.actions.enumerated()), id: \.offset) { _, action in
                            PillChip(title: action.title, primary: action.primary, finished: dismiss) { run(action) }
                        }
                    }
                    .padding(.top, PillCardStyle.chipTop)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(PillCardStyle.padding)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background {
            // Light glass over a bright screen: a quiet white veil, as the Changes card has, so dark ink reads.
            if skin.onBrightGlass {
                RoundedRectangle(cornerRadius: max(0, PillCardStyle.radius - 1.5), style: .continuous)
                    .fill(Color.white.opacity(0.68)).padding(1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PillCardStyle.radius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            PillCountdownClose(remaining: remaining, action: dismiss)
                .padding(.top, PillCardStyle.padding - 3)
                .padding(.trailing, PillCardStyle.padding - 3)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { stopTimer() } else { startTimer() }
        }
        .onAppear(perform: startTimer)
        .onDisappear { timer?.cancel() }
    }

    private func run(_ action: PillCardModel.Action) -> Bool {
        switch action.kind {
        case .close: return true
        case .copy: return copy(model.notice.id)
        case .post(let name, let recordingID):
            var info: [String: Any]?
            if name == "flow.openHistory", model.notice.kind == .recoveredAudio {
                var recovered: [String: Any] = ["recordings": true]
                if let recordingID { recovered["recordingID"] = recordingID.uuidString }
                info = recovered
            }
            NotificationCenter.default.post(name: Notification.Name(name), object: nil, userInfo: info)
            return true
        }
    }

    private func startTimer() {
        timer?.cancel()
        deadline = nil
        guard !hovering else { return }
        let duration = model.notice.resumedTimeout(remaining: pausedRecoverySeconds) ?? model.timeout
        pausedRecoverySeconds = nil
        var reset = Transaction(); reset.disablesAnimations = true
        withTransaction(reset) { remaining = duration / model.timeout }
        let end = ContinuousClock.now + .seconds(duration)
        deadline = end
        withAnimation(.linear(duration: duration)) { remaining = 0 }
        timer = Task { @MainActor in
            try? await ContinuousClock().sleep(until: end)
            if !Task.isCancelled { dismiss() }
        }
    }

    /// Pauses while hovered; recovery resumes with enough time to move to Copy.
    private func stopTimer() {
        timer?.cancel()
        guard let deadline else { return }
        self.deadline = nil
        let left = ContinuousClock.now.duration(to: deadline).components
        let seconds = max(0, Double(left.seconds) + Double(left.attoseconds) / 1e18)
        if model.notice.recoveryText != nil { pausedRecoverySeconds = seconds }
        var still = Transaction(); still.disablesAnimations = true
        withTransaction(still) { remaining = min(1, seconds / model.timeout) }
    }
}

/// The notice's leading icon: a 28 pt circle at white 10%, with the tone's glyph inside.
struct PillNoticeIcon: View {
    let tone: PillTone
    @Environment(\.pillSkin) private var skin
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.10))
            switch tone {
            case .info:
                Text("i").font(PillCardType.font(skin, 13, .semibold)).foregroundStyle(skin.palette.ink)
            case .success:
                PillCheckGlyph().stroke(skin.palette.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 12, height: 9)
            case .warning:
                PillStatusGlyph(alert: true).stroke(skin.palette.warning, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
            case .error:
                PillStatusGlyph().stroke(skin.palette.danger, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
            }
        }
        .frame(width: PillCardStyle.icon, height: PillCardStyle.icon)
        .accessibilityHidden(true)
    }
}

/// Tone marks for one-line faces. Errors get the red "!" disc; warnings and success get a glyph.
struct PillToneMark: View {
    let tone: PillTone
    var size: CGFloat
    @Environment(\.pillSkin) private var skin
    var body: some View {
        switch tone {
        case .info: EmptyView()
        case .success:
            PillCheckGlyph().stroke(skin.palette.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.75, height: size * 0.52)
        case .warning:
            PillStatusGlyph(alert: true).stroke(skin.palette.warning, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        case .error:
            PillErrorMark()
        }
    }
}

/// The one-line error mark: a 15 pt red disc with a white "!".
struct PillErrorMark: View {
    @Environment(\.pillSkin) private var skin
    var body: some View {
        Circle().fill(skin.palette.danger)
            .frame(width: PillCardStyle.errorMark, height: PillCardStyle.errorMark)
            .overlay {
                Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.white)
            }
            .accessibilityHidden(true)
    }
}

/// The card's close button: a cross inside an 18 pt ring that empties as the card times out.
struct PillCountdownClose: View {
    let remaining: CGFloat
    let action: () -> Void
    @Environment(\.pillSkin) private var skin
    @State private var hovering = false
    private var rim: Color { skin.onBrightGlass ? .black : .white }
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(rim.opacity(0.10), lineWidth: 1.5)
                Circle().trim(from: 0, to: remaining)
                    .stroke(rim.opacity(0.40), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                PillCrossGlyph().stroke(skin.palette.ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(width: 6, height: 6)
            }
            .frame(width: PillCardStyle.ring, height: PillCardStyle.ring)
            .background(Circle().fill(rim.opacity(hovering ? 0.12 : 0)).padding(-3))
            .contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(PillPressStyle())
        .onHover { hovering = $0 }
        .animation(skin.motion.hover, value: hovering)
        .accessibilityLabel("Dismiss")
    }
}

/// The one chip for every card and Changes view. Primary is white with black text; secondary is
/// white 12% with a 0.5 pt inner edge. A click shows a check, then the card closes.
struct PillChip: View {
    let title: String
    var primary = false
    var finished: () -> Void = {}
    let action: () -> Bool
    @Environment(\.pillSkin) private var skin
    @State private var hovering = false
    @State private var done = false
    var body: some View {
        let bright = skin.onBrightGlass
        let ink: Color = primary ? (bright ? Color(white: 0.97) : .black) : (bright ? Color(white: 0.08) : Color.white.opacity(0.96))
        Button {
            guard !done, action() else { return }
            done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { finished() }
        } label: {
            Text(title).font(PillCardType.chip(skin)).foregroundStyle(ink)
                .opacity(done ? 0 : 1)
                .overlay {
                    if done {
                        PillCheckGlyph().stroke(ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .frame(width: 10, height: 7)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: PillCardStyle.chipHeight)
                .background(Capsule(style: .continuous).fill(fill))
                .overlay {
                    if !primary {
                        Capsule(style: .continuous).strokeBorder(bright ? Color.black.opacity(0.18) : Color.white.opacity(0.22), lineWidth: 0.5)
                    }
                }
                .fixedSize()
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PillPressStyle())
        .disabled(done)
        .onHover { inside in
            hovering = inside
            if inside && !done { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .animation(skin.motion.hover, value: hovering)
        .accessibilityLabel(title)
    }

    private var fill: Color {
        if skin.onBrightGlass {
            if primary { return Color(white: 0.08, opacity: hovering && !done ? 0.86 : 1) }
            return Color.black.opacity(hovering && !done ? 0.14 : 0.08)
        }
        if primary { return Color.white.opacity(hovering && !done ? 0.86 : 1) }
        return Color.white.opacity(hovering && !done ? 0.18 : 0.12)
    }
}
