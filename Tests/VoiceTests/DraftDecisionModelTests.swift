import XCTest
@testable import Voice

final class DraftDecisionModelTests: XCTestCase {
    private let questions = ["same": DraftDecisionModel.Question(type: .noul, instructions: "Is this the same request?")]

    func testColdDecisionSkipsTextAndWarmDecisionReadsReply() async {
        let model = stub()
        let cold = await model.decideWithStatus(state: "Cold draft", questions: questions)
        XCTAssertEqual(cold.status, .warming)
        XCTAssertNil(cold.probabilities)
        let ready = await waitForReady(model)
        XCTAssertTrue(ready)
        let warm = await model.decideWithStatus(state: "Warm draft", questions: questions)
        XCTAssertEqual(warm.status, .answered)
        XCTAssertEqual(warm.probabilities, ["same": ["yes": 0.92, "no": 0.08]])
    }

    func testTimeoutReturnsWithoutQueuingASecondDraft() async {
        let model = stub()
        await model.prewarm()
        let ready = await waitForReady(model)
        XCTAssertTrue(ready)
        let timeout = await model.decideWithStatus(state: "slow", questions: questions, timeout: .milliseconds(30))
        XCTAssertEqual(timeout.status, .timedOut)
        XCTAssertNil(timeout.probabilities)
        let busy = await model.decideWithStatus(state: "Another draft", questions: questions)
        XCTAssertEqual(busy.status, .busy)
        // A response that arrives after its deadline must not poison the next request.
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(20))
            if let result = await model.decide(state: "Warm again", questions: questions) {
                XCTAssertEqual(result, ["same": ["yes": 0.92, "no": 0.08]])
                return
            }
        }
        XCTFail("The worker did not process a fresh request after its late reply")
    }

    func testPrewarmRefreshesIdleWorker() async {
        let model = stub()
        await model.prewarm()
        let ready = await waitForReady(model)
        XCTAssertTrue(ready)
        try? await Task.sleep(for: .milliseconds(650))
        await model.prewarm()
        try? await Task.sleep(for: .milliseconds(600))
        let stillReady = await model.isReady
        XCTAssertTrue(stillReady, "A fresh recording should extend an idle worker's lifetime")
        let result = await model.decide(state: "The blue kettle is cold.", questions: questions)
        XCTAssertEqual(result, ["same": ["yes": 0.92, "no": 0.08]])
    }

    func testMalformedReplyDropsWorker() async {
        let model = stub()
        await model.prewarm()
        let ready = await waitForReady(model)
        XCTAssertTrue(ready)
        let reply = await model.decideWithStatus(state: "bad", questions: questions)
        let retained = await model.isReady
        XCTAssertEqual(reply.status, .workerFailed)
        XCTAssertNil(reply.probabilities)
        XCTAssertFalse(retained)
    }

    func testUnavailableAndInvalidRequestsAreDistinct() async {
        let model = DraftDecisionModel(configuration: nil)
        let missing = await model.decideWithStatus(state: "The blue kettle is cold.", questions: questions)
        XCTAssertEqual(missing.status, .unavailable)
        let invalid = await model.decideWithStatus(state: "", questions: questions)
        XCTAssertEqual(invalid.status, .invalidInput)
    }

    private func waitForReady(_ model: DraftDecisionModel) async -> Bool {
        for _ in 0..<100 {
            if await model.isReady { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func stub() -> DraftDecisionModel {
        DraftDecisionModel(configuration: .init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-I", "-B", "-u", "-c", #"""
                import json, sys, time
                print(json.dumps({"ready": True}), flush=True)
                for line in sys.stdin:
                    request = json.loads(line)
                    if request["state"] == "slow": time.sleep(0.18)
                    values = {"yes": 2, "no": -1} if request["state"] == "bad" else {"yes": 0.92, "no": 0.08}
                    print(json.dumps({"id": request["id"], "answers": {"same": values}}), flush=True)
                """#], environment: ["PATH": "/usr/bin:/bin"], idleTimeout: .seconds(1)))
    }
}
