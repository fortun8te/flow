import Foundation

/// Model prompts use only a prefix of vocabulary and suspect lists. Deduplication
/// must keep source priority and the first spelling instead of Set iteration
/// order, which changes across processes and can change the model's prompt.
enum PromptTerms {
    /// Supply groups in priority order: preferred spellings before other
    /// vocabulary, or ASR suspects before formatter hints. No alphabetical sort
    /// or fuzzy/diacritic normalization changes that order or combines names.
    static func orderedUnique(_ groups: [String]...) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for group in groups {
            for raw in group {
                let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
                result.append(term)
            }
        }
        return result
    }

    /// Compute an expensive context score once per term. Equal scores retain
    /// the input's preferred-spelling order, including at a prompt cutoff.
    static func ranked(_ terms: [String], score: (String) -> Int) -> [String] {
        guard terms.count > 1 else { return terms }
        let scored = terms.enumerated().map { (position: $0.offset, term: $0.element, score: score($0.element)) }
        return scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.position < $1.position
        }.map(\.term)
    }

    /// Small FIFO for phonetic prompt ranking. Keys retain array boundaries
    /// and exact bytes: a hash collision or Swift's canonical String equality
    /// must not return another request's spelling or vocabulary.
    final class RankingCache: @unchecked Sendable {
        struct Key: Hashable, Sendable {
            private let vocabulary: [Data]
            private let suspects: [Data]

            init(vocabulary: [String], suspects: [String]) {
                self.vocabulary = vocabulary.map { Data($0.utf8) }
                self.suspects = suspects.map { Data($0.utf8) }
            }
        }

        private let lock = NSLock()
        private let capacity: Int
        private var order: [Key] = []
        private var values: [Key: [String]] = [:]

        init(capacity: Int) {
            precondition(capacity > 0)
            self.capacity = capacity
        }

        func read(_ key: Key) -> [String]? {
            lock.withLock { values[key] }
        }

        func write(_ key: Key, value: [String]) {
            lock.withLock {
                if values[key] != nil {
                    values[key] = value
                    return
                }
                if order.count >= capacity {
                    values.removeValue(forKey: order.removeFirst())
                }
                order.append(key)
                values[key] = value
            }
        }
    }
}
