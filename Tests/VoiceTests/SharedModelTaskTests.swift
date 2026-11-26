import Foundation
import XCTest
@testable import Voice

final class SharedModelTaskTests: XCTestCase {
    private final class CompletionCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
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

    func testCompletionCallbackWaitsForActualWorkAfterOwnerCancellation() async {
        let started = expectation(description: "operation started")
        let completed = expectation(description: "underlying operation completed")
        completed.assertForOverFulfill = true
        let gate = Gate(), count = CompletionCount()
        let load = SharedModelTask<Int>(onCompletion: {
            count.increment()
            completed.fulfill()
        }) {
            started.fulfill()
            await gate.wait() // An uncooperative model call cannot yet stop.
            return 42
        }
        await fulfillment(of: [started], timeout: 1)
        load.cancel()
        do { _ = try await load.value; XCTFail("Cancelled operation returned a value") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(count.value, 0, "A released waiter must not release the model's lease")
        await gate.release()
        await fulfillment(of: [completed], timeout: 1)
        load.cancel()
        XCTAssertEqual(count.value, 1)
    }

    func testImmediateCancellationStillCompletesEveryOwnedOperationOnce() async {
        let completed = expectation(description: "all cancelled operations completed")
        completed.expectedFulfillmentCount = 100
        completed.assertForOverFulfill = true
        let count = CompletionCount()
        for _ in 0..<100 {
            let task = SharedModelTask<Int>(onCompletion: {
                count.increment()
                completed.fulfill()
            }) { 42 }
            task.cancel()
            task.cancel()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(count.value, 100)
    }

    func testCompletionBookkeepingFinishesBeforeResultReachesWaiter() async {
        enum Failure: Error { case invalidWeights }
        // The completion callback owns the inference lease. A published result
        // must not let the next window run before that lease is released.
        for fails in [false, true] {
            let entered = expectation(description: "completion callback entered")
            let premature = expectation(description: "result must wait for completion bookkeeping")
            premature.isInverted = true
            let returned = expectation(description: "result returned after completion bookkeeping")
            let release = DispatchSemaphore(value: 0)
            let count = CompletionCount()
            let load = SharedModelTask<Int>(onCompletion: {
                entered.fulfill()
                if release.wait(timeout: .now() + 2) != .success {
                    XCTFail("Test did not release completion callback")
                }
                count.increment()
            }) {
                if fails { throw Failure.invalidWeights }
                return 42
            }
            let waiter = Task {
                do {
                    let value = try await load.value
                    XCTAssertFalse(fails)
                    XCTAssertEqual(value, 42)
                } catch {
                    XCTAssertTrue(fails)
                    XCTAssertTrue(error is Failure)
                }
                if count.value == 0 { premature.fulfill() }
                returned.fulfill()
            }
            await fulfillment(of: [entered], timeout: 1)
            await fulfillment(of: [premature], timeout: 0.05)
            release.signal()
            await fulfillment(of: [returned], timeout: 1)
            await waiter.value
            XCTAssertEqual(count.value, 1)
        }
    }

    func testOwnerCancellationDoesNotWaitForCompletionBookkeeping() async {
        let entered = expectation(description: "completion callback entered")
        let cancelled = expectation(description: "cancelled waiter returned")
        let completed = expectation(description: "completion callback finished")
        let release = DispatchSemaphore(value: 0)
        let count = CompletionCount()
        let load = SharedModelTask<Int>(onCompletion: {
            entered.fulfill()
            if release.wait(timeout: .now() + 2) != .success {
                XCTFail("Test did not release completion callback")
            }
            count.increment()
            completed.fulfill()
        }) { 42 }
        let waiter = Task {
            do { _ = try await load.value; XCTFail("Cancelled owner published its result") }
            catch { XCTAssertTrue(error is CancellationError) }
            cancelled.fulfill()
        }
        await fulfillment(of: [entered], timeout: 1)
        load.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(count.value, 0)
        release.signal()
        await fulfillment(of: [completed], timeout: 1)
        await waiter.value
        XCTAssertEqual(count.value, 1)
    }
}
