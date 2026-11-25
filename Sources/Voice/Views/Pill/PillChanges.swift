import SwiftUI
import AppKit

// MARK: - The Changes card
//
// Clicking "Done. See changes" grows the pill itself into this card: no window, no title bar. The
// polished text is the main text. Changed words are a touch brighter on a faint soft highlight;
// hovering one shows what it was in a small tooltip. "Original" swaps in the text as it was. Undo
// and Copy are two small round icon buttons. Esc, a click anywhere else, or a few seconds after the
// pointer leaves fold the card back into the pill (22 Nov 2026: "smaller, less width, less empty
// space, in the style of the pill").

/// Sizes of the Changes card. Corner radius, glass and type come from the card system.
enum PillChangesStyle {
    /// Widest card; short text shrinks it down to `minWidth`.
    static let maxWidth: CGFloat = 316
    static let minWidth: CGFloat = 228
    static let padding: CGFloat = 14
    static let topPadding: CGFloat = 10
    static let bottomPadding: CGFloat = 13
    static let headerHeight: CGFloat = 24
    static let headerGap: CGFloat = 5
    /// Text: 13 regular, 19 pt lines, scrolls past six lines.
    static let textSize: CGFloat = 13
    static let line: CGFloat = 19
    static let maxLines = 6
    /// Room each side of the text for the highlight to reach past a word.
    static let bleed: CGFloat = 3
    /// Where a change's underline sits in its line: just under the baseline.
    static let underline: CGFloat = 16.5
    static let button: CGFloat = 24
    static let tipHeight: CGFloat = 22
    static let tipSize: CGFloat = 11.5
    /// Seconds after the pointer leaves before the card folds back; and if it is never touched.
    static let idleSeconds = 2.5
    static let untouchedSeconds = 20.0
    /// Esc.
    static let escapeKey: UInt16 = 53
}

/// One word of the card's text.
struct PillChangeWord: Equatable {
    var text: String
    /// Line breaks after the word (0: a space, or the end).
    var breaks = 0
    /// The change this word belongs to; nil for a kept word.
    var run: Int?
    /// The other version's words for this change. Empty when the words are new (or, in the
    /// original, were dropped).
    var was: String?
}

/// The card's words, measured and laid out. Pure: the look builder sizes the card from it before
/// anything is drawn, and the card draws from the same numbers, so text can never spill.
enum PillChangesText {
    private static let lock = NSLock()
    private static var memo: [String: [PillChangeWord]] = [:]

    /// The words as one version shows them: the polished text, or the original with `original`.
    static func words(_ diff: PolishDiff, original: Bool = false) -> [PillChangeWord] {
        let key = "\(diff.id)|\(original)"
        lock.lock()
        if let cached = memo[key] { lock.unlock(); return cached }
        lock.unlock()
        let value = words(pieces: diff.pieces, original: original)
        lock.lock()
        if memo.count > 64 { memo.removeAll() }
        memo[key] = value
        lock.unlock()
        return value
    }

    static func words(pieces: [PolishDiff.Piece], original: Bool) -> [PillChangeWord] {
        var result: [PillChangeWord] = []
        var run = 0
        /// A change with nothing to show in this version waits for the next kept word.
        var pending: (run: Int, text: String)?
        var index = 0
        while index < pieces.count {
            if pieces[index].kind == .same {
                var words = split(pieces[index].text, into: &result)
                if let wait = pending, !words.isEmpty {
                    words[0].run = wait.run
                    words[0].was = wait.text + " " + words[0].text
                    pending = nil
                }
                result += words
                index += 1
                continue
            }
            var removed = "", added = ""
            while index < pieces.count, pieces[index].kind != .same {
                if pieces[index].kind == .removed { removed += pieces[index].text } else { added += pieces[index].text }
                index += 1
            }
            var scratch: [PillChangeWord] = []
            var shown = split(original ? removed : added, into: &scratch)
            let other = plain(original ? added : removed)
            if shown.map(\.text) == other.split(separator: " ").map(String.init) {
                // Only the spacing or the line breaks changed: nothing to mark.
                result += shown
                continue
            }
            if shown.isEmpty {
                guard !other.isEmpty else { continue }
                pending = (run, other)
            } else {
                for i in shown.indices { shown[i].run = run; shown[i].was = other }
                result += shown
            }
            run += 1
        }
        if let wait = pending, let last = result.indices.last {
            result[last].was = result[last].text + " " + wait.text
            result[last].run = wait.run
        }
        return result
    }

