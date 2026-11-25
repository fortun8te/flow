// VOICE — Storage Service (GRDB + SQLite + FTS5)
// ============================================================
// Durable, searchable persistence layer for meetings, transcripts, and
// summaries. Uses GRDB.swift on top of SQLite with FTS5.
//
// Schema (current = v8; see migrate() for v5 to v8 additions such as
// meetings.finalText, the cleaned text a dictation pasted):
//   meetings(
//     id TEXT PRIMARY KEY,
//     title TEXT NOT NULL DEFAULT 'Untitled Meeting',
//     date DATETIME NOT NULL,
//     duration REAL NOT NULL DEFAULT 0,
//     audioFilePath TEXT,                -- v1; nil if no audio retained
//     kind TEXT NOT NULL DEFAULT 'meeting',  -- v3
//     markdownExportPath TEXT,           -- v3
//     tagsJson TEXT NOT NULL DEFAULT '[]',  -- v3
//     pinnedNote TEXT                    -- v3
//   )
//   segments(
//     id TEXT PRIMARY KEY,
//     meetingId TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
//     speaker TEXT NOT NULL,
//     text TEXT NOT NULL,
//     startTime REAL NOT NULL,
//     endTime REAL NOT NULL,
//     confidence REAL,
//     speakerId TEXT,                    -- v2
//     isFinal INTEGER NOT NULL DEFAULT 1 -- v2 (0/1 boolean)
//   )
//   summaries(
//     id TEXT PRIMARY KEY,
//     meetingId TEXT NOT NULL UNIQUE REFERENCES meetings(id) ON DELETE CASCADE,
//     overview TEXT NOT NULL,
//     keyDecisionsJson TEXT NOT NULL,
//     actionItemsJson TEXT NOT NULL,
//     openQuestionsJson TEXT NOT NULL
//   )
//   segments_fts (FTS5 virtual table mirroring segments.text + speaker)
//
// Pragmas: journal_mode=WAL, synchronous=NORMAL (fast, durable).
// Backups: voice.db.backup is refreshed on launch when older than 24h.
// Recovery: PRAGMA integrity_check on launch; preserve files on failure.
// ============================================================

import Foundation
import Darwin
import SQLite3
import GRDB

/// A single full-text-search hit: which meeting/segment matched, with
/// a snippet of highlighted context and the BM25 rank (lower is better).
struct SearchHit: Codable, Sendable {
    let meeting: Meeting
    let segment: TranscriptSegment
    let snippet: String
    let rank: Double
}

class StorageService {
    private var dbPool: DatabasePool?
    private let directoryOverride: URL?

    init(directory: URL? = nil) { self.directoryOverride = directory }

    /// Called after a row was saved, changed or deleted, with that row's kind.
    /// Only the running app sets this (it tells Companion to refresh); it may be
    /// called on any thread.
    var onChange: (@Sendable (MeetingKind) -> Void)?

