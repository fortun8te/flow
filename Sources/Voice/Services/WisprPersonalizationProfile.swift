import Foundation

/// The small, local-only subset of a Wispr export that VOICE can understand.
/// Unknown fields are ignored; the original export is never loaded here.
struct WisprPersonalizationProfile: Decodable {
    struct PolishInstructions: Decodable {
        let concise: Bool?
        let clarity: Bool?
        let reorder: Bool?
        let structure: Bool?
        let maintainYourTone: Bool?
        let editingPrompt: String?

        enum CodingKeys: String, CodingKey {
            case concise = "Make more concise"
            case clarity = "Reword for clarity"
            case reorder = "Reorder for readability"
            case structure = "Add structure for readability"
            case maintainYourTone = "Maintain your tone"
            case editingPrompt = "Customize your Polish prompt"
        }
    }

    private struct InstructionContainer: Decodable {
        let `default`: PolishInstructions?
    }

    enum Context: String, CaseIterable {
        case work, email, other, personal, unset
    }

    private let autoCleanupLevel: String?
    private let personalizationStyles: [String: String]?
    private let instructionContainer: InstructionContainer?
    let schemaVersion: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case autoCleanupLevel = "auto_cleanup_level"
        case personalizationStyles = "personalization_styles"
        case instructionContainer = "polish_instructions"
    }

    var cleanupLevel: String? {
        guard let value = autoCleanupLevel?.lowercased(),
              ["none", "light", "medium", "high"].contains(value) else { return nil }
        return value
    }

    var instructions: PolishInstructions? { instructionContainer?.default }

    /// Unsupported values are neutral, rather than being passed into a prompt.
    func style(for context: Context) -> String {
        switch personalizationStyles?[context.rawValue]?.lowercased() {
        case "excited": return "excited"
        case "verycasual": return "veryCasual"
        case "casual": return "casual"
        case "formal": return "formal"
        default: return "neutral"
        }
    }

    func style(forBundleID bundle: String?) -> String {
        guard let bundle else { return style(for: .unset) }
        let personal: Set<String> = ["com.apple.MobileSMS", "ru.keepcoder.Telegram", "com.whatsapp.WhatsApp", "net.whatsapp.WhatsApp", "com.hnc.Discord", "com.discord", "com.facebook.Messenger"]
        let work: Set<String> = ["com.tinyspeck.slackmacOS", "com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.microsoft.teams2"]
        let email: Set<String> = ["com.apple.mail", "com.microsoft.Outlook", "com.superhuman.Superhuman", "com.readdle.smartemail-Mac"]
        if personal.contains(bundle) { return style(for: .personal) }
        if work.contains(bundle) { return style(for: .work) }
        if email.contains(bundle) { return style(for: .email) }
        return style(for: .other)
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VOICE/WisprPersonalization/profile.json")
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 64 * 1024,
              let profile = try? JSONDecoder().decode(Self.self, from: data),
              profile.schemaVersion == 1 else { return nil }
        return profile
    }

    static func load(from url: URL = defaultURL) -> Self? {
        guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024 else { return nil }
        return decode(data)
    }

    /// Apply once, only where VOICE has no saved setting. Returning false means
    /// an earlier import already ran; callers must not reapply context styles.
    @discardableResult
    func applyInitialPreferences(to defaults: UserDefaults) -> Bool {
        let marker = "voice.wisprPersonalizationImported"
        guard !defaults.bool(forKey: marker) else { return false }
        if defaults.object(forKey: "cleanupLevel") == nil,
           defaults.object(forKey: "llmPolishEnabled") == nil,
           let cleanupLevel {
            defaults.set(cleanupLevel, forKey: "cleanupLevel")
        }
        // A pre-existing style is explicit and takes precedence over import.
        let useContextStyles = defaults.object(forKey: "personalityStyle") == nil
        defaults.set(useContextStyles, forKey: "voice.wisprContextStylesEnabled")
        defaults.set(true, forKey: marker)
        return true
    }

    private struct PreparedDictionary: Decodable {
        struct Entry: Decodable {
            let word: String
            let replacement: String?
        }
        let schema_version: Int
        let entries: [Entry]
    }

    static let wisprVocabularySeenKey = "voice.wisprVocabularySeen"

    static func preparedVocabulary(from directory: URL = defaultURL.deletingLastPathComponent()) -> [String]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("dictionary.json")),
              data.count <= 4 * 1024 * 1024,
              let dictionary = try? JSONDecoder().decode(PreparedDictionary.self, from: data),
              dictionary.schema_version == 1 else { return nil }
        return dictionary.entries.map {
            let replacement = $0.replacement?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return replacement.isEmpty ? $0.word : replacement
        }
    }

    /// Record terms seen at the source separately from the editable dictionary.
    /// A word deleted in Flow is only resurrected by an explicit import.
    @discardableResult
    static func mergeWisprVocabulary(_ source: [String], preparedSeed: [String] = [], defaults: UserDefaults) -> Bool {
        let marker = wisprVocabularySeenKey
        let dictionaryKey = "voice.userDictionary"
        let stored = defaults.stringArray(forKey: marker)
        let previous = Set(stored ?? preparedSeed.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var seen = previous
        var dictionary = defaults.stringArray(forKey: dictionaryKey) ?? []
        let originalCount = dictionary.count
        var existing = Set(dictionary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for raw in source {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 500,
                  !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            let key = term.lowercased()
            if seen.insert(key).inserted, existing.insert(key).inserted { dictionary.append(term) }
        }
        if stored == nil || seen != previous { defaults.set(seen.sorted(), forKey: marker) }
        guard dictionary.count != originalCount else { return false }
        defaults.set(dictionary, forKey: dictionaryKey)
        return true
    }

    /// Reads the prepared vocabulary only. It never touches the export or the
    /// replacement archive. A failed or missing file remains retryable.
    @discardableResult
    static func importPreparedDictionary(
        from directory: URL = defaultURL.deletingLastPathComponent(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        let marker = "voice.wisprDictionaryImported"
        guard !defaults.bool(forKey: marker), let prepared = preparedVocabulary(from: directory) else { return false }

        var terms = defaults.stringArray(forKey: "voice.userDictionary") ?? []
        var seen = Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for word in prepared {
            let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 500,
                  !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        defaults.set(terms, forKey: "voice.userDictionary")
        defaults.set(true, forKey: marker)
        return true
    }

}
