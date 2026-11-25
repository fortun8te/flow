import Foundation
import Testing
@testable import Voice

@MainActor
@Suite("Learned words wait for review (sol/01 clean-room list)")
struct LearnedWordQueueTests {
    private func makeQueue() -> (LearnedWordQueue, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flow-learned-\(UUID().uuidString).json")
        return (LearnedWordQueue(fileURL: url), url)
    }

    private let day: TimeInterval = 86_400

    @Test("A first sighting is pending, never live")
    func firstSightingWaits() {
        let (queue, url) = makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(queue.sight("Diatype") == .pending)
        #expect(queue.entries["diatype"]?.sightings == 1)
    }

    @Test("A second sighting within 7 days promotes the word")
    func secondSightingPromotes() {
        let (queue, url) = makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        #expect(queue.sight("Diatype", now: start) == .pending)
        #expect(queue.sight("Diatype", now: start.addingTimeInterval(2 * day)) == .promoted)
        #expect(queue.entries["diatype"] == nil)
    }

    @Test("A second sighting after 7 days starts the count again")
    func lateSecondSightingWaitsAgain() {
        let (queue, url) = makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        queue.sight("Diatype", now: start)
        #expect(queue.sight("Diatype", now: start.addingTimeInterval(8 * day)) == .pending)
    }

    @Test("A dismissed word stays away for 7 days, then for good after 3 dismissals")
    func vetoHolds() {
        let (queue, url) = makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        queue.dismiss("Acme", now: start)
        #expect(queue.sight("Acme", now: start.addingTimeInterval(day)) == .blocked)
        #expect(queue.sight("Acme", now: start.addingTimeInterval(8 * day)) == .pending)
        queue.dismiss("Acme", now: start.addingTimeInterval(9 * day))
        queue.dismiss("Acme", now: start.addingTimeInterval(20 * day))
        #expect(queue.isVetoed("Acme", now: start.addingTimeInterval(400 * day)))
        #expect(queue.sight("Acme", now: start.addingTimeInterval(400 * day)) == .blocked)
    }

    @Test("Function words, short words and multi-word phrases are not learned")
    func filters() {
        #expect(!LearnedWordRules.isEligible("the"))
        #expect(!LearnedWordRules.isEligible("ok"))
        #expect(!LearnedWordRules.isEligible("a b c d"))
        #expect(LearnedWordRules.isEligible("Diatype"))
    }

    @Test("A change of case, ending or punctuation alone is not learned")
    func realChangeOnly() {
        #expect(!LearnedWordRules.isRealChange(from: "diatype", to: "Diatype"))
        #expect(!LearnedWordRules.isRealChange(from: "walk", to: "walks"))
        #expect(LearnedWordRules.isRealChange(from: "diatribe", to: "Diatype"))
    }

    @Test("Pending words survive a restart")
    func persists() {
        let (queue, url) = makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }
        queue.sight("Diatype")
        let reloaded = LearnedWordQueue(fileURL: url)
        #expect(reloaded.entries["diatype"]?.sightings == 1)
    }

    @Test("Jordan's yes promotes at once, and Forget removes a word")
    func promoteAndForget() {
        let (queue, url) = makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }
        queue.sight("Diatype")
        #expect(queue.promote("Diatype"))
        #expect(queue.entries["diatype"] == nil)
        queue.sight("Lumora")
        queue.forget("Lumora")
        #expect(queue.entries["lumora"] == nil)
    }
}
