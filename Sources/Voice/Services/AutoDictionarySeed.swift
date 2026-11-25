import Foundation
import SQLite3

/// One-time seed of the learned dictionary from fixes Jordan already made (22 Nov 2026). Everything is
/// read only and stays on this Mac. The same evidence rules apply as live (AutoDictionary.observe):
///   - Wispr Flow history: each dictation he edited (formattedText -> editedText), oldest first.
///   - Wispr Flow's dictionary rows it learned from his edits (observedSource -> phrase).
///   - Flow's own saved edits (VOICE/training/dictations.jsonl, kind "edit"), only where the pasted text
///     can be found again.
///   - Opt+1 results he kept (VOICE/opt1-evidence/attempts.jsonl, "applied" and never "undone").
enum AutoDictionarySeed {
    struct Report: Equatable {
        var wisprEdits = 0
        var wisprDictionaryRows = 0
        var flowEdits = 0
        var opt1Kept = 0
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
        var evidence: [(at: Date, apply: () -> [AutoDictionary.Event])] = []

        let wisprDate = DateFormatter()
        wisprDate.locale = Locale(identifier: "en_US_POSIX")
        wisprDate.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        for row in query(wispr, """
            SELECT formattedText, editedText, timestamp FROM History
            WHERE editedText IS NOT NULL AND editedText != '' AND formattedText IS NOT NULL AND editedText != formattedText
            """) where row.count == 3 {
            let before = row[0], after = row[1]
            let at = wisprDate.date(from: row[2]) ?? Date.distantPast
            report.wisprEdits += 1
            evidence.append((at, { dictionary.observe(before: before, after: after, source: .wisprEdit, now: at, judge: judge) }))
        }
        for row in query(wispr, """
            SELECT observedSource, phrase, createdAt FROM Dictionary
            WHERE source = 'user_edits' AND isDeleted = 0 AND observedSource IS NOT NULL AND observedSource != ''
            """) where row.count == 3 {
            let heard = row[0], written = row[1]
            let at = wisprDate.date(from: row[2]) ?? Date.distantPast
            report.wisprDictionaryRows += 1
            evidence.append((at, { dictionary.observePair(heard: heard, written: written, source: .wisprDictionary, now: at, judge: judge) }))
        }

        let iso = ISO8601DateFormatter()
        let isoFraction = ISO8601DateFormatter()
        isoFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ any: Any?) -> Date {
            guard let s = any as? String else { return .distantPast }
            return iso.date(from: s) ?? isoFraction.date(from: s) ?? .distantPast
        }
        for row in jsonLines(voice.appendingPathComponent("training/dictations.jsonl")) where row["kind"] as? String == "edit" {
            guard let pasted = (row["finalText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let field = row["editedField"] as? String, !pasted.isEmpty else { continue }
            // Still there word for word: nothing was corrected.
            guard !field.contains(pasted) else { continue }
            report.flowEdits += 1
            let at = date(row["recordedAt"])
            evidence.append((at, { dictionary.observe(before: pasted, after: field, source: .flowHistory, now: at, judge: judge) }))
        }
        let attempts = jsonLines(voice.appendingPathComponent("opt1-evidence/attempts.jsonl"))
        let undone = Set(attempts.filter { $0["outcome"] as? String == "undone" }.compactMap { $0["operationID"] as? String })
        for row in attempts where row["outcome"] as? String == "applied" {
            guard let id = row["operationID"] as? String, !undone.contains(id),
                  let input = row["input"] as? String, let output = row["proposedOutput"] as? String else { continue }
            report.opt1Kept += 1
            let at = date(row["recordedAt"])
            evidence.append((at, { dictionary.observe(before: input, after: output, source: .opt1Kept, now: at, judge: judge) }))
        }

        dictionary.batch {
            for item in evidence.sorted(by: { $0.at < $1.at }) { report.promoted += item.apply() }
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

    private static func jsonLines(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }
}
