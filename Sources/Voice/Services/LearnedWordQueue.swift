// Flow: learned words wait for a second sighting or Jordan's yes.
//
// A correction from an in-field fix used to go straight into the vocabulary. Now it is PENDING:
//  - it goes live after a second sighting within 7 days, or when Jordan says yes in Settings;
//  - Jordan can dismiss it. A dismissed word stays away for 7 days, and for good after 3 dismissals;
//  - rejected words can block a match but never create one.
// Filters: at most 3 words, not a function word, at least 3 letters, and a real change of word
// (a different case, ending or punctuation alone is not learned). Persisted at VOICE/learned-pending.json.

import Foundation

enum LearnedWordRules {
    static let windowSeconds: TimeInterval = 7 * 86_400
    static let dismissalCooldownSeconds: TimeInterval = 7 * 86_400
    static let permanentDismissals = 3

    static let functionWords: Set<String> = [
        "the", "and", "but", "for", "with", "that", "this", "you", "your", "they", "them", "have", "has",
        "just", "like", "what", "when", "where", "from", "into", "about", "there", "here", "will", "would",
        "could", "should", "can", "cant", "dont", "not", "its", "was", "were", "are", "is", "its", "our",
        "out", "all", "any", "one", "get", "got", "let", "lets", "ok", "okay", "yeah", "yes", "now", "then",
    ]

    /// True when the phrase may be learned at all.
    static func isEligible(_ word: String) -> Bool {
        let parts = word.split(separator: " ").map { String($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return false }
        let letters = word.lowercased().filter(\.isLetter)
        guard letters.count >= 3 else { return false }
        return !functionWords.contains(word.lowercased().filter { $0.isLetter || $0 == " " })
    }

    /// True when `new` is a real change from `old`, not just a case, punctuation or ending change.
    static func isRealChange(from old: String, to new: String) -> Bool {
        let a = old.lowercased().filter(\.isLetter)
        let b = new.lowercased().filter(\.isLetter)
        guard !a.isEmpty, !b.isEmpty, a != b else { return false }
        return editDistance(a, b) > 1
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        for i in 1...s.count {
            var cur = [i] + Array(repeating: 0, count: t.count)
            for j in 1...t.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (s[i - 1] == t[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[t.count]
    }
}

struct PendingLearnedWord: Codable, Equatable {
    var word: String
    var firstSeen: Date
    var sightings: Int
    var dismissals: Int
    var dismissedAt: Date?
}

@MainActor
final class LearnedWordQueue {
    enum Outcome: Equatable {
        case pending
        case promoted
        case blocked      // dismissed, or not eligible: nothing is learned
    }

    static let shared = LearnedWordQueue(fileURL: defaultURL)

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VOICE/learned-pending.json")
    }

    private let fileURL: URL
    private(set) var entries: [String: PendingLearnedWord] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// One correction seen. Returns whether the word is now live, still waiting, or blocked.
    @discardableResult
    func sight(_ word: String, now: Date = Date()) -> Outcome {
        guard LearnedWordRules.isEligible(word) else { return .blocked }
        let key = word.lowercased()
        if var entry = entries[key] {
            if isVetoed(entry, now: now) { return .blocked }
            if now.timeIntervalSince(entry.firstSeen) <= LearnedWordRules.windowSeconds {
                entries[key] = nil
                save()
                return .promoted
            }
            // The first sighting is too old. Start again from this one.
            entry.firstSeen = now
            entry.sightings = 1
            entries[key] = entry
            save()
            return .pending
        }
        entries[key] = PendingLearnedWord(word: word, firstSeen: now, sightings: 1, dismissals: 0, dismissedAt: nil)
        save()
        return .pending
    }

    /// Jordan says yes in Settings. The word goes live now.
    func promote(_ word: String) -> Bool {
        let key = word.lowercased()
        guard entries[key] != nil else { return false }
        entries[key] = nil
        save()
        return true
    }

    /// Jordan says no. Blocks the word for 7 days, and for good after 3 dismissals.
    func dismiss(_ word: String, now: Date = Date()) {
        let key = word.lowercased()
        var entry = entries[key] ?? PendingLearnedWord(word: word, firstSeen: now, sightings: 0, dismissals: 0, dismissedAt: nil)
        entry.dismissals += 1
        entry.dismissedAt = now
        entries[key] = entry
        save()
    }

    /// Forget a word entirely (Undo / Forget in Settings).
    func forget(_ word: String) {
        entries[word.lowercased()] = nil
        save()
    }

    /// Puts back exactly what was there before an action (Undo). A nil entry means there was none.
    func restore(_ entry: PendingLearnedWord?, forWord word: String) {
        entries[word.lowercased()] = entry
        save()
    }

    /// Waiting for Jordan's yes: seen at least once, never dismissed. Oldest first.
    var pendingForReview: [PendingLearnedWord] {
        entries.values
            .filter { $0.dismissals == 0 && $0.sightings > 0 }
            .sorted { $0.firstSeen < $1.firstSeen }
    }

    func isVetoed(_ word: String, now: Date = Date()) -> Bool {
        guard let entry = entries[word.lowercased()] else { return false }
        return isVetoed(entry, now: now)
    }

    private func isVetoed(_ entry: PendingLearnedWord, now: Date) -> Bool {
        if entry.dismissals >= LearnedWordRules.permanentDismissals { return true }
        guard let at = entry.dismissedAt else { return false }
        return now.timeIntervalSince(at) < LearnedWordRules.dismissalCooldownSeconds
    }

    // MARK: Storage

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PendingLearnedWord].self, from: data) else { return }
        entries = Dictionary(uniqueKeysWithValues: decoded.map { ($0.word.lowercased(), $0) })
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Array(entries.values))
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("[VOICE-CORRECTION] could not save the learned-word list: \(error.localizedDescription)")
        }
    }
}
