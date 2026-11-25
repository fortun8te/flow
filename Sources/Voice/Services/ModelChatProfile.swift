import Foundation
import CryptoKit

/// A model's template contract, exported from its actual tokenizer/Jinja, bound to one active GGUF.
/// T2 requires chat_profiles[active filename] in manifest.json. A changed template or profile fails closed.
struct ModelChatProfile: Codable, Equatable, Sendable {
    let base: String
    let probeUser: String
    let expectedPrompt: String
    let chatTemplateKwargs: [String: Bool]
    let templateSHA256: String
    let systemPrompt: String?
    let textNormalization: String?
    let templateFile: String?

    init(base: String, probeUser: String, expectedPrompt: String, chatTemplateKwargs: [String: Bool],
         templateSHA256: String, systemPrompt: String? = nil, textNormalization: String? = nil, templateFile: String? = nil) {
        self.base = base
        self.probeUser = probeUser
        self.expectedPrompt = expectedPrompt
        self.chatTemplateKwargs = chatTemplateKwargs
        self.templateSHA256 = templateSHA256
        self.systemPrompt = systemPrompt
        self.textNormalization = textNormalization
        self.templateFile = templateFile
    }

    enum CodingKeys: String, CodingKey {
        case base
        case systemPrompt = "system_prompt"
        case textNormalization = "text_normalization", templateFile = "template_file"
        case probeUser = "probe_user", expectedPrompt = "expected_prompt"
        case chatTemplateKwargs = "chat_template_kwargs", templateSHA256 = "template_sha256"
    }

    /// Existing T1 bytes and absent kwargs stay unchanged.
    static let legacyT1 = Self(base: "dose1-t1", probeUser: "um so can you send me the report by friday",
        expectedPrompt: "<|startoftext|><|im_start|>user\num so can you send me the report by friday<|im_end|>\n<|im_start|>assistant\n",
        chatTemplateKwargs: [:], templateSHA256: "")

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable identity includes the exact optional System text, user probe, expected render and kwargs.
    func identitySHA256() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Self.sha256(try encoder.encode(self))
    }

    func normalized(_ text: String) -> String {
        textNormalization == "NFC" ? text.precomposedStringWithCanonicalMapping : text
    }
    var effectiveExpectedPrompt: String { normalized(expectedPrompt) }
    var templateBasename: String { templateFile ?? "chat_template.jinja" }

    static func isSafeTemplateBasename(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 200 && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
            }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard let left = try? lhs.identitySHA256(), let right = try? rhs.identitySHA256() else { return false }
        return left == right
    }

    func matchesRenderedPrompt(_ rendered: String) -> Bool {
        rendered.utf8.elementsEqual(effectiveExpectedPrompt.utf8)
    }

    /// The app checks shape, file binding and template bytes. The runtime probe checks actual server rendering.
    var isWellFormed: Bool {
        let expectedPrompt = effectiveExpectedPrompt
        let probeUser = normalized(self.probeUser)
        guard textNormalization == nil || textNormalization == "NFC" else { return false }
        guard Self.isSafeTemplateBasename(templateBasename) else { return false }
        guard !base.isEmpty, base.count <= 100,
              base.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }),
              !probeUser.isEmpty, probeUser == probeUser.trimmingCharacters(in: .whitespacesAndNewlines),
              probeUser.unicodeScalars.count <= 1_000,
              !probeUser.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !["<|", "|>", "[inst]", "[/inst]", "<<sys>>", "<</sys>>"].contains(where: probeUser.lowercased().contains),
              expectedPrompt.utf8.count <= 32_768,
              !expectedPrompt.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 127 }),
              expectedPrompt.components(separatedBy: probeUser).count == 2,
              expectedPrompt.components(separatedBy: "<|im_start|>user\n").count == 2,
              expectedPrompt.components(separatedBy: "<|im_start|>assistant\n").count == 2,
              expectedPrompt.contains("<|im_start|>user\n" + probeUser + "<|im_end|>"),
              let userEnd = expectedPrompt.range(of: probeUser + "<|im_end|>"),
              let assistant = expectedPrompt.range(of: "<|im_start|>assistant\n"), userEnd.upperBound <= assistant.lowerBound,
              templateSHA256.count == 64, templateSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              Set(chatTemplateKwargs.keys).isSubset(of: ["enable_thinking"]),
              chatTemplateKwargs["enable_thinking"] != true else { return false }
        if let systemPrompt = self.systemPrompt.map(normalized) {
            guard !systemPrompt.isEmpty, systemPrompt == systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                  systemPrompt.unicodeScalars.count <= 8_000,
                  !systemPrompt.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 127 }),
                  !["<|", "|>", "[inst]", "[/inst]", "<<sys>>", "<</sys>>"].contains(where: systemPrompt.lowercased().contains),
                  expectedPrompt.components(separatedBy: "<|im_start|>system\n").count == 2,
                  let system = expectedPrompt.range(of: "<|im_start|>system\n" + systemPrompt + "<|im_end|>"),
                  let user = expectedPrompt.range(of: "<|im_start|>user\n"), system.upperBound <= user.lowerBound else { return false }
        } else if expectedPrompt.contains("<|im_start|>system\n") {
            return false
        }
        return true
    }

    static func declaredProfile(manifest: Data?, modelFilename: String) -> Self? {
        guard let manifest, manifest.count <= 256 * 1024,
              let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              json["active"] as? String == modelFilename,
              let profiles = json["chat_profiles"] as? [String: Any], let raw = profiles[modelFilename],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let profile = try? JSONDecoder().decode(Self.self, from: data), profile.isWellFormed else { return nil }
        return profile
    }

    static func resolve(manifest: Data?, modelFilename: String, requiresExplicitProfile: Bool, templateData: Data?) -> Self? {
        // The untagged legacy T1 route deliberately keeps its historical request and probe unchanged.
        guard requiresExplicitProfile else { return .legacyT1 }
        guard let profile = declaredProfile(manifest: manifest, modelFilename: modelFilename),
              let templateData, sha256(templateData) == profile.templateSHA256 else { return nil }
        return profile
    }

    /// Both the render probe and completion use identical kwargs. T1 omits the field entirely.
    func applyingTemplateKwargs(to body: [String: Any]) -> [String: Any] {
        var body = body
        if !chatTemplateKwargs.isEmpty { body["chat_template_kwargs"] = chatTemplateKwargs }
        return body
    }

    func messages(for user: String) -> [[String: String]] {
        var messages: [[String: String]] = []
        if let systemPrompt { messages.append(["role": "system", "content": normalized(systemPrompt)]) }
        messages.append(["role": "user", "content": normalized(user)])
        return messages
    }

    func completionBody(userContent: String, sourceText: String) -> [String: Any] {
        var body = T2CleanupOptions.requestBody(userContent: userContent, sourceText: sourceText)
        body["messages"] = messages(for: userContent)
        return applyingTemplateKwargs(to: body)
    }

    var probeBody: [String: Any] {
        applyingTemplateKwargs(to: ["messages": messages(for: probeUser)])
    }
}
