#if MODEL_CHAT_PROFILE_CHECK
import Foundation

/// swiftc -D MODEL_CHAT_PROFILE_CHECK Sources/Voice/Services/ModelChatProfile.swift Sources/Voice/Services/T2CleanupRequest.swift Tests/VoiceTests/ModelChatProfileCheck.swift -o /tmp/model-chat-profile-check
/// Pass an actual tokenizer-exported profile JSON and its actual template file. No model is loaded.
@main enum ModelChatProfileCheck {
    static func main() throws {
        let actualProfileData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let template = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let actual = try JSONDecoder().decode(ModelChatProfile.self, from: actualProfileData)
        precondition(actual.isWellFormed)
        precondition(ModelChatProfile.sha256(template) == actual.templateSHA256)
        let raw = try JSONSerialization.jsonObject(with: actualProfileData)
        func manifest(profile: Any = raw, active: String = "splash-t2.gguf") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["active": active, "chat_profiles": ["splash-t2.gguf": profile]])
        }
        let receipt = try manifest()
        let resolved = ModelChatProfile.resolve(manifest: receipt, modelFilename: "splash-t2.gguf", requiresExplicitProfile: true, templateData: template)
        precondition(resolved == actual)
        precondition(resolved != ModelChatProfile.legacyT1, "Splash must not inherit the T1 BOS/template assumption")
        precondition(actual.chatTemplateKwargs["enable_thinking"] == false)
        let probeKwargs = actual.probeBody["chat_template_kwargs"] as! [String: Bool]
        let completion = actual.completionBody(userContent: "fixture", sourceText: "fixture")
        precondition(probeKwargs == completion["chat_template_kwargs"] as! [String: Bool])
        precondition(ModelChatProfile.resolve(manifest: nil, modelFilename: "splash-t2.gguf", requiresExplicitProfile: true, templateData: template) == nil)
        precondition(ModelChatProfile.resolve(manifest: receipt, modelFilename: "t1.gguf", requiresExplicitProfile: true, templateData: template) == nil)
        precondition(ModelChatProfile.resolve(manifest: receipt, modelFilename: "splash-t2.gguf", requiresExplicitProfile: true, templateData: Data("wrong template".utf8)) == nil)
        for changes: [String: Any] in [
            ["probe_user": "[INST]"], ["expected_prompt": "missing actual probe"],
            ["chat_template_kwargs": ["enable_thinking": true]], ["chat_template_kwargs": ["unknown": false]],
            ["template_sha256": "unknown"], ["base": "../wrong"],
            ["text_normalization": "NFD"], ["template_file": "../outside.jinja"], ["template_file": "/absolute.jinja"],
            ["system_prompt": ""], ["system_prompt": "[INST]"], ["system_prompt": String(repeating: "x", count: 8001)],
            ["system_prompt": "mismatched system"]
        ] {
            var invalid = raw as! [String: Any]
            for (key, value) in changes { invalid[key] = value }
            let bad = try manifest(profile: invalid)
            precondition(ModelChatProfile.resolve(manifest: bad, modelFilename: "splash-t2.gguf", requiresExplicitProfile: true, templateData: template) == nil)
        }
        let legacy = ModelChatProfile.resolve(manifest: nil, modelFilename: "model-Q8_0.gguf", requiresExplicitProfile: false, templateData: nil)!
        precondition(legacy == .legacyT1)
        precondition(legacy.expectedPrompt == "<|startoftext|><|im_start|>user\num so can you send me the report by friday<|im_end|>\n<|im_start|>assistant\n")
        precondition(legacy.probeBody["chat_template_kwargs"] == nil)
        precondition(legacy.completionBody(userContent: "fixture", sourceText: "fixture")["chat_template_kwargs"] == nil)
        let completionMessages = completion["messages"] as! [[String: String]]
        let probeMessages = actual.probeBody["messages"] as! [[String: String]]
        precondition(completionMessages == actual.messages(for: "fixture"))
        precondition(probeMessages == actual.messages(for: actual.probeUser))
        if let system = actual.systemPrompt {
            precondition(completionMessages.count == 2 && probeMessages.count == 2)
            precondition(completionMessages[0] == ["role": "system", "content": system])
            precondition(probeMessages[0] == completionMessages[0])
        } else {
            precondition(completionMessages == [["role": "user", "content": "fixture"]])
        }
        precondition(legacy.messages(for: "fixture") == [["role": "user", "content": "fixture"]])
        let nfcProfile = ModelChatProfile(base: actual.base, probeUser: actual.probeUser, expectedPrompt: actual.expectedPrompt,
            chatTemplateKwargs: actual.chatTemplateKwargs, templateSHA256: actual.templateSHA256,
            systemPrompt: actual.systemPrompt, textNormalization: "NFC", templateFile: "splash-t2-chat_template.jinja")
        precondition(nfcProfile.isWellFormed)
        let decomposed = "cafe\u{301} Zoe\u{308}"
        let composed = "café Zoë"
        let sent = nfcProfile.messages(for: decomposed).last!["content"]!
        precondition(sent.utf8.elementsEqual(composed.utf8))
        precondition(!decomposed.utf8.elementsEqual(sent.utf8), "Raw source must remain decomposed")
        let custom = #"[Polish request v1] {"editing_prompt":"cafe\#u{301} Zoe\#u{308}"}"#
        let sentCustom = nfcProfile.messages(for: custom).last!["content"]!
        precondition(sentCustom.utf8.elementsEqual(custom.precomposedStringWithCanonicalMapping.utf8))
        precondition(!custom.utf8.elementsEqual(sentCustom.utf8))
        let legacySent = legacy.messages(for: decomposed).last!["content"]!
        precondition(legacySent.utf8.elementsEqual(decomposed.utf8))
        for bad in ["/absolute.jinja", "../outside.jinja", "sub/file.jinja", "sub\\file.jinja", ".", ".."] {
            precondition(!ModelChatProfile.isSafeTemplateBasename(bad))
        }
        precondition(ModelChatProfile.isSafeTemplateBasename("splash-t2-chat_template.jinja"))
        precondition(nfcProfile.templateBasename == "splash-t2-chat_template.jinja")
        precondition(legacy.templateBasename == "chat_template.jinja")
        let changedIdentity = ModelChatProfile(base: actual.base + "-changed", probeUser: actual.probeUser,
            expectedPrompt: actual.expectedPrompt, chatTemplateKwargs: actual.chatTemplateKwargs, templateSHA256: actual.templateSHA256, systemPrompt: actual.systemPrompt)
        precondition(actual != changedIdentity, "A running server must match the full current profile identity")
        let changedSystem = ModelChatProfile(base: actual.base, probeUser: actual.probeUser, expectedPrompt: actual.expectedPrompt,
            chatTemplateKwargs: actual.chatTemplateKwargs, templateSHA256: actual.templateSHA256,
            systemPrompt: actual.systemPrompt == nil ? "identity fixture only" : nil)
        precondition(actual != changedSystem)
        let identity = try actual.identitySHA256()
        let systemChangedIdentity = try changedSystem.identitySHA256()
        precondition(identity != systemChangedIdentity, "Exact optional System participates in the profile hash")
        if CommandLine.arguments.count >= 5 {
            let fixtureData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
            let measurementData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))
            let fixtures = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
            let measurement = try JSONSerialization.jsonObject(with: measurementData) as! [String: Any]
            let cases = fixtures["cases"] as! [[String: Any]]
            let nfd = cases.first { $0["id"] as? String == "nfd" }!
            let nfc = cases.first { $0["id"] as? String == "nfc" }!
            let sourceMessages = nfd["messages"] as! [[String: String]]
            let sentMessages = nfcProfile.messages(for: sourceMessages.last!["content"]!)
            let sentBytes = try JSONSerialization.data(withJSONObject: sentMessages, options: [.sortedKeys])
            let expectedBytes = try JSONSerialization.data(withJSONObject: nfc["messages"]!, options: [.sortedKeys])
            precondition(sentBytes == expectedBytes)
            let nfdProbe = ModelChatProfile(base: actual.base, probeUser: sourceMessages.last!["content"]!,
                expectedPrompt: nfd["prompt"] as! String, chatTemplateKwargs: actual.chatTemplateKwargs,
                templateSHA256: actual.templateSHA256, systemPrompt: sourceMessages.first!["content"], textNormalization: "NFC")
            precondition(nfdProbe.isWellFormed)
            let probeBytes = try JSONSerialization.data(withJSONObject: nfdProbe.probeBody["messages"]!, options: [.sortedKeys])
            precondition(probeBytes == expectedBytes)
            precondition(nfdProbe.matchesRenderedPrompt(nfc["prompt"] as! String))
            precondition(!nfdProbe.matchesRenderedPrompt(nfd["prompt"] as! String), "Raw NFD must not pass the exact NFC rendered-probe byte check")
            let ids = nfd["expected_ids"] as! [Int]
            precondition(ids == nfc["expected_ids"] as! [Int])
            let measured = (measurement["token_checks"] as! [[String: Any]]).first { $0["id"] as? String == "nfd" }!
            precondition(measured["nfc_token_ids_exact"] as? Bool == true)
            precondition(measured["expected_ids"] as! [Int] == ids)
            precondition(measured["expected_tokens"] as? Int == ids.count)
            print("PASS: Swift NFC messages byte-match the measured NFC fixture; exact \(ids.count) expected token IDs match its recorded parity result; raw runtime had \(measured["actual_tokens"]!) tokens. No model called.")
        }
        print("PASS: actual tokenizer-exported Splash profile, exact template hash, both request kwargs, missing/wrong-file/malformed profiles fail closed, T1 bytes unchanged, running profile identity includes exact optional System; probe/completion messages align")
    }
}
#endif
