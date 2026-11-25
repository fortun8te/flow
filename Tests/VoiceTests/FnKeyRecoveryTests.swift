import Foundation
import Testing
@testable import Voice

@Suite("Fn key recovery: latch carry-over, retry and counts")
struct FnKeyRecoveryTests {
    @Test("Rebuild while fn is held keeps the press alive, so the release is still handled")
    func heldAcrossRebuild() {
        let latch = FnKeyTap.latchAfterInstall(wasDown: true, heldNow: true)
        #expect(latch.down == true)
        #expect(latch.commitRelease == false)
    }

    @Test("Fn released during a rebuild commits the release once, so a recording cannot hang")
    func releasedDuringRebuild() {
        let latch = FnKeyTap.latchAfterInstall(wasDown: true, heldNow: false)
        #expect(latch.down == false)
        #expect(latch.commitRelease == true)
    }

    @Test("A fresh install with fn not held starts clean")
    func freshInstall() {
        let latch = FnKeyTap.latchAfterInstall(wasDown: false, heldNow: false)
        #expect(latch.down == false)
        #expect(latch.commitRelease == false)
    }

    @Test("A fresh install that finds fn already held starts with the latch set")
    func freshInstallHeld() {
        let latch = FnKeyTap.latchAfterInstall(wasDown: false, heldNow: true)
        #expect(latch.down == true)
        #expect(latch.commitRelease == false)
    }

    @Test("Stats list every event, with zero for ones that have not happened")
    func statsSnapshot() {
        let stats = FnKeyStats()
        stats.note(.swallowedFnPress)
        stats.note(.swallowedFnPress)
        let counts = stats.snapshot()
        #expect(counts[FnKeyEvent.swallowedFnPress.rawValue] == 2)
        #expect(counts[FnKeyEvent.disabledByTimeout.rawValue] == 0)
        #expect(Set(counts.keys) == Set(FnKeyEvent.allCases.map(\.rawValue)))
    }

    @Test("The stats file holds counts only and is written")
    func statsFileWritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FnKeyStats.directoryOverride = folder
        defer {
            FnKeyStats.directoryOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let stats = FnKeyStats()
        stats.note(.tapInstalled)
        stats.write()
        let data = try Data(contentsOf: FnKeyStats.fileURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let counts = object?["counts"] as? [String: Int]
        #expect(counts?[FnKeyEvent.tapInstalled.rawValue] == 1)
    }
}
