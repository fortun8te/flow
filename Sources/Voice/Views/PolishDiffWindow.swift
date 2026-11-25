import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by the Changes window: undo the last Opt+1 polish, or undo it and polish the original again.
    static let flowUndoLastPolish = Notification.Name("flow.undoLastPolish")
    static let flowRetryLastPolish = Notification.Name("flow.retryLastPolish")
}

/// A compact confirmation. There is a separate explicit review action.
enum PolishPillWords {
    static let line = "Polished"
}

/// What a polish changed in the selected text. Shown when "Done. See changes" is clicked.
struct PolishDiff: Equatable, Identifiable {
    let id = UUID()
    let original: String
    let polished: String
    /// True for Wispr's dictation nudge ("Cleaned up! See what's changed") rather than a polish of a selection.
    var autoCleanup = false
    var undoAvailable = true
    /// Who made this edit, in a few plain words ("ExampleModel 9B", "Basic fixes"). Shown quietly on the card.
    var model: String? = nil

    /// Wispr's rule (main process, AutoCleanupV0): medium or high cleanup, more than 30 words
    /// heard, more than 5 changed word runs, and only the first five times ever.
    static let autoCleanupShownKey = "flow.autoCleanupDiffShownCount"
    static func autoCleanupNudge(raw: String, final: String, level: String,
                                 defaults: UserDefaults = .standard) -> PolishDiff? {
        guard level == "medium" || level == "high" else { return nil }
        let words = raw.split(whereSeparator: { $0.isWhitespace }).count
        guard words > 30 else { return nil }
        let changed = pieces(from: raw, to: final).filter { $0.kind != .same }.count
        guard changed > 5 else { return nil }
        guard defaults.integer(forKey: autoCleanupShownKey) < 5 else { return nil }
        return PolishDiff(original: raw, polished: final, autoCleanup: true)
    }

    enum Kind: Equatable { case same, removed, added }
    struct Piece: Equatable {
        let text: String
        let kind: Kind
    }

    struct Comparison {
        let original: [Piece]
        let edited: [Piece]
        let removedWords: Int
        let addedWords: Int
        let layoutOnly: Bool
    }

    func canUndo(inDraftReview: Bool) -> Bool {
        undoAvailable && !autoCleanup && !inDraftReview
    }

    /// Word-level changes, in reading order: kept words, then removed and added runs where they differ.
    var pieces: [Piece] { Self.pieces(from: original, to: polished) }

    /// Keep each pane's spacing and paragraphs exactly. Diff the words without
    /// their trailing whitespace so a new paragraph doesn't look like a rewrite.
    var comparison: Comparison {
        let originalTokens = Self.tokens(original)
        let editedTokens = Self.tokens(polished)
        func word(_ token: String) -> String { String(token.prefix { !$0.isWhitespace }) }
        let originalWords = originalTokens.map(word)
        let editedWords = editedTokens.map(word)
        var removed = IndexSet(), added = IndexSet()
        for change in editedWords.difference(from: originalWords) {
            switch change {
            case .remove(let offset, let value, _) where !value.isEmpty: removed.insert(offset)
            case .insert(let offset, let value, _) where !value.isEmpty: added.insert(offset)
            default: break
            }
        }

        func runs(_ tokens: [String], words: [String], marked: IndexSet, kind: Kind) -> [Piece] {
            var pieces: [Piece] = []
            for (index, token) in tokens.enumerated() {
                if marked.contains(index) {
                    pieces.append(Piece(text: words[index], kind: kind))
                    let spacing = token.dropFirst(words[index].count)
                    if !spacing.isEmpty { pieces.append(Piece(text: String(spacing), kind: .same)) }
                } else {
                    pieces.append(Piece(text: token, kind: .same))
                }
            }
            return pieces
        }
        return Comparison(original: runs(originalTokens, words: originalWords, marked: removed, kind: .removed),
            edited: runs(editedTokens, words: editedWords, marked: added, kind: .added),
            removedWords: removed.count, addedWords: added.count,
            layoutOnly: original != polished && removed.isEmpty && added.isEmpty)
    }

