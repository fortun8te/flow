import Foundation
import XCTest
@testable import Voice

/// tinyfix real-word autocorrect (RealWordFixer), the referee that unifies Flow's small judges, and the
/// calibrated paste-safety score (21 Nov 2026).
final class RealWordFixerTests: XCTestCase {
    private var fixer: RealWordFixer { RealWordFixer.shared }

    private func requireModel() throws {
        guard fixer.model(wait: true) != nil else { throw XCTSkip("tinyfix weights are not in the test bundle") }
    }

    // MARK: Model

    func testWeightsLoadAndScoreLikeTheOriginal() throws {
        try requireModel()
        // Same inputs as the ONNX Runtime probe (stack/export_tinyfix.py, numpy port of the float model).
        let model = fixer.model(wait: true)!
        let left: [Int32] = [0, 0, 0, 0, 0, 3, 1507, 333, 3507, 16265, 12989, 18255, 10074, 12133, 19414, 14590]
        let right: [Int32] = [0, 0, 4279, 13048]
        let cands: [Int32] = [14673, 2346, 11833, 4950, 7335, 16128, 0, 0, 0]
        let expected: [Float] = [-2.63858, -2.15984, -2.58838, -0.53791, -1.92519, -3.71280, 0, 0, 0]
        for (a, b) in zip(model.scores(left: left, right: right, candidates: cands, batch: 1), expected) {
            XCTAssertEqual(a, b, accuracy: 0.01)
        }
        // Batched and split over cores: every row scores exactly as on its own.
        let rows = 130
        let batched = model.scores(left: Array(repeating: left, count: rows).flatMap { $0 },
                                   right: Array(repeating: right, count: rows).flatMap { $0 },
                                   candidates: Array(repeating: cands, count: rows).flatMap { $0 }, batch: rows)
        for r in [0, 64, 129] {
            for k in 0..<6 { XCTAssertEqual(batched[r * 9 + k], expected[k], accuracy: 0.01) }
        }
    }

    func testMissingWeightsLeaveTextUnchanged() {
        XCTAssertNil(TinyFixModel(directory: URL(fileURLWithPath: "/nonexistent")))
    }

    func testTypoCostMatchesTheEngine() {
        XCTAssertEqual(RealWordFixer.typoCost("form", "from"), 1.2, accuracy: 0.001)   // swap
        XCTAssertEqual(RealWordFixer.typoCost("teh", "the"), 1.2, accuracy: 0.001)
        XCTAssertTrue(RealWordFixer.differsOnlyInEnding("examples", "example"))
        XCTAssertFalse(RealWordFixer.differsOnlyInEnding("form", "from"))
    }

    func testOneEditNeighboursMatchTheBruteForceSearch() throws {
        try requireModel()
        let model = fixer.model(wait: true)!
        // "form": known mix-up "from" first, then one-edit words by id.
        let near = model.nearbyIDs(model.ids["form"]!).map { model.vocabulary[$0] }
        XCTAssertEqual(near.first, "from")
        XCTAssertTrue(near.contains("for") || near.contains("farm") || near.contains("forms"), "\(near)")
        XCTAssertLessThanOrEqual(near.count, TinyFixModel.maxNeighbors)
    }

    // MARK: Opt+1 (typed)

    func testTypedRealWordSlipsAreFixed() throws {
        try requireModel()
        XCTAssertEqual(fixer.fixTyped("I got a letter form the bank.", wait: true), "I got a letter from the bank.")
        XCTAssertEqual(fixer.fixTyped("I think your right about that.", wait: true), "I think you're right about that.")
        XCTAssertEqual(fixer.fixTyped("Their is a problem with the invoice.", wait: true), "There is a problem with the invoice.")
        XCTAssertEqual(fixer.fixTyped("I am to tired to cook tonight.", wait: true), "I am too tired to cook tonight.")
    }

    func testTypedModeLeavesOneEditNeighboursAlone() throws {
        try requireModel()
        // "modle"/"model" and "chat"/"that" are keyboard slips, not mix-ups: Opt+1 leaves them to the polish.
        XCTAssertEqual(fixer.fixTyped("we can see other mode project chats integrated", wait: true),
                       "we can see other mode project chats integrated")
        // The original engine (slips) would judge them.
        let slips = fixer.fix("I want to sea the report.", mode: .slips, wait: true)
        XCTAssertEqual(slips.text, "I want to see the report.")
    }

    func testCorrectWordsStay() throws {
        try requireModel()
        for text in ["Please fill out the form and return it.", "Their house is over there.",
                     "I want to go too.", "It's time to check its battery.", "Send it to me tomorrow.",
                     "Then we can compare it with the older one, which is faster than this."] {
            XCTAssertEqual(fixer.fixTyped(text, wait: true), text)
            XCTAssertEqual(fixer.fixDictation(text, wait: true), text)
        }
    }

