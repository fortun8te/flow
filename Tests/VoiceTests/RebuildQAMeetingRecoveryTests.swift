import Foundation
import Testing
@testable import Voice

@MainActor
@Suite("Meeting recovery preserves intent", .serialized)
struct RebuildQAMeetingRecoveryTests {
    private func withRecoveryEnabled(_ body: () throws -> Void) rethrows {
        let key = "voice.skipMeetingRecovery"
        let old = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try body()
    }

    @Test("A short recovered meeting stays a meeting")
    func shortMeeting() throws {
        try withRecoveryEnabled {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let storage = StorageService(directory: root)
            try storage.initialize()
            let recovery = MeetingRecoveryService(storage: storage, transcription: TranscriptionService())
            let orphan = OrphanedMeetingAudio(id: UUID(), audioFileURL: root.appendingPathComponent("meeting-synthetic.wav"), createdAt: Date(), durationSeconds: 30, sizeBytes: 1024)
            #expect(recovery.importOrphan(orphan))
            let meetings = try storage.fetchAllMeetings()
            #expect(meetings.count == 1)
            #expect(meetings.first?.kind == .meeting)
        }
    }

    @Test("Unavailable storage does not report successful recovery")
    func unavailableStorage() throws {
        try withRecoveryEnabled {
            let recovery = MeetingRecoveryService(storage: StorageService(), transcription: TranscriptionService())
            let orphan = OrphanedMeetingAudio(id: UUID(), audioFileURL: URL(fileURLWithPath: "/synthetic/meeting.wav"), createdAt: Date(), durationSeconds: 30, sizeBytes: 1024)
            #expect(!recovery.importOrphan(orphan))
        }
    }
}