    /// Splits text into words with their trailing spaces, so joining the pieces gives the text back.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSpace = false
        for character in text {
            let space = character.isWhitespace
            if !current.isEmpty && inSpace && !space {
                tokens.append(current); current = ""
            }
            current.append(character)
            inSpace = space
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func pieces(from original: String, to polished: String) -> [Piece] {
        let old = tokens(original), new = tokens(polished)
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Piece] = []
        func append(_ text: String, _ kind: Kind) {
            if let last = result.last, last.kind == kind {
                result[result.count - 1] = Piece(text: last.text + text, kind: kind)
            } else {
                result.append(Piece(text: text, kind: kind))
            }
        }
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) { append(old[i], .removed); i += 1; continue }
            if j < new.count, inserted.contains(j) { append(new[j], .added); j += 1; continue }
            if j < new.count { append(new[j], .same) }
            i += 1; j += 1
        }
        return result
    }
}

/// A review window for reading both versions without changing the source field.
@MainActor
enum PolishDiffWindow {
    private static var window: NSPanel?

    static func show(_ diff: PolishDiff) {
        present(diff, reviewDraft: false)
    }

    static func showDraft(_ diff: PolishDiff) {
        present(diff, reviewDraft: true)
    }

    private static func present(_ diff: PolishDiff, reviewDraft: Bool) {
        window?.close()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame
        let width = min(540, (visible?.width ?? 572) - 32)
        let height = min(reviewDraft ? 380 : 300, (visible?.height ?? 332) - 32)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = reviewDraft ? "Review draft" : "Changes"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentMinSize = NSSize(width: 380, height: 230)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: PolishDiffView(diff: diff, reviewDraft: reviewDraft) { [weak panel] in
            panel?.close()
        }.environment(\.pillSkin, .standard))
        if let visible {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        window = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }
}

/// Words and sizes of the Changes view, shared by the inline card and the window.
enum PolishDiffText {
    /// "1 fix" or "N fixes": one fix per run of changed words.
    static func fixesLabel(_ diff: PolishDiff) -> String {
        let n = diff.fixCount
        return n == 1 ? "1 fix" : "\(n) fixes"
    }

    /// Removed words at 38% white with a strikethrough; added words white semibold, underlined at 55%.
    /// Kept words stay at 86% white. No colour for the changes.
    static func styled(_ pieces: [PolishDiff.Piece], skin: PillSkin) -> AttributedString {
        var text = AttributedString()
        for piece in pieces {
            var part = AttributedString(piece.text)
            switch piece.kind {
            case .same:
                part.foregroundColor = Color.white.opacity(0.86)
            case .removed:
                part.foregroundColor = Color.white.opacity(0.38)
                part.strikethroughStyle = .single
            case .added:
                part.foregroundColor = Color.white
                part.font = PillCardType.font(skin, 13, .semibold)
                part.underlineStyle = .single
                part.appKit.underlineColor = NSColor(white: 1, alpha: 0.55)
            }
            text.append(part)
        }
        return text
    }

    /// The text's height in lines, at most `PillCardStyle.changesMaxLines`; longer text scrolls.
    static func bodyHeight(_ diff: PolishDiff, skin: PillSkin) -> CGFloat {
        let text = diff.pieces.map(\.text).joined()
        let lines = PillCardText.lines(text, PillCardType.nsFont(skin, 13, .regular),
                                       width: PillCardStyle.changesWidth, maximum: PillCardStyle.changesMaxLines)
        return CGFloat(max(1, lines)) * PillCardStyle.changesLine
    }

    /// The inline Changes card: 340 of content plus the card padding.
    static func cardSize(_ diff: PolishDiff, skin: PillSkin) -> CGSize {
        let header = PillCardStyle.chipHeight
        let height = PillCardStyle.padding * 2 + header + 8 + bodyHeight(diff, skin: skin)
        return CGSize(width: PillCardStyle.changesWidth + PillCardStyle.padding * 2, height: ceil(height))
    }
}

