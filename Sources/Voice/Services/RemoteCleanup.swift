// Flow: long-dictation cleanup on Jordan's Windows PC (RTX 5080), over the LAN only.
//
// The PC serves the same T4 model that Flow runs on the Mac, with more time per reply. Its answer is
// treated exactly like a local T4 answer: the same content guard and negation check (WhisperNowCleanupDecision),
// an English check on input and output, and the same minimal postprocessor. The caller then runs the usual
// final pass and real-word (tinyfix) pass. Anything that does not pass returns nil and the local path runs.
//
// PC side: AgentWorkspace\pc-cleanup (pc_cleanup_server.py, scheduled task FlowPCCleanup, starts at logon).
// The token lives in the login Keychain (service com.example.flow.voice.keys, account pcCleanupToken).

import Foundation
import KeychainAccess
import NaturalLanguage

enum RemoteCleanup {
    /// Setting: send cleanup to the PC when it answers in time. Default on.
    static let settingKey = "voice.pcCleanup"
    /// Setting: base URL of the PC server. Empty means the default below.
    static let urlSettingKey = "voice.pcCleanupURL"
    static let defaultBaseURL = "http://127.0.0.1:8765"
    static let keychainService = "com.example.flow.voice.keys"
    static let tokenAccount = "pcCleanupToken"
    /// Dictations above this many words go to the PC. Shorter ones go only when the local T4 server is not running.
    static let minimumWords = DictationDeadline.longWordThreshold
    static let healthCacheSeconds: TimeInterval = 30
    static let healthTimeoutSeconds: TimeInterval = 0.5

