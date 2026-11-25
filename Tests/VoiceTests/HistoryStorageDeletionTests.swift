import Foundation
import Testing
@testable import Voice

@Suite("Meeting audio deletion")
struct HistoryStorageDeletionTests {
    @Test("Shared recording survives deletion until last reference")
    func sharedAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(directory: root)
        try storage.initialize()
        let audio = storage.audioDirectoryURL.appendingPathComponent("synthetic.wav")
        try Data([1, 2, 3]).write(to: audio)
        let first = Meeting(title: "First", audioFilePath: audio.path)
        let second = Meeting(title: "Second", audioFilePath: audio.path)
        try storage.saveMeeting(first)
        try storage.saveMeeting(second)
        try storage.deleteMeeting(id: first.id)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        try storage.deleteMeeting(id: second.id)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("Audio outside managed folder is kept and partial deletion is reported")
    func outsideAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(directory: root.appendingPathComponent("store"))
        try storage.initialize()
        let audio = root.appendingPathComponent("outside.wav")
        try Data([1, 2, 3]).write(to: audio)
        let meeting = Meeting(title: "Synthetic", audioFilePath: audio.path)
        try storage.saveMeeting(meeting)
        do {
            try storage.deleteMeeting(id: meeting.id)
            Issue.record("Expected partial deletion error")
        } catch {
            #expect((error as NSError).code == 3)
        }
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(try storage.fetchAllMeetings().isEmpty)
    }
}
