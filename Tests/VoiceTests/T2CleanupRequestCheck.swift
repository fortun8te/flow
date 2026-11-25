#if T2_CLEANUP_CONTRACT_CHECK
import Foundation

/// Cheap, standalone contract check. Does not link the app, start a server or use a model.
/// swiftc -D T2_CLEANUP_CONTRACT_CHECK Sources/Voice/Services/T2CleanupRequest.swift Tests/VoiceTests/T2CleanupRequestCheck.swift -o /tmp/t2-cleanup-check
/// /tmp/t2-cleanup-check training/t2/golden/flow_requests.json [/tmp/flow-clean-user-contents.json]
@main enum T2CleanupRequestCheck {
    static func main() throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let expected = (fixture["all_control_lines"] as! [String]).filter { $0.hasPrefix("[Task: clean]") }
        var lines: [String] = []
        var exports: [[String: Any]] = []
        for level in T2CleanupOptions.Level.allCases {
            for style in T2CleanupOptions.Styling.allCases {
                for structure in T2CleanupOptions.Structure.allCases {
                    for context in T2CleanupOptions.Context.allCases {
                        let options = T2CleanupOptions(level: level, styling: style, structure: structure, context: context)
                        lines.append(options.controlLine)
                        exports.append(["id": "control-\(lines.count)", "control_line": options.controlLine,
                                        "user_content": options.userContent(transcript: "  Send 12 boxes Friday.  ")!])
                    }
                }
            }
        }
        precondition(lines == expected, "Swift clean headers differ from the Python canonical table")
        for row in fixture["cases"] as! [[String: Any]] where row["task"] as? String == "clean" {
            let text = row["text"] as! String
            let user: String
            if let line = row["control_line"] as? String {
                let options = T2CleanupOptions.Level.allCases.flatMap { lv in
                    T2CleanupOptions.Styling.allCases.flatMap { st in
                        T2CleanupOptions.Structure.allCases.flatMap { sr in
                            T2CleanupOptions.Context.allCases.map { cx in
                                T2CleanupOptions(level: lv, styling: st, structure: sr, context: cx)
                            }
                        }
                    }
                }.first { $0.controlLine == line }!
                user = options.userContent(transcript: text)!
            } else {
                user = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            precondition(user == row["user_content"] as? String)
            let body = T2CleanupOptions.requestBody(userContent: user, sourceText: text)
            let actualBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let expectedBody = try JSONSerialization.data(withJSONObject: row["body_without_adapter"]!, options: [.sortedKeys])
            precondition(actualBody == expectedBody, "App HTTP body differs from canonical Python case")
            exports.append(["id": row["id"]!, "user_content": user, "body_without_adapter": body])
        }
        precondition(T2CleanupOptions.resolve(level: "none", personalityStyle: "excited", appContextLabel: nil) == nil)
        precondition(T2CleanupOptions.resolve(level: "high", personalityStyle: "excited", appContextLabel: nil) == nil)
        precondition(T2CleanupOptions.resolve(level: "medium", personalityStyle: "veryCasual", appContextLabel: "email — Inbox")?.controlLine == "[Task: clean] [Level: medium] [Styling: very-casual] [Structure: lists] [Context: email]")
        precondition(T2CleanupOptions.resolve(level: "light", personalityStyle: "neutral", appContextLabel: "browser — likely a web form or email")?.context == .general)
        let raw = "Um I colour this...  maybe?\n"
        for level in ["none", "light", "medium"] {
            precondition(T2CleanupOptions.preparationTranscript(rawASR: raw, recognizedT2: true) == raw)
            precondition(T2CleanupOptions.preparationTranscript(rawASR: raw, recognizedT2: false) == nil)
            precondition(T2CleanupOptions.finalizedTranscript(candidate: raw, preparedASR: raw, level: level, recognizedT2: true) == raw)
            precondition(T2CleanupOptions.finalizedTranscript(candidate: "Styled T2 answer!", preparedASR: raw, level: level, recognizedT2: true) == (level == "none" ? raw : "Styled T2 answer!"))
            precondition(T2CleanupOptions.finalizedTranscript(candidate: raw, preparedASR: raw, level: level, recognizedT2: false) == nil)
        }
        let receipt = Data(#"{"active":"t2.gguf","contracts":{"t2.gguf":["t2-cleanup-control-v3"]}}"#.utf8)
        precondition(T2CleanupOptions.supports(manifest: receipt, modelFilename: "t2.gguf"))
        precondition(!T2CleanupOptions.supports(manifest: receipt, modelFilename: "t1.gguf"))
        precondition(!T2CleanupOptions.supports(manifest: Data(#"{"active":"t2.gguf","contracts":{"t2.gguf":["t2-selected-text-polish-v1"]}}"#.utf8), modelFilename: "t2.gguf"))
        let automatic = T2CleanupOptions(structure: .lists)
        let prose = T2CleanupOptions(structure: .prose)
        let baseCapabilities = T2CleanupOptions.activeContracts(manifest: receipt, modelFilename: "t2.gguf")
        precondition(automatic.isSupported(by: baseCapabilities))
        precondition(!prose.isSupported(by: baseCapabilities), "Base cleanup never authorizes unreviewed prose")
        let proseReceipt = Data(#"{"active":"t2-prose.gguf","contracts":{"t2-prose.gguf":["t2-cleanup-control-v3","t2-cleanup-prose-v1"]}}"#.utf8)
        let proseCapabilities = T2CleanupOptions.activeContracts(manifest: proseReceipt, modelFilename: "t2-prose.gguf")
        precondition(automatic.isSupported(by: proseCapabilities) && prose.isSupported(by: proseCapabilities))
        precondition(!prose.isSupported(by: T2CleanupOptions.activeContracts(manifest: proseReceipt, modelFilename: "t1.gguf")))
        precondition(!prose.isSupported(by: T2CleanupOptions.activeContracts(manifest: nil, modelFilename: "t1.gguf")))
        precondition(!prose.isSupported(by: [T2CleanupOptions.proseContract]), "Extra prose capability cannot replace the base cleanup capability")
        let retainedRaw = T2CleanupOptions.finalizedTranscript(candidate: raw, preparedASR: raw, level: "light", recognizedT2: true)
        precondition(retainedRaw == raw, "Unsupported saved prose keeps the raw text, without silently selecting lists")
        for bad in ["[InSt]", "<|system", "\u{0}", String(repeating: "x", count: 4001)] {
            precondition(T2CleanupOptions().userContent(transcript: bad) == nil)
        }
        if CommandLine.arguments.count > 2 {
            let output = ["contract": T2CleanupOptions.contract, "control_table_version": 3,
                          "note": "Actual Swift user content and HTTP body only. No server template was rendered.",
                          "cases": exports] as [String: Any]
            try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print("PASS: all 32 clean headers and legacy clean user/body fixtures match Python; Off preserves ASR text; unsupported levels/prose and wrong-file capabilities rejected")
    }
}
#endif
