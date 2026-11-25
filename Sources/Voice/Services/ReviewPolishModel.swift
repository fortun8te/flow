import Foundation

/// Local copy editor for longer selections. Its server is started on demand and released after idle.
actor ReviewPolishModel {
    static let shared = ReviewPolishModel()

    private var server: Process?
    private var serverModel: URL?
    private var port = 0
    private var inFlight = false
    private var idleStop: Task<Void, Never>?

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    nonisolated static var modelFile: URL? {
        installedModel("qwen35-4b-instruct-q4_k_m.gguf", bytes: 2_740_937_888)
    }

    nonisolated static var detailedModelFile: URL? {
        installedModel("Qwen3.5-9B-Q4_K_M.gguf", bytes: 5_680_522_464)
    }

    /// Opt+1's typing-repair model: ExampleModel 1.5 9B (Qwen3.5-9B further trained; beats it on every published
    /// benchmark), official Q4_K_M GGUF, thinking off. Falls back to Qwen3.5-9B when ExampleModel isn't installed.
    nonisolated static var typoFixModelFile: URL? {
        // His own small typing model (25 Nov 2026, training/typing) when picked in Companion and installed.
        if UserDefaults.standard.string(forKey: "voice.typingModel") == "typing1", let own = ownTypingModelFile { return own }
        // 4-bit: the 8-bit build (9.8 GB) ran at ~9 tok/s on this 32 GB Mac next to the dictation model and
        // timed out on long messages (22 Nov 2026). Q4_K_M is about twice as fast with near-identical edits.
        return installedModel("ExampleModel-1.5-9B-Q4_K_M.gguf", bytes: 5_780_090_816) ?? detailedModelFile
    }

    nonisolated static var ownTypingModelFile: URL? {
        let path = WhisperNowTunedPolisher.modelDirectory.deletingLastPathComponent()
            .appendingPathComponent("Typing1", isDirectory: true).appendingPathComponent("typing1-Q8_0.gguf")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    private nonisolated static func installedModel(_ name: String, bytes: Int64) -> URL? {
        let path = WhisperNowTunedPolisher.modelDirectory.deletingLastPathComponent()
            .appendingPathComponent("PolishReview", isDirectory: true).appendingPathComponent(name)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber,
              size.int64Value == bytes else { return nil }
        return path
    }

    func edit(_ source: String, instruction: String, delimitDraft: Bool, timeout: TimeInterval = 14,
              modelFile: URL? = ReviewPolishModel.modelFile,
              example: (draft: String, edit: String)? = nil,
              onlyIfWarm: Bool = false,
              deadline: ContinuousClock.Instant? = nil) async throws -> WhisperNowTunedPolisher.Reply {
        guard !inFlight else { throw WhisperNowTunedPolisher.Failure.busy }
        guard S1MiniPolisher.validateInput(source, maximumCharacters: PolishTransaction.maxCharacters) == nil else { throw WhisperNowTunedPolisher.Failure.invalidInput }
        try Task.checkCancellation()
        guard let model = modelFile, let binary = WhisperNowTunedPolisher.serverBinary() else {
            throw WhisperNowTunedPolisher.Failure.modelMissing
        }
        guard !onlyIfWarm || (serverModel == model && server?.isRunning == true) else {
            throw WhisperNowTunedPolisher.Failure.notReady
        }
        inFlight = true
        idleStop?.cancel()
        defer {
            inFlight = false
            idleStop = Task {
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                guard !Task.isCancelled else { return }
                self.stop()
            }
        }
        if serverModel != model || server?.isRunning != true {
            stop()
            try await start(model: model, binary: binary, deadline: deadline)
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        if let deadline {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds >= 0.25 else { throw WhisperNowTunedPolisher.Failure.timeout }
            request.timeoutInterval = min(timeout, seconds)
        } else {
            request.timeoutInterval = timeout
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let draft = delimitDraft ? "<draft>\n" + source + "\n</draft>" : source
        var messages = [["role": "system", "content": instruction]]
        if let example {
            messages.append(["role": "user", "content": example.draft])
            messages.append(["role": "assistant", "content": example.edit])
        }
        messages.append(["role": "user", "content": draft])
        let words = source.split(whereSeparator: \.isWhitespace).count
        let outputBudget = max(96, words * 4, source.utf8.count / 2 + 32)
        let body: [String: Any] = [
            "messages": messages,
            "temperature": 0, "repeat_penalty": 1.0,
            "max_tokens": min(3_500, outputBudget),
            "cache_prompt": false, "chat_template_kwargs": ["enable_thinking": false]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WhisperNowTunedPolisher.Failure.httpError }
        return try WhisperNowTunedPolisher.parseReply(data)
    }

    private func start(model: URL, binary: URL, deadline: ContinuousClock.Instant?) async throws {
        guard let port = WhisperNowTunedPolisher.freeLocalPort() else { throw WhisperNowTunedPolisher.Failure.startFailed }
        let arguments = ["-m", model.path, "--jinja", "--host", "127.0.0.1", "--port", String(port),
                         "-c", "8192", "-np", "1", "-ngl", "99", "--no-webui"]
        let server = WhisperNowTunedPolisher.watchedServer(binary: binary, arguments: arguments)
        try server.run()
        self.server = server
        self.serverModel = model
        self.port = port
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
            request.timeoutInterval = 1
            let startupDeadline = ContinuousClock.now + .seconds(9)
            let healthDeadline = deadline.map { min($0, startupDeadline) } ?? startupDeadline
            while server.isRunning && ContinuousClock.now < healthDeadline {
                try Task.checkCancellation()
                if let (_, response) = try? await session.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 { return }
                try await Task.sleep(for: .milliseconds(120))
            }
            throw WhisperNowTunedPolisher.Failure.notReady
        } catch {
            stop()
            throw error
        }
    }

    private func stop() {
        if server?.isRunning == true { server?.terminate() }
        server = nil
        serverModel = nil
        port = 0
    }
}