    /// Words with the line breaks after them. Whitespace before the first word adds its breaks to
    /// the word already in `into`.
    private static func split(_ text: String, into previous: inout [PillChangeWord]) -> [PillChangeWord] {
        var words: [PillChangeWord] = []
        for token in PolishDiff.tokens(text) {
            let word = String(token.prefix { !$0.isWhitespace })
            let breaks = min(2, token.filter { $0 == "\n" }.count)
            if word.isEmpty {
                if words.isEmpty, !previous.isEmpty {
                    previous[previous.count - 1].breaks = min(2, previous[previous.count - 1].breaks + breaks)
                } else if !words.isEmpty {
                    words[words.count - 1].breaks = min(2, words[words.count - 1].breaks + breaks)
                }
                continue
            }
            words.append(PillChangeWord(text: word, breaks: breaks))
        }
        return words
    }

    private static func plain(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Distinct changes, for "7 fixes".
    static func fixes(_ words: [PillChangeWord]) -> Int {
        Set(words.compactMap(\.run)).count
    }

    static func fixesLabel(_ diff: PolishDiff) -> String {
        let n = fixes(words(diff))
        if n == 0 { return "Spacing only" }
        return n == 1 ? "1 fix" : "\(n) fixes"
    }

    // MARK: Layout

    struct Flow: Equatable {
        /// Each word's top-left in the text's own space, and the width it draws at.
        var origins: [CGPoint]
        var widths: [CGFloat]
        var lines: Int
        /// The longest line's right edge.
        var extent: CGFloat
        /// Highlight runs: one rect per change per line.
        var marks: [Mark]
    }

    struct Mark: Equatable {
        var run: Int
        var rect: CGRect
        /// The first word in the mark (its `was` names the change).
        var word: Int
    }

    static func font(_ skin: PillSkin) -> NSFont { PillCardType.nsFont(skin, PillChangesStyle.textSize, .regular) }

    static func width(_ word: String, _ font: NSFont) -> CGFloat {
        PillTextMeasure.cached("chg|\(font.fontName)|\(font.pointSize)|\(word)") {
            (word as NSString).size(withAttributes: [.font: font]).width
        }
    }

    /// Greedy wrapping at `width`. A word longer than a line gets a line to itself, cut to fit.
    static func flow(_ words: [PillChangeWord], font: NSFont, width: CGFloat) -> Flow {
        let line = PillChangesStyle.line
        let space = self.width(" ", font)
        var origins: [CGPoint] = [], widths: [CGFloat] = []
        var x: CGFloat = 0, row = 0, extent: CGFloat = 0
        for word in words {
            let w = min(width, self.width(word.text, font))
            if x > 0, x + w > width { row += 1; x = 0 }
            origins.append(CGPoint(x: x, y: CGFloat(row) * line))
            widths.append(w)
            extent = max(extent, x + w)
            x += w + space
            if word.breaks > 0 { row += word.breaks; x = 0 }
        }
        // Trailing breaks after the last word add no lines.
        let lines = words.isEmpty ? 1 : Int((origins.last!.y / line).rounded()) + 1
        var marks: [Mark] = []
        for (i, word) in words.enumerated() {
            guard let run = word.run else { continue }
            let rect = CGRect(x: origins[i].x, y: origins[i].y, width: widths[i], height: line)
            if let last = marks.last, last.run == run, abs(last.rect.minY - rect.minY) < 0.5 {
                marks[marks.count - 1].rect = last.rect.union(rect)
            } else {
                marks.append(Mark(run: run, rect: rect, word: i))
            }
        }
        return Flow(origins: origins, widths: widths, lines: lines, extent: extent, marks: marks)
    }

    // MARK: Card size

    /// The card hugs its text: as narrow as the text allows (never narrower than the header needs)
    /// and as tall as its lines, up to six; longer text scrolls inside.
    static func cardSize(_ diff: PolishDiff, original: Bool, skin: PillSkin, dock: PillDockEdge) -> CGSize {
        let s = PillChangesStyle.self
        let limit = dock.isSide ? min(s.maxWidth, PillLayout.sideCardMaxWidth) : s.maxWidth
        let font = font(skin)
        let shownWords = words(diff, original: original)
        let natural = flow(shownWords, font: font, width: limit - s.padding * 2)
        // The header also names the model: fix count, name, Original, Undo and Copy must all fit.
        let header = diff.model.map { name in
            PillChangesText.width(fixesLabel(diff) + " · " + name, PillCardType.nsFont(skin, 12, .regular)) + 140
        } ?? 0
        let wanted = max(s.minWidth, ceil(header) + s.padding * 2, ceil(natural.extent) + s.padding * 2)
        let width = min(limit, wanted)
        let lines = flow(shownWords, font: font, width: width - s.padding * 2).lines
        let height = s.topPadding + s.headerHeight + s.headerGap + CGFloat(min(lines, s.maxLines)) * s.line + s.bottomPadding
        return CGSize(width: width, height: ceil(height))
    }
}

// MARK: - The card's content

struct PillChangesCard: View {
    let diff: PolishDiff
    let original: Bool
    let size: CGSize
    let actions: PillActions
    @Environment(\.pillSkin) private var skin
    @Environment(\.pillRendersOffscreen) private var offscreen
    @Environment(\.pillInspection) private var inspection
    @Environment(\.pillBackdrop) private var backdrop
    @State private var hoveredMark: Int?
    @State private var copied = false
    @State private var scrollY: CGFloat = 0
    @State private var idle: Task<Void, Never>?
    @State private var monitors: [Any] = []

