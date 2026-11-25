import Testing
import Foundation
@testable import Voice

@Suite struct PolishDiffTests {
    @Test func tokensRoundTrip() {
        let text = "Hello  there, world.\nNew line"
        #expect(PolishDiff.tokens(text).joined() == text)
    }

    @Test func piecesRebuildBothTexts() {
        let a = "i think we should of left earlier , the traffic was bad"
        let b = "I think we should have left earlier. The traffic was bad."
        let pieces = PolishDiff.pieces(from: a, to: b)
        #expect(pieces.filter { $0.kind != .added }.map(\.text).joined() == a)
        #expect(pieces.filter { $0.kind != .removed }.map(\.text).joined() == b)
        #expect(pieces.contains { $0.kind == .removed && $0.text.contains("of") })
        #expect(pieces.contains { $0.kind == .added && $0.text.contains("have") })
    }

    @Test func identicalTextIsOnePiece() {
        #expect(PolishDiff.pieces(from: "Same text", to: "Same text") == [PolishDiff.Piece(text: "Same text", kind: .same)])
    }

    @Test func comparisonKeepsLayoutWithoutMarkingWords() {
        let original = "  Send the draft. Send the link.\r\n"
        let edited = "Send the draft.\n\nSend the link."
        let review = PolishDiff(original: original, polished: edited).comparison
        #expect(review.layoutOnly)
        #expect(review.removedWords == 0)
        #expect(review.addedWords == 0)
        #expect(review.original.map(\.text).joined().utf8.elementsEqual(original.utf8))
        #expect(review.edited.map(\.text).joined().utf8.elementsEqual(edited.utf8))
    }

    @Test func comparisonShowsOnlyRealWordChangesInBothVersions() {
        let original = "SN-20 belongs to Béta team.\n\nSend draft to https://example.test/view?q=21"
        let edited = "SN-20 belongs to Béta team.\n\nSend the draft to https://example.test/view?q=21"
        let review = PolishDiff(original: original, polished: edited).comparison
        #expect(!review.layoutOnly)
        #expect(review.removedWords == 0)
        #expect(review.addedWords == 1)
        #expect(review.edited.filter { $0.kind == .added }.map(\.text) == ["the"])
        #expect(review.original.map(\.text).joined() == original)
        #expect(review.edited.map(\.text).joined() == edited)
    }

    @Test func onlyAnAppliedSelectionEditCanOfferUndo() {
        let selection = PolishDiff(original: "before", polished: "after")
        let dictation = PolishDiff(original: "before", polished: "after", autoCleanup: true)
        #expect(selection.canUndo(inDraftReview: false))
        #expect(!selection.canUndo(inDraftReview: true))
        #expect(!dictation.canUndo(inDraftReview: false))
        let unverified = PolishDiff(original: "Old.", polished: "New.", undoAvailable: false)
        #expect(!unverified.canUndo(inDraftReview: false))
    }

    @Test func autoCleanupNudgeFollowsWisprRules() {
        let defaults = UserDefaults(suiteName: "flow.test.cleanup." + UUID().uuidString)!
        let raw = (0..<40).map { "word\($0)" }.joined(separator: " ")
        var words = raw.split(separator: " ").map(String.init)
        for i in stride(from: 0, to: 40, by: 6) { words[i] = "changed\(i)" }
        let final = words.joined(separator: " ")
        #expect(PolishDiff.autoCleanupNudge(raw: raw, final: final, level: "light", defaults: defaults) == nil)
        #expect(PolishDiff.autoCleanupNudge(raw: "too short", final: "Too short.", level: "high", defaults: defaults) == nil)
        #expect(PolishDiff.autoCleanupNudge(raw: raw, final: raw, level: "high", defaults: defaults) == nil)
        #expect(PolishDiff.autoCleanupNudge(raw: raw, final: final, level: "medium", defaults: defaults)?.autoCleanup == true)
        defaults.set(5, forKey: PolishDiff.autoCleanupShownKey)
        #expect(PolishDiff.autoCleanupNudge(raw: raw, final: final, level: "medium", defaults: defaults) == nil)
    }
}