    private static func storageUnavailable() -> NSError {
        NSError(domain: "Voice.Storage", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Flow history is unavailable. Your recording has not been saved to history."])
    }

    // MARK: - Paths

    /// Directory containing the database file and its backup.
    private var voiceDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let voiceDir = directoryOverride ?? appSupport.appendingPathComponent("Voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        return voiceDir
    }

    /// Where the SQLite file lives (~/Library/Application Support/Voice/voice.db).
    private var databasePath: String {
        voiceDirectory.appendingPathComponent("voice.db").path
    }

    /// Sibling backup file used for automatic recovery.
    private var backupPath: String {
        voiceDirectory.appendingPathComponent("voice.db.backup").path
    }

    /// Directory where audio recordings are stored on disk.
    /// Used by `pruneOrphanedAudio()` to find unreferenced files.
    private var audioDirectory: URL {
        let dir = voiceDirectory.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Apply private modes through owned, no-follow descriptors. A symlink
    /// or unexpected file owner is an error, never a target for chmod.
    private func secureStoragePermissions(createDatabase: Bool) throws {
        let descriptor = open(voiceDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.permissionError() }
        defer { close(descriptor) }
        var directoryInfo = stat()
        guard fstat(descriptor, &directoryInfo) == 0,
              directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              fchmod(descriptor, 0o700) == 0 else { throw Self.permissionError() }

        for name in ["voice.db", "voice.db-wal", "voice.db-shm", "voice.db.backup"] {
            var file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if file < 0 && errno == ENOENT {
                guard createDatabase && name == "voice.db" else { continue }
                file = openat(descriptor, name,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            guard file >= 0 else { throw Self.permissionError() }
            defer { close(file) }
            var info = stat()
            guard fstat(file, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG,
                  fchmod(file, 0o600) == 0 else { throw Self.permissionError() }
        }
    }

    private static func permissionError() -> NSError {
        NSError(domain: "Voice.Storage", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Flow history could not be opened privately. Original files have been preserved."])
    }

    // MARK: - Initialization

    /// Open (or create) the database, configure pragmas, run migrations,
    /// verify integrity, and refresh the backup if it's older than 24h.
    /// Safe to call exactly once at app launch.
    func initialize() throws {
        try secureStoragePermissions(createDatabase: true)
        defer { try? secureStoragePermissions(createDatabase: false) }
        // Check the existing database before opening it for writes. Preserve
        // original data and sidecars if recovery is needed.
        try recoverIfCorrupt()

        var config = Configuration()
        // WAL + NORMAL synchronous: fast writes that survive crashes
        // (only loses txns from the last few ms before a power loss).
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbPool = try DatabasePool(path: databasePath, configuration: config)
        do {
            try migrate()
            try refreshBackupIfStale()
            try secureStoragePermissions(createDatabase: false)
        } catch {
            dbPool = nil
            throw error
        }
    }

    // MARK: - Schema Migration
    //
    // We use GRDB's DatabaseMigrator (which is backed by sqlite_master inspection
    // and is equivalent in spirit to a `user_version` PRAGMA — it's idempotent
    // and tracks applied migrations in a `grdb_migrations` table). Each ALTER
    // step is wrapped in a transaction by GRDB. New migrations are append-only.

    private func migrate() throws {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        var migrator = DatabaseMigrator()

        // -------- v1: initial schema --------
        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "meetings") { t in
                t.primaryKey("id", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "Untitled Meeting")
                t.column("date", .datetime).notNull()
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("audioFilePath", .text)
            }

            try db.create(table: "segments") { t in
                t.primaryKey("id", .text).notNull()
                t.column("meetingId", .text).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("speaker", .text).notNull()
                t.column("text", .text).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("confidence", .double)
            }

            try db.create(table: "summaries") { t in
                t.primaryKey("id", .text).notNull()
                t.column("meetingId", .text).notNull().unique()
                    .references("meetings", onDelete: .cascade)
                t.column("overview", .text).notNull()
                t.column("keyDecisionsJson", .text).notNull()
                t.column("actionItemsJson", .text).notNull()
                t.column("openQuestionsJson", .text).notNull()
            }

            // FTS5 virtual table mirroring segments. GRDB's `synchronize`
            // installs INSERT/UPDATE/DELETE triggers that keep the index
            // in lockstep with the source table.
            try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
                t.synchronize(withTable: "segments")
                t.tokenizer = .unicode61()
                t.column("text")
                t.column("speaker")
            }
        }

        // -------- v2: TranscriptSegment new columns --------
        // Idempotent because GRDB only runs unregistered migrations.
        migrator.registerMigration("v2_segment_columns") { db in
            try db.alter(table: "segments") { t in
                t.add(column: "speakerId", .text)
                t.add(column: "isFinal", .integer).notNull().defaults(to: 1)
            }
        }

        // -------- v3: Meeting new columns --------
        migrator.registerMigration("v3_meeting_columns") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "kind", .text).notNull().defaults(to: MeetingKind.meeting.rawValue)
                t.add(column: "markdownExportPath", .text)
                t.add(column: "tagsJson", .text).notNull().defaults(to: "[]")
                t.add(column: "pinnedNote", .text)
            }
        }

        // -------- v5: participantNames + speakerEventsJson --------
        // We use raw ALTER TABLE statements wrapped in try/catch so this
        // migration is idempotent on databases that may have had the
        // columns added out-of-band (e.g. by an earlier development build).
        // GRDB's `db.alter { t.add(...) }` would fail loudly if the column
        // already exists; raw SQL gives us the duplicate-column escape.
        migrator.registerMigration("v5_meeting_participants_and_events") { db in
            if try !db.columns(in: "meetings").contains(where: { $0.name == "participantNamesJson" }) {
                try db.execute(sql: "ALTER TABLE meetings ADD COLUMN participantNamesJson TEXT")
            }
            if try !db.columns(in: "meetings").contains(where: { $0.name == "speakerEventsJson" }) {
                try db.execute(sql: "ALTER TABLE meetings ADD COLUMN speakerEventsJson TEXT")
            }
        }

        // -------- v6: sourceApp persistence --------
        // Used by the dedup heuristic (rows within 30s of each other sharing
        // the same sourceApp are the same meeting captured twice) and by the
        // UI to show a friendly app label ("Meet", "Zoom", …) on the row.
        // Same idempotent ALTER pattern as v5.
        migrator.registerMigration("v6_meeting_source_app") { db in
            if try !db.columns(in: "meetings").contains(where: { $0.name == "sourceApp" }) {
                try db.execute(sql: "ALTER TABLE meetings ADD COLUMN sourceApp TEXT")
            }
        }

        // Record legacy imports before they can be deleted, without storing source text.
        migrator.registerMigration("v7_import_consumption_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE import_consumption_ledger (
                    source TEXT NOT NULL,
                    meetingId TEXT NOT NULL,
                    PRIMARY KEY (source, meetingId)
                )
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO import_consumption_ledger (source, meetingId)
                SELECT sourceApp, id FROM meetings WHERE sourceApp = 'wispr-flow-export-v1'
                """)
        }

        // -------- v8: cleaned text of a dictation --------
        // Segments hold what the speech model heard. This holds what was
        // pasted after cleanup, so history readers can show both. Nullable:
        // older rows and meetings have no value. Same idempotent ALTER as v5.
        migrator.registerMigration("v8_meeting_final_text") { db in
            if try !db.columns(in: "meetings").contains(where: { $0.name == "finalText" }) {
                try db.execute(sql: "ALTER TABLE meetings ADD COLUMN finalText TEXT")
            }
        }

        try migrator.migrate(db)
    }

    // MARK: - Backup & Recovery

    /// Copy the current database file to `voice.db.backup` if no backup
    /// exists or the existing one is older than 24 hours. Best-effort:
    /// failures are logged but not thrown — a stale backup is preferable
    /// to a failed launch.
    private func refreshBackupIfStale() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databasePath) else { return }

        let needsBackup: Bool
        if let attrs = try? fm.attributesOfItem(atPath: backupPath),
           let modDate = attrs[.modificationDate] as? Date {
            needsBackup = Date().timeIntervalSince(modDate) > 24 * 3600
        } else {
            needsBackup = true
        }

        guard needsBackup else { return }

        // SQLite's backup API takes a consistent snapshot including committed WAL
        // frames. Copying voice.db alone can silently omit recent recordings.
        let tempPath = backupPath + ".tmp-" + UUID().uuidString
        // SQLite normally creates files under the process umask. Precreate
        // this owned private backup without changing the global umask.
        let privateFile = open(tempPath, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard privateFile >= 0 else {
            NSLog("[Voice/Storage] could not create private backup snapshot")
            return
        }
        close(privateFile)
        defer { try? fm.removeItem(atPath: tempPath) }
        var source: OpaquePointer?
        var destination: OpaquePointer?
        defer {
            if let source { sqlite3_close(source) }
            if let destination { sqlite3_close(destination) }
        }
        guard sqlite3_open_v2(databasePath, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let source else {
            NSLog("[Voice/Storage] could not open source for backup")
            return
        }
        guard sqlite3_open_v2(tempPath, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let destination else {
            NSLog("[Voice/Storage] could not create backup snapshot")
            return
        }
        sqlite3_busy_timeout(source, 5000)
        sqlite3_busy_timeout(destination, 5000)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            NSLog("[Voice/Storage] could not initialize backup snapshot")
            return
        }
        let result = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            NSLog("[Voice/Storage] snapshot failed (step %d, finish %d)", result, finishResult)
            return
        }
        // Publish only the completed snapshot; rename is atomic on this volume.
        guard rename(tempPath, backupPath) == 0 else {
            NSLog("[Voice/Storage] could not publish backup snapshot")
            return
        }

    }

    /// Check the existing DB. On failure preserve the database and sidecars
    /// and surface an error rather than automatically replacing user data.
    private func recoverIfCorrupt() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databasePath) else { return }

        // Open in a temporary pool just for the check, so we don't pollute
        // the real pool's configuration.
        let tempPool: DatabasePool
        do {
            tempPool = try DatabasePool(path: databasePath)
        } catch {
            // Preserve the database and any WAL sidecars for manual recovery.
            // Replacing only the main file while WAL/SHM exist can lose data.
            throw error
        }

        // A failed read is not evidence of corruption. Preserve the actual
        // permission, I/O or SQLite error for safe diagnostics and retry.
        let healthy: Bool = try tempPool.read { db -> Bool in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? ""
            return result.lowercased() == "ok"
        }

        if !healthy {
            // Never overwrite a damaged database automatically. Its WAL may
            // contain recoverable changes, and the last backup may be older.
            throw NSError(domain: "Voice.Storage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The Flow database needs recovery. Original files and backups have been preserved."])
        }
    }

    // MARK: - CRUD Operations
    //
    // Every multi-row write goes through `db.write { ... }`, which GRDB
    // implements as `BEGIN IMMEDIATE; ... ; COMMIT`. Any thrown error
    // inside the block triggers ROLLBACK automatically, so partial
    // writes never reach disk.

    /// Insert or replace a meeting plus all of its segments and summary.
    /// Atomic: a failure on any row rolls back the whole save.
    ///
    /// Each recording retains its identity; only the same ID is updated.
    func saveMeeting(_ meeting: Meeting) throws {
        _ = try saveMeeting(meeting, onlyIfAbsent: false)
    }

    /// Import without ever replacing a recording or edits already in history.
    /// The existence check and insert share one write transaction.
    @discardableResult
    func insertMeetingIfAbsent(_ meeting: Meeting) throws -> Bool {
        try saveMeeting(meeting, onlyIfAbsent: true)
    }

    /// Consume the source ID atomically with the insert. The ledger survives
    /// deletion of the meeting, so retries cannot resurrect it.
    @discardableResult
    func insertImportedMeetingIfAbsent(_ meeting: Meeting, source: String) throws -> Bool {
        try saveMeeting(meeting, onlyIfAbsent: true, importSource: source)
    }

    private func saveMeeting(_ meeting: Meeting, onlyIfAbsent: Bool, importSource: String? = nil) throws -> Bool {
        guard let db = dbPool else { throw Self.storageUnavailable() }

        // Distinct recordings retain their own identity, even when created close together.
        let writeId = meeting.id

        let saved: Bool = try db.write { db in
            if let source = importSource {
                let consumed = try Int.fetchOne(db, sql: "SELECT 1 FROM import_consumption_ledger WHERE source = ? AND meetingId = ? LIMIT 1", arguments: [source, writeId.uuidString]) != nil
                if consumed { return false }
                // Inserting this before the meeting is safe: both share this
                // transaction and any later failure rolls the ledger back too.
                try db.execute(sql: "INSERT INTO import_consumption_ledger (source, meetingId) VALUES (?, ?)", arguments: [source, writeId.uuidString])
            }
            if onlyIfAbsent, try Int.fetchOne(db, sql: "SELECT 1 FROM meetings WHERE id = ? LIMIT 1", arguments: [writeId.uuidString]) != nil {
                return false
            }
            let tagsJson = (try? String(data: JSONEncoder().encode(meeting.tags), encoding: .utf8)) ?? "[]"
            // v5: JSON-encode participant names. Empty list serializes as
            // "[]" so the column is never NULL on writes from this code
            // path (older rows may still be NULL — the fetch side handles
            // that with a `decodeIfPresent`-style fallback).
            let participantNamesJson = (try? String(
                data: JSONEncoder().encode(meeting.participantNames),
                encoding: .utf8
            )) ?? "[]"

            try db.execute(
                sql: """
                INSERT INTO meetings
                    (id, title, date, duration, audioFilePath,
                     kind, markdownExportPath, tagsJson, pinnedNote,
                     participantNamesJson, speakerEventsJson, sourceApp, finalText)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, date=excluded.date, duration=excluded.duration, audioFilePath=excluded.audioFilePath, kind=excluded.kind, markdownExportPath=excluded.markdownExportPath, tagsJson=excluded.tagsJson, pinnedNote=excluded.pinnedNote, participantNamesJson=excluded.participantNamesJson, speakerEventsJson=excluded.speakerEventsJson, sourceApp=excluded.sourceApp, finalText=COALESCE(excluded.finalText, meetings.finalText)
                """,
                arguments: [
                    writeId.uuidString,
                    meeting.title,
                    meeting.date,
                    meeting.duration,
                    meeting.audioFilePath,
                    meeting.kind.rawValue,
                    meeting.markdownExportPath,
                    tagsJson,
                    meeting.pinnedNote,
                    participantNamesJson,
                    meeting.speakerEventsJson,
                    meeting.sourceApp,
                    meeting.finalText
                ]
            )

            // Upsert segments without cascading deletion of existing history.
            for segment in meeting.segments {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO segments
                        (id, meetingId, speaker, text, startTime, endTime,
                         confidence, speakerId, isFinal)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        segment.id.uuidString,
                        writeId.uuidString,
                        segment.speaker,
                        segment.text,
                        segment.startTime,
                        segment.endTime,
                        segment.confidence,
                        segment.speakerId,
                        segment.isFinal ? 1 : 0
                    ]
                )
            }

            if let summary = meeting.summary {
                let decisionsJson = try JSONEncoder().encode(summary.keyDecisions)
                let actionsJson = try JSONEncoder().encode(summary.actionItems)
                let questionsJson = try JSONEncoder().encode(summary.openQuestions)

                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO summaries
                        (id, meetingId, overview, keyDecisionsJson,
                         actionItemsJson, openQuestionsJson)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString,
                        writeId.uuidString,
                        summary.overview,
                        String(data: decisionsJson, encoding: .utf8),
                        String(data: actionsJson, encoding: .utf8),
                        String(data: questionsJson, encoding: .utf8)
                    ]
                )
            }
            return true
        }
        if saved { onChange?(meeting.kind) }
        return saved
    }

    /// The newest dictation row's id (for the pill's "Retry" and "Insert" buttons).
    func latestDictationID() throws -> UUID? {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        return try db.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM meetings WHERE kind = ? ORDER BY date DESC LIMIT 1",
                                arguments: [MeetingKind.dictation.rawValue]).flatMap(UUID.init(uuidString:))
        }
    }

    /// One row with its segments and summary, or nil when the id is unknown.
    func fetchMeeting(id: UUID) throws -> Meeting? {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        return try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM meetings WHERE id = ?",
                                             arguments: [id.uuidString]) else { return nil }
            return try meeting(from: row, in: db)
        }
    }

    /// Record the cleaned text a dictation pasted. Only dictation rows are
    /// touched. Returns false when there is no such dictation row.
    @discardableResult
    func setFinalText(meetingId: UUID, text: String?) throws -> Bool {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        let updated: Bool = try db.write { db in
            try db.execute(sql: "UPDATE meetings SET finalText = ? WHERE id = ? AND kind = ?",
                           arguments: [text, meetingId.uuidString, MeetingKind.dictation.rawValue])
            return db.changesCount > 0
        }
        if updated { onChange?(.dictation) }
        return updated
    }

    /// Replace what a dictation says after it was transcribed again: its
    /// segments and its cleaned text change together or not at all. The audio,
    /// date, title and tags stay as they were. Returns false when there is no
    /// such dictation row.
    @discardableResult
    func replaceDictationTranscript(id: UUID, segments: [TranscriptSegment], finalText: String?) throws -> Bool {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        let replaced: Bool = try db.write { db in
            try db.execute(sql: "UPDATE meetings SET finalText = ? WHERE id = ? AND kind = ?",
                           arguments: [finalText, id.uuidString, MeetingKind.dictation.rawValue])
            guard db.changesCount > 0 else { return false }
            try db.execute(sql: "DELETE FROM segments WHERE meetingId = ?", arguments: [id.uuidString])
            for segment in segments {
                try db.execute(
                    sql: """
                    INSERT INTO segments
                        (id, meetingId, speaker, text, startTime, endTime,
                         confidence, speakerId, isFinal)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [segment.id.uuidString, id.uuidString, segment.speaker, segment.text,
                                segment.startTime, segment.endTime, segment.confidence,
                                segment.speakerId, segment.isFinal ? 1 : 0])
            }
            return true
        }
        if replaced { onChange?(.dictation) }
        return replaced
    }

    /// Fetch every meeting, newest first, with segments and summary inlined.
    func fetchAllMeetings() throws -> [Meeting] {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM meetings ORDER BY date DESC")
            return try rows.map { try meeting(from: $0, in: db) }
        }
    }

    /// Most recent N meetings (date DESC). Convenience wrapper.
    func recentMeetings(limit: Int = 20) throws -> [Meeting] {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM meetings ORDER BY date DESC LIMIT ?",
                arguments: [limit]
            )
            return try rows.map { try meeting(from: $0, in: db) }
        }
    }

    /// Filter meetings by kind (`.dictation` or `.meeting`), newest first.
    func meetingsByKind(_ kind: MeetingKind) throws -> [Meeting] {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM meetings WHERE kind = ? ORDER BY date DESC",
                arguments: [kind.rawValue]
            )
            return try rows.map { try meeting(from: $0, in: db) }
        }
    }

    /// Delete history first, then remove its unshared managed audio. If the
    /// filesystem operation fails, report that the row was already deleted.
    func deleteMeeting(id: UUID) throws {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        let (audioPath, deletedKind): (String?, MeetingKind?) = try db.write { db in
            let path = try String.fetchOne(
                db, sql: "SELECT audioFilePath FROM meetings WHERE id = ?",
                arguments: [id.uuidString]
            )
            let kind = try self.kind(of: id, in: db)
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id.uuidString])
            return (path, kind)
        }
        // The row is gone whether or not its audio can be removed below.
        if let deletedKind { onChange?(deletedKind) }
        guard let path = audioPath, !path.isEmpty else { return }

        do {
            // Hold the writer lock while checking references and removing audio,
            // so another row cannot attach the same path between those steps.
            try db.write { db in
                let references = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM meetings WHERE audioFilePath = ?",
                    arguments: [path]
                ) ?? 0
                guard references == 0 else { return }
                let audioRoot = audioDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                guard file.path.hasPrefix(audioRoot) else {
                    throw NSError(domain: "Voice.Storage", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Audio is outside the Flow recordings folder and was kept."])
                }
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }
        } catch {
            throw NSError(domain: "Voice.Storage", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Meeting history was deleted, but its audio was kept: \(error.localizedDescription)", NSUnderlyingErrorKey: error])
        }
    }

    /// Delete a meeting row (and its segments/summary via cascade) WITHOUT
    /// touching the audio file on disk. Used by the dedup pass when two
    /// rows share a WAV: only one row should disappear, the file stays
    /// because the winner row still references it.
    func deleteMeetingRowKeepingAudio(id: UUID) throws {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        let deletedKind: MeetingKind? = try db.write { db in
            let kind = try self.kind(of: id, in: db)
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id.uuidString])
            return kind
        }
        if let deletedKind { onChange?(deletedKind) }
    }

    /// The kind of an existing row, or nil when there is no such row.
    private func kind(of id: UUID, in db: Database) throws -> MeetingKind? {
        guard let raw = try String.fetchOne(db, sql: "SELECT kind FROM meetings WHERE id = ?",
                                            arguments: [id.uuidString]) else { return nil }
        return MeetingKind(rawValue: raw) ?? .meeting
    }

    // MARK: - Search

    /// Legacy full-text search returning whole meetings. Kept for callers
    /// that just want a list of matching meetings (e.g. the search UI in
    /// RecordingCoordinator).
    func searchTranscripts(query: String) throws -> [Meeting] {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        let safeQuery = sanitizeFTSQuery(query)
        guard !safeQuery.isEmpty else { return [] }

        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT s.meetingId
                FROM segments_fts fts
                JOIN segments s ON s.rowid = fts.rowid
                WHERE segments_fts MATCH ?
                ORDER BY rank
            """, arguments: [safeQuery])

            let meetingIds = rows.map { $0["meetingId"] as String }
            return try meetingIds.compactMap { meetingId in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM meetings WHERE id = ?",
                    arguments: [meetingId]
                ) else { return nil }
                return try self.meeting(from: row, in: db)
            }
        }
    }

    /// Full-text search returning hit-level results. Each hit carries the
    /// matching segment, a highlighted snippet, the BM25 rank (lower is
    /// better), and the parent meeting (without its segments inlined, to
    /// keep payload small — call `fetchAllMeetings` if you need them).
    func searchTranscripts(query: String, limit: Int = 50) throws -> [SearchHit] {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        let safeQuery = sanitizeFTSQuery(query)
        guard !safeQuery.isEmpty else { return [] }

        return try db.read { db in
            // bm25() — lower is more relevant. snippet() wraps matches in
            // « / » so callers can highlight without re-tokenizing.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    s.id           AS segmentId,
                    s.meetingId    AS meetingId,
                    s.speaker      AS speaker,
                    s.text         AS text,
                    s.startTime    AS startTime,
                    s.endTime      AS endTime,
                    s.confidence   AS confidence,
                    s.speakerId    AS speakerId,
                    s.isFinal      AS isFinal,
                    snippet(segments_fts, 0, '«', '»', '…', 12) AS snippet,
                    bm25(segments_fts) AS rank
                FROM segments_fts fts
                JOIN segments s ON s.rowid = fts.rowid
                WHERE segments_fts MATCH ?
                ORDER BY rank
                LIMIT ?
            """, arguments: [safeQuery, limit])

            return try rows.compactMap { row -> SearchHit? in
                let meetingId = row["meetingId"] as String
                guard let meetingRow = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM meetings WHERE id = ?",
                    arguments: [meetingId]
                ) else { return nil }

                // Build a lightweight meeting (no segments/summary inlined).
                let parent = try self.meetingHeader(from: meetingRow)

                let segment = TranscriptSegment(
                    id: UUID(uuidString: row["segmentId"]) ?? UUID(),
                    speaker: row["speaker"],
                    speakerId: row["speakerId"],
                    text: row["text"],
                    startTime: row["startTime"],
                    endTime: row["endTime"],
                    confidence: row["confidence"],
                    isFinal: ((row["isFinal"] as Int?) ?? 1) != 0
                )

                return SearchHit(
                    meeting: parent,
                    segment: segment,
                    snippet: row["snippet"] ?? "",
                    rank: row["rank"] ?? 0
                )
            }
        }
    }

    /// Strip characters that would make the FTS5 MATCH grammar choke
    /// (quotes, parens, colons). Falls back to a quoted phrase if the
    /// caller passed something that looks like free text rather than an
    /// FTS expression.
    private func sanitizeFTSQuery(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Strip dangerous chars; keep word chars, spaces, *, AND/OR/NOT.
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "*-_"))
        let cleaned = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        // Quote each token: FTS5 barewords reject "-" and treat AND/OR/NOT/NEAR
        // as operators, so "COVID-19" or a lone "NOT" would throw. A trailing
        // "*" stays outside the quotes to keep prefix search.
        let tokens: [String] = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { raw in
            let isPrefix = raw.hasSuffix("*")
            let word = raw.replacingOccurrences(of: "*", with: "")
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return "\"\(word)\"" + (isPrefix ? "*" : "")
        }
        return tokens.joined(separator: " ")
    }

    // MARK: - Tags & Notes

    /// Append `tag` to the meeting's tag list (deduped). No-op if the
    /// meeting doesn't exist or already has the tag.
    func addTag(meetingId: UUID, tag: String) throws {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        let tag = tag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        try db.write { db in
            var tags = try self.fetchTags(meetingId: meetingId, in: db)
            guard !tags.contains(tag) else { return }
            tags.append(tag)
            try self.writeTags(tags, meetingId: meetingId, in: db)
        }
        try notifyChanged(meetingId)
    }

    /// Remove `tag` from the meeting's tag list. No-op if absent.
    func removeTag(meetingId: UUID, tag: String) throws {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        try db.write { db in
            var tags = try self.fetchTags(meetingId: meetingId, in: db)
            tags.removeAll { $0 == tag }
            try self.writeTags(tags, meetingId: meetingId, in: db)
        }
        try notifyChanged(meetingId)
    }

    /// Set or clear (`nil`) the single user-pinned note shown above the
    /// transcript for a meeting.
    func setPinnedNote(meetingId: UUID, note: String?) throws {
        guard let db = dbPool else { throw Self.storageUnavailable() }
        try db.write { db in
            try db.execute(
                sql: "UPDATE meetings SET pinnedNote = ? WHERE id = ?",
                arguments: [note, meetingId.uuidString]
            )
        }
        try notifyChanged(meetingId)
    }

    private func notifyChanged(_ id: UUID) throws {
        guard let onChange, let db = dbPool else { return }
        if let kind = try db.read({ db in try self.kind(of: id, in: db) }) { onChange(kind) }
    }

    private func fetchTags(meetingId: UUID, in db: Database) throws -> [String] {
        let json = try String.fetchOne(
            db,
            sql: "SELECT tagsJson FROM meetings WHERE id = ?",
            arguments: [meetingId.uuidString]
        ) ?? "[]"
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    private func writeTags(_ tags: [String], meetingId: UUID, in db: Database) throws {
        let data = try JSONEncoder().encode(tags)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        try db.execute(
            sql: "UPDATE meetings SET tagsJson = ? WHERE id = ?",
            arguments: [json, meetingId.uuidString]
        )
    }

    // MARK: - Audio retention

    /// Public read-only view of the audio directory URL so callers
    /// (RecordingCoordinator) can place new files there and the pruner
    /// can find them.
    var audioDirectoryURL: URL { audioDirectory }

    /// Map of normalized segment text → audioFilePath, used by the
    /// `--rerun-audio` harness to bridge a `RecentDictation` (which stores no
    /// audio path) to its retained `.caf`. The segments table stores the raw
    /// Parakeet text, which equals `RecentDictation.parakeetRawText`, so a
    /// normalized-text lookup resolves the audio file. Read-only.
    func audioPathsByNormalizedSegmentText() -> [String: String] {
        guard let db = dbPool else { return [:] }
        func norm(_ s: String) -> String {
            s.lowercased().split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        return (try? db.read { db -> [String: String] in
            var out: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.text AS text, m.audioFilePath AS audioFilePath
                FROM segments s JOIN meetings m ON m.id = s.meetingId
                WHERE m.audioFilePath IS NOT NULL
                """)
            for r in rows {
                let path: String? = r["audioFilePath"]
                let text: String? = r["text"]
                guard let p = path, !p.isEmpty, let t = text else { continue }
                out[norm(t)] = p   // last write wins; fine for our purpose
            }
            return out
        }) ?? [:]
    }

    /// Disk-safety pruner. If the total size of `audioDirectory` exceeds
    /// `highWatermark` bytes, deletes the oldest audio files (by modification
    /// date) until total drops below `lowWatermark`. Skips files that are
    /// still referenced by a meeting row only if `respectReferences` is true;
    /// otherwise size-based eviction wins (oldest first).
    ///
    /// Safe to call on a background queue; does not touch the DB.
    /// Returns (bytesRemoved, filesRemoved).
    @discardableResult
    func pruneAudioBySize(
        highWatermark: Int = 5 * 1024 * 1024 * 1024,   // 5 GB
        lowWatermark: Int  = 4 * 1024 * 1024 * 1024    // 4 GB
    ) -> (bytesRemoved: Int, filesRemoved: Int) {
        // Recordings are user data. Never evict them automatically.
        return (0, 0)
    }

    /// Scan the audio directory and delete any `.caf`/`.wav`/`.m4a` files
    /// that aren't referenced by a meeting row. Returns the number of
    /// files removed. Safe to call any time; cheap (single DB query +
    /// directory listing).
    @discardableResult
    func pruneOrphanedAudio() throws -> Int {
        // An unreferenced recording may be a recovery file or in-flight capture.
        return 0
    }

    // MARK: - Export

    /// Build a Markdown document from a meeting (title, summary, full transcript).
    func exportAsMarkdown(_ meeting: Meeting) -> String {
        var md = "# \(meeting.title)\n"
        md += "**Date:** \(meeting.date.formatted())\n"
        md += "**Duration:** \(Int(meeting.duration / 60)) minutes\n"
        md += "**Speakers:** \(meeting.speakerCount)\n\n"

        if let pin = meeting.pinnedNote, !pin.isEmpty {
            md += "> \(pin)\n\n"
        }

        if !meeting.tags.isEmpty {
            md += "**Tags:** " + meeting.tags.map { "`\($0)`" }.joined(separator: " ") + "\n\n"
        }

        if let summary = meeting.summary {
            md += "## Summary\n\(summary.overview)\n\n"

            if !summary.keyDecisions.isEmpty {
                md += "## Key Decisions\n"
                summary.keyDecisions.forEach { md += "- \($0)\n" }
                md += "\n"
            }

            if !summary.actionItems.isEmpty {
                md += "## Action Items\n"
                summary.actionItems.forEach { item in
                    let check = item.isCompleted ? "[x]" : "[ ]"
                    md += "- \(check) \(item.text)"
                    if let assignee = item.assignee { md += " — \(assignee)" }
                    md += "\n"
                }
                md += "\n"
            }
        }

        md += "## Transcript\n\n"
        for segment in meeting.segments {
            md += "**\(segment.speaker)** (\(segment.formattedTimestamp))\n"
            md += "\(segment.text)\n\n"
        }
        return md
    }

    /// Encode a meeting as JSON. Reflects the full v3 schema.
    func exportAsJSON(_ meeting: Meeting) throws -> Data {
        try JSONEncoder().encode(meeting)
    }

    // MARK: - Private Helpers

    /// Build a full Meeting (with segments + summary) from a `meetings` row.
    private func meeting(from row: Row, in db: Database) throws -> Meeting {
        let meetingId = row["id"] as String
        let segments = try fetchSegments(for: meetingId, in: db)
        let summary = try fetchSummary(for: meetingId, in: db)
        let tags = decodeTags(row["tagsJson"] as String?)
        let kind = MeetingKind(rawValue: (row["kind"] as String?) ?? "") ?? .meeting
        let participantNames = decodeStringArray(row["participantNamesJson"] as String?)

        return Meeting(
            id: UUID(uuidString: meetingId) ?? UUID(),
            title: row["title"],
            date: row["date"],
            duration: row["duration"],
            segments: segments,
            summary: summary,
            audioFilePath: row["audioFilePath"],
            kind: kind,
            markdownExportPath: row["markdownExportPath"],
            tags: tags,
            pinnedNote: row["pinnedNote"],
            sourceApp: row["sourceApp"] as String?,
            participantNames: participantNames,
            speakerEventsJson: row["speakerEventsJson"] as String?,
            finalText: row["finalText"] as String?
        )
    }

    /// Build a Meeting "header" (no segments/summary) from a row.
    /// Used by search hits where we don't want to load every segment.
    private func meetingHeader(from row: Row) throws -> Meeting {
        let meetingId = row["id"] as String
        let tags = decodeTags(row["tagsJson"] as String?)
        let kind = MeetingKind(rawValue: (row["kind"] as String?) ?? "") ?? .meeting
        let participantNames = decodeStringArray(row["participantNamesJson"] as String?)

        return Meeting(
            id: UUID(uuidString: meetingId) ?? UUID(),
            title: row["title"],
            date: row["date"],
            duration: row["duration"],
            segments: [],
            summary: nil,
            audioFilePath: row["audioFilePath"],
            kind: kind,
            markdownExportPath: row["markdownExportPath"],
            tags: tags,
            pinnedNote: row["pinnedNote"],
            sourceApp: row["sourceApp"] as String?,
            participantNames: participantNames,
            speakerEventsJson: row["speakerEventsJson"] as String?,
            finalText: row["finalText"] as String?
        )
    }

    private func decodeTags(_ json: String?) -> [String] {
        guard let json, !json.isEmpty else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    /// Decode a JSON-encoded `[String]` column. Returns `[]` for nil, empty,
    /// or unparseable values so pre-v5 rows continue to load cleanly.
    private func decodeStringArray(_ json: String?) -> [String] {
        guard let json, !json.isEmpty else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    private func fetchSegments(for meetingId: String, in db: Database) throws -> [TranscriptSegment] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM segments WHERE meetingId = ? ORDER BY startTime",
            arguments: [meetingId]
        )
        return rows.map { row in
            TranscriptSegment(
                id: UUID(uuidString: row["id"]) ?? UUID(),
                speaker: row["speaker"],
                speakerId: row["speakerId"],
                text: row["text"],
                startTime: row["startTime"],
                endTime: row["endTime"],
                confidence: row["confidence"],
                isFinal: ((row["isFinal"] as Int?) ?? 1) != 0
            )
        }
    }

    private func fetchSummary(for meetingId: String, in db: Database) throws -> MeetingSummary? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM summaries WHERE meetingId = ?",
            arguments: [meetingId]
        ) else {
            return nil
        }

        let decisions = try JSONDecoder().decode(
            [String].self,
            from: (row["keyDecisionsJson"] as String).data(using: .utf8)!
        )
        let actions = try JSONDecoder().decode(
            [ActionItem].self,
            from: (row["actionItemsJson"] as String).data(using: .utf8)!
        )
        let questions = try JSONDecoder().decode(
            [String].self,
            from: (row["openQuestionsJson"] as String).data(using: .utf8)!
        )

        return MeetingSummary(
            overview: row["overview"],
            keyDecisions: decisions,
            actionItems: actions,
            openQuestions: questions
        )
    }

    // MARK: - Self tests
    //
    // Not wired into a test target. Call manually from a debug menu when
    // you want to smoke-check the storage layer end-to-end.

    #if DEBUG
    /// Build a throwaway DB in a temp dir, exercise the full surface,
    /// assert search + cascade delete behave. Throws on first failure.
    static func runSelfTests() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(
            path: tmp.appendingPathComponent("voice.db").path,
            configuration: config
        )

        // We can't reuse `migrate()` because it needs a real instance, so
        // run a minimal copy here. (Trade-off: this stub validates the
        // wiring but isn't a substitute for an XCTest target.)
        let svc = StorageService()
        svc.dbPool = pool
        try svc.migrate()

        // Insert 3 meetings, each with one segment.
        for i in 0..<3 {
            let m = Meeting(
                title: "Meeting \(i)",
                duration: 60,
                segments: [
                    TranscriptSegment(
                        speaker: "Speaker \(i)",
                        text: i == 1 ? "the quick brown fox" : "filler text \(i)",
                        startTime: 0,
                        endTime: 1
                    )
                ],
                kind: .meeting
            )
            try svc.saveMeeting(m)
        }

        // Search hits the middle meeting.
        let hits = try svc.searchTranscripts(query: "brown", limit: 10)
        guard hits.count == 1, hits[0].meeting.title == "Meeting 1" else {
            throw NSError(domain: "Voice.StorageService.SelfTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "search expected 1 hit, got \(hits.count)"])
        }

        // Delete cascade.
        try svc.deleteMeeting(id: hits[0].meeting.id)
        let postDelete = try svc.searchTranscripts(query: "brown", limit: 10)
        guard postDelete.isEmpty else {
            throw NSError(domain: "Voice.StorageService.SelfTest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "delete cascade leaked \(postDelete.count) hits"])
        }

        let remaining = try svc.fetchAllMeetings()
        guard remaining.count == 2 else {
            throw NSError(domain: "Voice.StorageService.SelfTest", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "expected 2 remaining meetings, got \(remaining.count)"])
        }
    }
    #endif
}
