import Foundation
import XCTest
@testable import Voice

final class WordDecisionEvidenceTests: XCTestCase {
    private func observation(chosen: Int = 0) -> WordDecisionEvidence? {
        let source = "the blue kettle says their moon is square"
        return WordDecisionEvidence.make(stage: "tinyfix", mode: "dictation", source: source,
            range: (source as NSString).range(of: "their"), contextRange: NSRange(location: 9, length: 32),
            candidates: [.init(text: "their", rawScore: -4, adjustedScore: 0),
                         .init(text: "there", rawScore: -3, adjustedScore: 1, features: ["knownMixup": 1])],
            chosenIndex: chosen, margin: 1, threshold: 5, modelID: "tinyfix-fixture")
    }

    func testKeepObservationPreservesExactContextAndCandidateOrder() throws {
        let value = try XCTUnwrap(observation())
        XCTAssertEqual(value.original, "their")
        XCTAssertEqual(value.context, "kettle says their moon is square")
        XCTAssertEqual(value.sourceSpan.location, 21)
        XCTAssertEqual(value.contextSpan.location, 9)
        XCTAssertEqual(value.candidates.map(\.text), ["their", "there"])
        XCTAssertEqual(value.chosenIndex, 0)
        XCTAssertTrue(value.isValid)
        XCTAssertEqual(try JSONDecoder().decode(WordDecisionEvidence.self, from: JSONEncoder().encode(value)), value)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertNil(json["target"])
        XCTAssertNil(json["probability"])
    }

    func testChosenAlternativeIsAnObservationNotATarget() throws {
        let value = try XCTUnwrap(observation(chosen: 1))
        XCTAssertEqual(value.chosenIndex, 1)
        XCTAssertTrue(value.isValid)
    }

    func testUTF16OffsetsRemainCorrectAfterEmoji() throws {
        let source = "🫖 their moon is blue"
        let range = (source as NSString).range(of: "their")
        let value = try XCTUnwrap(WordDecisionEvidence.make(stage: "soundalike", mode: "dictation", source: source,
            range: range, contextRange: NSRange(location: 0, length: (source as NSString).length),
            candidates: [.init(text: "their", rawScore: -4), .init(text: "there", rawScore: -3)],
            chosenIndex: 0, margin: 1, threshold: 5.5, modelID: "tinynext-fixture"))
        XCTAssertEqual(value.sourceSpan.location, 3)
        XCTAssertEqual(value.original, "their")
    }

    func testCanonicalUnicodeEquivalenceCannotHideDifferentModelInput() throws {
        let original = "a\u{0301}\u{0323}"
        let reordered = "a\u{0323}\u{0301}"
        XCTAssertEqual(original, reordered, "Swift equality intentionally treats these as the same grapheme")
        let source = original + " glows above the cube"
        let range = NSRange(location: 0, length: original.utf16.count)
        let context = NSRange(location: 0, length: source.utf16.count)
        XCTAssertNil(WordDecisionEvidence.make(stage: "tinyfix", mode: "dictation", source: source,
            range: range, contextRange: context,
            candidates: [.init(text: reordered, rawScore: -4), .init(text: "other", rawScore: -3)],
            chosenIndex: 0, margin: 1, threshold: 5, modelID: "fixture"))
        var value = try XCTUnwrap(WordDecisionEvidence.make(stage: "tinyfix", mode: "dictation", source: source,
            range: range, contextRange: context,
            candidates: [.init(text: original, rawScore: -4), .init(text: reordered, rawScore: -3)],
            chosenIndex: 0, margin: 1, threshold: 5, modelID: "fixture"))
        XCTAssertTrue(value.isValid, "distinct UTF-8 candidates stay distinct for the tokenizer")
        value.context = reordered + " glows above the cube"
        XCTAssertFalse(value.isValid, "context matching must preserve exact UTF-16 units")
    }

