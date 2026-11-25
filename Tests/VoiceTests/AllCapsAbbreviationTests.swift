import XCTest
@testable import Voice

/// "asap" and friends must come out in capitals in both dictation and Opt+1 (22 Nov 2026).
final class AllCapsAbbreviationTests: XCTestCase {
    private func dictation(_ text: String) -> String {
        ProperNounVocabulary.applyPreferredSpelling(text, terms: [])
    }

    private func optOne(_ text: String) -> String {
        TypoRepair.shared.snapVocabulary(text)
    }

    func testASAPBecomesCapitalsInEveryForm() {
        for form in ["asap", "ASAP", "Asap", "a s a p", "A S A P", "A.S.A.P."] {
            XCTAssertEqual(dictation("Send it \(form) please"), "Send it ASAP please", form)
            XCTAssertEqual(optOne("Send it \(form) please"), "Send it ASAP please", form)
        }
    }

    func testDottedASAPKeepsSentenceFlowAndFinalDot() {
        XCTAssertEqual(dictation("Send it A.S.A.P. today"), "Send it ASAP today")
        XCTAssertEqual(dictation("Send it A.S.A.P. Thanks"), "Send it ASAP. Thanks")
        XCTAssertEqual(dictation("I need it a s a p."), "I need it ASAP.")
    }

    func testSpacedLettersInsideAWordAreLeftAlone() {
        XCTAssertEqual(dictation("He took a sap from the tree"), "He took a sap from the tree")
        XCTAssertEqual(dictation("the pcs are fine"), "the pcs are fine")
    }

    func testOtherAbbreviationsComeOutInCapitals() {
        let pairs = [("fyi", "FYI"), ("eta", "ETA"), ("tbh", "TBH"), ("idk", "IDK"), ("api", "API"), ("ui", "UI"),
                     ("mcp", "MCP"), ("nas", "NAS"), ("pc", "PC"), ("gpu", "GPU"), ("ai", "AI"), ("dm", "DM")]
        for (typed, written) in pairs {
            XCTAssertEqual(dictation("Check the \(typed) today"), "Check the \(written) today", typed)
        }
    }

    func testLowercaseNglStaysAsTyped() {
        XCTAssertEqual(dictation("ngl that works"), "ngl that works")
    }
}
