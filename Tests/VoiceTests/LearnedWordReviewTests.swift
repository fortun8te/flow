import Foundation
import Testing
@testable import Voice

@MainActor
@Suite("Learned-word review list: Yes, Not this, Undo (A7)")
struct LearnedWordReviewTests {
    /// A review over a throwaway queue file, with the live vocabulary kept in a local set.
    private func makeReview() -> (LearnedWordReview, LearnedWordQueue, Box, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flow-review-\(UUID().uuidString).json")
        let queue = LearnedWordQueue(fileURL: url)
        let live = Box()
        let review = LearnedWordReview(queue: queue,
                                       addLive: { live.words.insert($0) },
                                       removeLive: { live.words.remove($0) })
        return (review, queue, live, url)
    }

    final class Box { var words: Set<String> = [] }

    @Test("A waiting word is listed, oldest first, and dismissed words are not")
    func listsOnlyWaitingWords() {
        let (review, queue, _, url) = makeReview()
        defer { try? FileManager.default.removeItem(at: url) }
        queue.sight("Diatype")
        queue.sight("Veecrv")
        review.dismiss("Veecrv")
        #expect(review.waiting.map(\.word) == ["Diatype"])
    }

    @Test("Yes makes the word live and removes it from the waiting list")
    func yesGoesLive() {
        let (review, queue, live, url) = makeReview()
        defer { try? FileManager.default.removeItem(at: url) }
        queue.sight("Diatype")
        review.approve("Diatype")
        #expect(live.words == ["Diatype"])
        #expect(review.waiting.isEmpty)
    }

    @Test("Undo after Yes takes the word back out and puts it in the waiting list")
    func undoAfterYes() {
        let (review, queue, live, url) = makeReview()
        defer { try? FileManager.default.removeItem(at: url) }
        queue.sight("Diatype")
        review.approve("Diatype")
        #expect(review.undo())
        #expect(live.words.isEmpty)
        #expect(review.waiting.map(\.word) == ["Diatype"])
        #expect(review.undo() == false)
    }

    @Test("Undo after Not this lets the word wait again")
    func undoAfterDismiss() {
        let (review, queue, _, url) = makeReview()
        defer { try? FileManager.default.removeItem(at: url) }
        queue.sight("Diatype")
        review.dismiss("Diatype")
        #expect(review.waiting.isEmpty)
        #expect(review.undo())
        #expect(review.waiting.map(\.word) == ["Diatype"])
        #expect(queue.isVetoed("Diatype") == false)
    }

    @Test("A dismissed word stays blocked until Undo, and Undo removes the block it added")
    func dismissBlocksUntilUndo() {
        let (review, queue, _, url) = makeReview()
        defer { try? FileManager.default.removeItem(at: url) }
        queue.sight("Diatype")
        review.dismiss("Diatype")
        #expect(queue.isVetoed("Diatype"))
        review.undo()
        #expect(queue.isVetoed("Diatype") == false)
    }
}
