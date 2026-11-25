// Flow: the review list for learned words, with one level of Undo.
//
// A correction waits in LearnedWordQueue until it is seen twice or Jordan says yes. This type is what
// the Settings list calls: Yes makes the word live (ProperNounVocabulary), Not this dismisses it, and
// Undo puts back exactly what the last action changed. Only the last action can be undone.

import Foundation

@MainActor
final class LearnedWordReview {
    enum Action: Equatable {
        /// The word went live. `previous` is the waiting entry it came from.
        case approved(word: String, previous: PendingLearnedWord?)
        /// The word was dismissed. `previous` is the entry before the dismissal, nil when there was none.
        case dismissed(word: String, previous: PendingLearnedWord?)
    }

    private let queue: LearnedWordQueue
    private let addLive: (String) -> Void
    private let removeLive: (String) -> Void
    private(set) var lastAction: Action?

    init(queue: LearnedWordQueue, addLive: @escaping (String) -> Void, removeLive: @escaping (String) -> Void) {
        self.queue = queue
        self.addLive = addLive
        self.removeLive = removeLive
    }

    /// Words waiting for a decision, oldest first.
    var waiting: [PendingLearnedWord] { queue.pendingForReview }

    /// Jordan says yes: the word goes live now.
    func approve(_ word: String) {
        let previous = queue.entries[word.lowercased()]
        guard queue.promote(word) else { return }
        addLive(word)
        lastAction = .approved(word: word, previous: previous)
    }

    /// Jordan says no: the word is blocked for 7 days, and for good after 3 dismissals.
    func dismiss(_ word: String, now: Date = Date()) {
        let previous = queue.entries[word.lowercased()]
        queue.dismiss(word, now: now)
        lastAction = .dismissed(word: word, previous: previous)
    }

    /// Undoes the last approve or dismiss. Returns false when there is nothing to undo.
    @discardableResult
    func undo() -> Bool {
        guard let action = lastAction else { return false }
        switch action {
        case let .approved(word, previous):
            removeLive(word)
            queue.restore(previous, forWord: word)
        case let .dismissed(word, previous):
            queue.restore(previous, forWord: word)
        }
        lastAction = nil
        return true
    }
}