    private typealias S = PillChangesStyle
    private var textWidth: CGFloat { size.width - S.padding * 2 }

    var body: some View {
        let words = PillChangesText.words(diff, original: original)
        let flow = PillChangesText.flow(words, font: PillChangesText.font(skin), width: textWidth)
        let shownMark = hoveredMark ?? inspection.changesHover
        VStack(alignment: .leading, spacing: S.headerGap) {
            header(words)
            text(words, flow, hovered: shownMark)
        }
        .padding(.horizontal, S.padding)
        .padding(.top, S.topPadding)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background { veil }
        .overlay(alignment: .topLeading) { tooltip(words, flow, mark: shownMark) }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { idle?.cancel() } else { scheduleClose(after: S.idleSeconds) }
        }
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .onChange(of: original) { _, _ in hoveredMark = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes")
    }

    /// See-through glass (Clear, Liquid) shows the screen behind it sharply; a page of text over
    /// that is hard to read. A quiet veil inside the rim settles it: light over a bright screen
    /// (the ink is dark there), dark over a dark one. Jet and Default need none.
    @ViewBuilder private var veil: some View {
        if case .glass(let glass) = skin.renderer, !glass.dark {
            let bright = skin.onBrightGlass && glass.adaptiveInk
            RoundedRectangle(cornerRadius: max(0, skin.surface.cardCornerRadius - 1.5), style: .continuous)
                .fill(bright ? Color.white.opacity(0.68) : Color.black.opacity(0.32))
                .padding(1.5)
        }
    }

    // MARK: Header

