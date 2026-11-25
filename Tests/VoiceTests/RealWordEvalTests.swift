import Foundation
import XCTest
@testable import Voice

/// Offline replay of the referee over saved rows, in the debug build Flow ships. Runs only when
/// REFEREE_EVAL_IN and REFEREE_EVAL_OUT are set (JSON lines in: id, source, output?, mode?; out: guard
/// verdicts, paste-safety features, real-word fixes and the time of every stage). Skipped otherwise.
@MainActor
final class RealWordEvalTests: XCTestCase {
    func testReplaySavedRows() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["REFEREE_EVAL_IN"], let output = env["REFEREE_EVAL_OUT"] else {
            throw XCTSkip("Set REFEREE_EVAL_IN and REFEREE_EVAL_OUT to replay rows.")
        }
        XCTAssertNotNil(RealWordFixer.shared.model(wait: true), "tinyfix weights must load")
        func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
        var out = ""
        for line in try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n") {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, let source = row["source"] as? String else { continue }
            var result: [String: Any] = ["id": id]
            if (row["mode"] as? String) == "typed" {
                // The real Opt+1 pairing: Flow's edit-distance dictionary repairs non-words for the judgement.
                var nonWordMs = 0.0
                let t = DispatchTime.now().uptimeNanoseconds
                let fixed = DictationReferee.typedPrePass(source) { text in
                    let n = DispatchTime.now().uptimeNanoseconds
                    defer { nonWordMs = ms(n) }
                    return Qwen3Polisher.shared.recoverTypedSpelling(text, deadline: .now + .milliseconds(150))
                }
                result["typed_ms"] = ms(t); result["nonword_ms"] = nonWordMs; result["typed"] = fixed
            } else if let modelOutput = row["output"] as? String {
                var t = DispatchTime.now().uptimeNanoseconds
                result["trip"] = WhisperNowContentGuard.trip(source: source, output: modelOutput)?.label ?? NSNull()
                result["guard_ms"] = ms(t)
                t = DispatchTime.now().uptimeNanoseconds
                let hard = WhisperNowContentGuard.hardTrip(source: source, output: modelOutput)
                result["hard_ms"] = ms(t)
                result["hard_trip"] = hard?.label ?? NSNull()
                let trimmed = modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                result["old_coverage_ok"] = WhisperNowContentGuard.coverageRuleAccepts(source: source, output: trimmed)
                t = DispatchTime.now().uptimeNanoseconds
                let f = PasteSafety.features(source: source, output: trimmed)
                result["features_ms"] = ms(t)
                result["features"] = f.vector
                result["units"] = f.units
                result["fallback"] = DictationFinalPass.apply(WhisperNowContentGuard.stripHesitations(source))
                t = DispatchTime.now().uptimeNanoseconds
                let pass = DictationFinalPass.apply(modelOutput)
                result["final_pass_ms"] = ms(t)
                t = DispatchTime.now().uptimeNanoseconds
                let real = DictationReferee.realWords(pass, mode: .dictation, protectedTerms: [], wait: true)
                result["realword_ms"] = ms(t)
                result["realword_fixes"] = real.fixes.map { "\($0.original)->\($0.replacement)" }
                t = DispatchTime.now().uptimeNanoseconds
                result["language"] = DictationReferee.language(source).reason
                result["language_ms"] = ms(t)
            } else {
                let t = DispatchTime.now().uptimeNanoseconds
                let real = DictationReferee.realWords(source, mode: .dictation, protectedTerms: [], wait: true)
                result["realword_ms"] = ms(t)
                result["realword_fixes"] = real.fixes.map { "\($0.original)->\($0.replacement)" }
            }
            result["words"] = source.split(whereSeparator: \.isWhitespace).count
            out += String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)! + "\n"
        }
        try out.write(toFile: output, atomically: true, encoding: .utf8)
    }
}
