import XCTest
@testable import Voice

/// Offline evaluation of Flow's current rules on the d1 decision datasets. Opt-in: runs only when
/// FLOW_D1_RULE_CASES (JSONL of {"id", "original", "proposed_copy_edit"}) and FLOW_D1_RULE_OUT are set.
/// Writes, per row, what each live rule decides, so the rules and a trained d1 model are scored on the same rows.
final class D1DecisionRuleEvalTests: XCTestCase {
    @MainActor func testWriteRuleDecisionsForCases() throws {
        let env = ProcessInfo.processInfo.environment
        guard let casesPath = env["FLOW_D1_RULE_CASES"], let outPath = env["FLOW_D1_RULE_OUT"] else {
            throw XCTSkip("set FLOW_D1_RULE_CASES and FLOW_D1_RULE_OUT to run the d1 rule evaluation")
        }
        let lines = try String(contentsOfFile: casesPath, encoding: .utf8).split(separator: "\n")
        var out = ""
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let original = obj["original"] as? String ?? ""
            let edited = obj["proposed_copy_edit"] as? String ?? ""
            var record: [String: Any] = ["id": obj["id"] ?? ""]
            let started = DispatchTime.now().uptimeNanoseconds
            record["trip"] = WhisperNowContentGuard.trip(source: original, output: edited)?.label ?? NSNull()
            record["hardTrip"] = WhisperNowContentGuard.hardTrip(source: original, output: edited)?.label ?? NSNull()
            record["responseProblem"] = T2ResponseSafety.responseProblem(source: original, candidate: edited) ?? NSNull()
            record["negationAdded"] = MeaningIntegrity.introducesNegation(original: original, candidate: edited)
            record["fillerMention"] = DictationFinalPass.dropsFillerMention(source: original, output: edited)
            record["rule_us"] = Double(DispatchTime.now().uptimeNanoseconds - started) / 1000
            record["needsReview"] = DraftDecisionGate.needsReview(original: original, edited: edited)
            out += String(data: try JSONSerialization.data(withJSONObject: record), encoding: .utf8)! + "\n"
        }
        try out.write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    /// FLOW_D1_TEXT_CASES (JSONL of {"id", "text"}) -> FLOW_D1_TEXT_OUT: the final word pass and the layout pass.
    @MainActor func testWriteTextPassesForCases() throws {
        let env = ProcessInfo.processInfo.environment
        guard let casesPath = env["FLOW_D1_TEXT_CASES"], let outPath = env["FLOW_D1_TEXT_OUT"] else {
            throw XCTSkip("set FLOW_D1_TEXT_CASES and FLOW_D1_TEXT_OUT to run the text-pass evaluation")
        }
        let lines = try String(contentsOfFile: casesPath, encoding: .utf8).split(separator: "\n")
        var out = ""
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let text = obj["text"] as? String ?? ""
            let finalPass = DictationFinalPass.apply(text)
            let record: [String: Any] = ["id": obj["id"] ?? "", "finalPass": finalPass,
                                         "layout": DictationParagraphs.formatDictation(finalPass),
                                         "mentions": DictationFinalPass.fillerMentions(text).count]
            out += String(data: try JSONSerialization.data(withJSONObject: record), encoding: .utf8)! + "\n"
        }
        try out.write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}
