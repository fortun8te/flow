import Foundation
import Testing
@testable import Voice

struct WisprMeetingImportTests {
    @Test func importsOnceAndPreservesEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("meetings.json")
        let json = #"""
        {"schema_version":1,"meetings":[{"id":"source-1","title":"Original","created_at":"2026-01-01T12:00:00.000Z","recorded_ms":null,"ended_at":"2026-01-01T12:01:30.000Z","summary":"Source summary","notes":"Source note","segments":[{"timestamp":"01:02","text":"Hello","speaker":{"id":1,"name":null}}]}]}
        """#
        try Data(json.utf8).write(to: file)
        let storage = StorageService(directory: root.appendingPathComponent("store"))
        try storage.initialize()
        let firstResult = try WisprMeetingImportService.run(storage: storage, file: file)
        let first = try #require(firstResult)
        #expect(first.imported == 1 && first.existing == 0)
        var meeting = try #require(storage.fetchAllMeetings().first)
        #expect(meeting.kind == .meeting)
        #expect(meeting.sourceApp == WisprMeetingImportService.sourceMarker)
        #expect(meeting.audioFilePath == nil)
        #expect(meeting.duration == 90)
        #expect(meeting.segments.first?.speakerId == "1")
        #expect(meeting.summary?.overview == "Source summary")
        #expect(meeting.segments.first?.speaker == "Unknown")
        #expect(meeting.segments.first?.startTime == 62)
        meeting.title = "Edited"
        meeting.pinnedNote = "My note"
        try storage.saveMeeting(meeting)
        let againResult = try WisprMeetingImportService.run(storage: storage, file: file)
        let again = try #require(againResult)
        #expect(again.imported == 0 && again.existing == 1)
        let kept = try #require(storage.fetchAllMeetings().first)
        #expect(kept.title == "Edited" && kept.pinnedNote == "My note")
        #expect(kept.id == WisprMeetingImportService.stableID("source-1"))
    }
    @Test func retryDoesNotRestoreDeletedMeetingWhenAnotherRowWasSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("meetings.json")
        let json = #"""
        {"schema_version":1,"meetings":[{"id":"kept","created_at":"2026-01-01T12:00:00.000Z"},{"id":"invalid","created_at":"invalid"}]}
        """#
        try Data(json.utf8).write(to: file)
        let storage = StorageService(directory: root.appendingPathComponent("store"))
        try storage.initialize()
        let first = try #require(try WisprMeetingImportService.run(storage: storage, file: file))
        #expect(first.imported == 1 && first.skipped == 1)
        try storage.deleteMeeting(id: WisprMeetingImportService.stableID("kept"))
        let retry = try #require(try WisprMeetingImportService.run(storage: storage, file: file))
        #expect(retry.imported == 0 && retry.existing == 1 && retry.skipped == 1)
        #expect(try storage.fetchAllMeetings().isEmpty)
    }

    @Test func existingMeetingIsRecordedInLedgerBeforeDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("meetings.json")
        try Data(#"{"schema_version":1,"meetings":[{"id":"legacy","created_at":"2026-01-01T12:00:00Z"}]}"#.utf8).write(to: file)
        let storage = StorageService(directory: root.appendingPathComponent("store"))
        try storage.initialize()
        let id = WisprMeetingImportService.stableID("legacy")
        let meeting = Meeting(id: id, title: "Existing", date: Date(), duration: 1, segments: [], summary: nil, kind: .meeting, sourceApp: WisprMeetingImportService.sourceMarker)
        try storage.saveMeeting(meeting)
        let first = try #require(try WisprMeetingImportService.run(storage: storage, file: file))
        #expect(first.existing == 1 && first.imported == 0)
        try storage.deleteMeeting(id: id)
        let retry = try #require(try WisprMeetingImportService.run(storage: storage, file: file))
        #expect(retry.existing == 1 && retry.imported == 0)
        #expect(try storage.fetchAllMeetings().isEmpty)
    }
    @Test func rejectsUnknownVersionAndOversizedInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(directory: root.appendingPathComponent("store"))
        try storage.initialize()
        let file = root.appendingPathComponent("meetings.json")
        try Data(#"{"schema_version":2,"meetings":[]}"#.utf8).write(to: file)
        #expect(throws: WisprMeetingImportService.ImportError.self) { try WisprMeetingImportService.run(storage: storage, file: file) }
        try Data(repeating: 32, count: WisprMeetingImportService.maximumBytes + 1).write(to: file)
        #expect(throws: WisprMeetingImportService.ImportError.self) { try WisprMeetingImportService.run(storage: storage, file: file) }
        #expect(try storage.fetchAllMeetings().isEmpty)
    }
}
