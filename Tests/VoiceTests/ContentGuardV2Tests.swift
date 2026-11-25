import Foundation
import XCTest
@testable import Voice

/// Invented cleanup examples covering content-guard decisions.
final class ContentGuardV2Tests: XCTestCase {
    private typealias Guard = WhisperNowContentGuard

    func testGoodCleanupsTheStrictGuardRejectedNowPass() {
        let keep: [(String, String)] = [

            ("Uh, like um the old pump keeps making some bullsh*t noise again",
             "The old pump keeps making some bullshit noise again."),
            ("Like m maybe the sketch belongs upstairs, maybe the sign should stay downstairs.",
             "Maybe the sketch belongs upstairs. Maybe the sign should stay downstairs."),
            ("Did you pack one hundred and twenty eight brass markers and um sixty four slate tiles? When can we count them?",
             "Did you pack 128 brass markers and 64 slate tiles? When can we count them?"),
            ("Uh so we will plant one versus sixteen rows and then we will plant uhm a hundred sixty after the irrigation test.",
             "We will plant 1 versus 16 rows, and then we will plant 160 after the irrigation test."),
            ("So the be- bell rings twice in the morning.",
             "So the bell rings twice in the morning."),
            ("i need like twenty five clay tiles before sunset not thirty",
             "I need 25 clay tiles before sunset, not 30."),
            ("Three things first fold the maps second pack the lantern third lock the shed",
             "Three things:\n\n1. Fold the maps.\n2. Pack the lantern.\n3. Lock the shed."),
            ("cut the plywood for a 50 80 panel",
             "Cut the plywood for a 50/80 panel."),
        ]
        for (source, output) in keep {
            XCTAssertNil(Guard.trip(source: source, output: output), source)
        }
        // The same rows under the strict guard, for the record.
        XCTAssertNotNil(Guard.strictTrip(source: keep[0].0, output: keep[0].1).map { _ in () } ?? (Guard.strictTrip(source: keep[2].0, output: keep[2].1).map { _ in () }))
    }

    func testRealProblemsStillTrip() {
        // Translated Dutch (dev row w-...): cleanup must not translate.
        XCTAssertEqual(Guard.trip(source: "De blauwe roeiboot ligt achter de oude molen. Morgen gaat de sluis open.",
                                  output: "The blue rowing boat is behind the old mill. The lock opens tomorrow."), .coverage)
        // A dropped "It doesn't." (dev row, D7 review).
        XCTAssertEqual(Guard.trip(source: "The attic lamp flickers. It doesn't. Bring a ladder. The spare bulb is upstairs.",
                                  output: "The attic lamp flickers. Bring a ladder. The spare bulb is upstairs."), .negation)
        XCTAssertEqual(Guard.trip(source: "send me the twenty five slides", output: "Send me the 35 slides."), .number)
        XCTAssertEqual(Guard.trip(source: "send me the slides", output: "Send me the 5 slides."), .number)
        XCTAssertEqual(Guard.trip(source: "Rate it a 7/10 and send it.", output: "Rate it and send it."), .number)
        XCTAssertEqual(Guard.trip(source: "open https://example.com/brief now", output: "Open the brief now."), .link)
        XCTAssertEqual(Guard.trip(source: "Ask Nora to label the red crates before breakfast.",
                                  output: "Ask to label the red crates before breakfast."), .name)
        XCTAssertEqual(Guard.trip(source: "Please call the dentist about the appointment tomorrow morning and confirm the insurance details.",
                                  output: "Please call tomorrow."), .coverage)
        XCTAssertEqual(Guard.trip(source: "um uh", output: "EMPTY"), .empty)
    }

    func testSpellingFixOfANameIsAllowed() {
        XCTAssertNil(Guard.trip(source: "Please call Quen about the glass lantern before dusk.",
                                output: "Please call Qwen about the glass lantern before dusk."))
    }

    func testRejectedFallbackNeverPastesHesitations() async {
        let source = "Uh the birdhouse needs a new roof and um we can patch the cracked perch."
        let result = await WhisperNowCleanupDecision.decide(source: source, reply: .success(.text("Rebuild."))) { nil }
        XCTAssertFalse(result.text.lowercased().contains("uh "), result.text)
        XCTAssertFalse(result.text.lowercased().contains(" um "), result.text)
    }

    /// Reject rate on the models fixer's dev set (private, absent on other machines).
    func testDevSetRejectRate() throws {
        let base = URL(fileURLWithPath: "/Users/example/work/sample-project/next-t5-v3")
        guard let panel = try? String(contentsOf: base.appendingPathComponent("data/dev-v3-private.jsonl"), encoding: .utf8),
              let outs = try? String(contentsOf: base.appendingPathComponent("out/dev-base-outputs-private.jsonl"), encoding: .utf8)
        else { throw XCTSkip("dev set not on this machine") }
        var raw: [String: String] = [:]
        for line in panel.components(separatedBy: .newlines) where !line.isEmpty {
            if let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let id = o["id"] as? String, let r = o["raw"] as? String { raw[id] = r }
        }
        var rows = 0, strict = 0, v2 = 0
        for line in outs.components(separatedBy: .newlines) where !line.isEmpty {
            guard let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["arm"] as? String == "t4", let id = o["id"] as? String, let out = o["output"] as? String,
                  let src = raw[id] else { continue }
            rows += 1
            if Guard.strictTrip(source: src, output: out) != nil { strict += 1 }
            if Guard.trip(source: src, output: out) != nil { v2 += 1 }
        }
        print("[GUARD-DEV] rows=\(rows) strict=\(strict) v2=\(v2)")
        XCTAssertEqual(rows, 216)
        XCTAssertLessThan(Double(v2) / Double(rows), 0.12)
    }
}
