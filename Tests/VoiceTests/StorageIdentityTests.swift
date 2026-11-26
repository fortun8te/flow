import Foundation
import GRDB
import Testing
@testable import Voice

@Suite("Stored recording identity and indexed retrieval")
struct StorageIdentityTests {
    private func withStorage(_ body: (StorageService, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flow-storage-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(directory: root)
        try storage.initialize()
        try body(storage, root)
    }

    @Test("A segment ID cannot move to a different recording, and the entire save rolls back")
    func segmentOwnership() throws {
        try withStorage { storage, _ in
            let segment = TranscriptSegment(text: "violet kettle", startTime: 0, endTime: 1)
            let first = Meeting(title: "First fixture", segments: [segment])
            try storage.saveMeeting(first)
            let second = Meeting(title: "Second fixture", segments: [segment])
            #expect(throws: (any Error).self) { try storage.saveMeeting(second) }
            #expect(try storage.fetchMeeting(id: second.id) == nil)
            #expect(try storage.fetchMeeting(id: first.id)?.segments.map(\.id) == [segment.id])
            #expect(try storage.searchTranscripts(query: "violet").map(\.meeting.id) == [first.id])

            var changed = first
            changed.segments[0].text = "silver lantern"
            try storage.saveMeeting(changed)
            #expect(try storage.fetchMeeting(id: first.id)?.segments.map(\.text) == ["silver lantern"])
            #expect(try storage.searchTranscripts(query: "violet").isEmpty)
            #expect(try storage.searchTranscripts(query: "silver").count == 1)
        }
    }

    @Test("Multiline and punctuated queries retain word boundaries, and nonpositive limits stay empty")
    func searchBoundariesAndLimits() throws {
        try withStorage { storage, _ in
            let segments = [
                TranscriptSegment(text: "violet kettle near the harbor", startTime: 0, endTime: 1),
                TranscriptSegment(text: "violet kettle above the harbor", startTime: 1, endTime: 2),
            ]
            let meeting = Meeting(title: "Search fixture", segments: segments)
            try storage.saveMeeting(meeting)
            let hits = try storage.searchTranscripts(query: "violet\nkettle/harbor")
            #expect(hits.count == 2)
            #expect(hits.allSatisfy { $0.meeting.id == meeting.id && $0.meeting.segments.isEmpty })
            #expect(try storage.recentMeetings(limit: -1).isEmpty)
            #expect(try storage.searchTranscripts(query: "violet", limit: -1).isEmpty)
        }
    }

    @Test("Text lookup omits repeated recordings; exact identities retain their own audio paths")
    func ambiguousAudioText() throws {
        try withStorage { storage, _ in
            let first = Meeting(title: "One", segments: [.init(text: "violet kettle", startTime: 0, endTime: 1)], audioFilePath: "/fixture/one.caf")
            let second = Meeting(title: "Two", segments: [.init(text: "Violet\nkettle", startTime: 0, endTime: 1)], audioFilePath: "/fixture/two.caf")
            try storage.saveMeeting(first)
            try storage.saveMeeting(second)
            #expect(storage.audioPathsByNormalizedSegmentText()["violet kettle"] == nil)
            #expect(try storage.audioPath(forRecordingID: first.id) == "/fixture/one.caf")
            #expect(try storage.audioPath(forRecordingID: second.id) == "/fixture/two.caf")
        }
    }

    @Test("Query index migration is recorded without replacing existing history")
    func queryIndexes() throws {
        try withStorage { storage, root in
            let meeting = Meeting(title: "Retained fixture", segments: [.init(text: "violet kettle", startTime: 0, endTime: 1)])
            try storage.saveMeeting(meeting)
            let db = try DatabaseQueue(path: root.appendingPathComponent("voice.db").path)
            try db.read { db in
                let indexes = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
                #expect(indexes.isSuperset(of: ["segments_meeting_time", "meetings_date", "meetings_kind_date", "meetings_audio_path"]))
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v9_history_query_indexes'") == 1)
            }
            #expect(try storage.fetchMeeting(id: meeting.id)?.title == "Retained fixture")
        }
    }
}
