import XCTest
import AppKit
@testable import Voice

final class FlowOwnershipTests: XCTestCase {
    @MainActor func testExclusiveLifetimeLockAndRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var first: FlowOwnership? = FlowOwnership(directory: root, applications: { [] })
        XCTAssertNil(first?.acquire())
        let second = FlowOwnership(directory: root, applications: { [] })
        XCTAssertNotNil(second.acquire())
        first = nil
        XCTAssertNil(second.acquire())
    }
    @MainActor func testRejectsSymbolicLinkDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let link = root.appendingPathExtension("link")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(FlowOwnership(directory: link, applications: { [] }).acquire())
    }
    @MainActor func testLegacyIdentityAndOwnProcessExclusion() {
        XCTAssertTrue(FlowOwnership.conflicts(bundleID: "local.jordan.pcmonitor.sender", executable: "Other", pid: 2, ownPID: 1))
        XCTAssertTrue(FlowOwnership.conflicts(bundleID: "com.example.flow.voice", executable: nil, pid: 2, ownPID: 1))
        XCTAssertFalse(FlowOwnership.conflicts(bundleID: "com.example.flow.voice", executable: "Voice", pid: 1, ownPID: 1))
        XCTAssertFalse(FlowOwnership.conflicts(bundleID: "com.electron.wispr", executable: "Wispr Flow", pid: 2, ownPID: 1))
        XCTAssertFalse(FlowOwnership.conflicts(bundleID: "local.jordan.pcmonitor.sender", executable: "Companion", pid: 2, ownPID: 1, verifiedPureClient: true))
        XCTAssertTrue(FlowOwnership.conflicts(bundleID: "com.example.flow.voice", executable: "Voice", pid: 2, ownPID: 1, verifiedPureClient: true))
    }
    @MainActor func testPureClientRequiresEveryIdentityCheck() {
        let hash = Data([1, 2, 3])
        XCTAssertTrue(FlowOwnership.verifiedClient(role: "client", staticValid: true, staticHash: hash, liveHash: hash))
        XCTAssertFalse(FlowOwnership.verifiedClient(role: nil, staticValid: true, staticHash: hash, liveHash: hash))
        XCTAssertFalse(FlowOwnership.verifiedClient(role: "backend", staticValid: true, staticHash: hash, liveHash: hash))
        XCTAssertFalse(FlowOwnership.verifiedClient(role: "client", staticValid: false, staticHash: hash, liveHash: hash))
        XCTAssertFalse(FlowOwnership.verifiedClient(role: "client", staticValid: true, staticHash: hash, liveHash: Data([4])))
        XCTAssertFalse(FlowOwnership.verifiedClient(role: "client", staticValid: true, staticHash: hash, liveHash: nil))
        XCTAssertFalse(FlowOwnership.verifiedClient(role: "client", staticValid: true, staticHash: Data(), liveHash: Data()))
    }
    @MainActor func testInterruptedAudioReferenceRemainsAvailableForHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = FlowOwnership(directory: root, applications: { [] })
        XCTAssertNil(owner.acquire())
        let audio = root.appendingPathComponent("saved.caf")
        try Data([1, 2, 3, 4]).write(to: audio)
        owner.retainRecoveryReference(audio)
        let records = owner.retainedRecordings()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.audioURL, audio)
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3, 4]))
    }

}
