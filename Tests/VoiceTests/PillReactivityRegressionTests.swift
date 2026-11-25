import XCTest
import AppKit
import SwiftUI
@testable import Voice

final class PillReactivityRegressionTests: XCTestCase {
    /// The real panel and pill: a pointer over the resting pill opens it straight away, and a
    /// native menu from it keeps it open until the menu closes.
    @MainActor func testPointerEntryOpensTheHostedIdlePillWithoutAnotherMouseEvent() async throws {
        _ = NSApplication.shared
        let state = RecordingState()
        let panel = OverlayPanel(recordingState: state, observesSystemChanges: false)
        panel.isReleasedWhenClosed = false
        panel.setFrame(NSRect(origin: NSPoint(x: -10000, y: -10000), size: PillLayout.panelSize), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        try await Task.sleep(for: .milliseconds(120))
        let host = try XCTUnwrap(panel.contentView)
        let band = panel.interactiveBand(in: host.bounds.size)
        XCTAssertFalse(band.isEmpty, "The resting pill reported no clickable area")
        let point = NSPoint(x: panel.frame.minX + band.midX, y: panel.frame.minY + band.midY)
        let start = ContinuousClock.now
        panel.handlePointerMotion(at: point)
        // Wispr's hover delay is 150 ms before the pill opens, so allow that plus margin.
        while !panel.idleExpanded && start.duration(to: .now) < .milliseconds(400) {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(panel.idleExpanded, "Pointer entry did not open the idle pill")
        print("PILL_REACTIVITY pointer-entry-to-ready \(start.duration(to: .now))")

        NotificationCenter.default.post(name: Notification.Name("flow.pillMenu"), object: nil, userInfo: ["open": true])
        let outside = NSPoint(x: panel.frame.maxX + 100, y: panel.frame.maxY + 100)
        panel.handlePointerMotion(at: outside)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertTrue(panel.idleExpanded, "Leaving the panel for its native menu collapsed the pill")
        NotificationCenter.default.post(name: Notification.Name("flow.pillMenu"), object: nil, userInfo: ["open": false])
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertFalse(panel.idleExpanded, "Closing the menu outside the panel left stale hover behind")

        let farStart = ContinuousClock.now
        for _ in 0..<10_000 { panel.handlePointerMotion(at: outside) }
        print("PILL_REACTIVITY 10000-far-pointer-events \(farStart.duration(to: .now))")
    }

    /// Uses the real NSPanel policy. The completion pill must remain clickable after
    /// the next pointer refresh, rather than only during its phase-change callback.
    @MainActor func testCompletedPolishRemainsClickableInsideItsVisibleBounds() async throws {
        let previousSuppression = Telemetry.isSuppressed
        Telemetry.isSuppressed = true
        defer { Telemetry.isSuppressed = previousSuppression }
        _ = NSApplication.shared
        let state = RecordingState()
        state.polishDiff = PolishDiff(original: "before", polished: "after")
        let panel = OverlayPanel(recordingState: state, observesSystemChanges: false)
        panel.isReleasedWhenClosed = false
        panel.setFrame(NSRect(origin: NSPoint(x: -10000, y: -10000), size: PillLayout.panelSize), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        try await Task.sleep(for: .milliseconds(80))
        let host = try XCTUnwrap(panel.contentView)
        let band = panel.interactiveBand(in: host.bounds.size)
        let point = NSPoint(x: panel.frame.minX + band.midX, y: panel.frame.minY + band.midY)
        panel.updatePointerPolicy(at: point)
        XCTAssertFalse(panel.ignoresMouseEvents, "The next pointer refresh disabled the Done pill")

        panel.updatePointerPolicy(at: NSPoint(x: panel.frame.minX + 1, y: panel.frame.maxY - 1))
        XCTAssertTrue(panel.ignoresMouseEvents, "Transparent space around Done must stay click-through")
    }

    /// The display link reaches the pill about 4 times a second at rest and at full refresh while recording.
    /// Prints PILL_LINK so the before and after rates can be compared.
    @MainActor func testDisplayLinkRunsAtFullRateWhileRecording() async throws {
        let previousSuppression = Telemetry.isSuppressed
        Telemetry.isSuppressed = true
        defer { Telemetry.isSuppressed = previousSuppression }
        _ = NSApplication.shared
        let state = RecordingState()
        let panel = OverlayPanel(recordingState: state, observesSystemChanges: false)
        panel.isReleasedWhenClosed = false
        panel.setFrame(NSRect(origin: NSPoint(x: -10000, y: -10000), size: PillLayout.panelSize), display: false)
        panel.showPersistent()
        defer { panel.orderOut(nil); panel.close() }
        try await Task.sleep(for: .milliseconds(1500))
        let restStart = panel.tickCount
        try await Task.sleep(for: .seconds(1))
        let rest = panel.tickCount - restStart

        state.isRecording = true
        try await Task.sleep(for: .milliseconds(300))
        let recordingStart = panel.tickCount
        try await Task.sleep(for: .seconds(1))
        let recording = panel.tickCount - recordingStart
        state.isRecording = false
        print("PILL_LINK rest=\(rest)/s recording=\(recording)/s")
        XCTAssertGreaterThan(recording, rest * 3, "The link stayed at rest rate while the pill was recording")
    }
}
