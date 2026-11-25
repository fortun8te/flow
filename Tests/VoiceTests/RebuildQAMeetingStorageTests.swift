import Foundation
import Testing
@testable import Voice

@Suite("Meeting history availability")
struct RebuildQAMeetingStorageTests {
    @Test("Saving a meeting fails explicitly when history is unavailable")
    func unavailableHistoryDoesNotPretendToSave() {
        let storage = StorageService()
        let meeting = Meeting(title: "Synthetic meeting", duration: 12)
        do {
            try storage.saveMeeting(meeting)
            Issue.record("Saving without an initialized database must fail")
        } catch {
            let error = error as NSError
            #expect(error.domain == "Voice.Storage")
            #expect(error.code == 2)
        }
    }

    @Test("Deleting a meeting fails explicitly when history is unavailable")
    func unavailableHistoryDoesNotPretendToDelete() {
        let storage = StorageService()
        do {
            try storage.deleteMeeting(id: UUID())
            Issue.record("Deleting without an initialized database must fail")
        } catch {
            let error = error as NSError
            #expect(error.domain == "Voice.Storage")
            #expect(error.code == 2)
        }
    }
}
