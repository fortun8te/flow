import Foundation

/// Persisted history of the last dictations. Capped at 100 (see
/// `RecentDictations.limit`). The store keeps backward-compatible JSON,
/// while recording identity links new entries to their audio and run evidence.
///
/// `text` is the polished (final) version that was actually pasted at the cursor.
/// `rawText` is the pre-polish formatted version (optional for backward compat —
/// older persisted entries didn't capture it). When both are present the UI can
/// show a before/after compare.
struct RecentDictation: Codable, Identifiable, Sendable {
    let text: String
    let timestamp: Date
    /// Pre-polish formatted text. Optional so we don't break decoding of older
    /// entries written before this field existed.
    var rawText: String? = nil
    /// Bundle ID of the app text was pasted into (e.g. "com.tinyspeck.slackmacgap").
    var pasteTargetBundleID: String? = nil
    /// Milliseconds the Qwen3 polish stage took. Nil if polish was skipped/disabled.
    var polishMs: Int? = nil
    /// Raw transcript from Granite 4.0 1B (second ASR), captured at the moment
    /// of dictation. Optional for backward compat with older entries.
    var graniteText: String? = nil
    /// Raw transcript from Moonshine Tiny (third ASR), captured at the moment
    /// of dictation. Optional for backward compat with older entries.
    var moonshineText: String? = nil
    /// Raw Parakeet ASR before TextFormatter ran — the actual speech recognizer output.
    /// Stored to let the pipeline view show all 3 stages: ASR → Formatter → Polish.
    var parakeetRawText: String? = nil
    /// Low-confidence words flagged by Parakeet's per-token confidence scoring.
    /// Passed to Qwen3 as hints; shown in the pipeline view.
    var parakeetSuspects: [String]? = nil
    /// Recording duration in seconds. Optional for back-compat with older entries
    /// captured before this field existed. Used by the BigMenu stats row to
    /// compute words-per-minute over recent dictations.
    var durationSeconds: Int? = nil
    /// Number of spoken punctuation/formatting commands the TextFormatter
    /// converted to characters (period, comma, new line, exclamation, etc.).
    /// Surfaced as "fixes made by voice" in the BigMenu stats row.
    // NOTE: BigMenuWindow's computeStats() should sum `polishFixCount` (not
    // `voiceCommandCount`) for the "fixes by voice" stat card. Keep this field
    // around for back-compat but the UI now prefers polishFixCount.
    var voiceCommandCount: Int? = nil
    /// Number of fix-events the polish stage applied (spelling/capitalization/grammar/filler).
    /// Computed by diffing raw → polished at finishRecording time.
    var polishFixCount: Int? = nil
    /// Cleanup level the polish stage was running on when this dictation was captured.
    /// Optional for back-compat with older entries. Display value: "None" / "Light" / "Medium" / "High".
    var cleanupLevelUsed: String? = nil
    /// Personality preset in effect when the polish ran. "Neutral" / "Formal" / "Casual" / "Excited".
    var personalityStyleUsed: String? = nil
    /// Engine that actually polished this dictation. Tagged by Qwen3Polisher
    /// during polish so the history view can show "Cloud (Qwen 235B)" vs
    /// "Local (Qwen3 4B)". Optional for back-compat with older entries.
    /// Format: "cloud:qwen-3-235b" / "local:qwen3-4b" / "local:qwen3-1.7b" / "rules-only"
    var polishEngine: String? = nil
    /// True when this dictation was CANCELLED rather than committed. Cancelled
    /// dictations are retained (audio kept on disk, transcript saved) but were
    /// never pasted at the cursor and were not fully polished. Optional /
    /// defaults false for back-compat with older entries.
    var cancelled: Bool = false
    /// On-disk path to retained audio, when available. Older entries may only
    /// reference audio through their corresponding Meeting row.
    var audioFilePath: String? = nil
    var deletedAt: Date? = nil
    var recordingID: String? = nil
    var id: String { recordingID ?? "\(timestamp.timeIntervalSince1970)" }

