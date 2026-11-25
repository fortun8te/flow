import Foundation
import GRDB
import Testing
@testable import Voice

struct StorageMigrationTests {
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
