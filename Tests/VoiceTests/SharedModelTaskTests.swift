import Foundation
import XCTest
@testable import Voice

final class SharedModelTaskTests: XCTestCase {
    private actor Gate {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            let waiting = waiters
            waiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
    }

    func testConcurrentWaitersShareOneLoadAndCachedResult() async throws {
        let started = expectation(description: "one load")
        started.assertForOverFulfill = true
        let gate = Gate()
        let load = SharedModelTask<Int> {
            started.fulfill()
            await gate.wait()
            return 42
        }
        let results = Task {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<32 { group.addTask { try await load.value } }
                var values: [Int] = []
                for try await value in group { values.append(value) }
                return values
            }
        }
        await fulfillment(of: [started], timeout: 1)
        await gate.release()
        let values = try await results.value
        XCTAssertEqual(values, Array(repeating: 42, count: 32))
        let cached = try await load.value
        XCTAssertEqual(cached, 42)
    }

    func testCancelledWaiterReturnsBeforeUninterruptibleLoadFinishes() async throws {
        let started = expectation(description: "load started")
        let cancelled = expectation(description: "waiter cancelled promptly")
        let gate = Gate()
        let load = SharedModelTask<Int> {
            started.fulfill()
            await gate.wait()
            try Task.checkCancellation()
            return 42
        }
        let waiter = Task {
            do { _ = try await load.value; XCTFail("Cancelled waiter returned a value") }
            catch { XCTAssertTrue(error is CancellationError) }
            cancelled.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        waiter.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        // The shared load must still succeed for a surviving/new caller.
        await gate.release()
        let value = try await load.value
        XCTAssertEqual(value, 42)
        await waiter.value
    }

    func testOwnerCancellationRejectsLateLoaderResult() async throws {
        let started = expectation(description: "load started")
        let cancelled = expectation(description: "shared wait cancelled promptly")
        let completed = expectation(description: "uncooperative load finished")
        let gate = Gate()
        let load = SharedModelTask<Int> {
            started.fulfill()
            await gate.wait()
            completed.fulfill()
            return 42 // Deliberately ignores Task cancellation, like a weight mapping call.
        }
        let waiter = Task {
            do { _ = try await load.value; XCTFail("Stopped load returned a value") }
            catch { XCTAssertTrue(error is CancellationError) }
            cancelled.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        load.cancel()
        load.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        await gate.release()
        await fulfillment(of: [completed], timeout: 1)
        do { _ = try await load.value; XCTFail("Late result resurrected a stopped load") }
        catch { XCTAssertTrue(error is CancellationError) }
        await waiter.value
    }

    func testLoadFailureReachesEveryWaiter() async {
        enum Failure: Error { case invalidWeights }
        let load = SharedModelTask<Int> { throw Failure.invalidWeights }
        for _ in 0..<3 {
            do { _ = try await load.value; XCTFail("Failed load returned a value") }
            catch { XCTAssertTrue(error is Failure) }
        }
    }

    func testAlreadyCancelledWaiterDoesNotConsumeCachedValue() async throws {
        let gate = Gate()
        let load = SharedModelTask<Int> { 42 }
        let initial = try await load.value
        XCTAssertEqual(initial, 42)
        let waiter = Task {
            await gate.wait()
            do { _ = try await load.value; XCTFail("Cancelled caller consumed a cached model") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        waiter.cancel()
        await gate.release()
        await waiter.value
        let cached = try await load.value
        XCTAssertEqual(cached, 42)
    }
}