    /// True when raw differs meaningfully from polished — i.e. polish actually
    /// changed something. Used by the UI to decide whether to show a compare
    /// affordance.
    var hasPolishDiff: Bool {
        guard let raw = rawText else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when we have a raw transcript to show, regardless of whether
    /// polish changed anything. Used to enable the "show raw" affordance
    /// on every entry that has the pre-polish text available.
    var hasRawText: Bool {
        guard let raw = rawText else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension RecentDictation {
    enum CodingKeys: String, CodingKey {
        case text, timestamp, rawText, pasteTargetBundleID, polishMs, graniteText, moonshineText
        case parakeetRawText, parakeetSuspects, durationSeconds, voiceCommandCount, polishFixCount
        case cleanupLevelUsed, personalityStyleUsed, polishEngine, cancelled, audioFilePath, deletedAt, recordingID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
        pasteTargetBundleID = try c.decodeIfPresent(String.self, forKey: .pasteTargetBundleID)
        polishMs = try c.decodeIfPresent(Int.self, forKey: .polishMs)
        graniteText = try c.decodeIfPresent(String.self, forKey: .graniteText)
        moonshineText = try c.decodeIfPresent(String.self, forKey: .moonshineText)
        parakeetRawText = try c.decodeIfPresent(String.self, forKey: .parakeetRawText)
        parakeetSuspects = try c.decodeIfPresent([String].self, forKey: .parakeetSuspects)
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds)
        voiceCommandCount = try c.decodeIfPresent(Int.self, forKey: .voiceCommandCount)
        polishFixCount = try c.decodeIfPresent(Int.self, forKey: .polishFixCount)
        cleanupLevelUsed = try c.decodeIfPresent(String.self, forKey: .cleanupLevelUsed)
        personalityStyleUsed = try c.decodeIfPresent(String.self, forKey: .personalityStyleUsed)
        polishEngine = try c.decodeIfPresent(String.self, forKey: .polishEngine)
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        audioFilePath = try c.decodeIfPresent(String.self, forKey: .audioFilePath)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        recordingID = try c.decodeIfPresent(String.self, forKey: .recordingID)
        if recordingID?.isEmpty == true { recordingID = nil }
    }
}

/// A failed decode is never interpreted as an empty store for a later write.
/// The memory lock and file lease cover the complete read/modify/write operation.
final class RecentDictationStore: @unchecked Sendable {
    private let file: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: (identity: PrivateDataFile.Identity?, legacy: Data?, items: [RecentDictation])?
    private var failure: String?
    static let legacyKey = "recentDictations"

    init(file: URL, defaults: UserDefaults = .standard) { self.file = file; self.defaults = defaults }

    var lastError: String? { lock.withLock { failure } }

    func stored(now: Date = Date()) -> [RecentDictation] {
        lock.withLock {
            do {
                let items = try load()
                failure = nil
                return RecentDictations.retainingHistory(items, now: now)
            } catch {
                failure = "Recent dictation history could not be read. Existing data was preserved."
                return RecentDictations.retainingHistory(cached?.items ?? [], now: now)
            }
        }
    }

    @discardableResult
    func mutate(collecting: Bool = false, now: Date = Date(), _ update: (inout [RecentDictation]) -> Void) -> Bool {
        lock.withLock {
            guard !collecting || !defaults.bool(forKey: "voice.privacyMode") else { return false }
            do {
                try PrivateDataFile.withExclusiveAccess(to: file) {
                    var items = RecentDictations.retainingHistory(try load(), now: now)
                    update(&items)
                    guard !collecting || !defaults.bool(forKey: "voice.privacyMode") else { throw CancellationError() }
                    let data = try JSONEncoder().encode(items)
                    try PrivateDataFile.replace(data, at: file)
                    // Re-read once after a write. Associating our in-memory
                    // items with a later stat could cache another editor's
                    // replacement under the wrong contents indefinitely.
                    cached = nil
                    // A failed migration retains the only complete legacy copy.
                    defaults.removeObject(forKey: Self.legacyKey)
                    failure = nil
                }
                return true
            } catch PrivateDataFile.PersistenceError.synchronizationAfterPublishFailed {
                failure = "Recent dictation history was written, but storage synchronization could not be confirmed."
                NSLog("[VOICE-STORAGE] recent dictation update written; storage synchronization unconfirmed")
                return false
            } catch {
                failure = "Recent dictation history could not be saved. Existing data was preserved."
                NSLog("[VOICE-STORAGE] recent dictation update failed; existing data preserved")
                return false
            }
        }
    }

    private func load() throws -> [RecentDictation] {
        let identity = try PrivateDataFile.identity(at: file)
        let legacy = identity == nil ? defaults.data(forKey: Self.legacyKey) : nil
        if let cached, cached.identity == identity, cached.legacy == legacy { return cached.items }
        let data = identity == nil ? legacy : try PrivateDataFile.read(file)
        let items = try data.map { try JSONDecoder().decode([RecentDictation].self, from: $0) } ?? []
        guard try PrivateDataFile.identity(at: file) == identity else { throw POSIXError(.EBUSY) }
        cached = (identity, legacy, items)
        return items
    }
}

fileprivate extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

enum RecentDictations {
    private static let limit = 100

    /// File at ~/Library/Application Support/Voice/recent_dictations.json.
    /// Mirrors the pattern used by StorageService / Telemetry.
    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let voiceDir = appSupport.appendingPathComponent("Voice", isDirectory: true)
        return voiceDir.appendingPathComponent("recent_dictations.json")
    }

    private static let store = RecentDictationStore(file: fileURL)
    static var lastStorageError: String? { store.lastError }

    /// Cache unchanged history. Legacy defaults migrate on the next successful
    /// mutation; a failed write never deletes the only legacy copy.
    static func all() -> [RecentDictation] { store.stored().filter { $0.deletedAt == nil } }

    /// Recurrence evidence comes from other committed recordings' recognizer
    /// output. Cleaned output, cancellations and duplicate rows cannot add votes.
    static func recognitionHistory(_ items: [RecentDictation], excluding recordingID: String, limit: Int = 50) -> [String] {
        guard limit > 0 else { return [] }
        func identity(_ value: String) -> String { UUID(uuidString: value)?.uuidString ?? value }
        let current = identity(recordingID)
        var seen: Set<String> = []
        var texts: [String] = []
        for item in items {
            let id = identity(item.id)
            guard !item.cancelled, item.deletedAt == nil, id != current,
                  let text = item.parakeetRawText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, seen.insert(id).inserted else { continue }
            texts.append(text)
            if texts.count == limit { break }
        }
        return texts
    }

    static func retainingHistory(_ items: [RecentDictation], now: Date) -> [RecentDictation] {
        items.filter { $0.deletedAt.map { now.timeIntervalSince($0) < 7 * 24 * 3600 } ?? true }
    }

    static func trash(now: Date = Date()) -> [RecentDictation] {
        store.stored(now: now).filter { item in
            item.deletedAt.map { now.timeIntervalSince($0) < 7 * 24 * 3600 } ?? false
        }
    }

    static func restore(id: String) {
        store.mutate { items in
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].deletedAt != nil else { return }
            items[index].deletedAt = nil
        }
    }

