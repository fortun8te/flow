import XCTest
import AppKit
import SwiftUI
@testable import Voice

final class PillProgressTests: XCTestCase {
    func testFallbackReachesTheKneeAtSevenSecondsAndNeverFull() {
        XCTAssertEqual(PillProgressCurve.fallback(elapsed: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(PillProgressCurve.fallback(elapsed: 7), PillProgressCurve.knee, accuracy: 1e-9)
        var last = -1.0
        for step in 0...400 {
            let value = PillProgressCurve.fallback(elapsed: Double(step) * 0.25)
            XCTAssertGreaterThanOrEqual(value, last, "the fallback must never move back")
            XCTAssertLessThan(value, 1, "the fallback must not reach full while the polish runs")
            last = value
        }
        XCTAssertLessThan(PillProgressCurve.ceiling, 1)
    }

    func testFallbackSlowsNearTheKnee() {
        let early = PillProgressCurve.fallback(elapsed: 0.1) - PillProgressCurve.fallback(elapsed: 0)
        let late = PillProgressCurve.fallback(elapsed: 7) - PillProgressCurve.fallback(elapsed: 6.9)  // same 0.1 s span
        XCTAssertGreaterThan(early, late * 10, "the eased curve must be far slower at 90 % than at the start")
        let creep = PillProgressCurve.fallback(elapsed: 30) - PillProgressCurve.fallback(elapsed: 29)
        XCTAssertLessThan(creep, 0.002, "after the knee it creeps, it does not climb")
    }

    func testRealProgressWinsAndNeverMovesBack() {
        var state = PillPolishState()
        state.apply(PillPolishSignal(fraction: 0.4))
        XCTAssertEqual(PillProgressCurve.target(elapsed: 1, state: state), 0.4, accuracy: 1e-9)
        state.apply(PillPolishSignal(fraction: 0.6))
        state.apply(PillPolishSignal(fraction: 0.3))
        XCTAssertEqual(state.floor, 0.6, accuracy: 1e-9)
        XCTAssertEqual(PillProgressCurve.target(elapsed: 1, state: state), 0.6, accuracy: 1e-9)
        state.apply(PillPolishSignal(fraction: nil))
        XCTAssertGreaterThanOrEqual(PillProgressCurve.target(elapsed: 0.5, state: state), 0.6)
    }

    func testSignalClampsBadValuesAndReadsTheLoadingFlag() {
        XCTAssertEqual(PillPolishSignal(fraction: 2).fraction, 1)
        XCTAssertEqual(PillPolishSignal(fraction: -1).fraction, 0)
        XCTAssertNil(PillPolishSignal(fraction: .nan).fraction)
        let note = Notification(name: PillPolishSignal.notification, object: nil,
                                userInfo: [PillPolishSignal.fractionKey: 0.5, PillPolishSignal.loadingKey: true])
        XCTAssertEqual(PillPolishSignal(notification: note), PillPolishSignal(fraction: 0.5, loadingModel: true))
    }

    /// Frame strips for a visual check. Written only when `PILL_PROGRESS_STRIPS` names a folder.
    @MainActor func testWritesProgressFrameStrips() throws {
        guard let folder = ProcessInfo.processInfo.environment["PILL_PROGRESS_STRIPS"] else {
            throw XCTSkip("set PILL_PROGRESS_STRIPS to a folder to render the strips")
        }
        _ = NSApplication.shared
        let width: CGFloat = PillWispr.polishingWidth
        let times: [Double] = [0.4, 1.5, 3, 5, 7, 10, 20]
        let frames: [(String, Double)] = times.map { ("fallback-\(Int($0 * 10))ds", PillProgressCurve.fallback(elapsed: $0)) }
            + [("real-0.25", 0.25), ("real-0.8", 0.8), ("done-sweep-1", 1.0)]
        for (name, fraction) in frames {
            let view = ZStack(alignment: .leading) {
                Color(white: 0.12)
                PillPolishFill(fraction: fraction, width: width)
                Text("Polishing").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12)
            }
            .frame(width: width, height: 30)
            .clipShape(Capsule())
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
