import XCTest
@testable import Voice

final class EnglishStructureRegressionTests: XCTestCase {
    func testCommaWrappedSpokenParagraphSurvivesFormatting() {
        let output = TextFormatter(config: TextFormatterConfig()).format("I will send the proposal tomorrow, new paragraph, we can discuss the budget on Friday.")
        XCTAssertTrue(output.contains("\n\n"), output)
        XCTAssertFalse(output.lowercased().contains("new paragraph"))
    }
    func testExplicitDayAndNumberCorrectionsKeepTheClause() {
        let formatter = TextFormatter(config: TextFormatterConfig())
        let day = formatter.format("Send it on Monday, sorry, I mean Tuesday.")
        XCTAssertTrue(day.contains("Send it on Tuesday"), day)
        XCTAssertFalse(day.contains("Monday"), day)
        let number = formatter.format("Set it to 12, sorry, I mean 15.")
        XCTAssertTrue(number.contains("15"), number)
        XCTAssertFalse(number.contains("12"), number)
    }
    func testWebsitePathIsNotTurnedIntoEmailAndDotsStayOpaque() {
        let formatter = TextFormatter(config: TextFormatterConfig())
        let website = formatter.format("Send Jane Smith the notes at example.com slash brief.")
        XCTAssertTrue(website.contains("at example.com/brief"), website)
        XCTAssertFalse(website.contains("notes@"), website)
        let email = formatter.format("Send it to jane at example dot com")
        XCTAssertTrue(email.contains("jane@example.com"), email)
    }
    func testLiteralCommandsAndProhibitionsRemainLiteral() {
        let formatter = TextFormatter(config: TextFormatterConfig())
        XCTAssertFalse(formatter.format("Do not send this before Friday.").hasSuffix("?"))
        let quote = formatter.format("She said \"Monday, sorry, I mean Tuesday\".")
        XCTAssertTrue(quote.contains("Monday"), quote)
        XCTAssertTrue(quote.contains("Tuesday"), quote)
    }
    func testS1CannotFlattenAnExplicitParagraph() {
        let result = S1MiniPolisher.assess(candidate: "Send it tomorrow. Discuss it on Friday.", original: "Send it tomorrow.\n\nDiscuss it on Friday.")
        if case .rejected = result {} else { XCTFail("Flattened paragraph accepted") }
    }
}
