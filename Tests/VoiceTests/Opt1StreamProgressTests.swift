import Foundation
import Testing
@testable import Voice

/// Opt+1's pill shows real progress: the typo model streams, and the share done is streamed tokens over
/// the tokens the selection should take (22 Nov 2026).
@Suite("Opt+1 streamed progress")
struct Opt1TypoFixProgressTests {
    @Test("Chunk splitting preserves whitespace-only selections and leading/trailing blank paragraphs")
    func chunksRoundTrip() {
        for text in ["  ", "\n\n", " \n\n  alpha\n\nbeta\n\n ", "a\n\nb\n\nc\n\nd\n\n"] {
            let chunks = TypoFixModel.chunks(text)
            #expect(chunks.count <= 3)
            #expect(chunks.map { $0.lead + $0.body + $0.trail }.joined() == text)
        }
    }

    @Test("Long single-paragraph selections use all available slots and preserve every byte")
    func longProseUsesSlots() {
        let sentence = "Check the backup tomorrow, then send the report to the team. "
        let text = String(repeating: sentence, count: 36) + "Keep version 2.4."
        let chunks = TypoFixModel.chunks(text)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { !$0.body.isEmpty })
        #expect(chunks.map { $0.lead + $0.body + $0.trail }.joined() == text)
        #expect(chunks.map { $0.body.count }.max()! < text.count * 2 / 3)
        let code = " `" + text + "` "
        #expect(TypoFixModel.chunks(code).count == 1)
        #expect(TypoFixModel.chunks("Short request.").count == 1)
    }

    @Test("A streamed reply collects text, stops at [DONE] and keeps the finish reason")
    func streamedReplyCollectsText() throws {
        var stream = StreamedReply()
        #expect(stream.consume(": keep-alive") == 0)
        #expect(stream.consume(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == 0)
        #expect(stream.consume(#"data: {"choices":[{"delta":{"content":"Can you "}}]}"#) == 1)
        #expect(stream.consume(#"data: {"choices":[{"delta":{"content":"check it?"}}]}"#) == 1)
        #expect(!stream.done)
        #expect(stream.consume(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == 0)
        #expect(stream.done)
        #expect(stream.consume("data: [DONE]") == 0)
        #expect(try WhisperNowTunedPolisher.parseReply(stream.replyData()) == .text("Can you check it?"))
    }

    @Test("A streamed reply cut at the token limit is refused, like a non-streamed one")
    func streamedTokenLimitIsRefused() {
        var stream = StreamedReply()
        _ = stream.consume(#"data: {"choices":[{"delta":{"content":"half of it"}}]}"#)
        _ = stream.consume(#"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        #expect(throws: WhisperNowTunedPolisher.Failure.tokenLimit) { try WhisperNowTunedPolisher.parseReply(stream.replyData()) }
    }

    @Test("Progress is streamed over expected tokens across chunks, and never reads finished early")
    func progressAcrossChunks() {
        #expect(TypoFixProgress.fraction(streamed: [0, 0], expected: [100, 100]) == 0)
        #expect(TypoFixProgress.fraction(streamed: [50, 0], expected: [100, 100]) == 0.25)
        #expect(TypoFixProgress.fraction(streamed: [100, 50], expected: [100, 100]) == 0.75)
        // More tokens than expected caps at the ceiling, so the fill does not reach full before the text lands.
        #expect(TypoFixProgress.fraction(streamed: [140, 120], expected: [100, 100]) == TypoFixProgress.ceiling)
        #expect(TypoFixProgress.fraction(streamed: [], expected: []) == 0)
    }

    @Test("The meter reports rising fractions, at most once per percent")
    func meterReportsRisingFractions() {
        final class Box: @unchecked Sendable { var values: [Double] = [] }
        let box = Box()
        let meter = TypoFixProgress(chunks: 1) { box.values.append($0) }
        meter.expect(0, tokens: 400)
        for _ in 0..<400 { meter.streamed(0) }
        #expect(box.values.count <= 101)
        #expect(box.values.count >= 90)
        #expect(box.values == box.values.sorted())
        #expect(box.values.last == TypoFixProgress.ceiling)
    }

    @Test("The pill signal posts the fraction and the loading flag")
    func pillSignalRoundTrip() {
        let info = PillPolishSignal(fraction: 0.4, loadingModel: false).userInfo
        let note = Notification(name: PillPolishSignal.notification, object: nil, userInfo: info)
        #expect(PillPolishSignal(notification: note) == PillPolishSignal(fraction: 0.4))
        let loading = Notification(name: PillPolishSignal.notification, object: nil,
                                   userInfo: PillPolishSignal(fraction: nil, loadingModel: true).userInfo)
        #expect(PillPolishSignal(notification: loading) == PillPolishSignal(fraction: nil, loadingModel: true))
    }

    @Test("Estimated tokens without the server stay positive and grow with length")
    func estimatedTokens() {
        #expect(TypoFixModel.estimatedTokens("") == 1)
        #expect(TypoFixModel.estimatedTokens(String(repeating: "word ", count: 100)) > 100)
    }
}
