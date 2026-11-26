import Foundation
import XCTest
@testable import Voice

final class PromptTermsTests: XCTestCase {
    func testPreferredSpellingWinsCaseInsensitiveDuplicatesAcrossGroups() {
        let result = PromptTerms.orderedUnique(["VioletOS", "cuprum"],
                                               ["violetos", "Cuprum", "Lantern"],
                                               ["LANTERN", "Zinc"])
        XCTAssertEqual(result, ["VioletOS", "cuprum", "Lantern", "Zinc"])
    }

    func testTruncatedPromptPrefixRetainsInputPriority() {
        let preferred = ["Zeta Project", "Copper Team", "Violet Engine"]
        let other = ["Alpha", "Beta", "zeta project", "Gamma"]
        let result = PromptTerms.orderedUnique(preferred, other)
        XCTAssertEqual(Array(result.prefix(3)), preferred)
        XCTAssertEqual(result, preferred + ["Alpha", "Beta", "Gamma"])
    }

    func testASRSuspectsKeepTheirPositionBeforeFormatterHints() {
        let asr = ["violet", "copper", "VIOLET", "lantern", "zinc", "cobalt", "silver", "tin", "lead"]
        let formatter = ["Lantern", "bronze", "COPPER", "nickel"]
        let result = PromptTerms.orderedUnique(asr, formatter)
        XCTAssertEqual(Array(result.prefix(8)), ["violet", "copper", "lantern", "zinc", "cobalt", "silver", "tin", "lead"])
        XCTAssertEqual(Array(result.suffix(2)), ["bronze", "nickel"])
    }

    func testBlankTermsDoNotConsumePromptSlots() {
        XCTAssertEqual(PromptTerms.orderedUnique(["", " \t\r\n", "  VioletOS\t", "violetos ", "\nCopper\n"]),
                       ["VioletOS", "Copper"])
        XCTAssertEqual(PromptTerms.orderedUnique(), [])
        XCTAssertEqual(PromptTerms.orderedUnique([], []), [])
    }

