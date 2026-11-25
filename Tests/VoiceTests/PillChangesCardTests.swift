import Testing
import CoreGraphics
import Foundation
@testable import Voice

/// The Changes card: the pill grows into it, it hugs its text, and its marks match the edit.
@Suite("Changes card", .serialized) @MainActor
struct PillChangesCardTests {
    private let real = PolishDiff(
        original: "ok well finalise everything an dmake sure its installed anp erpoerly optimzied etc etc etc and make sure thatwe're not loading like thousand deicinomodels acorss all apps at ondce or whatever",
        polished: "Ok well finalise everything and make sure it's installed and properly optimized etc etc etc and make sure that we're not loading like thousand decision models across all apps at once or whatever")

    private func look(_ diff: PolishDiff?, dock: PillDockEdge = .bottom, original: Bool = false,
                      skin: PillSkin = .standard) -> PillLook {
        var input = PillLookInput()
        input.phase = .polishDone
        input.dock = dock
        input.changes = diff
        input.changesOriginal = original
        return PillLookBuilder.look(input, skin: skin)
    }

    @Test("See changes turns the Done pill into a card of the same body, rounded like every card")
    func cardIsALook() {
        #expect(look(nil).face == .polished(autoCleanup: false))
        let card = look(real)
        #expect(card.face == .changes(real, original: false))
        #expect(card.face.isCard)
        #expect(card.radius == PillSkin.standard.surface.cardCornerRadius)
        #expect(look(real, original: true).face == .changes(real, original: true))
        // A new dictation takes the pill back at once.
        var input = PillLookInput()
        input.phase = .recording
        input.changes = real
        #expect(PillLookBuilder.look(input, skin: .standard).face == .listening)
    }

    @Test("The polished text is shown; changed words carry what they were")
    func wordsMarkTheEdit() {
        let words = PillChangesText.words(real)
        #expect(words.map(\.text).joined(separator: " ") == real.polished)
        let changed = Dictionary(grouping: words.filter { $0.run != nil }, by: { $0.run! })
            .mapValues { ($0.map(\.text).joined(separator: " "), $0[0].was ?? "") }
        let pairs = Set(changed.values.map { "\($0.0)|\($0.1)" })
        #expect(pairs.contains("Ok|ok"))
        #expect(pairs.contains("and make|an dmake"))
        #expect(pairs.contains("it's|its"))
        #expect(pairs.contains("and properly optimized|anp erpoerly optimzied"))
        #expect(pairs.contains("decision models across|deicinomodels acorss"))
        #expect(PillChangesText.fixesLabel(real) == "7 fixes")
        // Kept words stay plain.
        #expect(words.first { $0.text == "finalise" }?.run == nil)
    }

    @Test("The original side shows the old words, each knowing what replaced it")
    func originalSide() {
        let words = PillChangesText.words(real, original: true)
        #expect(words.map(\.text).joined(separator: " ") == real.original)
        #expect(words.first { $0.text == "erpoerly" }?.was == "and properly optimized")
    }

    @Test("Dropped words mark the word beside them; spacing alone is no fix")
    func deletionsAndSpacing() {
        let dropped = PillChangesText.words(PolishDiff(original: "I I think so", polished: "I think so"))
        #expect(dropped.map(\.text) == ["I", "think", "so"])
        let marked = dropped.filter { $0.run != nil }
        #expect(marked.count == 1)
        #expect(["I I", "I think"].contains(marked.first?.was ?? ""))
        let tail = PillChangesText.words(PolishDiff(original: "send it now um", polished: "send it now"))
        #expect(tail.last?.was == "now um")
        let spacing = PolishDiff(original: "Send the draft.  Send the link.", polished: "Send the draft.\n\nSend the link.")
        #expect(PillChangesText.fixes(PillChangesText.words(spacing)) == 0)
        #expect(PillChangesText.fixesLabel(spacing) == "Spacing only")
        #expect(PillChangesText.words(spacing)[2].breaks == 2)
    }

    @Test("The card hugs its text: narrow for a short edit, at most 316 wide, six lines, then it scrolls")
    func sizeHugsText() {
        let s = PillChangesStyle.self
        let short = look(PolishDiff(original: "ok", polished: "OK.")).size
        #expect(short.width == s.minWidth)
        let oneLine = s.topPadding + s.headerHeight + s.headerGap + s.line + s.bottomPadding
        #expect(short.height == ceil(oneLine))
        let realSize = look(real).size
        #expect(realSize.width <= s.maxWidth && realSize.width > s.minWidth)
        let longText = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 40)
        let long = look(PolishDiff(original: longText, polished: longText + "again")).size
        let sixLines = s.topPadding + s.headerHeight + s.headerGap + CGFloat(s.maxLines) * s.line + s.bottomPadding
        #expect(long.height == ceil(sixLines))
        #expect(long.width <= s.maxWidth)
        for skin in PillSkin.all {
            #expect(look(real, skin: skin).size.width <= s.maxWidth)
        }
    }

    @Test("No word ever runs past the text width, on any dock")
    func textNeverSpills() {
        let url = PolishDiff(original: "see https://example.test/a/very/long/path/that/does/not/fit/on/one/line/at/all/ok",
                             polished: "See https://example.test/a/very/long/path/that/does/not/fit/on/one/line/at/all/ok.")
        for diff in [real, url] {
            for dock in PillDockEdge.allCases {
                let size = look(diff, dock: dock).size
                let width = size.width - PillChangesStyle.padding * 2
                let flow = PillChangesText.flow(PillChangesText.words(diff), font: PillChangesText.font(.standard), width: width)
                for (origin, w) in zip(flow.origins, flow.widths) {
                    #expect(origin.x + w <= width + 0.01, "\(dock): word at \(origin.x) + \(w) > \(width)")
                }
            }
        }
    }

    @Test("Wrapping is the same at the card's width as at the widest width")
    func shrinkKeepsLines() {
        let font = PillChangesText.font(.standard)
        let words = PillChangesText.words(real)
        let wide = PillChangesText.flow(words, font: font, width: PillChangesStyle.maxWidth - PillChangesStyle.padding * 2)
        let card = look(real).size.width - PillChangesStyle.padding * 2
        #expect(PillChangesText.flow(words, font: font, width: card).lines == wide.lines)
    }
}