    /// Back-compat single-text add — used by code paths that don't know the
    /// pre-polish version. Newer callers should use `add(raw:polished:)`.
    static func add(_ text: String) {
        add(raw: nil, polished: text)
    }

    /// Add a dictation with both the pre-polish formatted text and the final
    /// polished text. `raw` is optional — pass nil if polish was skipped /
    /// disabled / unchanged, and only the polished version will be stored.
    static func delete(id: String) {
        store.mutate { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].deletedAt = Date()
        }
    }

    @discardableResult
    static func add(raw: String?, polished: String, pasteTargetBundleID: String? = nil, polishMs: Int? = nil,
                    granite: String? = nil, moonshine: String? = nil,
                    parakeetRaw: String? = nil, suspects: [String]? = nil,
                    durationSeconds: Int? = nil, voiceCommandCount: Int? = nil,
                    cleanupLevelUsed: String? = nil,
                    personalityStyleUsed: String? = nil,
                    polishFixCount: Int? = nil,
                    polishEngine: String? = nil,
                    cancelled: Bool = false,
                    audioFilePath: String? = nil, recordingID: String? = nil) -> Bool {
        let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let trimmedRaw = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Always persist `rawText` when it's non-empty (even when identical to
        // the polished version). The History UI uses `hasPolishDiff` to gate
        // the compare button — keeping `rawText` populated lets us surface
        // "polish was a no-op for this one" cleanly, and means users who want
        // to see the raw transcript always can.
        let rawForStorage: String? = {
            guard let r = trimmedRaw, !r.isEmpty else { return nil }
            return r
        }()
        let now = Date()
        let item = RecentDictation(text: trimmed, timestamp: now, rawText: rawForStorage,
                            pasteTargetBundleID: pasteTargetBundleID, polishMs: polishMs,
                            graniteText: granite?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                            moonshineText: moonshine?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                            parakeetRawText: parakeetRaw?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                            parakeetSuspects: (suspects?.isEmpty == false) ? suspects : nil,
                            durationSeconds: durationSeconds,
                            voiceCommandCount: voiceCommandCount,
                            polishFixCount: polishFixCount,
                            cleanupLevelUsed: cleanupLevelUsed,
                            personalityStyleUsed: personalityStyleUsed,
                            polishEngine: polishEngine,
                            cancelled: cancelled,
                            audioFilePath: audioFilePath, recordingID: recordingID?.nonEmptyOrNil ?? UUID().uuidString)
        return store.mutate(collecting: true, now: now) { items in
            // A late completion or replay of a deleted recording must not resurrect it.
            if let existing = items.first(where: { $0.id == item.id }), existing.deletedAt != nil { return }
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
            let retainedTrash = items.filter { $0.deletedAt != nil }
            items = Array(items.filter { $0.deletedAt == nil }.prefix(limit)) + retainedTrash
        }
    }

    /// Count distinct fix events between raw and polished text. A "fix event" is
    /// any contiguous run of words that differs between the two. This collapses
    /// e.g. "i think" → "I think" + "yeah" → "" into 2 fixes, not 2.5.
    static func countFixes(raw: String, polished: String) -> Int {
        let rawWords = raw.split(whereSeparator: \.isWhitespace)
        let polishedWords = polished.split(whereSeparator: \.isWhitespace)
        guard rawWords != polishedWords else { return 0 }
        var prefix = 0
        while prefix < min(rawWords.count, polishedWords.count), rawWords[prefix] == polishedWords[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(rawWords.count, polishedWords.count) - prefix,
              rawWords[rawWords.count - suffix - 1] == polishedWords[polishedWords.count - suffix - 1] { suffix += 1 }
        let rawTokens = Array(rawWords[prefix..<(rawWords.count - suffix)])
        let polTokens = Array(polishedWords[prefix..<(polishedWords.count - suffix)])

        // Myers-lite: count edit runs via 2D LCS-style backtrack.
        let m = rawTokens.count
        let n = polTokens.count
        if m == 0 { return n > 0 ? 1 : 0 }
        if n == 0 { return 1 }
        // A UI statistic must not allocate a quadratic table for a long
        // dictation. A very large rewrite is conservatively one fix event;
        // this approximate display count is never a training/evaluation label.
        guard m <= 250_000 / n else { return 1 }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if rawTokens[i] == polTokens[j] {
                    dp[i+1][j+1] = dp[i][j] + 1
                } else {
                    dp[i+1][j+1] = max(dp[i][j+1], dp[i+1][j])
                }
            }
        }

        // Backtrack to count edit runs (contiguous mismatch streaks).
        var i = m, j = n
        var runs = 0
        var inMismatch = false
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && rawTokens[i-1] == polTokens[j-1] {
                if inMismatch { runs += 1; inMismatch = false }
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                inMismatch = true; j -= 1
            } else {
                inMismatch = true; i -= 1
            }
        }
        if inMismatch { runs += 1 }
        return runs
    }
}

