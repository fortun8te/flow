import Foundation
import XCTest
@testable import Voice

final class ModelWorkLeaseTests: XCTestCase {
    func testOnlyTheCurrentOperationCanReleaseItsLease() throws {
        let lease = ModelWorkLease()
        let token = try XCTUnwrap(lease.claim())
        XCTAssertTrue(lease.isBusy)
        XCTAssertNil(lease.claim())
        lease.release(UUID())
        XCTAssertTrue(lease.isBusy)
        lease.release(token)
        XCTAssertFalse(lease.isBusy)
        XCTAssertNotNil(lease.claim())
    }

    func testLateDuplicateReleaseCannotEndTheNextOperation() throws {
        let lease = ModelWorkLease()
        let first = try XCTUnwrap(lease.claim())
        lease.release(first)
        let second = try XCTUnwrap(lease.claim())
        lease.release(first)
        XCTAssertNil(lease.claim())
        lease.release(second)
        XCTAssertFalse(lease.isBusy)
    }
}
