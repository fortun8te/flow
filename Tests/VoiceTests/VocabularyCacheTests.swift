import Foundation
import XCTest
@testable import Voice

final class VocabularyCacheTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vocabulary-cache-\(UUID().uuidString)")
        suite = "vocabulary-cache-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var judge: AutoDictionary.WordJudge {
        AutoDictionary.WordJudge(count: { ["because", "weather"].contains($0) ? 6_000_000 : nil },
                                 isKnown: { ["because", "weather"].contains($0) })
    }

    private func store(_ name: String) -> AutoDictionary {
        AutoDictionary(directory: directory.appendingPathComponent(name), settings: nil)
    }

    func testEqualRevisionsFromDifferentDictionariesCannotShareNameRules() {
        let first = store("first"), second = store("second")
        first.observe(before: "open zetavo beside the blue toy", after: "open OrbitToy beside the blue toy",
                      source: .dictationEdit, evidenceID: "first", judge: judge)
        second.observe(before: "open zetavo beside the blue toy", after: "open MoonToy beside the blue toy",
                       source: .dictationEdit, evidenceID: "second", judge: judge)
        XCTAssertEqual(first.currentRevision, second.currentRevision)
        XCTAssertEqual(ProperNounVocabulary.heardNameRules(learned: first, defaults: defaults).apply(to: "zetavo"), "OrbitToy")
        XCTAssertEqual(ProperNounVocabulary.heardNameRules(learned: second, defaults: defaults).apply(to: "zetavo"), "MoonToy")
        XCTAssertEqual(ProperNounVocabulary.heardNameRules(learned: first, defaults: defaults).apply(to: "zetavo"), "OrbitToy")
    }

    func testEqualRevisionsFromDifferentDictionariesCannotShareSpellingMaps() {
        let first = store("first"), second = store("second")
        for index in 0..<2 {
            first.observe(before: "it spins becuase the moon is blue", after: "it spins because the moon is blue",
                          source: .dictationEdit, evidenceID: "first-\(index)", judge: judge)
            second.observe(before: "the wether makes the toy spin around", after: "the weather makes the toy spin around",
                           source: .dictationEdit, evidenceID: "second-\(index)", judge: judge)
        }
        XCTAssertEqual(first.currentRevision, second.currentRevision)
        let a = TypoRepair.currentPersonalDictionary(learned: first)
        XCTAssertEqual(a["becuase"], "because")
        XCTAssertNil(a["wether"])
        let b = TypoRepair.currentPersonalDictionary(learned: second)
        XCTAssertEqual(b["wether"], "weather")
        XCTAssertNil(b["becuase"])
        let again = TypoRepair.currentPersonalDictionary(learned: first)
        XCTAssertEqual(again["becuase"], "because")
        XCTAssertNil(again["wether"])
    }

    func testLearnedAmbiguityAlsoBlocksTheBuiltinAlias() {
        let learned = store("learned")
        for name in ["OrbitToy", "MoonToy"] {
            learned.observe(before: "open quen beside the blue toy", after: "open \(name) beside the blue toy",
                            source: .dictationEdit, evidenceID: "name-\(name)", judge: judge)
        }
        XCTAssertTrue(learned.liveSnapshot().conflictingAliases.contains("quen"))
        XCTAssertEqual(ProperNounVocabulary.heardNameRules(learned: learned, defaults: defaults).apply(to: "quen"), "quen")
        XCTAssertEqual(learned.liveNames(), ["MoonToy", "OrbitToy"])
    }

    func testChangedExclusionsInvalidateCachedBuiltinRulesImmediately() throws {
        let learned = store("learned")
        let original = ProperNounVocabulary.heardNameRules(learned: learned, defaults: defaults)
        let repeated = ProperNounVocabulary.heardNameRules(learned: learned, defaults: defaults)
        XCTAssertTrue(try XCTUnwrap(original.regex) === XCTUnwrap(repeated.regex))
        XCTAssertEqual(original.apply(to: "quen"), "Qwen")
        defaults.set([" QWEN "], forKey: ProperNounVocabulary.excludedTermsKey)
        let excluded = ProperNounVocabulary.heardNameRules(learned: learned, defaults: defaults)
        XCTAssertEqual(excluded.apply(to: "quen and clod code"), "quen and Claude Code")
    }

    func testManualCasingOverridesSeedsAndInvalidatesCachedVocabulary() {
        let learned = store("learned")
        defaults.set(["QWEN"], forKey: "userProperNouns")
        let first = ProperNounVocabulary.vocabularyView(defaults: defaults, learned: learned)
        XCTAssertEqual(first.all.filter { $0.lowercased() == "qwen" }, ["QWEN"])
        defaults.set(["qWen"], forKey: "userProperNouns")
        let changed = ProperNounVocabulary.vocabularyView(defaults: defaults, learned: learned)
        XCTAssertEqual(changed.all.filter { $0.lowercased() == "qwen" }, ["qWen"])
        defaults.set(["qwen"], forKey: ProperNounVocabulary.excludedTermsKey)
        XCTAssertFalse(ProperNounVocabulary.vocabularyView(defaults: defaults, learned: learned).all.contains { $0.lowercased() == "qwen" })
    }

    func testLatestOwnCasingWinsAcrossAliasesAndPassiveNames() {
        let learned = store("learned")
        let now = Date()
        learned.observe(before: "open zetavo beside the blue toy", after: "open OrbitToy beside the blue toy",
                        source: .dictationEdit, now: now, evidenceID: "older-case", judge: judge)
        learned.observe(before: "open movaro beside the blue toy", after: "open OrbitTOY beside the blue toy",
                        source: .dictationEdit, now: now.addingTimeInterval(1), evidenceID: "newer-case", judge: judge)
        for index in 0..<3 {
            learned.observeRecurringName("ORBITTOY", context: "the ORBITTOY floats beside moon \(index)",
                                         now: now.addingTimeInterval(10), evidenceID: "recurring-\(index)", judge: judge)
        }
        XCTAssertEqual(learned.liveNames(), ["OrbitTOY"])
        XCTAssertTrue(learned.liveReplacements().allSatisfy { $0.written == "OrbitTOY" })
        learned.remove(written: "OrbitTOY")
        XCTAssertTrue(learned.liveSnapshot().names.isEmpty)
        XCTAssertTrue(learned.liveSnapshot().replacements.isEmpty)
    }

    func testAbbreviationAndPreferredSpellingPassesPreserveFragileSpans() {
        let source = "use api beside `api` and https://example.com/api and /tmp/api"
        XCTAssertEqual(ProperNounVocabulary.applyCapsAbbreviations(source),
                       "use API beside `api` and https://example.com/api and /tmp/api")
        let phrase = "orbit  toy beside `orbit toy` and https://example.com/api"
        XCTAssertEqual(ProperNounVocabulary.applyPreferredSpelling(phrase, terms: ["Orbit Toy"]),
                       "Orbit Toy beside `orbit toy` and https://example.com/api")
        XCTAssertEqual(ProperNounVocabulary.applyPreferredSpelling(phrase, terms: ["ORBIT TOY"]),
                       "ORBIT TOY beside `orbit toy` and https://example.com/api")
    }

    func testRemovalUsesTheSameSpaceAndApostropheNormalization() {
        let learned = store("learned")
        for index in 0..<2 {
            learned.observePair(heard: "zetavo", written: "Zen’s  Box", source: .dictationEdit,
                                evidenceID: "phrase-\(index)", judge: judge)
        }
        XCTAssertEqual(learned.liveNames(), ["Zen’s  Box"])
        learned.remove(written: "  zen's box  ")
        XCTAssertTrue(learned.liveNames().isEmpty)
        XCTAssertEqual(learned.entry(heard: "zetavo", written: "Zen’s  Box")?.status, .removed)
    }
}
