import Foundation

/// The v3 training control table, for automatic dictation only. Off never makes a request.
/// Installation receipt in manifest.json must bind capability to the active file:
/// {"active":"t2.gguf","contracts":{"t2.gguf":["t2-cleanup-control-v3"]}}
/// A filename or a UI choice alone does not establish that a model learned these controls.
struct T2CleanupOptions: Equatable, Sendable {
    static let contract = "t2-cleanup-control-v3"
    /// Prose requires separate reviewed supervision; the base contract permits automatic structure only.
    static let proseContract = "t2-cleanup-prose-v1"
    static let structureKey = "voice.t2CleanupStructure.v3"
    enum Level: String, CaseIterable { case light, medium }
    enum Styling: String, CaseIterable { case formal, casual, veryCasual = "very-casual", excited }
    enum Structure: String, CaseIterable { case prose, lists }
    enum Context: String, CaseIterable { case general, email }
    var level: Level = .light
    var styling: Styling = .formal
    var structure: Structure = .lists
    var context: Context = .general

    func isSupported(by activeContracts: Set<String>) -> Bool {
        activeContracts.contains(Self.contract)
            && (structure == .lists || activeContracts.contains(Self.proseContract))
    }

    var controlLine: String {
        "[Task: clean] [Level: \(level.rawValue)] [Styling: \(styling.rawValue)] [Structure: \(structure.rawValue)] [Context: \(context.rawValue)]"
    }

    /// Uses the target app's already-resolved style, never the currently focused app at finish time.
    static func resolve(level: String, personalityStyle: String, appContextLabel: String?, structure: String = "lists") -> Self? {
        guard let level = Level(rawValue: level), let structure = Structure(rawValue: structure) else { return nil }
        let styling: Styling
        switch personalityStyle.lowercased() {
        case "formal", "neutral", "": styling = .formal
        case "casual": styling = .casual
        case "verycasual", "very-casual", "genz": styling = .veryCasual
        case "excited": styling = .excited
        default: return nil
        }
        // The browser label says "likely ... email", which does not establish an email target.
        let baseContext = appContextLabel?.components(separatedBy: " — ").first?.lowercased()
        return Self(level: level, styling: styling, structure: structure, context: baseContext == "email" ? .email : .general)
    }

    func userContent(transcript: String) -> String? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 4_000,
              !text.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 127 }),
              !["<|", "|>", "[inst]", "[/inst]", "<<sys>>", "<</sys>>"].contains(where: text.lowercased().contains) else { return nil }
        return controlLine + "\n" + text
    }

    /// The same pure builder used by the local HTTP client and the offline export check.
    /// Adapter execution is not enabled by this contract. The current server serves a merged GGUF.
    static func requestBody(userContent: String, sourceText: String) -> [String: Any] {
        let words = sourceText.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        return ["messages": [["role": "user", "content": userContent]],
                "temperature": 0, "repeat_penalty": 1.05, "repeat_last_n": 4096,
                "max_tokens": max(64, Int(ceil(2.5 * Double(words)))),
                "cache_prompt": false, "stream": false]
    }

    static func activeContracts(manifest: Data?, modelFilename: String) -> Set<String> {
        guard let manifest, let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              json["active"] as? String == modelFilename,
              let contracts = json["contracts"] as? [String: [String]] else { return [] }
        return Set(contracts[modelFilename] ?? [])
    }
    static func supports(manifest: Data?, modelFilename: String) -> Bool {
        activeContracts(manifest: manifest, modelFilename: modelFilename).contains(contract)
    }

    /// The T2 task is trained on speech-engine text. Returning nil selects the existing legacy formatter.
    static func preparationTranscript(rawASR: String, recognizedT2: Bool) -> String? {
        recognizedT2 ? rawASR : nil
    }

    /// T2 output has already learned style and spelling. Returning nil selects the legacy finalizer.
    static func finalizedTranscript(candidate: String, preparedASR: String, level: String, recognizedT2: Bool) -> String? {
        guard recognizedT2 else { return nil }
        if level == "none" || candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return preparedASR }
        return candidate
    }

}