    // MARK: Dictation

    func testDictationFixesSpellingHomophones() throws {
        try requireModel()
        XCTAssertEqual(fixer.fixDictation("I think their going to be late.", wait: true), "I think they're going to be late.")
        XCTAssertEqual(fixer.fixDictation("There is a lot that changed in the update, so make sure its all integrated.", wait: true),
                       "There is a lot that changed in the update, so make sure it's all integrated.")
        XCTAssertEqual(fixer.fixDictation("If it looks wrong, than we start again tomorrow.", wait: true),
                       "If it looks wrong, then we start again tomorrow.")
    }

    func testDictationKeepsSoundAlikeChoicesOfTheRecogniser() throws {
        try requireModel()
        // These acoustic pairs should keep the recognizer’s wording.
        for text in ["I don't know who to.", "We were varnishing the mast yesterday.",
                     "Go by the shed and buy a bag of seed.", "The fishing reel is made of brass.",
                     "Take this letter from the blue tray.", "Which shelf did it come from?"] {
            XCTAssertEqual(fixer.fixDictation(text, wait: true), text)
        }
    }

    func testProtectedSpansNamesDictionaryAndDutchStay() throws {
        try requireModel()
        XCTAssertEqual(fixer.fixTyped("Open https://their.com/form now", wait: true), "Open https://their.com/form now")
        XCTAssertEqual(fixer.fixTyped("Run `git log form the start` please", wait: true), "Run `git log form the start` please")
        XCTAssertEqual(fixer.fixTyped("I got a letter form the bank.", protectedTerms: ["Form"], wait: true),
                       "I got a letter form the bank.")
        XCTAssertEqual(fixer.fixTyped("Ik heb de form van de bank gekregen en dat is goed.", wait: true),
                       "Ik heb de form van de bank gekregen en dat is goed.")
        XCTAssertEqual(fixer.fixTyped("de spanning is op wit en rood zit", wait: true), "de spanning is op wit en rood zit")
        XCTAssertEqual(fixer.fixTyped("We met Their at the office.", wait: true), "We met Their at the office.")
        // An English sentence next to a Dutch one is still checked.
        XCTAssertEqual(fixer.fixDictation("Dat is goed voor nu. I think their going to be late.", wait: true),
                       "Dat is goed voor nu. I think they're going to be late.")
    }

    func testFixesCarryScoresForTheTrace() throws {
        try requireModel()
        let result = fixer.fix("I think their going to be late.", mode: .dictation, wait: true)
        XCTAssertEqual(result.fixes.count, 1)
        let fix = try XCTUnwrap(result.fixes.first)
        XCTAssertEqual(fix.original, "their"); XCTAssertEqual(fix.replacement, "they're")
        XCTAssertEqual(fix.location, 8)
        XCTAssertTrue(fix.knownMixup)
        XCTAssertGreaterThanOrEqual(fix.value, RealWordFixer.threshold)
        XCTAssertGreaterThan(fix.probability, 0.9)
    }

