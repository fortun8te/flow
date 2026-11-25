import Foundation
import Testing
@testable import Voice

@Suite("Audio writer belongs to one recording (sol/01 finding 1)")
struct AudioWriterOwnershipTests {
    @Test("A finishing session cannot close the writer a newer recording has taken")
    func oldSessionLeavesNewWriterOpen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = AudioCaptureService()
        let older = folder.appendingPathComponent("older.caf")
        let newer = folder.appendingPathComponent("newer.caf")

        try capture.startWritingToFile(url: older)
        try capture.startWritingToFile(url: newer)   // the new recording takes over

        #expect(capture.isWritingToFile(newer))
        #expect(!capture.isWritingToFile(older))
        // The old session finishes late and asks to close its own file. Nothing should happen.
        #expect(capture.stopWritingToFile(ifURL: older) == false)
        #expect(capture.isWritingToFile(newer))
        // Its own file is closed when asked for by name.
        #expect(capture.stopWritingToFile(ifURL: newer) == true)
        #expect(!capture.isWritingToFile(newer))
        capture.stopWritingToFile()
    }
}
