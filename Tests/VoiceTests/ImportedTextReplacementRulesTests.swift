import Foundation
import XCTest
@testable import Voice

final class ImportedTextReplacementRulesTests: XCTestCase {
    func testLongestPhraseAndWholeWordsWinWithoutCascading() {
        let rules = ImportedTextReplacementRules([
            ("new", "old"), ("new york", "NYC"), ("NYC", "unexpected"), ("one", "two")
        ])
        XCTAssertEqual(rules.apply(to: "New York is new. Someone said ONE."), "NYC is old. Someone said two.")
    }

    func testMultilineAndLiteralSnippetTargetsArePreserved() {
        let rules = ImportedTextReplacementRules([("signature", "Michael\n$1 \\draft"), ("remove", "")])
        XCTAssertEqual(rules.apply(to: "signature remove"), "Michael\n$1 \\draft ")
    }

    func testWhitespaceOnlyTriggersCannotChangeEveryWordBoundary() {
        let rules = ImportedTextReplacementRules([(" \t\n", "bad"), ("", "bad")])
        XCTAssertEqual(rules.apply(to: "Keep these words.\nAnd this line."), "Keep these words.\nAnd this line.")
    }

    func testRegexPunctuationAndDuplicateRulesKeepImportSemantics() {
        let rules = ImportedTextReplacementRules([("c++", "C++"), ("team", "old"), ("TEAM", "new")])
        XCTAssertEqual(rules.apply(to: "c++ team teammate TEAM"), "C++ new teammate new")
    }

    func testConcurrentReadsUseTheSameImmutableRules() {
        let rules = ImportedTextReplacementRules([("release note", "Release note\n")])
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            XCTAssertEqual(rules.apply(to: "🙂 release note"), "🙂 Release note\n")
        }
    }
}
