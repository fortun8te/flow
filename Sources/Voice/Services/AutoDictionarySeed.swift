import Foundation
import SQLite3

/// One-time seed of the learned dictionary from fixes Jordan already made (22 Nov 2026). Everything is
/// read only and stays on this Mac. The same evidence rules apply as live (AutoDictionary.observe):
///   - Wispr Flow history: each dictation he edited (formattedText -> editedText), oldest first.
///   - Wispr Flow's dictionary rows it learned from his edits (observedSource -> phrase).
///   - Flow's own saved edits with explicit observed-edit provenance and an isolated pasted span.
///   - Opt+1 results left on screen are weak evidence and cannot promote replacements on their own.
enum AutoDictionarySeed {
    struct Report: Equatable {
        var wisprEdits = 0
        var wisprDictionaryRows = 0
        var flowEdits = 0
        var opt1Kept = 0
        var opt1Undone = 0
        var unreadableSources = 0
        var promoted: [AutoDictionary.Event] = []
    }

    static var wisprDatabase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wispr Flow/flow.sqlite")
    }

    static var voiceDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VOICE")
    }

    static func run(into dictionary: AutoDictionary, judge: AutoDictionary.WordJudge,
                    wispr: URL = wisprDatabase, voice: URL = voiceDirectory) -> Report {
        var report = Report()
        guard !UserDefaults.standard.bool(forKey: "voice.privacyMode") else { return report }
        var evidence: [(at: Date, apply: () -> [AutoDictionary.Event])] = []

        let wisprDate = DateFormatter()
        wisprDate.locale = Locale(identifier: "en_US_POSIX")
        wisprDate.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        for row in query(wispr, """
            SELECT CAST(rowid AS TEXT), formattedText, editedText, timestamp FROM History
            WHERE editedText IS NOT NULL AND editedText != '' AND formattedText IS NOT NULL AND editedText != formattedText
            """) where row.count == 4 {
            let before = row[1], after = row[2]
            let at = wisprDate.date(from: row[3]) ?? Date.distantPast
            let id = "wispr-history:" + row[0]
            report.wisprEdits += 1
            evidence.append((at, { dictionary.observe(before: before, after: after, source: .wisprEdit,
                                                       now: at, evidenceID: id, judge: judge) }))
        }
        for row in query(wispr, """
            SELECT CAST(rowid AS TEXT), observedSource, phrase, createdAt FROM Dictionary
            WHERE source = 'user_edits' AND isDeleted = 0 AND observedSource IS NOT NULL AND observedSource != ''
            """) where row.count == 4 {
            let heard = row[1], written = row[2]
            let at = wisprDate.date(from: row[3]) ?? Date.distantPast
            let id = "wispr-dictionary:" + row[0]
            report.wisprDictionaryRows += 1
            evidence.append((at, { dictionary.observePair(heard: heard, written: written, source: .wisprDictionary,
                                                           now: at, evidenceID: id, judge: judge) }))
        }

        let iso = ISO8601DateFormatter()
        let isoFraction = ISO8601DateFormatter()
        isoFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ any: Any?) -> Date {
            guard let s = any as? String else { return .distantPast }
            return iso.date(from: s) ?? isoFraction.date(from: s) ?? .distantPast
        }
        let flowRows = jsonLines(voice.appendingPathComponent("training/dictations.jsonl"))
        if flowRows == nil { report.unreadableSources += 1 }
        for row in flowRows ?? [] where row["kind"] as? String == "edit" {
            guard row["feedbackSource"] as? String == "observed-edit",
                  row["targetScope"] as? String == "pasted-span",
                  let id = row["id"] as? String, !id.isEmpty,
                  let pasted = row["finalText"] as? String,
                  let corrected = row["editedField"] as? String,
                  !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  pasted != corrected else { continue }
            // Legacy editedField held the entire field. It cannot safely label
            // a correction of this insertion without a baseline and exact range.
            report.flowEdits += 1
            let at = date(row["recordedAt"])
            evidence.append((at, { dictionary.observe(before: pasted, after: corrected, source: .flowHistory,
                                                       now: at, evidenceID: id, judge: judge) }))
        }
        let attemptRows = jsonLines(voice.appendingPathComponent("opt1-evidence/attempts.jsonl"))
        if attemptRows == nil { report.unreadableSources += 1 }
        let attempts = attemptRows ?? []
        let undone = Set(attempts.filter { $0["outcome"] as? String == "undone" }.compactMap { $0["operationID"] as? String })
        let applied = Dictionary(grouping: attempts.filter { $0["outcome"] as? String == "applied" },
                                 by: { $0["operationID"] as? String ?? "" })
        // Imported Undo also retracts a keep seeded on an earlier launch, not
        // only the positive rows in this particular import snapshot.
        for row in attempts where row["outcome"] as? String == "undone" {
            guard let id = row["operationID"] as? String, !id.isEmpty else { continue }
            let matching = (applied[id] ?? []).compactMap { item -> (String, String)? in
                guard let input = item["input"] as? String, let output = item["proposedOutput"] as? String else { return nil }
                return (input, output)
            }
            let sameEdit = matching.first.map { first in matching.allSatisfy { $0.0 == first.0 && $0.1 == first.1 } } ?? false
            // An absent/ambiguous applied row can still revoke this operation's
            // stored passive vote, but cannot identify another alias to veto.
            let input = sameEdit ? matching[0].0 : "", output = sameEdit ? matching[0].1 : ""
            let at = date(row["recordedAt"])
            report.opt1Undone += 1
            evidence.append((at, { dictionary.observeUndo(original: input, candidate: output, evidenceID: id, now: at) }))
        }
        for row in attempts where row["outcome"] as? String == "applied" {
            guard let id = row["operationID"] as? String, !undone.contains(id),
                  let input = row["input"] as? String, let output = row["proposedOutput"] as? String else { continue }
            report.opt1Kept += 1
            let at = date(row["recordedAt"])
            evidence.append((at, { dictionary.observe(before: input, after: output, source: .opt1Kept,
                                                       now: at, evidenceID: id, judge: judge) }))
        }

        let ordered = evidence.sorted(by: { $0.at < $1.at })
        // Release the store between bounded chunks so a large history import
        // cannot hold dictionary reads behind its entire corpus.
        for start in stride(from: 0, to: ordered.count, by: 16) {
            guard !UserDefaults.standard.bool(forKey: "voice.privacyMode") else { break }
            dictionary.batch {
                for item in ordered[start..<min(start + 16, ordered.count)] { report.promoted += item.apply() }
            }
        }
        return report
    }

    // MARK: Reading

    private static func query(_ url: URL, _ sql: String) -> [[String]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var db: OpaquePointer?
        let uri = "file:" + url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let n = sqlite3_column_count(statement)
            rows.append((0..<n).map { i in sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" })
        }
        return rows
    }

    private static func jsonLines(_ url: URL) -> [[String: Any]]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var rows: [[String: Any]] = []
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Dropping a corrupt Undo line while accepting earlier keeps would
            // manufacture positive evidence. Reject this source as a unit.
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
            rows.append(row)
        }
        return rows
    }
}
