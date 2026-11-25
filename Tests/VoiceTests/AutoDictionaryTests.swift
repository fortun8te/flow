import Foundation
import XCTest
@testable import Voice

/// The learning dictionary (AutoDictionary): evidence, promotion, routing, undo, and the history seed.
@MainActor
final class AutoDictionaryTests: XCTestCase {
    private var dir: URL!
    private var settings: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autodict-\(UUID().uuidString)")
        suite = "autodict-tests-\(UUID().uuidString)"
        settings = UserDefaults(suiteName: suite)
        AutoDictionary.shared.removeAll()
    }

    override func tearDown() {
        AutoDictionary.shared.removeAll()
        try? FileManager.default.removeItem(at: dir)
        settings.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func judge() throws -> AutoDictionary.WordJudge {
        guard let judge = AutoDictionary.WordJudge.lexicon(wait: true) else {
            throw XCTSkip("words.txt is not in the test bundle")
        }
        return judge
    }

    /// What CorrectionLearner hands over: the pasted text, read back in the field, then edited.
    private func edit(field before: String, pasted: String, edited: String) -> (before: String, after: String)? {
        let range = (before as NSString).range(of: pasted, options: .backwards)
        return CorrectionLearner.editedSpan(baseline: before, pastedRange: range, current: edited)
    }

    // MARK: The whole loop

    func testDictationsEditsPromotionThenNextDictationComesOutRight() throws {
        let judge = try judge()
        let store = AutoDictionary.shared
        let start = Date()

        // Dictation 1: Flow writes "zorvex" for his product Zorvexa and he fixes it in the field.
        let field1 = "Notes: we shipped the zorvik beta today."
        let e1 = try XCTUnwrap(edit(field: field1, pasted: "we shipped the zorvik beta today.",
                                    edited: "Notes: we shipped the Zorvexa beta today."))
        let first = store.observe(before: e1.before, after: e1.after, source: .dictationEdit, now: start, judge: judge)
        // A clear product name he typed himself goes live on first sight.
        XCTAssertEqual(first.map(\.written), ["Zorvexa"])
        XCTAssertTrue(ProperNounVocabulary.customTerms().contains("Zorvexa"), "boosted and spelled his way")
        XCTAssertTrue(ASRVocabularyBoost.trustedTerms().contains("Zorvexa"), "the speech model boosts it")

        // A misheard phrase needs two sightings.
        XCTAssertTrue(store.observe(before: "ask qeen code to run it", after: "ask QeenCode to run it",
                                    source: .dictationEdit, now: start, judge: judge).isEmpty)
        XCTAssertEqual(store.entry(heard: "qeen code", written: "QeenCode")?.status, .pending)
        let again = store.observe(before: "then qeen code fixed the bug", after: "then QeenCode fixed the bug",
                                  source: .dictationEdit, now: start.addingTimeInterval(60), judge: judge)
        XCTAssertEqual(again.map(\.written), ["QeenCode"])
        let entry = try XCTUnwrap(store.entry(heard: "qeen code", written: "QeenCode"))
        XCTAssertEqual(entry.count, 2)
        XCTAssertEqual(entry.examples.count, 2, "every entry keeps its examples")
        XCTAssertEqual(entry.sources["dictation edit"], 2)

        // The next dictation comes out right, with no restart.
        let next = ProperNounVocabulary.applyPreferredSpelling("so the zorvik build and qeen code are ready",
                                                               terms: ProperNounVocabulary.preferredSpellingTerms())
        XCTAssertEqual(next, "so the Zorvexa build and QeenCode are ready")
    }

    func testMisspellingNeedsTwoSightingsAndReachesOptOne() throws {
        let judge = try judge()
        let store = AutoDictionary.shared
        XCTAssertNil(TypoRepair.personalDictionary["becuase"], "not a bundled pair")
        store.observe(before: "i did it becuase it broke", after: "i did it because it broke", source: .opt1Kept, judge: judge)
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("becuase"), "becuase", "one sighting is not enough")
        store.observe(before: "Becuase of that", after: "Because of that", source: .dictationEdit, judge: judge)
        XCTAssertEqual(store.entry(heard: "becuase", written: "because")?.status, .live)
        XCTAssertEqual(store.entry(heard: "becuase", written: "because")?.kind, .spelling)
        // Opt+1's deterministic repair and dictation both apply it.
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("Becuase it works, becuase"), "Because it works, because")
        XCTAssertEqual(TypoRepair.applyLearnedSpelling("why becuase"), "why because")
        // The user overlay file holds it; the bundled JSON is untouched.
        let overlay = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: store.overlayURL))
        XCTAssertEqual(overlay["becuase"], "because")
    }

    // MARK: Never learned

    func testCommonWordsAreNeverLearned() throws {
        let judge = try judge()
        let store = AutoDictionary(directory: dir, settings: settings)
        // The four words the old learner queued from a field that held earlier text.
        for _ in 0..<4 {
            store.observe(before: "Put the chalk beside the pale. at the start of the trail.",
                          after: "Put the chalk beside the pail. At the middle of the trail.", source: .dictationEdit, judge: judge)
            store.observe(before: "Wider, more depth, green paint.", after: "Wider, more depth, green stain.",
                          source: .dictationEdit, judge: judge)
            store.observe(before: "do it actually now", after: "do it ac now", source: .dictationEdit, judge: judge)
        }
        XCTAssertTrue(store.allEntries().isEmpty, "\(store.allEntries().map(\.key))")
        // A common word is not a name, even capitalised.
        XCTAssertFalse(AutoDictionary.isNameLike("Start", atSentenceStart: false, judge: judge))
        XCTAssertFalse(AutoDictionary.isNameLike("pale", atSentenceStart: false, judge: judge))
    }

    func testMeaningChangesAreNeverLearned() throws {
        let judge = try judge()
        let store = AutoDictionary(directory: dir, settings: settings)
        for _ in 0..<3 {
            store.observe(before: "send 40 frames", after: "send 1080 frames", source: .dictationEdit, judge: judge)
            store.observe(before: "it is Zorvexa ready", after: "it is not Zorvexa ready", source: .dictationEdit, judge: judge)
            store.observe(before: "call Mark at five", after: "call Marek at six", source: .dictationEdit, judge: judge)
        }
        XCTAssertNil(store.entry(heard: "40", written: "1080"))
        XCTAssertNil(store.entry(heard: "five", written: "six"))
        XCTAssertFalse(store.allEntries().contains { $0.written.lowercased() == "not" })
    }

    func testOldFalseCorrectionIsGone() {
        // He kept typing after a short paste: nothing inside the paste changed.
        let field = "The paddles go beside the ferry ramp. Shorter straps, fewer knots. If the latch makes noise!"
        XCTAssertNil(edit(field: field, pasted: "If the latch makes noise!", edited: field + " I don't know!"))
        // An edit in earlier text is not a correction of this paste.
        XCTAssertNil(edit(field: field, pasted: "If the latch makes noise!",
                          edited: field.replacingOccurrences(of: "Shorter", with: "Longer")))
        // A real fix inside the paste is found, widened to whole words.
        let found = edit(field: field, pasted: "If the latch makes noise!", edited: field.replacingOccurrences(of: "makes", with: "make"))
        XCTAssertEqual(found?.before.contains("makes"), true)
        XCTAssertEqual(found?.after.contains("make noise"), true)
    }

    func testRewriteGivesNothing() {
        XCTAssertTrue(AutoDictionary.substitutions(before: "please move the canoes closer to the western dock",
                                                   after: "bring those boats back to this landing").isEmpty)
    }

    // MARK: Undo and decay

    func testUndoRemovesTheEntry() throws {
        let judge = try judge()
        let store = AutoDictionary.shared
        let now = Date()
        store.observe(before: "it was becuase", after: "it was because", source: .dictationEdit, now: now, judge: judge)
        store.observe(before: "only becuase", after: "only because", source: .dictationEdit, now: now, judge: judge)
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("becuase"), "because")

        // He undoes an Opt+1 edit that made this fix.
        let events = store.observeUndo(original: "i left becuase", candidate: "I left because", now: now)
        XCTAssertEqual(events.map(\.change), [.removed])
        XCTAssertEqual(store.entry(heard: "becuase", written: "because")?.status, .removed)
        XCTAssertEqual(TypoRepair.applyPersonalDictionary("becuase"), "becuase", "no longer applied")
        // Seen again inside the cooldown: stays out.
        store.observe(before: "becuase x", after: "because x", source: .dictationEdit, now: now.addingTimeInterval(86_400), judge: judge)
        store.observe(before: "becuase y", after: "because y", source: .dictationEdit, now: now.addingTimeInterval(86_500), judge: judge)
        XCTAssertEqual(store.entry(heard: "becuase", written: "because")?.status, .removed)
    }

    func testEditingALearnedFixBackRemovesIt() throws {
        let judge = try judge()
        let store = AutoDictionary.shared
        store.observe(before: "ask Rowen about it", after: "ask Rowan about it", source: .dictationEdit, judge: judge)
        XCTAssertEqual(store.entry(heard: "Rowen", written: "Rowan")?.status, .live)
        XCTAssertEqual(ProperNounVocabulary.applyHeardNameFixes("ask Rowen now"), "ask Rowan now")
        let events = store.observe(before: "ask Rowan now", after: "ask Rowen now", source: .dictationEdit, judge: judge)
        XCTAssertEqual(events.map(\.change), [.removed])
        XCTAssertNil(store.entry(heard: "Rowan", written: "Rowen"), "the way back is not learned as a new fix")
        XCTAssertEqual(ProperNounVocabulary.applyHeardNameFixes("ask Rowen now"), "ask Rowen now")
    }

    func testOptOneKeepThenUndoTakesTheSightingBack() throws {
        let judge = try judge()
        let store = AutoDictionary(directory: dir, settings: settings)
        let op = UUID()
        store.observe(before: "wrote it wierdly", after: "wrote it weirdly", source: .opt1Kept, operation: op, judge: judge)
        XCTAssertEqual(store.entry(heard: "wierdly", written: "weirdly")?.count, 1)
        store.observeUndo(original: "wrote it wierdly", candidate: "wrote it weirdly", operation: op)
        XCTAssertNil(store.entry(heard: "wierdly", written: "weirdly"))
    }

    func testOrdinaryHeardWordOnlyBoostsTheName() throws {
        let judge = try judge()
        let store = AutoDictionary(directory: dir, settings: settings)
        store.observe(before: "open it in trigger first", after: "open it in Illustrator first", source: .dictationEdit, judge: judge)
        let e = try XCTUnwrap(store.entry(heard: "trigger", written: "Illustrator"))
        XCTAssertEqual(e.status, .live)
        XCTAssertFalse(e.replaces, "\"trigger\" is an everyday word: never replaced in text")
        XCTAssertTrue(store.liveNames().contains("Illustrator"))
        XCTAssertTrue(store.liveReplacements().isEmpty)
    }

    func testGrowthIsCappedAndPendingDecays() throws {
        let judge = try judge()
        let store = AutoDictionary(directory: dir, settings: settings)
        let old = Date(timeIntervalSinceNow: -90 * 86_400)
        store.observe(before: "wrote wierdly", after: "wrote weirdly", source: .opt1Kept, now: old, judge: judge)
        XCTAssertNotNil(store.entry(heard: "wierdly", written: "weirdly"))
        store.observe(before: "it is becuase", after: "it is because", source: .opt1Kept, judge: judge)
        XCTAssertNil(store.entry(heard: "wierdly", written: "weirdly"), "a pending entry decays after 60 days")
        XCTAssertLessThanOrEqual(AutoDictionary.Rules.maxLive, 300)
    }

    func testReviewListIsInFlowSettings() throws {
        let judge = try judge()
        let store = AutoDictionary(directory: dir, settings: settings)
        store.observe(before: "ask Rowen", after: "ask Rowan", source: .dictationEdit, judge: judge)
        let rows = try XCTUnwrap(settings.array(forKey: AutoDictionary.settingsKey) as? [[String: Any]])
        XCTAssertEqual(rows.first?["written"] as? String, "Rowan")
        XCTAssertEqual(rows.first?["status"] as? String, "live")
        XCTAssertEqual(rows.first?["count"] as? Int, 1)
        // The plain store on disk keeps examples and dates.
        let text = try String(contentsOf: store.storeURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"examples\"") && text.contains("ask Rowen"))
    }

    func testSoundAlikeCorrectionIsLearnedAsSoundAlike() throws {
        let judge = try judge()
        let store = AutoDictionary(directory: dir, settings: settings)
        store.observe(before: "the whether is nice", after: "the weather is nice", source: .dictationEdit, judge: judge)
        store.observe(before: "bad whether today", after: "bad weather today", source: .dictationEdit, judge: judge)
        let e = try XCTUnwrap(store.entry(heard: "whether", written: "weather"))
        XCTAssertEqual(e.kind, .soundAlike)
        XCTAssertEqual(e.status, .live)
        XCTAssertTrue(store.liveSoundAlikes().contains(AutoDictionary.key("whether", "weather")))
        XCTAssertTrue(store.liveReplacements().isEmpty, "never a blanket replacement")
    }

    // MARK: History seed (offline, opt-in)

    /// Seeds a store from a local dictation history. Runs only with AUTODICT_SEED_DIR set (the target
    /// folder); prints what was added. Read only on the sources.
    func testSeedFromHistory() throws {
        guard let target = ProcessInfo.processInfo.environment["AUTODICT_SEED_DIR"] else {
            throw XCTSkip("Set AUTODICT_SEED_DIR to seed from history.")
        }
        let judge = try judge()
        let store = AutoDictionary(directory: URL(fileURLWithPath: target, isDirectory: true), settings: nil)
        let report = AutoDictionarySeed.run(into: store, judge: judge)
        print("[AUTODICT-SEED] wispr edits \(report.wisprEdits), wispr dictionary \(report.wisprDictionaryRows), "
              + "flow edits \(report.flowEdits), opt1 kept \(report.opt1Kept), promoted \(report.promoted.count)")
        for e in store.allEntries() where e.status == .live {
            print("[AUTODICT-SEED] live \(e.kind.rawValue): \(e.heard) -> \(e.written) x\(e.count) replaces=\(e.replaces) [\(e.sources.keys.sorted().joined(separator: ", "))]")
        }
        let pending = store.allEntries().filter { $0.status == .pending }
        print("[AUTODICT-SEED] pending \(pending.count): " + pending.prefix(60).map { "\($0.heard)->\($0.written)" }.joined(separator: "; "))
    }
}

/// whether/weather and friends, read in context by tinynext (SoundAlikeCheck).
final class SoundAlikeCheckTests: XCTestCase {
    private func ready() throws {
        guard TinyNextScorer.shared.ready(wait: true) != nil else { throw XCTSkip("tinynext is not in the test bundle") }
    }

    func testWhetherStaysWhenRight() throws {
        try ready()
        XCTAssertEqual(SoundAlikeCheck.check("I don't know whether it works", learned: [], wait: true).text,
                       "I don't know whether it works")
    }

    func testWeatherIsFixedInContext() throws {
        try ready()
        XCTAssertEqual(SoundAlikeCheck.check("the whether is nice", learned: [], wait: true).text, "the weather is nice")
    }

    func testTwoIsNeverTouched() throws {
        try ready()
        XCTAssertEqual(SoundAlikeCheck.check("I want two of them", learned: [], wait: true).text, "I want two of them")
    }
}
