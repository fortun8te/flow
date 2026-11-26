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

    func testUnknownWordConfidenceIsNotFabricatedAsOne() throws {
        let timings = [token(" Or", .nan), token("ivex", .infinity), token(" Labs", -1), token(" confirmed", 0.8344)]
        let words = try XCTUnwrap(TranscriptionService.wordConfidences(from: timings))
        XCTAssertEqual(words.map(\.word), ["Orivex", "Labs", "confirmed"])
        XCTAssertNil(words[0].confidence)
        XCTAssertNil(words[1].confidence)
        XCTAssertEqual(try XCTUnwrap(words[2].confidence), 0.834, accuracy: 0.000_01)
    }

    func testWordConfidenceUsesOnlyValidScoresAndIgnoresEmptyBoundaryPieces() throws {
        let timings = [token("▁", 0), token("Ori", .nan), token("vex", 0.67), token("ian", 0.81)]
        let words = try XCTUnwrap(TranscriptionService.wordConfidences(from: timings))
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(try XCTUnwrap(words[0].confidence), 0.67, accuracy: 0.000_01)
    }

    func testInvalidPieceTimesLeaveTheWordSpanUnknown() throws {
        let timings = [TokenTiming(token: " Ori", tokenId: 1, startTime: 1, endTime: 1.1, confidence: 0.8),
                       TokenTiming(token: "vex", tokenId: 2, startTime: .nan, endTime: 1.3, confidence: 0.7),
                       TokenTiming(token: " Labs", tokenId: 3, startTime: 1.25, endTime: 1.4, confidence: 0.9)]
        let words = try XCTUnwrap(TranscriptionService.wordConfidences(from: timings))
        XCTAssertNil(words[0].start)
        XCTAssertNil(words[0].end)
        XCTAssertEqual(try XCTUnwrap(words[0].confidence), 0.7, accuracy: 0.000_01)
        XCTAssertEqual(words[1].start, 1.25)
        XCTAssertEqual(words[1].end, 1.4)
    }

    func testNegativeReversedAndUnboundedSpansAreNotLoggedAsValidTimes() throws {
        for (start, end) in [(-1.0, 0.2), (2.0, 1.0), (1.0, .infinity), (0.0, Double.greatestFiniteMagnitude)] {
            let words = try XCTUnwrap(TranscriptionService.wordConfidences(from: [
                TokenTiming(token: " Orivex", tokenId: 1, startTime: start, endTime: end, confidence: 0.8)
            ]))
            XCTAssertNil(words[0].start)
            XCTAssertNil(words[0].end)
        }
    }

    func testChunkEvidenceUsesRecordingTimeAndPreservesInvalidLocalSpans() throws {
        let local = [TokenTiming(token: " Orivex", tokenId: 7, startTime: 0.5, endTime: 0.8, confidence: 0.8),
                     TokenTiming(token: " Labs", tokenId: 8, startTime: -0.1, endTime: 0.2, confidence: 0.6)]
        let shifted = try XCTUnwrap(TranscriptionService.recordingRelativeTimings(local, chunkStart: 200_000, sampleRate: 16_000))
        XCTAssertEqual(shifted[0].startTime, 13)
        XCTAssertEqual(shifted[0].endTime, 13.3)
        XCTAssertEqual(shifted[0].tokenId, 7)
        XCTAssertEqual(shifted[0].confidence, 0.8)
        let words = try XCTUnwrap(TranscriptionService.wordConfidences(from: shifted))
        XCTAssertEqual(words[0].start, 13)
        XCTAssertNil(words[1].start)
        XCTAssertNil(words[1].end)
        XCTAssertNil(TranscriptionService.recordingRelativeTimings(local, chunkStart: 0, sampleRate: 0))
    }

    func testSegmentAverageIgnoresInvalidScoresAndInvalidFallbacks() {
        let timings = [token(" One", .nan), token(" two", 0.8), token(" three", 0.6), token(" four", 2)]
        XCTAssertEqual(TranscriptionService.meanConfidence(from: timings, fallback: 0.9), 0.7, accuracy: 0.000_01)
        XCTAssertEqual(TranscriptionService.meanConfidence(from: [token(" One", .nan)], fallback: 0.9), 0.9)
        XCTAssertEqual(TranscriptionService.meanConfidence(from: nil, fallback: .nan), 0)
    }
}
