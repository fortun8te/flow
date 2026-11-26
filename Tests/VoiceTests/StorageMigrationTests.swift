import Foundation
import GRDB
import Testing
@testable import Voice

struct StorageMigrationTests {
    @Test func addsQueryIndexesToExistingHistoryWithoutChangingRecordings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Indexed history fixture", segments: [.init(text: "violet kettle", startTime: 0, endTime: 1)])
        var original: StorageService? = StorageService(directory: root)
        try original?.initialize()
        try original?.saveMeeting(meeting)
        original = nil

        var setup: DatabaseQueue? = try DatabaseQueue(path: root.appendingPathComponent("voice.db").path)
        try setup?.write { db in
            for index in ["segments_meeting_time", "meetings_date", "meetings_kind_date", "meetings_audio_path"] {
                try db.execute(sql: "DROP INDEX \(index)")
            }
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v9_history_query_indexes'")
        }
        setup = nil

        let upgraded = StorageService(directory: root)
        try upgraded.initialize()
        #expect(try upgraded.fetchMeeting(id: meeting.id)?.segments.map(\.text) == ["violet kettle"])
        let inspection = try DatabaseQueue(path: root.appendingPathComponent("voice.db").path)
        try inspection.read { db in
            let indexes = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
            #expect(indexes.isSuperset(of: ["segments_meeting_time", "meetings_date", "meetings_kind_date", "meetings_audio_path"]))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v9_history_query_indexes'") == 1)
        }
    }

    @Test func upgradesExistingHistoryAndSeedsConsumedImports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var legacy: StorageService? = StorageService(directory: root)
        try legacy?.initialize()
        let id = WisprMeetingImportService.stableID("pre-ledger-meeting")
        let source = WisprMeetingImportService.sourceMarker
        let meeting = Meeting(id: id, title: "Retained history", date: Date(), duration: 1,
            segments: [], summary: nil, kind: .meeting, sourceApp: source)
        try legacy?.saveMeeting(meeting)
        legacy = nil

        // Recreate the deployed v6 state, which has existing history but no
        // import ledger. This is a temporary fixture, never the user's store.
        var setup: DatabaseQueue? = try DatabaseQueue(path: root.appendingPathComponent("voice.db").path)
        try setup?.write { db in
            try db.execute(sql: "DROP TABLE import_consumption_ledger")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                           arguments: ["v7_import_consumption_ledger"])
        }
        setup = nil

        let upgraded = StorageService(directory: root)
        try upgraded.initialize()
        let meetings = try upgraded.fetchAllMeetings()
        let stored = try #require(meetings.first)
        #expect(stored.id == id)
        #expect(stored.title == "Retained history")
        try upgraded.deleteMeeting(id: id)
        let reinserted = try upgraded.insertImportedMeetingIfAbsent(meeting, source: source)
        #expect(!reinserted)
        #expect(try upgraded.fetchAllMeetings().isEmpty)
    }
}
