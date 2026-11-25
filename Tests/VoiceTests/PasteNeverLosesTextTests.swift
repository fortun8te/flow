import AppKit
import XCTest
@testable import Voice

/// "Text sometimes disappears and it doesn't paste." (21 Nov 2026)
/// events.jsonl 2026-11-21T15:00:29Z: a 51 s hands-free dictation ended with
/// `paste.skipped target_app_changed` and "You switched apps. Dictation is in history." Nothing was
/// on the clipboard because auto-copy is off, so Cmd-V gave him his old clipboard.
final class PasteNeverLosesTextTests: XCTestCase {
    private typealias Target = CursorPaster.PasteTargetSnapshot

    func testTheAppInFrontWhenRecordingStopsIsTheTarget() {
        let started = Target(bundleId: "local.jordan.pcmonitor", focusedElement: nil)
        let stopped = Target(bundleId: "com.t3tools.t3code", focusedElement: nil)
        XCTAssertEqual(CursorPaster.targetForDelivery(started: started, stopped: stopped, ownBundleID: "com.example.flow")?.bundleId,
                       "com.t3tools.t3code")
    }

    func testSameAppKeepsTheFieldCapturedAtTheStart() {
        let started = Target(bundleId: "com.google.Chrome", focusedElement: AXUIElementCreateSystemWide())
        let stopped = Target(bundleId: "com.google.Chrome", focusedElement: nil)
        let chosen = CursorPaster.targetForDelivery(started: started, stopped: stopped, ownBundleID: "com.example.flow")
        XCTAssertNotNil(chosen?.focusedElement)
    }

    func testFlowsOwnWindowNeverBecomesTheTarget() {
        let started = Target(bundleId: "com.apple.Notes", focusedElement: nil)
        let stopped = Target(bundleId: "com.example.flow", focusedElement: nil)
        XCTAssertEqual(CursorPaster.targetForDelivery(started: started, stopped: stopped, ownBundleID: "com.example.flow")?.bundleId,
                       "com.apple.Notes")
        XCTAssertEqual(CursorPaster.targetForDelivery(started: nil, stopped: stopped, ownBundleID: "com.example.flow")?.bundleId, nil)
    }

    func testAFailedPasteLeavesTheDictationOnTheClipboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("flow-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("old clipboard", forType: .string)
        XCTAssertTrue(CursorPaster.keepForManualPaste("Six violet beads belong beside the lantern.", pasteboard: pb))
        XCTAssertEqual(pb.string(forType: .string), "Six violet beads belong beside the lantern.")
        XCTAssertFalse(CursorPaster.keepForManualPaste("   ", pasteboard: pb))
        XCTAssertEqual(pb.string(forType: .string), "Six violet beads belong beside the lantern.")
    }

    func testEveryDictationIsWrittenToTheTrainingLog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flow-training-\(UUID().uuidString)")
        DictationTrainingLog.directoryOverride = dir
        defer { DictationTrainingLog.directoryOverride = nil; try? FileManager.default.removeItem(at: dir) }
        DictationTrainingLog.append(DictationTrainingRecord(
            id: "C1A56609", recordedAt: Date(), app: "com.t3tools.t3code", audioPath: "/tmp/a.caf", durationSeconds: 51,
            asrRaw: "Uh meetings tab", rulesText: "Uh meetings tab", modelOutput: "Uh meetings tab",
            finalText: "Meetings tab", engine: "t4-step918", fallbackReason: "deadline", level: "light", style: "excited",
            pasteVerdict: "skipped"), synchronously: true)
        DictationTrainingLog.append(DictationTrainingRecord(kind: "edit", id: "C1A56609", recordedAt: Date(),
            finalText: "Meetings tab", editedField: "The meetings tab"), synchronously: true)
        let records = DictationTrainingLog.readAll()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].pasteVerdict, "skipped")
        XCTAssertEqual(records[0].modelOutput, "Uh meetings tab")
        XCTAssertEqual(records[1].kind, "edit")
        let mode = try FileManager.default.attributesOfItem(atPath: DictationTrainingLog.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