    static let sharedClient = Client()

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        // Off unless turned on: Jordan does not want dictations sent to the PC (21 Nov 2026).
        return defaults.object(forKey: settingKey) == nil ? false : defaults.bool(forKey: settingKey)
    }

    static var baseURL: URL? {
        let raw = UserDefaults.standard.string(forKey: urlSettingKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return URL(string: raw.isEmpty ? defaultBaseURL : raw)
    }

    static func token() -> String? {
        guard let value = try? Keychain(service: keychainService).get(tokenAccount) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let spent = start.duration(to: ContinuousClock.now)
        return Double(spent.components.seconds) + Double(spent.components.attoseconds) / 1e18
    }

    /// The PC's cleanup of `text` after the local guards, or nil. nil means the caller runs its usual local path:
    /// the PC is off, not wanted for this dictation, asleep, slow, or its answer did not pass.
    @MainActor static func cleanedText(_ text: String, cleanupLevel: String, userVocabulary: [String]?, personalityStyle: String,
                            appContextLabel: String?, longProse: Bool, timeout: TimeInterval,
                            client: Client = sharedClient) async -> String? {
        guard isEnabled, cleanupLevel != "none", Qwen3Polisher.isEnabled,
              Qwen3Polisher.effectiveAutomaticCleanupModel == WhisperNowTunedPolisher.settingValue,
              WhisperNowTunedPolisher.usesT4, !WhisperNowTunedPolisher.usesT2Contracts,
              // A general model picked in Companion (24 Nov 2026) is tried locally first; the PC would bypass it.
              GeneralCleanupModel.selectedEntry == nil else { return nil }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = input.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        // Short dictations stay local while the local server is warm: it answers in well under the deadline.
        if words <= minimumWords, await WhisperNowTunedPolisher.shared.isRunning { return nil }
        guard let base = baseURL, let token = token() else { return nil }
        return await guardedCleanup(input, client: client, base: base, token: token, timeout: timeout,
                                    userVocabulary: userVocabulary, personalityStyle: personalityStyle,
                                    appContextLabel: appContextLabel)
    }

    /// The network step and the guards, with the connection passed in so tests can use a fake server.
    static func guardedCleanup(_ input: String, client: Client, base: URL, token: String, timeout: TimeInterval,
                               userVocabulary: [String]?, personalityStyle: String, appContextLabel: String?) async -> String? {
        guard input.count >= 4, input.count <= WhisperNowTunedPolisher.maximumInputCharacters,
              S1MiniPolisher.validateInput(input) == nil, !Qwen3Polisher.isNonEnglish(input) else { return nil }
        guard englishDominant(input) || WhisperNowContentGuard.isNoiseOnly(input) else { return nil }

        let started = CFAbsoluteTimeGetCurrent()
        func report(_ outcome: String) {
            Telemetry.log("cleanup.remote", properties: ["outcome": outcome,
                                                         "ms": Int((CFAbsoluteTimeGetCurrent() - started) * 1000),
                                                         "words": input.split(separator: " ").count])
        }
        guard await client.isHealthy(base: base, token: token) else { report("unavailable"); return nil }
        let budget = WhisperNowTunedPolisher.tokenBudget(for: input)
        guard let raw = await client.clean(WhisperNowTunedPolisher.t4Prompt(input), base: base, token: token,
                                           maxTokens: budget, timeout: timeout) else {
            report("unavailable"); return nil
        }
        let reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = reply.lowercased()
        // Same reply rules as the local server: EMPTY and template leaks never reach the paste.
        guard !reply.isEmpty, reply != "EMPTY",
              !["<|im_start|>", "<|im_end|>", "<think>", "</think>"].contains(where: lower.contains) else {
            report("rejected:reply"); return nil
        }
        let decision = await WhisperNowCleanupDecision.decide(source: input, reply: .success(.text(reply))) { nil }
        guard decision.outcome == .model else { report("rejected:" + (decision.outcome.reason ?? decision.outcome.label)); return nil }
        guard englishDominant(decision.text) else { report("rejected:language"); return nil }
        let finalText = Qwen3Polisher.applyMinimalPostprocessor(decision.text, userVocabulary: userVocabulary,
                                                                personalityStyle: personalityStyle, appContextLabel: appContextLabel)
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { report("rejected:empty"); return nil }
        report("accepted")
        return finalText
    }

    static func englishDominant(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english
    }

    /// Talks to the PC. The health answer is cached for `healthCacheSeconds`, good or bad, and a failed
    /// request counts as unhealthy, so a sleeping PC costs one short wait, not one per dictation.
    actor Client {
        private let session: URLSession
        private var cachedHealth: (at: Date, ok: Bool)?

        init(session: URLSession = Client.liveSession()) {
            self.session = session
        }

        static func liveSession() -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            config.waitsForConnectivity = false
            config.connectionProxyDictionary = [:]  // LAN only: never through a system proxy
            return URLSession(configuration: config)
        }

        func isHealthy(base: URL, token: String) async -> Bool {
            if let cached = cachedHealth, Date().timeIntervalSince(cached.at) < RemoteCleanup.healthCacheSeconds {
                return cached.ok
            }
            var request = URLRequest(url: base.appendingPathComponent("health"))
            request.timeoutInterval = RemoteCleanup.healthTimeoutSeconds
            request.setValue(token, forHTTPHeaderField: "X-Flow-Token")
            var ok = false
            do {
                let (data, response) = try await session.data(for: request)
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                ok = (response as? HTTPURLResponse)?.statusCode == 200 && json?["ok"] as? Bool == true
            } catch {
                ok = false
            }
            cachedHealth = (Date(), ok)
            return ok
        }

        /// One cleanup call. Returns the model's raw text, or nil on any failure or timeout.
        func clean(_ prompt: String, base: URL, token: String, maxTokens: Int, timeout: TimeInterval) async -> String? {
            var request = URLRequest(url: base.appendingPathComponent("v1/cleanup"))
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token, forHTTPHeaderField: "X-Flow-Token")
            guard let body = try? JSONSerialization.data(withJSONObject: ["content": prompt, "max_tokens": maxTokens]) else {
                return nil
            }
            request.httpBody = body
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String else {
                    cachedHealth = (Date(), false)
                    return nil
                }
                return text
            } catch {
                cachedHealth = (Date(), false)
                return nil
            }
        }
    }
}
