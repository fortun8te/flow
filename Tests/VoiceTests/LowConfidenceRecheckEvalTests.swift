import XCTest
@testable import Voice

/// Offline evaluation of LowConfidenceRecheck. Opt-in: runs only when FLOW_LCR_CASES (JSONL of
/// {"id", "text", "suspects"}) and FLOW_LCR_OUT are set. Writes every decision with its gain so the
/// margin is chosen offline on the dev split and reported on the test split.
final class LowConfidenceRecheckEvalTests: XCTestCase {
    func testWriteDecisionsForCases() throws {
        let env = ProcessInfo.processInfo.environment
        guard let casesPath = env["FLOW_LCR_CASES"], let outPath = env["FLOW_LCR_OUT"] else {
            throw XCTSkip("set FLOW_LCR_CASES and FLOW_LCR_OUT to run the tinynext evaluation")
        }
        guard let lexicon = TypoRepair.shared.lexicon(wait: true),
              let scorer = TinyNextScorer.shared.ready(wait: true) else {
            throw XCTSkip("lexicon or tinynext weights are not in the bundle")
        }
        var config = LowConfidenceRecheck.Config()
        config.maxFlagged = 100_000  // stress: no per-dictation cap, so every flagged word is measured
        let lines = try String(contentsOfFile: casesPath, encoding: .utf8).split(separator: "\n")
        var out = ""
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let text = obj["text"] as! String
            let suspects = obj["suspects"] as! [String]
            let found = LowConfidenceRecheck.decisions(text, suspects: suspects, lexicon: lexicon,
                                                       scorer: scorer, config: config)
            let rows: [[String: Any]] = found.map {
                ["start": $0.start, "end": $0.end, "original": $0.original,
                 "replacement": $0.replacement, "delta": Double($0.delta)]
            }
            let record: [String: Any] = ["id": obj["id"] ?? "", "decisions": rows]
            out += String(data: try JSONSerialization.data(withJSONObject: record), encoding: .utf8)! + "\n"
        }
        try out.write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}
