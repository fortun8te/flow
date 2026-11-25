import XCTest
@testable import Voice

// Long dictation: scaled cleanup budget, and paragraph layout over whole long texts (21 Nov 2026).
final class DictationLongDictationTests: XCTestCase {
    func testShortDictationBudget() {
        XCTAssertEqual(DictationDeadline.budgetSeconds(words: 0), 1.8, accuracy: 0.0001)
        XCTAssertEqual(DictationDeadline.budgetSeconds(words: 10), 1.95, accuracy: 0.0001)
        XCTAssertEqual(DictationDeadline.remainingSeconds(sinceKeyRelease: 0.2), 1.6, accuracy: 0.0001)
    }

    func testLongDictationGetsMorePerWordUpToSixSeconds() {
        XCTAssertEqual(DictationDeadline.budgetSeconds(words: 100), 3.3, accuracy: 0.0001)
        XCTAssertEqual(DictationDeadline.budgetSeconds(words: 200), 4.8, accuracy: 0.0001)
        XCTAssertEqual(DictationDeadline.budgetSeconds(words: 400), 6, accuracy: 0.0001)
        XCTAssertEqual(DictationDeadline.budgetSeconds(words: 5000), 6, accuracy: 0.0001)
    }

    func testRemainingBudgetCountsKeyReleaseTimeAgainstTheScaledCap() {
        // A 100-word dictation whose transcript took 0.5 s still has 2.8 s for cleanup.
        XCTAssertEqual(DictationDeadline.remainingSeconds(sinceKeyRelease: 0.5, words: 100), 2.8, accuracy: 0.0001)
        XCTAssertEqual(DictationDeadline.remainingSeconds(sinceKeyRelease: 9, words: 100), 0.05, accuracy: 0.0001)
    }

    func testLongThresholdIsSixtyWords() {
        XCTAssertFalse(DictationDeadline.isLong(words: 60))
        XCTAssertTrue(DictationDeadline.isLong(words: 61))
    }

    func testEveryLongFixtureKeepsItsWordsInOrder() {
        for text in LongDictationFixtures.prose {
            let output = DictationParagraphs.formatDictation(text)
            XCTAssertEqual(output.filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace },
                           "layout must not add, drop or reword text")
        }
    }

    func testParagraphBreaksOnlyFollowASentenceEnd() {
        for text in LongDictationFixtures.prose {
            let output = DictationParagraphs.formatDictation(text)
            let parts = output.components(separatedBy: "\n\n")
            for part in parts.dropLast() {
                let last = part.trimmingCharacters(in: .whitespacesAndNewlines).last
                XCTAssertTrue(last.map { ".!?\"”'".contains($0) } ?? false,
                              "a break must not land inside a sentence: ...\(part.suffix(40))")
            }
        }
    }

    func testLongProseGetsAtLeastOneParagraphBreak() {
        for text in LongDictationFixtures.prose where text.split(whereSeparator: \.isWhitespace).count >= 120 {
            let output = DictationParagraphs.formatDictation(text)
            XCTAssertTrue(output.contains("\n\n"), "a \(text.split(whereSeparator: \.isWhitespace).count)-word dictation should be split into paragraphs")
        }
    }

    func testLongProseNeverStartsAParagraphWithAContinuation() {
        for text in LongDictationFixtures.prose {
            let output = DictationParagraphs.formatDictation(text)
            for part in output.components(separatedBy: "\n\n").dropFirst() {
                let first = part.split(separator: " ").first.map { $0.lowercased() } ?? ""
                XCTAssertFalse(["and", "but", "so", "because", "which", "cause"].contains(first),
                               "a paragraph must not open on a continuation word: \(part.prefix(40))")
            }
        }
    }
}
