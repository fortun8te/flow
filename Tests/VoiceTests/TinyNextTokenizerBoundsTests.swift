import Foundation
import XCTest
@testable import Voice

final class TinyNextTokenizerBoundsTests: XCTestCase {
    private func tokenizer() throws -> TinyNextScorer.Tokenizer {
        let directory = try XCTUnwrap(RealWordFixer.resourceDirectory(containing: "tinynext-vocab.txt"))
        return try XCTUnwrap(TinyNextScorer.Tokenizer(directory: directory),
                             "The public vocabulary and merge files must be present; weights are not required.")
    }

    func testBoundedEncodingPreservesExactTokenPrefix() throws {
        let tokenizer = try tokenizer()
        let samples = ["The violet kettle isn't on the shelf.", "Café, café!\nNext line: 42.",
                       "  tabs\tand spaces  ", "🙂 a composed café and cafe\u{0301}"]
        for sample in samples {
            let full = tokenizer.encode(sample)
            XCTAssertFalse(full.isEmpty)
            for limit in [1, 2, 5, full.count, full.count + 1] {
                XCTAssertEqual(tokenizer.encode(sample, limit: limit), Array(full.prefix(limit)))
            }
        }
    }

    func testNonpositiveLimitAndEmptyTextReturnNoTokens() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.encode("violet", limit: 0), [])
        XCTAssertEqual(tokenizer.encode("violet", limit: -1), [])
        XCTAssertEqual(tokenizer.encode("", limit: 512), [])
    }

    func testOversizedSinglePieceMarksContextUnscorable() throws {
        let tokenizer = try tokenizer()
        let tokens = tokenizer.encode(String(repeating: "q", count: 4_096), limit: 512)
        XCTAssertEqual(tokens, [-1])
        XCTAssertTrue(tokenizer.encode("violet " + String(repeating: "q", count: 4_096), limit: 512).contains(-1))
    }

    func testOneExtraTokenExposesContextOverflow() throws {
        let tokenizer = try tokenizer()
        let text = String(repeating: " violet", count: 900)
        let bounded = tokenizer.encode(text, limit: 512)
        XCTAssertEqual(bounded.count, 512)
        XCTAssertEqual(Array(bounded.prefix(511)), tokenizer.encode(text, limit: 511))
        XCTAssertTrue(bounded.allSatisfy { $0 >= 0 })
    }

    func testByteDistinctUnicodeRetainsDifferentTokenSequences() throws {
        let tokenizer = try tokenizer()
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(tokenizer.encode(composed, limit: 512), tokenizer.encode(decomposed, limit: 512))
    }
}