    private func header(_ words: [PillChangeWord]) -> some View {
        let ink = skin.palette.ink
        return HStack(spacing: 2) {
            (Text(PillChangesText.fixesLabel(diff)).foregroundStyle(ink.opacity(0.5))
             + Text(diff.model.map { " · " + $0 } ?? "").foregroundStyle(ink.opacity(0.32)))
                .font(PillCardType.meta(skin))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            PillChangesTextButton(title: "Original", on: original) {
                PillHaptics.press()
                actions.toggleChangesOriginal()
            }
            .padding(.trailing, 2)
            if diff.canUndo(inDraftReview: false) {
                PillChangesIconButton(label: "Undo") {
                    PillUndoGlyph().stroke(ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 12, height: 12)
                } action: {
                    PillHaptics.press()
                    NotificationCenter.default.post(name: .flowUndoLastPolish, object: diff.id)
                    actions.closeChanges()
                }
            }
            PillChangesIconButton(label: copied ? "Copied" : "Copy") {
                if copied {
                    PillCheckGlyph().stroke(ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 10, height: 7)
                } else {
                    PillCopyGlyph().stroke(ink, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        .frame(width: 12, height: 12)
                }
            } action: {
                PillHaptics.press()
                copied = DictationPasteboard.write(original ? diff.original : diff.polished)
            }
        }
        .padding(.trailing, -5)
        .frame(height: S.headerHeight)
    }

    // MARK: Text

    @ViewBuilder private func text(_ words: [PillChangeWord], _ flow: PillChangesText.Flow, hovered: Int?) -> some View {
        let height = CGFloat(flow.lines) * S.line
        let visible = CGFloat(min(flow.lines, S.maxLines)) * S.line
        let canvas = wordLayer(words, flow, hovered: hovered)
            .frame(width: textWidth, height: height, alignment: .topLeading)
            .padding(.horizontal, S.bleed)
        Group {
            if flow.lines > S.maxLines && offscreen {
                // Offscreen renders cannot draw a ScrollView: show it scrolled to the top.
                canvas.frame(height: visible, alignment: .top).clipped()
                    .mask(fade(atEnd: false, atStart: true))
            } else if flow.lines > S.maxLines {
                ScrollView(.vertical, showsIndicators: false) { canvas }
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                        scrollY = y
                        hoveredMark = nil
                    }
                    .mask(fade(atEnd: scrollY + visible >= height - 1, atStart: scrollY <= 1))
            } else {
                canvas
            }
        }
        .frame(width: textWidth + S.bleed * 2, height: visible, alignment: .topLeading)
        .padding(.horizontal, -S.bleed)
    }