    func testLongDictationIsFast() throws {
        try requireModel()
        let sentence = "I think their going to send it to me tomorrow and then we can check if its right, because the "
            + "last version was slower than the one before it and your team said there was a problem with it. "
        let text = String(repeating: sentence, count: 70)   // about 2,600 words
        _ = fixer.fixDictation(text, wait: true)
        var times: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = fixer.fixDictation(text, wait: true)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        // Debug build (what Flow ships): ~25 ms here; a typical 50-word dictation is under 1 ms.
        XCTAssertLessThan(times.min()!, 120, "2,600-word dictation took \(times) ms")
        let short = "Can you send me their report by Friday so we can check its numbers?"
        let s = DispatchTime.now().uptimeNanoseconds
        _ = fixer.fixDictation(short, wait: true)
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6, 15)
    }

    // MARK: Referee

    func testRefereeRealWordsAndKillSwitch() throws {
        try requireModel()
        let r = DictationReferee.realWords("I think their going to be late.", mode: .dictation, protectedTerms: [], wait: true)
        XCTAssertEqual(r.text, "I think they're going to be late.")
        XCTAssertEqual(r.verdict.action, .fix)
        XCTAssertEqual(r.verdict.judge, .realWords)
        XCTAssertFalse(r.verdict.reason.contains("their"), "reasons never hold transcript words")
        let code = DictationReferee.realWords("their going", mode: .dictation, isCode: true, protectedTerms: [], wait: true)
        XCTAssertEqual(code.text, "their going"); XCTAssertEqual(code.verdict.action, .skip)

        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: RealWordFixer.enabledKey)
        defaults.set(false, forKey: RealWordFixer.enabledKey)
        defer { if let before { defaults.set(before, forKey: RealWordFixer.enabledKey) } else { defaults.removeObject(forKey: RealWordFixer.enabledKey) } }
        XCTAssertEqual(DictationReferee.dictationPass("I think their going to be late.", isCode: false), "I think their going to be late.")
        XCTAssertEqual(DictationReferee.realWords("I think their going.", mode: .dictation, wait: true).verdict.reason, "turned off")
    }

    func testTypedPrePassJudgesWithNonWordsRepairedButWritesOnlyRealWordFixes() throws {
        try requireModel()
        let source = "htey said their going to send it tomorow"
        let out = DictationReferee.typedPrePass(source) { text in
            text.replacingOccurrences(of: "htey", with: "they").replacingOccurrences(of: "tomorow", with: "tomorrow")
        }
        XCTAssertEqual(out, "htey said they're going to send it tomorow")
    }

    func testTransplantMapsFixesByOccurrence() {
        // Cleaned and original differ in length before the word, so the fix moves by occurrence, not offset.
        let cleaned = "they sayd so. their is their plan"
        let original = "htey sayd so, actually. their is their plan"
        let fix = RealWordFixer.Fix(original: "their", replacement: "There", margin: 6, value: 6, location: 14)
        XCTAssertEqual(DictationReferee.transplant([fix], from: cleaned, onto: original),
                       "htey sayd so, actually. There is their plan")
        // A word the cleaning changed the count of is not moved.
        let unsure = RealWordFixer.Fix(original: "their", replacement: "there", margin: 6, value: 6, location: 0)
        XCTAssertEqual(DictationReferee.transplant([unsure], from: "their their", onto: "thier their"), "thier their")
    }

    func testRefereeCleanupVerdicts() {
        let numbers = DictationReferee.cleanup(source: "send me the twenty five slides", output: "Send me the 35 slides.")
        XCTAssertEqual(numbers.guardVerdict.action, .fallback)
        XCTAssertEqual(numbers.guardVerdict.reason, "a number changed")
        XCTAssertNil(numbers.safety)
        let good = DictationReferee.cleanup(
            source: "Uh so like the the onboarding screen is um kind of slow and uh I think we should like cache the images",
            output: "The onboarding screen is slow, and I think we should cache the images.")
        XCTAssertEqual(good.guardVerdict.action, .keep)
        XCTAssertEqual(good.safety?.action, .keep)
        let cut = DictationReferee.cleanup(
            source: "Please call the dentist about the appointment tomorrow morning and confirm the insurance details.",
            output: "Please call tomorrow.")
        XCTAssertEqual(cut.safety?.action, .fallback)
        XCTAssertLessThanOrEqual(cut.safety?.probability ?? 1, 0.5)
    }

    func testRefereeLanguageAndFinalPass() {
        XCTAssertEqual(DictationReferee.language("Can you send me the report by Friday?").action, .keep)
        XCTAssertEqual(DictationReferee.language("Kun je mij het rapport voor vrijdag sturen?").reason, "not English")
        let mixed = DictationReferee.language("Ik ga morgen naar de winkel om boodschappen te doen. Then I will send the report to the whole team.")
        XCTAssertEqual(mixed.reason, "mixed languages")
        let pass = DictationReferee.finalPass("Uh, the slider is um too slow.")
        XCTAssertEqual(pass.text, "The slider is too slow.")
        XCTAssertEqual(pass.verdict.action, .fix)
        XCTAssertEqual(DictationReferee.finalPass("All good.").verdict.action, .keep)
    }

    // MARK: Paste safety

    func testPasteSafetyKeepsHardChecksAndScoresCoverage() {
        XCTAssertEqual(WhisperNowContentGuard.trip(source: "send me the twenty five slides", output: "Send me the 35 slides."), .number)
        XCTAssertEqual(WhisperNowContentGuard.trip(
            source: "Please call the dentist about the appointment tomorrow morning and confirm the insurance details.",
            output: "Please call tomorrow."), .coverage)
        XCTAssertNil(WhisperNowContentGuard.trip(
            source: "Uh so like the the onboarding screen is um kind of slow and uh I think we should like cache the images",
            output: "The onboarding screen is slow, and I think we should cache the images."))
        let f = PasteSafety.features(source: "one two three alpha beta gamma delta", output: "alpha beta gamma delta")
        XCTAssertEqual(f.vector.count, PasteSafety.featureNames.count)
        if !PasteSafety.weights.isEmpty { XCTAssertEqual(PasteSafety.weights.count, PasteSafety.featureNames.count) }
    }
}
