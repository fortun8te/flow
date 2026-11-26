import Foundation
import XCTest
@testable import Voice

final class HistorySearchQueryTests: XCTestCase {
    func testLineBreaksAndPunctuationDoNotJoinWords() {
        XCTAssertEqual(HistorySearchQuery.literalTerms("violet\nkettle/lantern:harbor"), "\"violet\" \"kettle\" \"lantern\" \"harbor\"")
        XCTAssertEqual(HistorySearchQuery.literalTerms("one\t two\r\nthree\u{00a0}four"), "\"one\" \"two\" \"three\" \"four\"")
    }

    func testOperatorsAndPrefixTermsAreLiteralAndWellFormed() {
        XCTAssertEqual(HistorySearchQuery.literalTerms("NOT OR AND NEAR"), "\"NOT\" \"OR\" \"AND\" \"NEAR\"")
        XCTAssertEqual(HistorySearchQuery.literalTerms("COVID-19 lantern*"), "\"COVID-19\" \"lantern\"*")
        XCTAssertEqual(HistorySearchQuery.literalTerms("a*b\" OR (speaker:moon)"), "\"a b\" \"OR\" \"speaker\" \"moon\"")
        XCTAssertEqual(HistorySearchQuery.literalTerms(" * - _ \" () : " ), "")
    }

    func testAccentsAndNonLatinWordsRemainSearchable() {
        XCTAssertEqual(HistorySearchQuery.literalTerms("cafe\u{0301} 東京"), "\"cafe\u{0301}\" \"東京\"")
    }
}
