import Foundation
import Testing
@testable import Voice

/// Content guard and fallback decisions.
@Suite("WhisperNow tuned: content guard and fallback")
struct WhisperNowTunedTests {
    typealias Guard = WhisperNowContentGuard

    // MARK: Invented examples

    @Test("Keeps a cleanup that only removes fillers and adds punctuation")
    func keepsPunctuationAndFillerCleanup() {
        #expect(Guard.strictTrip(source: "Also the brass hinge needs more oil I think or maybe a new pin I don't know try both.",
                           output: "Also, the brass hinge needs more oil, I think, or maybe a new pin. I don't know, try both.") == nil)
        #expect(Guard.strictTrip(source: "Make sure the crank or like the turning wheel clears the wooden support.",
                           output: "Make sure the crank or the turning wheel clears the wooden support.") == nil)
    }

    @Test("Trips when a content word is dropped without a reason")
    func tripsOnUnexplainedCut() {
        #expect(Guard.strictTrip(source: "Carry the wooden crate across the courtyard before lunch.",
                           output: "Carry the crate across the courtyard before lunch.") == .cut(["wooden"]))
        #expect(Guard.strictTrip(source: "A wooden wedge will let you lift the hatch.",
                           output: "A wedge will let you lift the hatch.") == .cut(["wooden"]))
    }

    @Test("Trips when a negation is lost")
    func tripsOnLostNegation() {
        let source = "The red crate isn't ready for the ferry."
        let output = "The red crate is ready for the ferry."
        #expect(Guard.trip(source: source, output: output) == .negation)
    }

    @Test("Trips when a number is invented or changed, not when spoken numbers become digits")
    func numbers() {
        #expect(Guard.strictTrip(source: "i need twenty five clay tiles before sunset not thirty",
                           output: "I need 25 clay tiles before sunset, not 30.") == nil)
        // Known guard.py false positive, kept for parity: a filler inside the replaced span ("like twenty five"
        // -> "25") is not explained, so this safe edit falls back.
        #expect(Guard.strictTrip(source: "i need like twenty five clay tiles before sunset not thirty",
                           output: "I need 25 clay tiles before sunset, not 30.") == .cut(["twenty", "five"]))
        #expect(Guard.strictTrip(source: "lets meet on thursday no actually wednesday at uh three thirty",
                           output: "Let's meet on Wednesday at 3:30.") == nil)
        #expect(Guard.strictTrip(source: "send me the twenty five slides", output: "Send me the 35 slides.") == .number)
        #expect(Guard.strictTrip(source: "send me the slides", output: "Send me the 5 slides.") == .number)
        #expect(Guard.inventedNumbers(source: "first the intro", output: "1. The intro") == [])
    }

    @Test("Self-corrections, restarts and spoken symbols are explainable edits")
    func explainableEdits() {
        #expect(Guard.strictTrip(source: "make sure the flag is dash dash verbose and the file is in slash users slash sample",
                           output: "Make sure the flag is --verbose and the file is in /users/sample.") == nil)
        #expect(Guard.strictTrip(source: "we should we should ship it", output: "We should ship it.") == nil)
        #expect(Guard.strictTrip(source: "send it to Anna, no wait, to Maria", output: "Send it to Maria.") == nil)
        #expect(Guard.strictTrip(source: "I'm gonna send it", output: "I'm going to send it.") == nil)
    }

    @Test("EMPTY is only accepted for hesitation sounds")
    func emptyReplies() {
        #expect(Guard.strictTrip(source: "um uh", output: "EMPTY") == .empty)
        #expect(Guard.isNoiseOnly("Er... mm... um..."))
        #expect(Guard.isNoiseOnly("um uh"))
        #expect(!Guard.isNoiseOnly("um send it"))
        #expect(!Guard.isNoiseOnly(""))
    }

    @Test("Hesitation stripping matches guard.py")
    func stripHesitations() {
        #expect(Guard.stripHesitations("um so I think, uh, we should go") == "So I think we should go")
        #expect(Guard.stripHesitations("Hmm. okay") == "Okay")
    }

    // MARK: Parity with the Python guard on every row of scripts/pc/dev/final

    struct ParityRow: Decodable {
        let set: String
        let input: String
        let output: String
        let trip: String?
        let cut: [String]
        let stripped: String
    }

    @Test("Same verdict as guard.py on 1,444 real dev rows")
    func pythonParity() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/whispernow-guard-parity.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Private fixture (real dictations); absent on machines without the dev data.
            return
        }
        let rows = try text.split(separator: "\n").map { try JSONDecoder().decode(ParityRow.self, from: Data($0.utf8)) }
        #expect(rows.count > 1_000)
        var mismatches: [String] = []
        for (index, row) in rows.enumerated() {
            let trip = Guard.strictTrip(source: row.input, output: row.output)
            let label = trip.map { $0.label }
            if label != row.trip { mismatches.append("\(index) \(row.set): swift=\(label ?? "keep") python=\(row.trip ?? "keep")") }
            if case .cut(let words) = trip, Array(words.prefix(12)) != row.cut {
                mismatches.append("\(index) \(row.set): cut words differ")
            }
            if Guard.stripHesitations(row.input) != row.stripped { mismatches.append("\(index) \(row.set): strip differs") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches: \(mismatches.prefix(10))")
    }

    // MARK: Decision rules

    @Test("Neither cleanup model can add a prohibition to an instruction")
    func rejectsIntroducedNegation() async {
        let source = "Please send the report tomorrow. Copy Lila."
        let reversed = "Please send the report tomorrow. Don't copy Lila."
        // The historical parity guard detects lost negations. This extra
        // delivery check catches the opposite failure on both candidates.
        #expect(Guard.trip(source: source, output: reversed) == nil)
        let result = await WhisperNowCleanupDecision.decide(source: source,
            reply: .success(.text(reversed))) { reversed }
        #expect(result.outcome == .stripped(reason: "negation-added"))
        #expect(result.text == source)
    }

    @Test("Equivalent negation and spoken self-correction still pass")
    func keepsEquivalentPolarityAndCorrection() async {
        let original = "Do not copy Lila. Send the brief Thursday, no actually Friday."
        let edited = "Do not copy Lila. Send the brief Friday."
        let result = await WhisperNowCleanupDecision.decide(source: original,
            reply: .success(.text(edited))) { nil }
        #expect(result.outcome == .model)
        #expect(result.text == edited)
        #expect(!MeaningIntegrity.introducesNegation(original: "Copy the file.",
                    candidate: "Copy the file. `no`"))
    }

    @Test("A passing reply is used; a trip falls back to S1-mini if S1 passes, else to stripped text")
    func decision() async {
        let source = "um leave the blue crate with Nora at the east gate"
        let s1Output = "Leave the blue crate with Nora at the east gate."
        let missingName = "Leave the blue crate at the east gate."
        let good = await WhisperNowCleanupDecision.decide(source: source,
            reply: .success(.text(s1Output))) { nil }
        #expect(good.outcome == .model)
        #expect(good.text == s1Output)

        let viaS1 = await WhisperNowCleanupDecision.decide(source: source,
            reply: .success(.text(missingName))) { s1Output }
        #expect(viaS1.outcome == .s1mini(reason: "name"))
        #expect(viaS1.text == s1Output)

        let stripped = await WhisperNowCleanupDecision.decide(source: source,
            reply: .success(.text(missingName))) { "Leave the blue crate." }
        #expect(stripped.outcome == .stripped(reason: "name"))
        #expect(stripped.text == "Leave the blue crate with Nora at the east gate")
    }

    @Test("Failures fall back without asking the model again; EMPTY for real words is not 'no speech'")
    func failuresAndEmpty() async {
        let failed = await WhisperNowCleanupDecision.decide(source: "send the report today",
            reply: .failure(.timeout)) { "Send the report today." }
        #expect(failed.outcome == .s1mini(reason: "failure:timeout"))

        let noSpeech = await WhisperNowCleanupDecision.decide(source: "Er... um... hmm.", reply: .success(.empty)) { nil }
        #expect(noSpeech.outcome == .noSpeech)
        #expect(noSpeech.text.isEmpty)

        let falseEmpty = await WhisperNowCleanupDecision.decide(source: "send the report today",
            reply: .success(.empty)) { nil }
        #expect(falseEmpty.outcome == .stripped(reason: "empty"))
        #expect(falseEmpty.text == "Send the report today")
    }

    @Test("Reply parsing: EMPTY, length stops and template leaks")
    func parseReply() throws {
        func reply(_ content: String, _ finish: String = "stop") -> Data {
            try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
        }
        #expect(try WhisperNowTunedPolisher.parseReply(reply("EMPTY")) == .empty)
        #expect(try WhisperNowTunedPolisher.parseReply(reply("  Okay, cool!\n")) == .text("Okay, cool!"))
        #expect(throws: WhisperNowTunedPolisher.Failure.tokenLimit) { try WhisperNowTunedPolisher.parseReply(reply("Okay", "length")) }
        #expect(throws: WhisperNowTunedPolisher.Failure.badReply) { try WhisperNowTunedPolisher.parseReply(reply("x<|im_end|>")) }
        #expect(throws: WhisperNowTunedPolisher.Failure.badReply) { try WhisperNowTunedPolisher.parseReply(Data("{}".utf8)) }
    }

    @Test("Serving contract: token budget and golden prompt")
    func servingContract() {
        #expect(WhisperNowTunedPolisher.tokenBudget(for: "okay cool") == 64)
        #expect(WhisperNowTunedPolisher.tokenBudget(for: Array(repeating: "word", count: 41).joined(separator: " ")) == 103)
        #expect(WhisperNowTunedPolisher.goldenPrompt.hasPrefix("<|startoftext|><|im_start|>user\n"))
        #expect(WhisperNowTunedPolisher.freeLocalPort() != nil)
    }

    @Test("Engine choice: S1-mini and Qwen3 stay selectable")
    @MainActor func engineChoice() {
        let key = "voice.cleanupModel"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set("s1-mini", forKey: key)
        #expect(Qwen3Polisher.effectiveAutomaticCleanupModel == "s1-mini")
        UserDefaults.standard.set("qwen3", forKey: key)
        #expect(Qwen3Polisher.effectiveAutomaticCleanupModel == "qwen3")
        UserDefaults.standard.set(WhisperNowTunedPolisher.settingValue, forKey: key)
        #expect(Qwen3Polisher.effectiveAutomaticCleanupModel
                == (WhisperNowTunedPolisher.isInstalled ? WhisperNowTunedPolisher.settingValue : "s1-mini"))
    }
    @Test("Dictation adapter: v3c ships, voice.cleanupAdapter = t4 rolls back")
    func dictationAdapterChoice() {
        let key = WhisperNowTunedPolisher.cleanupAdapterKey
        #expect(key == "voice.cleanupAdapter")
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        #expect(WhisperNowTunedPolisher.DictationAdapter.v3c.fileName == "v3c240.gguf")
        #expect(WhisperNowTunedPolisher.DictationAdapter.t4.fileName == "step918.gguf")
        #expect(WhisperNowTunedPolisher.DictationAdapter.v3c.traceName == "t5-v3c240")
        #expect(WhisperNowTunedPolisher.DictationAdapter.t4.traceName == "t4-step918")
        UserDefaults.standard.set("t4", forKey: key)
        #expect(WhisperNowTunedPolisher.dictationAdapter == .t4)
        UserDefaults.standard.removeObject(forKey: key)
        let shipping = WhisperNowTunedPolisher.shippingDictationAdapter
        // Unset or unknown values use the shipping adapter when its file is installed, else step 918.
        let v3cInstalled = FileManager.default.fileExists(atPath:
            WhisperNowTunedPolisher.t4Directory.appendingPathComponent("v3c240.gguf").path)
        let expected: WhisperNowTunedPolisher.DictationAdapter = shipping == .t4 || v3cInstalled ? shipping : .t4
        #expect(WhisperNowTunedPolisher.dictationAdapter == expected)
        UserDefaults.standard.set("t9", forKey: key)
        #expect(WhisperNowTunedPolisher.dictationAdapter == expected)
    }
}
