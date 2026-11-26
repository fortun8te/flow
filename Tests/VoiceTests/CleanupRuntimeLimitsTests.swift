import Foundation
import XCTest
@testable import Voice

final class CleanupRuntimeLimitsTests: XCTestCase {
    func testMissingSettingsKeepExistingDefaults() {
        let limits = CleanupRuntimeLimits([:])
        XCTAssertEqual(limits.timeoutBase, 3)
        XCTAssertEqual(limits.timeoutPerWord, 0.12)
        XCTAssertEqual(limits.timeoutMax, 25)
        XCTAssertEqual(limits.coldWait, 1.5)
        XCTAssertEqual(limits.idleStop, 900)
        XCTAssertEqual(limits.contextSize, 8192)
    }

    func testValidSettingsAndZeroColdWaitArePreserved() {
        let limits = CleanupRuntimeLimits([
            "timeoutBase": 0, "timeoutPerWord": 0, "timeoutMax": 12.5,
            "coldWait": 0, "idleStop": 3600, "contextSize": 32768
        ])
        XCTAssertEqual(limits.timeoutBase, 0)
        XCTAssertEqual(limits.timeoutPerWord, 0)
        XCTAssertEqual(limits.timeoutMax, 12.5)
        XCTAssertEqual(limits.coldWait, 0)
        XCTAssertEqual(limits.idleStop, 3600)
        XCTAssertEqual(limits.contextSize, 32768)
    }

    func testNegativeNonfiniteAndOverflowingIntervalsUseDefaults() {
        for value in [-1.0, .nan, .infinity, -.infinity, 1e300] {
            let keys = ["timeoutBase", "timeoutPerWord", "timeoutMax", "coldWait", "idleStop"]
            let limits = CleanupRuntimeLimits(Dictionary(uniqueKeysWithValues: keys.map { ($0, value) }))
            XCTAssertEqual(limits, CleanupRuntimeLimits([:]))
        }
        let zeros = CleanupRuntimeLimits(["timeoutMax": 0, "idleStop": 0])
        XCTAssertEqual(zeros.timeoutMax, 25)
        XCTAssertEqual(zeros.idleStop, 900)
    }

    func testHugeJSONContextCannotTrapIntegerConversion() throws {
        let data = Data(#"{"contextSize":1e300,"timeoutMax":1e300}"#.utf8)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let limits = CleanupRuntimeLimits(row)
        XCTAssertEqual(limits.contextSize, 8192)
        XCTAssertEqual(limits.timeoutMax, 25)
        for value in [-1.0, 0, 1.5, .nan, .infinity, Double(Int.max)] {
            XCTAssertEqual(CleanupRuntimeLimits(["contextSize": value]).contextSize, 8192)
        }
    }

    func testWeightSizeMustBeAnExactPositiveInteger() {
        XCTAssertEqual(CleanupRuntimeLimits.weightBytes(3_000_000_000), 3_000_000_000)
        for value in [-1.0, 0, 1.5, .nan, .infinity, 1e300] {
            XCTAssertNil(CleanupRuntimeLimits.weightBytes(value))
        }
        XCTAssertNil(CleanupRuntimeLimits.weightBytes(nil))
        XCTAssertNil(CleanupRuntimeLimits.weightBytes("3000000000"))
    }
}