    func testInvalidAndSplitSurrogateSourceRangesAreRejected() {
        let source = "🫖 their moon is blue"
        for range in [NSRange(location: NSNotFound, length: 2), NSRange(location: -1, length: 1),
                      NSRange(location: 1, length: 1), NSRange(location: 0, length: Int.max)] {
            XCTAssertNil(WordDecisionEvidence.make(stage: "tinyfix", mode: "dictation", source: source,
                range: range, contextRange: NSRange(location: 0, length: (source as NSString).length),
                candidates: [.init(text: "their", rawScore: -4), .init(text: "there", rawScore: -3)],
                chosenIndex: 0, margin: 1, threshold: 5, modelID: "fixture"))
        }
    }

    func testContextMustContainTheExactOriginalSpan() throws {
        var value = try XCTUnwrap(observation())
        value.context = value.context.replacingOccurrences(of: "their", with: "other")
        XCTAssertFalse(value.isValid)
        value = try XCTUnwrap(observation())
        value.sourceSpan.location = Int.max
        XCTAssertFalse(value.isValid)
        value = try XCTUnwrap(observation())
        value.contextSpan.location = value.sourceSpan.location + 1
        XCTAssertFalse(value.isValid)
    }

    func testMissingKeepDuplicateAndOutOfRangeChoicesAreRejected() throws {
        var value = try XCTUnwrap(observation())
        value.candidates.reverse()
        XCTAssertFalse(value.isValid)
        value = try XCTUnwrap(observation())
        value.candidates[1] = value.candidates[0]
        XCTAssertFalse(value.isValid)
        value = try XCTUnwrap(observation())
        value.candidates.removeLast()
        XCTAssertFalse(value.isValid)
        XCTAssertNil(observation(chosen: -1))
        XCTAssertNil(observation(chosen: 2))
    }

    func testNonFiniteScoresMarginsThresholdsAndFeaturesAreRejected() throws {
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            var value = try XCTUnwrap(observation())
            value.candidates[0].rawScore = invalid
            XCTAssertFalse(value.isValid)
            value = try XCTUnwrap(observation())
            value.candidates[1].adjustedScore = invalid
            XCTAssertFalse(value.isValid)
            value = try XCTUnwrap(observation())
            value.candidates[1].features["cost"] = invalid
            XCTAssertFalse(value.isValid)
            value = try XCTUnwrap(observation())
            value.margin = invalid
            XCTAssertFalse(value.isValid)
            value = try XCTUnwrap(observation())
            value.threshold = invalid
            XCTAssertFalse(value.isValid)
        }
    }

    func testBoundedContextCandidatesAndFeaturesPreventOversizedEvidence() throws {
        var value = try XCTUnwrap(observation())
        value.context = String(repeating: "x", count: WordDecisionEvidence.maxContextUTF16 + 1)
        value.contextSpan.length = value.context.utf16.count
        XCTAssertFalse(value.isValid)
        value = try XCTUnwrap(observation())
        value.candidates[1].text = String(repeating: "x", count: WordDecisionEvidence.maxCandidateUTF16 + 1)
        XCTAssertFalse(value.isValid)
        value = try XCTUnwrap(observation())
        value.candidates += (0..<WordDecisionEvidence.maxCandidates).map { .init(text: "candidate\($0)", rawScore: -5) }
        XCTAssertFalse(value.isValid)
        value = try XCTUnwrap(observation())
        value.candidates[1].features = Dictionary(uniqueKeysWithValues: (0...WordDecisionEvidence.maxFeatures).map { ("feature\($0)", 1) })
        XCTAssertFalse(value.isValid)
    }

    func testIncompleteMetadataAndBlankAlternativesAreRejected() throws {
        var value = try XCTUnwrap(observation())
        value.stage = ""
        XCTAssertFalse(value.isValid)
        value = try XCTUnwrap(observation())
        value.mode = "unknown"
        XCTAssertFalse(value.isValid)
        value = try XCTUnwrap(observation())
        value.modelID = " "
        XCTAssertFalse(value.isValid)
        value = try XCTUnwrap(observation())
        value.schemaVersion = 99
        XCTAssertFalse(value.isValid)
        value = try XCTUnwrap(observation())
        value.candidates[1].text = "\n"
        XCTAssertFalse(value.isValid)
    }
}