/// The short name of whatever edited some text, for the pill card and toasts (25 Nov 2026).
enum ModelLabel {
    /// From an engine label ("local:bonsai-9b", "local:t5-v3c240", "rules:…") or a weights file name.
    static func short(_ engine: String?) -> String? {
        guard var name = engine, !name.isEmpty else { return nil }
        if name.hasPrefix("rules") { return "Basic rules" }
        if name.hasPrefix("cloud") { return "Cloud" }
        if name.hasPrefix("local:") { name = String(name.dropFirst(6)) }
        let lower = name.lowercased()
        if lower.hasPrefix("t4") || lower.hasPrefix("t5") || lower.hasPrefix("dose1") || lower.hasPrefix("whispernow") {
            return "DOSE1"
        }
        if lower.hasPrefix("examplemodel") { return "ExampleModel 9B" }
        if lower.hasPrefix("typing1") { return "Your typing model" }
        if lower.hasPrefix("qwen3.5-9b") { return "Qwen 9B" }
        if lower == "s1-mini" { return "S1-mini" }
        if lower == "qwen3" { return "Qwen3" }
        return GeneralCleanupModel.entry(id: name)?.name ?? name
    }

    /// Opt+1: the typing-repair model when it answered, else the rules that stood in for it.
    static func optOne(route: String?, modelFile: URL?) -> String? {
        switch route {
        case "model": return short(modelFile?.lastPathComponent)
        case "rules:model-timeout", "rules:model-cold": return "Basic fixes"
        default: return nil
        }
    }
}

extension PolishDiff {
    /// Runs of changed words (a removal and the addition that replaces it count once).
    var fixCount: Int {
        var count = 0
        var inChange = false
        for piece in pieces {
            if piece.kind == .same {
                inChange = false
            } else if !inChange {
                count += 1
                inChange = true
            }
        }
        return count
    }
}

/// The Changes window: the same card as the pill, for a diff too long to show inline.
/// Three chips as on the card (Undo when the polish can be undone, Copy, Done), no mode tabs.
struct PolishDiffView: View {
    private let diff: PolishDiff
    private let reviewDraft: Bool
    private let close: () -> Void
    private let pieces: [PolishDiff.Piece]
    private let layoutOnly: Bool
    @Environment(\.pillSkin) private var skin
    @State private var copied = false

    init(diff: PolishDiff, reviewDraft: Bool = false, close: @escaping () -> Void = {}) {
        self.diff = diff
        self.reviewDraft = reviewDraft
        self.close = close
        pieces = diff.pieces
        layoutOnly = diff.comparison.layoutOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(reviewDraft ? "Review draft" : "Polished").font(PillCardType.title(skin))
                    .foregroundStyle(skin.palette.ink)
                if !reviewDraft {
                    Text(PolishDiffText.fixesLabel(diff)).font(PillCardType.meta(skin))
                        .foregroundStyle(skin.palette.ink.opacity(0.5))
                }
                Spacer(minLength: 8)
                if diff.canUndo(inDraftReview: reviewDraft) {
                    PillChip(title: "Undo") { requestUndo(); return true }
                }
                PillChip(title: copied ? "Copied" : "Copy") { copyText() }
                PillChip(title: "Done", primary: true) { close(); return true }
            }
            ScrollView {
                Text(PolishDiffText.styled(pieces, skin: skin))
                    .lineSpacing(PillCardType.leading(PillCardType.nsFont(skin, 13, .regular), line: PillCardStyle.changesLine))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            if layoutOnly {
                Text("Layout only").font(PillCardType.meta(skin)).foregroundStyle(skin.palette.ink.opacity(0.5))
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 16).padding(.top, 30)
        .frame(minWidth: 380, minHeight: 230)
        .background(Color(white: 0.092))
        .onExitCommand(perform: close)
    }

    private func copyText() -> Bool {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(diff.polished, forType: .string)
        return copied
    }

    private func requestUndo() {
        close()
        NotificationCenter.default.post(name: .flowUndoLastPolish, object: diff.id)
    }
}