    func testCanonicalUnicodeDuplicatesPreserveTheFirstExactSpelling() {
        let decomposed = "cafe\u{301}"
        let result = PromptTerms.orderedUnique([decomposed], ["CAFÉ", "cafe"])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Array(result[0].utf8), Array(decomposed.utf8))
        XCTAssertEqual(result[1], "cafe", "Accented and unaccented names stay distinct")
    }

    func testDistinctIdentifiersAndInternalSpacingAreNotFuzzilyMerged() {
        XCTAssertEqual(PromptTerms.orderedUnique(["foo-bar", "foo bar", "foobar", "foo  bar", "foo_bar"], ["FOO-BAR"]),
                       ["foo-bar", "foo bar", "foobar", "foo  bar", "foo_bar"])
    }

    func testRankingEvaluatesEachTermOnceAndMatchesPreviousComparator() {
        let terms = (0..<64).map { "term-\($0)" }
        let scores = Dictionary(uniqueKeysWithValues: terms.enumerated().map { ($0.element, ($0.offset * 17) % 5) })
        var oldCalls = 0
        func oldScore(_ term: String) -> Int { oldCalls += 1; return scores[term]! }
        let previous = terms.sorted { oldScore($0) > oldScore($1) }
        var evaluations: [String: Int] = [:]
        let ranked = PromptTerms.ranked(terms) { term in
            evaluations[term, default: 0] += 1
            return scores[term]!
        }
        XCTAssertEqual(ranked, previous)
        XCTAssertEqual(evaluations, Dictionary(uniqueKeysWithValues: terms.map { ($0, 1) }))
        XCTAssertGreaterThan(oldCalls, terms.count)
        print("Prompt ranking synthetic 64-term check: comparator=\(oldCalls) score evaluations, ranked=\(evaluations.count)")
    }

    func testRankingRetainsPreferredOrderWithinEqualScoresAtCutoff() {
        let terms = ["VioletOS", "Cuprum", "Lantern", "Zeta", "Alpha"]
        let scores = ["VioletOS": 2, "Cuprum": 4, "Lantern": 2, "Zeta": 4, "Alpha": 2]
        XCTAssertEqual(Array(PromptTerms.ranked(terms) { scores[$0]! }.prefix(3)), ["Cuprum", "Zeta", "VioletOS"])
        XCTAssertEqual(PromptTerms.ranked(terms) { _ in 0 }, terms)
    }

    func testRankingSkipsUnnecessaryScoringOfEmptyOrSingleTerm() {
        XCTAssertEqual(PromptTerms.ranked([]) { _ in XCTFail("empty vocabulary scored"); return 0 }, [])
        XCTAssertEqual(PromptTerms.ranked(["VioletOS"]) { _ in XCTFail("single term needs no ranking"); return 0 }, ["VioletOS"])
    }

    func testRankingCacheKeepsExactUnicodeSpellingsSeparate() throws {
        let composed = "café", decomposed = "cafe\u{301}"
        XCTAssertEqual(composed, decomposed, "Swift String equality is canonical, not byte identity")
        func formerKey(_ term: String) -> Int {
            var hasher = Hasher()
            hasher.combine([term, "Cuprum"])
            hasher.combine(["heard"])
            return hasher.finalize()
        }
        XCTAssertEqual(formerKey(composed), formerKey(decomposed),
                       "The former hash-only cache reused a different byte spelling for this real case")
        let first = PromptTerms.RankingCache.Key(vocabulary: [composed, "Cuprum"], suspects: ["heard"])
        let second = PromptTerms.RankingCache.Key(vocabulary: [decomposed, "Cuprum"], suspects: ["heard"])
        let cache = PromptTerms.RankingCache(capacity: 2)
        cache.write(first, value: [composed, "Cuprum"])
        XCTAssertNil(cache.read(second), "A canonical-equivalent spelling must not hit another byte sequence")
        cache.write(second, value: [decomposed, "Cuprum"])
        XCTAssertEqual(Array(try XCTUnwrap(cache.read(first)?.first).utf8), Array(composed.utf8))
        XCTAssertEqual(Array(try XCTUnwrap(cache.read(second)?.first).utf8), Array(decomposed.utf8))
        XCTAssertNotEqual(PromptTerms.RankingCache.Key(vocabulary: ["word"], suspects: [composed]),
                          PromptTerms.RankingCache.Key(vocabulary: ["word"], suspects: [decomposed]))
    }

    func testRankingCacheKeyPreservesArrayAndFieldBoundaries() {
        typealias Key = PromptTerms.RankingCache.Key
        XCTAssertNotEqual(Key(vocabulary: ["ab", "c"], suspects: ["heard"]),
                          Key(vocabulary: ["a", "bc"], suspects: ["heard"]))
        XCTAssertNotEqual(Key(vocabulary: ["a"], suspects: ["b", "c"]),
                          Key(vocabulary: ["a", "b"], suspects: ["c"]))
        XCTAssertNotEqual(Key(vocabulary: ["a", "b"], suspects: ["heard"]),
                          Key(vocabulary: ["b", "a"], suspects: ["heard"]))
    }

    func testRankingCacheKeepsBoundedFIFOWhenAnEntryIsUpdated() {
        let cache = PromptTerms.RankingCache(capacity: 2)
        let keys = ["violet", "copper", "lantern"].map { PromptTerms.RankingCache.Key(vocabulary: [$0], suspects: ["heard"]) }
        cache.write(keys[0], value: ["violet"])
        cache.write(keys[1], value: ["copper"])
        cache.write(keys[0], value: ["updated violet"])
        XCTAssertEqual(cache.read(keys[0]), ["updated violet"])
        cache.write(keys[2], value: ["lantern"])
        XCTAssertNil(cache.read(keys[0]), "Updating a key must not add another FIFO slot")
        XCTAssertEqual(cache.read(keys[1]), ["copper"])
        XCTAssertEqual(cache.read(keys[2]), ["lantern"])
    }

    func testConcurrentRankingCacheReadsAndWritesCannotCrossResults() {
        let cache = PromptTerms.RankingCache(capacity: 16)
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let term = "term-\(index % 8)"
            let key = PromptTerms.RankingCache.Key(vocabulary: [term], suspects: ["heard"])
            cache.write(key, value: [term])
            XCTAssertEqual(cache.read(key), [term])
        }
    }
}
