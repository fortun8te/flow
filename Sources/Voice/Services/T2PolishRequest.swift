import Foundation

/// Opt-in selected-text contract. Automatic dictation and legacy model prompts never use this envelope.
struct T2PolishOptions: Codable, Equatable, Sendable {
    static let contract = "t2-selected-text-polish-v1"
    static let defaultsKey = "voice.t2PolishOptions.v1"
    var concise = true
    var clarity = true
    var reorder = true
    var structure = true
    var maintainYourTone = true
    var editingPrompt = ""

    static func load(defaults: UserDefaults = .standard,
                     instructions: WisprPersonalizationProfile.PolishInstructions? = nil) -> Self {
        if let data = defaults.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(Self.self, from: data) {
            return saved
        }
        var options = Self()
        if let instructions {
            options.concise = instructions.concise ?? true
            options.clarity = instructions.clarity ?? true
            options.reorder = instructions.reorder ?? true
            options.structure = instructions.structure ?? true
            options.maintainYourTone = instructions.maintainYourTone ?? true
            options.editingPrompt = instructions.editingPrompt ?? ""
        }
        return options
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    var promptProblem: String? {
        let prompt = editingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.unicodeScalars.count > 1_000 { return "Keep your prompt to 1,000 characters." }
        if prompt.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 127 }) {
            return "Remove control characters from your prompt."
        }
        if ["<|", "|>", "[inst]", "[/inst]", "<<sys>>", "<</sys>>"].contains(where: prompt.lowercased().contains) {
            return "Remove model role markers from your prompt."
        }
        return nil
    }

    func userPrompt(text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard promptProblem == nil, !text.isEmpty, text.unicodeScalars.count <= 4_000,
              !text.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 127 }),
              !["<|", "|>", "[inst]", "[/inst]", "<<sys>>", "<</sys>>"].contains(where: text.lowercased().contains) else { return nil }
        let envelope: [String: Any] = [
            "contract": Self.contract,
            "settings": ["concise": concise, "clarity": clarity, "reorder": reorder,
                         "structure": structure, "maintain_your_tone": maintainYourTone],
            "editing_prompt": editingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "[Polish request v1] " + json + "\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Capabilities belong to the selected file, never to the directory or a user toggle.
    static func supports(manifest: Data?, modelFilename: String) -> Bool {
        guard let manifest, let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              json["active"] as? String == modelFilename,
              let contracts = json["contracts"] as? [String: [String]] else { return false }
        return contracts[modelFilename]?.contains(contract) == true
    }
}
