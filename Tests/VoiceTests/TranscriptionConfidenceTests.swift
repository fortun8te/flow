import FluidAudio
import XCTest
@testable import Voice

final class TranscriptionConfidenceTests: XCTestCase {
    private func token(_ piece: String, _ confidence: Float) -> TokenTiming {
        TokenTiming(token: piece, tokenId: 0, startTime: 0, endTime: 0, confidence: confidence)
    }

    func testDecodedLeadingSpacesLimitTheHintToOneWord() {
        let timings = [token(" D", 0.98), token("id", 0.97), token(" you", 0.95), token(" ask", 0.44)]
        XCTAssertEqual(TranscriptionService.extractSuspectWords(from: timings, confidenceThreshold: 0.65), ["ask"])
    }

    func testSentencePieceBoundariesKeepUncertainSubwordsTogether() {
        let timings = [token("▁Send", 0.96), token("▁No", 0.99), token("or", 0.35), token(" the", 0.94),
                       token("▁file", 0.92), token(".", 0.12)]
        XCTAssertEqual(TranscriptionService.extractSuspectWords(from: timings, confidenceThreshold: 0.65), ["Noor"])
    }

    func testPunctuationAndUnavailableScoresProduceNoHint() {
        let timings = [token(" Welcome", 0.98), token("!", 0.13), token(" back", .nan), token("?", 0.22)]
        XCTAssertNil(TranscriptionService.extractSuspectWords(from: timings, confidenceThreshold: 0.65))
    }
}