    private func wordLayer(_ words: [PillChangeWord], _ flow: PillChangesText.Flow, hovered: Int?) -> some View {
        let ink = skin.palette.ink
        let font = PillCardType.font(skin, S.textSize, .regular)
        let hoveredRun = hovered.flatMap { flow.marks.indices.contains($0) ? flow.marks[$0].run : nil }
        return ZStack(alignment: .topLeading) {
            // Each change gets a soft underline; the hovered one a faint highlight instead.
            ForEach(Array(flow.marks.enumerated()), id: \.offset) { _, mark in
                let on = mark.run == hoveredRun
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(ink.opacity(on ? 0.13 : 0))
                        .frame(width: mark.rect.width + 6, height: S.line - 1)
                        .offset(x: -3, y: 0.5)
                    Capsule(style: .continuous)
                        .fill(ink.opacity(on ? 0 : 0.24))
                        .frame(width: mark.rect.width, height: 1)
                        .offset(y: S.underline)
                }
                .offset(x: mark.rect.minX, y: mark.rect.minY)
            }
            ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                Text(word.text)
                    .font(font)
                    .foregroundStyle(ink.opacity(word.run == nil ? 0.7 : 1))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: flow.widths[i] + 2, height: S.line, alignment: .leading)
                    .offset(x: flow.origins[i].x, y: flow.origins[i].y)
            }
            // Hover targets over each highlight.
            ForEach(Array(flow.marks.enumerated()), id: \.offset) { index, mark in
                Color.clear
                    .frame(width: mark.rect.width + 6, height: S.line)
                    .contentShape(Rectangle())
                    .offset(x: mark.rect.minX - 3, y: mark.rect.minY)
                    .onHover { inside in
                        if inside { hoveredMark = index } else if hoveredMark == index { hoveredMark = nil }
                    }
            }
        }
        .animation(skin.motion.hover, value: hoveredRun)
    }

    private func fade(atEnd: Bool, atStart: Bool) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(atStart ? 1 : 0), .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(atEnd ? 1 : 0)], startPoint: .top, endPoint: .bottom).frame(height: 14)
        }
    }

    // MARK: Tooltip

    /// What a changed word was, in a small dark capsule above it (below it on the first line).
    @ViewBuilder private func tooltip(_ words: [PillChangeWord], _ flow: PillChangesText.Flow, mark: Int?) -> some View {
        if let mark, flow.marks.indices.contains(mark) {
            let m = flow.marks[mark]
            let was = words[m.word].was ?? ""
            let lead = original ? (was.isEmpty ? "dropped" : "now") : (was.isEmpty ? "added" : "was")
            let font = PillCardType.nsFont(skin, S.tipSize, .medium)
            let maxWidth = size.width - 16
            let natural = PillChangesText.width(lead, font) + (was.isEmpty ? 0 : 4 + PillChangesText.width(was, font)) + 24
            let width = min(maxWidth, natural)
            let textTop = S.topPadding + S.headerHeight + S.headerGap
            let wordTop = textTop + m.rect.minY - scrollY
            let above = wordTop - S.tipHeight - 2
            // Above the word, unless that would cover the header: then just below it.
            let y = above >= textTop - 7 ? above : min(size.height - S.tipHeight - 4, wordTop + S.line + 2)
            let x = min(max(8, S.padding + m.rect.midX - width / 2), size.width - 8 - width)
            HStack(spacing: 4) {
                Text(lead).foregroundStyle(Color.white.opacity(0.5))
                if !was.isEmpty { Text(was).foregroundStyle(Color.white.opacity(0.95)) }
            }
            .font(PillCardType.font(skin, S.tipSize, .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .frame(width: width, height: S.tipHeight)
            .background(Capsule(style: .continuous).fill(Color(white: 0.11, opacity: 0.96)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .offset(x: x, y: y)
            .allowsHitTesting(false)
            .transition(.opacity.animation(.easeOut(duration: 0.12)))
            .id(mark)
        }
    }

    // MARK: Folding back

    private func scheduleClose(after seconds: Double) {
        idle?.cancel()
        guard !offscreen else { return }
        idle = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { actions.closeChanges() }
        }
    }

    private func begin() {
        guard !offscreen else { return }
        scheduleClose(after: S.untouchedSeconds)
        let close = actions.closeChanges
        // Clicks and keys that go to other apps: any click elsewhere or Esc folds the card.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { event in
            if event.type == .keyDown, event.keyCode != S.escapeKey { return }
            MainActor.assumeIsolated { close() }
        }) { monitors.append(global) }
        // Esc while one of Flow's own windows has the keyboard.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { event in
            guard event.keyCode == S.escapeKey else { return event }
            MainActor.assumeIsolated { close() }
            return nil
        }) { monitors.append(local) }
    }

    private func end() {
        idle?.cancel()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

/// A small round icon button in the card's header: no fill until hovered.
struct PillChangesIconButton<Glyph: View>: View {
    let label: String
    @ViewBuilder let glyph: Glyph
    let action: () -> Void
    @Environment(\.pillSkin) private var skin
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            glyph
                .opacity(hovering ? 1 : 0.72)
                .frame(width: PillChangesStyle.button, height: PillChangesStyle.button)
                .background(Circle().fill(skin.palette.ink.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PillPressStyle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .animation(skin.motion.hover, value: hovering)
        .accessibilityLabel(label)
    }
}

/// "Original": a quiet text toggle. On, it sits on a soft capsule.
struct PillChangesTextButton: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @Environment(\.pillSkin) private var skin
    @State private var hovering = false

    var body: some View {
        let ink = skin.palette.ink
        Button(action: action) {
            Text(title)
                .font(PillCardType.font(skin, 11.5, .medium))
                .foregroundStyle(ink.opacity(on || hovering ? 0.95 : 0.6))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule(style: .continuous).fill(ink.opacity(on ? 0.14 : hovering ? 0.08 : 0)))
                .fixedSize()
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PillPressStyle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .animation(skin.motion.hover, value: hovering)
        .animation(skin.motion.hover, value: on)
        .accessibilityLabel(on ? "Show polished" : "Show original")
    }
}

/// Two overlapping rounded sheets (copy), on a 24 grid.
struct PillCopyGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
        }
        var path = Path()
        path.addRoundedRect(in: r(8, 8, 13, 13), cornerSize: CGSize(width: 3 * s, height: 3 * s), style: .continuous)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        path.move(to: p(3, 16))
        path.addArc(tangent1End: p(3, 3), tangent2End: p(16, 3), radius: 3 * s)
        path.addLine(to: p(16, 3))
        return path
    }
}
