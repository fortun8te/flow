import Foundation

/// T2 output checks only. Request construction, raw source bytes and legacy engine rules stay unchanged.
enum T2ResponseSafety {
    static func responseProblem(source: String, candidate: String) -> String? {
        let source = source.lowercased()
        let candidate = candidate.lowercased()
        let markers = ["[polish request v1]", "[task: clean]", "[task: polish]", "t2-selected-text-polish-v1"]
        for marker in markers where occurrences(marker, in: candidate) > occurrences(marker, in: source) {
            return "response_envelope"
        }
        // Count anchored wrappers, rather than deleting one and trusting the remaining text.
        // Existing quoted/literal text is allowed; adding a new occurrence is not.
        let preambles = [#"here(?: is|'s)\b"#, #"i(?:'ve| have) (?:polished|edited|corrected)\b"#,
                         #"polished version\s*:"#, #"edited text\s*:"#, #"cleaned text\s*:"#,
                         #"corrected text\s*:"#, #"explanation\s*:"#, #"sure[,!:]"#, #"certainly[,!:]"#]
        for pattern in preambles {
            let anchored = #"(?im)^\s*(?:[\"'“‘>]\s*)?"# + pattern
            if matches(anchored, in: candidate) > 0,
               matches("(?i)" + pattern, in: candidate) > matches("(?i)" + pattern, in: source) {
                return "response_preamble"
            }
        }
        return nil
    }

    private static func occurrences(_ marker: String, in text: String) -> Int {
        text.components(separatedBy: marker).count - 1
    }
    private static func matches(_ pattern: String, in text: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Only these clear hesitation sounds can authorize T2 to suppress an EMPTY reply.
    /// Words such as yeah, oh, mhm, like and literal quoted text are meaningful by default.
    static func isHesitationOnly(_ text: String) -> Bool {
        matches(#"(?i)^\s*(?:um|uh|uhm|erm)(?:[\s.,!?;:…-]+(?:um|uh|uhm|erm))*[\s.,!?;:…-]*$"#, in: text) == 1
    }

    struct Trace: Equatable {
        let engine: String
        let ready: Bool
        let fallback: String?
    }
    static func trace(engine: String?, result: String?, deadlineExpired: Bool = false) -> Trace {
        if deadlineExpired { return Trace(engine: "rules", ready: false, fallback: "deadline") }
        let received = engine == "local:dose1-t2"
        let accepted = received && (result == "accepted" || result == "no-speech")
        return Trace(engine: received ? "dose1-t2" : "rules", ready: received,
                     fallback: accepted ? nil : (result ?? "unavailable:no-outcome"))
    }

    static func selectedFailureReason(_ failure: String) -> String {
        switch failure {
        case "notReady", "busy": return "T2 is not ready to polish yet"
        case "templateMismatch": return "T2's setup could not be verified"
        case "invalidInput": return "T2 cannot polish this selection"
        case "modelMissing", "serverMissing", "startFailed": return "T2 is unavailable"
        case "timeout", "cancelled": return "T2 did not finish polishing"
        default: return "T2 did not return a safe reply"
        }
    }
}
