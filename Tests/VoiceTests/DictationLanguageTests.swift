import Foundation
import XCTest
@testable import Voice

/// Language routing and the German-drift check (21 Nov 2026): a cleanup or Opt+1 polish must never
/// half-translate Dutch (or English) into German.
final class DictationLanguageTests: XCTestCase {
    // MARK: Language

    func testLanguageRouting() {
        XCTAssertEqual(DictationLanguage.route("Can you send me the report by Friday?"), .english)
        XCTAssertEqual(DictationLanguage.route("Kun je mij het rapport voor vrijdag sturen?"), .dutch)
        XCTAssertEqual(DictationLanguage.route("ja dat klopt"), .dutch)
        XCTAssertEqual(DictationLanguage.route("Ik ga morgen naar de winkel om boodschappen te doen. Then I will send the report to the whole team."), .mixed)
    }

    func testDutchHalfTranslatedIntoGermanTrips() {
        let source = "Ik weet het niet, maar dat is ook goed voor nu. We kijken morgen verder."
        XCTAssertTrue(DictationLanguage.germanDrift(source: source,
            output: "Ich weiß es nicht, aber das ist auch gut für nu. We kijken morgen verder."))
        XCTAssertTrue(DictationLanguage.germanDrift(source: source,
            output: "Ik weet het nicht, aber dat is auch goed voor nu. We kijken morgen verder."))
        XCTAssertNotNil(WhisperNowContentGuard.trip(source: source,
            output: "Ik weet het nicht, aber dat is auch goed voor nu. We kijken morgen verder."))
        // Clean Dutch output, English with German-looking words, and German input do not trip.
        XCTAssertFalse(DictationLanguage.germanDrift(source: source, output: "Ik weet het niet, maar dat is ook goed voor nu. We kijken morgen verder."))
        XCTAssertFalse(DictationLanguage.germanDrift(source: "The die was cast, so it was a gut call.",
                                                     output: "The die was cast, so it was a gut call."))
        XCTAssertFalse(DictationLanguage.germanDrift(source: "Ich weiß es nicht, aber das ist gut.",
                                                     output: "Ich weiß es nicht, aber das ist gut."))
    }

    func testOptOnePolishRefusesGermanDrift() {
        let outcome = PolishTransaction.classify(original: "dat is ook goed voor nu denk ik",
                                                 candidate: "Das ist auch gut für nu, denk ik.", rejection: nil)
        guard case .couldNotImprove = outcome else { return XCTFail("\(outcome)") }
    }
}
