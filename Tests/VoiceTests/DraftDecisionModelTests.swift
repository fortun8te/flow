import XCTest
@testable import Voice

final class DraftDecisionModelTests: XCTestCase {
    private let questions = ["same": DraftDecisionModel.Question(type: .noul, instructions: "Is this the same request?")]

    func testColdDecisionSkipsTextAndWarmDecisionReadsReply() async {
        let model = stub()
        let cold = await model.decide(state: "Cold draft", questions: questions)
        XCTAssertNil(cold)
        let ready = await waitForReady(model)
        XCTAssertTrue(ready)
        let warm = await model.decide(state: "Warm draft", questions: questions)
        XCTAssertEqual(warm, ["same": ["yes": 0.92, "no": 0.08]])
    }

    func testTimeoutReturnsWithoutQueuingASecondDraft() async {
        let model = stub()
        await model.prewarm()
        let ready = await waitForReady(model)
        XCTAssertTrue(ready)
        let timeout = await model.decide(state: "slow", questions: questions, timeout: .milliseconds(30))
        XCTAssertNil(timeout)
        let busy = await model.decide(state: "Another draft", questions: questions)
        XCTAssertNil(busy)
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

    func testMalformedReplyDropsWorker() async {
        let model = stub()
        await model.prewarm()
        let ready = await waitForReady(model)
        XCTAssertTrue(ready)
        let reply = await model.decide(state: "bad", questions: questions)
        let retained = await model.isReady
        XCTAssertNil(reply)
        XCTAssertFalse(retained)
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
