import Darwin
import Foundation

/// Automatic cleanup with the fine-tuned WhisperNow LFM3 1.7B (GGUF), served by a warm local `llama-server`
/// subprocess on 127.0.0.1 for crash isolation.
///
/// Serving contract (scripts/eval-whispernow.py, the trainer's generate_all): the trimmed transcript as the only
/// user turn, no system prompt, the model's chat template, greedy, repeat penalty 1.05 over the sequence,
/// max tokens max(64, ceil(2.5 x words)). A reply of `EMPTY` means "no speech".
///
/// The server starts on prewarm or use, exits after inactivity, is restarted when it dies (with a back-off),
/// and is stopped with Flow: a shell watchdog kills it if Flow itself goes away. Every failure is reported to
/// the caller, which falls back to S1-mini. Local only: the socket is bound to 127.0.0.1.
actor WhisperNowTunedPolisher {
    static let shared = WhisperNowTunedPolisher()

    /// DOSE1: Flow's own cleanup model, WhisperNow LFM3 1.7B (LiquidAI LFM3 base) fine-tuned on Jordan's dictations.
    nonisolated static var displayName: String {
        guard usesT4 else { return "DOSE1" }
        if routesByLength { return "T5 + T4" }
        return dictationAdapter == .v3c ? "T5" : "T4"
    }
    /// `voice.cleanupModel` value that selects this engine.
    nonisolated static let settingValue = "dose1"
    /// Earlier setting value, still accepted.
    nonisolated static let legacySettingValue = "whispernow-tuned"
    nonisolated static var engineLabel: String { usesT4 ? "local:" + dictationAdapter.traceName : "local:dose1" }
    /// Default automatic cleanup engine when `voice.cleanupModel` is unset and the model is installed.
    nonisolated static let isDefaultEngine = true
    nonisolated static let maximumInputCharacters = 4_000

    enum Failure: String, Error, Sendable {
        case modelMissing, serverMissing, startFailed, templateMismatch, notReady, busy, invalidInput
        case timeout, httpError, badReply, tokenLimit, cancelled
    }

    enum Reply: Equatable, Sendable {
        case text(String)
        /// The model answered EMPTY (no speech).
        case empty
    }

    // MARK: Install locations

    nonisolated static var modelDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VOICE/Models/DOSE1", isDirectory: true)
    }

    nonisolated static var t4Directory: URL {
        modelDirectory.deletingLastPathComponent().appendingPathComponent("T4-step918", isDirectory: true)
    }

    /// Dictation cleanup adapter on the T4 base. T5 v3c step 240 ships; `voice.cleanupAdapter` = "t4" rolls back to
    /// T4 step 918. A missing or short v3c file also falls back to step 918 (22 Nov 2026).
    enum DictationAdapter: String, Sendable {
        case v3c, t4
        var fileName: String { self == .v3c ? "v3c240.gguf" : "step918.gguf" }
        var traceName: String { self == .v3c ? "t5-v3c240" : "t4-step918" }
    }
    nonisolated static let cleanupAdapterKey = "voice.cleanupAdapter"
    nonisolated static let shippingDictationAdapter: DictationAdapter = .v3c

    /// The adapter dictation cleanup uses: the setting, else the shipping one, else step 918 when that file is absent.
    nonisolated static var dictationAdapter: DictationAdapter {
        let requested = pinnedDictationAdapter ?? shippingDictationAdapter
        if requested == .t4 || v3cInstalled { return requested }
        return .t4
    }

    /// `voice.cleanupAdapter` = "v3c" or "t4" pins one adapter for every dictation. Unset (or "auto") routes by length.
    nonisolated static var pinnedDictationAdapter: DictationAdapter? {
        UserDefaults.standard.string(forKey: cleanupAdapterKey).flatMap(DictationAdapter.init(rawValue:))
    }

    private nonisolated static var v3cInstalled: Bool {
        t4Asset(DictationAdapter.v3c.fileName, minimumBytes: 200_000_000) != nil
    }

    /// Length routing (22 Nov 2026 replay of 296 held-out dictations through Flow's live finish path, see
    /// `DictationRouting`): nil when one adapter is pinned or the T5 file is missing.
    nonisolated static var routesByLength: Bool {
        DictationRouting.enabled && pinnedDictationAdapter == nil && v3cInstalled
    }

    /// The adapter for one cleanup call: the pinned one, else routed by the transcript's word count.
    nonisolated static func dictationAdapter(for transcript: String) -> DictationAdapter {
        DictationRouting.choose(words: DictationRouting.words(transcript), pinned: pinnedDictationAdapter,
                                v3cInstalled: v3cInstalled)
    }

    nonisolated static var dictationAdapterFile: URL? {
        t4Asset(dictationAdapter.fileName, minimumBytes: 200_000_000)
    }

    /// The dictation adapters one server loads, in LoRA id order. With routing both stay loaded on the one base
    /// model (about 260 MB more, no second model), and each request picks its adapter by scale.
    nonisolated static var servedDictationAdapters: [DictationAdapter] {
        DictationRouting.served(pinned: pinnedDictationAdapter, v3cInstalled: v3cInstalled)
    }

    /// The `lora` field of a request: scale 1 for `adapter` (or the quick-polish adapter), 0 for the rest.
    nonisolated static func loraScales(served: [DictationAdapter], adapter: DictationAdapter?,
                                       quickLoaded: Bool) -> [[String: Any]] {
        var scales: [[String: Any]] = served.enumerated().map { index, item in
            ["id": index, "scale": item == adapter ? 1 : 0]
        }
        if quickLoaded { scales.append(["id": served.count, "scale": adapter == nil ? 1 : 0]) }
        return scales
    }

    nonisolated static var usesT4: Bool {
        modelFile()?.deletingLastPathComponent() == t4Directory
    }

    private nonisolated static func t4Asset(_ name: String, minimumBytes: Int64) -> URL? {
        let path = t4Directory.appendingPathComponent(name)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber,
              size.int64Value >= minimumBytes else { return nil }
        return path
    }

    /// The adapter files a correctly started server has loaded for the current settings (in LoRA id order).
    nonisolated static var servedAdapterFiles: [URL] {
        guard usesT4 else { return [] }
        let files = servedDictationAdapters.compactMap { t4Asset($0.fileName, minimumBytes: 200_000_000) }
        return files.count == servedDictationAdapters.count ? files : []
    }

    nonisolated static var hasQuickPolishAdapter: Bool {
        usesT4 && t4Asset("opt1-strict.gguf", minimumBytes: 100_000_000) != nil
    }

    nonisolated static func t4Prompt(_ transcript: String) -> String {
        "[Cleanup: light] [Styling: excited] [Structure: lists] [Context: general]\n" + transcript
    }

    /// The GGUF Flow serves: `voice.whispernowModelFile` override, else manifest.json "active", else Q8_0, else Q6_K.
    nonisolated static func modelFile(in directory: URL = modelDirectory) -> URL? {
        if directory == modelDirectory, UserDefaults.standard.string(forKey: "voice.whispernowModelFile") == nil,
           let base = t4Asset("base-Q8_0.gguf", minimumBytes: 1_800_000_000),
           t4Asset("step918.gguf", minimumBytes: 200_000_000) != nil,
           t4Asset("chat_template.jinja", minimumBytes: 1) != nil {
            return base
        }
        var names: [String] = []
        if let override = UserDefaults.standard.string(forKey: "voice.whispernowModelFile") { names.append(override) }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let active = json["active"] as? String { names.append(active) }
        names += ["model-Q8_0.gguf", "model-Q6_K.gguf"]
        for name in names where name.hasSuffix(".gguf") && !name.contains("/") {
            let url = directory.appendingPathComponent(name)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.int64Value > 100_000_000 { return url }
        }
        return nil
    }

    /// llama-server: `voice.whispernowServerPath`, a copy bundled in Flow.app, then Homebrew/MacPorts locations.
    nonisolated static func serverBinary() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let override = UserDefaults.standard.string(forKey: "voice.whispernowServerPath") { candidates.append(override) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("llama/llama-server").path { candidates.append(bundled) }
        candidates += [fm.homeDirectoryForCurrentUser.appendingPathComponent("homebrew/bin/llama-server").path,
                       "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    nonisolated static var isInstalled: Bool { modelFile() != nil && serverBinary() != nil }

    nonisolated static var supportsSelectedTextPolish: Bool {
        guard isInstalled, !usesT4, let model = modelFile() else { return false }
        return T2PolishOptions.supports(
            manifest: try? Data(contentsOf: modelDirectory.appendingPathComponent("manifest.json")),
            modelFilename: model.lastPathComponent)
    }

    nonisolated static var activeT2Contracts: Set<String> {
        guard !usesT4, let model = modelFile() else { return [] }
        return T2CleanupOptions.activeContracts(
            manifest: try? Data(contentsOf: modelDirectory.appendingPathComponent("manifest.json")),
            modelFilename: model.lastPathComponent)
    }
    nonisolated static var usesT2Contracts: Bool { activeT2Contracts.contains(where: { $0.hasPrefix("t2-") }) }
    nonisolated static var supportsCleanupControls: Bool {
        isInstalled && activeT2Contracts.contains(T2CleanupOptions.contract)
    }

    /// T2 profiles are mandatory and must match the installed template, before a server can start.
    nonisolated static var activeChatProfile: ModelChatProfile? {
        guard let model = modelFile() else { return nil }
        let manifest = try? Data(contentsOf: modelDirectory.appendingPathComponent("manifest.json"))
        let explicit = usesT2Contracts
        let declared = explicit ? ModelChatProfile.declaredProfile(manifest: manifest, modelFilename: model.lastPathComponent) : .legacyT1
        guard let declared else { return nil }
        return ModelChatProfile.resolve(manifest: manifest,
            modelFilename: model.lastPathComponent, requiresExplicitProfile: explicit,
            templateData: try? Data(contentsOf: model.deletingLastPathComponent().appendingPathComponent(declared.templateBasename)))
    }

    nonisolated static func tokenBudget(for transcript: String) -> Int {
        max(64, Int(ceil(2.5 * Double(transcript.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count))))
    }

    /// Request timeout: warm replies take ~0.2-0.6 s; long dictations get more room.
    nonisolated static func timeout(for transcript: String) -> TimeInterval {
        min(20, 4 + 0.03 * Double(transcript.split(separator: " ").count))
    }

    /// What the served template must render for this probe (WhisperNow's golden prompt).
    nonisolated static let goldenProbe = ModelChatProfile.legacyT1.probeUser
    nonisolated static let goldenPrompt = ModelChatProfile.legacyT1.expectedPrompt

    // MARK: State

    private var process: Process?
    private var port: Int = 0
    private var runningModelURL: URL?
    /// The dictation adapters the running server loaded, in LoRA id order. A changed `voice.cleanupAdapter` restarts it.
    private var runningAdapterURLs: [URL] = []
    private var runningAdapters: [DictationAdapter] = []
    private var runningChatProfile: ModelChatProfile?
    private var runningSelectedTextContract = false
    private var runningCleanupContract = false
    private var runningQuickAdapter = false
    private var starting: Task<Bool, Never>?
    private var inFlight = false
    private var idleStop: Task<Void, Never>?
    // Stay warm: a cold start made Opt+1 wait 6-8 s and then give up (21 Nov 2026).
    private static let idleLifetime: Duration = .seconds(3 * 60 * 60)
    private var recentDeaths: [Date] = []
    private var lastStartFailure: Date?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    var isRunning: Bool { process?.isRunning == true && port > 0 && starting == nil }

    // MARK: Lifecycle

    /// Starts the server if it is not running and waits until it answers. Safe to call repeatedly.
    @discardableResult
    func prepare() async -> Bool {
        if isRunning {
            if runningModelURL == Self.modelFile(), runningChatProfile == Self.activeChatProfile,
               runningAdapterURLs == Self.servedAdapterFiles {
                scheduleIdleStop()
                return true
            }
            guard !inFlight else { return false }
            shutdown()
        }
        if let starting { return await starting.value }
        guard Self.isInstalled else { return false }
        guard !Self.usesT2Contracts || Self.supportsCleanupControls || Self.supportsSelectedTextPolish else { return false }
        // Back-off: a server that died three times in five minutes, or failed to start in the last
        // minute, is not restarted on every dictation (S1-mini covers in the meantime).
        recentDeaths = recentDeaths.filter { Date().timeIntervalSince($0) < 300 }
        if recentDeaths.count >= 3 { return false }
        if let lastStartFailure, Date().timeIntervalSince(lastStartFailure) < 60 { return false }
        let task = Task { await self.start() }
        starting = task
        let ok = await task.value
        starting = nil
        if ok { scheduleIdleStop() }
        else { lastStartFailure = Date() }
        return ok
    }

    /// Starts the server in the background without waiting (used when a dictation finds it cold).
    func prepareInBackground() {
        guard !isRunning, starting == nil else { return }
        Task { await self.prepare() }
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        guard isRunning, !inFlight else { return }
        idleStop = Task { [weak self] in
            do { try await Task.sleep(for: Self.idleLifetime) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.releaseIfIdle()
        }
    }

    /// A separate large draft editor can free this server if it is not doing work.
    func releaseIfIdle() {
        guard !Task.isCancelled, !inFlight, starting == nil else { return }
        shutdown()
    }

    func shutdown() {
        idleStop?.cancel()
        idleStop = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        port = 0
        runningModelURL = nil
        runningAdapterURLs = []
        runningAdapters = []
        runningChatProfile = nil
        runningSelectedTextContract = false
        runningCleanupContract = false
        runningQuickAdapter = false
    }

    private func start() async -> Bool {
        guard let model = Self.modelFile(), let binary = Self.serverBinary(),
              let chatProfile = Self.activeChatProfile else { return false }
        shutdown()
        guard let freePort = Self.freeLocalPort() else { return false }
        let isT4 = model.deletingLastPathComponent() == Self.t4Directory
        let logURL = model.deletingLastPathComponent().appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let logHandle = try? FileHandle(forWritingTo: logURL)

        var arguments = ["-m", model.path, "--jinja", "--host", "127.0.0.1", "--port", String(freePort),
                         "-c", "8192", "-np", "1", "-ngl", "99", "--no-webui"]
        var quickAdapterLoaded = false
        let adapterFiles = isT4 ? Self.servedAdapterFiles : []
        let adapters = isT4 ? Self.servedDictationAdapters : []
        if isT4 {
            guard let first = adapterFiles.first else { return false }
            arguments += ["--lora", first.path]
            for other in adapterFiles.dropFirst() { arguments += ["--lora-scaled", other.path + ":0"] }
            if let quick = Self.t4Asset("opt1-strict.gguf", minimumBytes: 100_000_000) {
                arguments += ["--lora-scaled", quick.path + ":0"]
                quickAdapterLoaded = true
            }
        }
        let template = model.deletingLastPathComponent().appendingPathComponent(chatProfile.templateBasename)
        if FileManager.default.fileExists(atPath: template.path) { arguments += ["--chat-template-file", template.path] }

        let process = Self.watchedServer(binary: binary, arguments: arguments, log: logHandle)
        process.terminationHandler = { [weak self] terminated in
            Task { await self?.noteTermination(terminated) }
        }
        do { try process.run() } catch {
            Telemetry.log("cleanup.whispernow_server", properties: ["event": "launch_failed"])
            return false
        }
        self.process = process
        self.port = freePort
        self.runningModelURL = model
        self.runningAdapterURLs = adapterFiles
        self.runningAdapters = adapters
        self.runningChatProfile = chatProfile
        self.runningSelectedTextContract = Self.supportsSelectedTextPolish
        self.runningCleanupContract = Self.supportsCleanupControls
        self.runningQuickAdapter = quickAdapterLoaded
        let began = Date()
        while Date().timeIntervalSince(began) < 90 {
            guard process.isRunning else { break }
            if await health(port: freePort) {
                guard await templateMatches(port: freePort, profile: chatProfile) else {
                    Telemetry.log("cleanup.whispernow_server", properties: ["event": "template_mismatch"])
                    shutdown(); return false
                }
                Telemetry.log("cleanup.whispernow_server", properties: [
                    "event": "ready", "ms": Int(Date().timeIntervalSince(began) * 1000), "model": model.lastPathComponent])
                // Warm-up so the first dictation does not pay the first-token cost.
                let warmup: String
                if isT4 {
                    warmup = Self.t4Prompt("okay cool")
                } else if Self.supportsCleanupControls {
                    warmup = T2CleanupOptions().userContent(transcript: "okay cool")!
                } else if Self.supportsSelectedTextPolish {
                    warmup = T2PolishOptions().userPrompt(text: "okay cool")!
                } else {
                    warmup = "okay cool"
                }
                if isT4 {
                    for adapter in adapters {
                        _ = try? await complete(warmup, port: freePort, budgetText: "okay cool", adapter: adapter)
                    }
                } else {
                    _ = try? await complete(warmup, port: freePort, budgetText: "okay cool")
                }
                if quickAdapterLoaded && UserDefaults.standard.bool(forKey: HotkeyService.quickPolishEnabledKey) {
                    _ = try? await complete("[Polish: light]\nokay cool", port: freePort,
                                            budgetText: "okay cool", quickPolish: true)
                }
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        Telemetry.log("cleanup.whispernow_server", properties: ["event": "start_failed"])
        shutdown()
        return false
    }

    private func noteTermination(_ terminated: Process? = nil) {
        guard let process, !process.isRunning, terminated == nil || process === terminated else { return }
        idleStop?.cancel()
        idleStop = nil
        recentDeaths.append(Date())
        Telemetry.log("cleanup.whispernow_server", properties: ["event": "exited", "status": Int(process.terminationStatus)])
        self.process = nil
        port = 0
        runningModelURL = nil
        runningAdapterURLs = []
        runningAdapters = []
        runningChatProfile = nil
        runningSelectedTextContract = false
        runningCleanupContract = false
        runningQuickAdapter = false
    }

    // MARK: Cleanup

    /// One cleanup. Never throws; any failure is returned so the caller can fall back.
    /// `adapter` is the T4-base adapter for this call (`dictationAdapter(for:)`); nil picks it from the transcript.
    func clean(_ transcript: String, adapter: DictationAdapter? = nil) async -> Result<Reply, Failure> {
        // An activated T2 must use its explicit task contract, never T1's bare-text prompt.
        guard !Self.usesT2Contracts else { return .failure(.invalidInput) }
        let input = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .success(.empty) }
        guard input.count <= Self.maximumInputCharacters, S1MiniPolisher.validateInput(input) == nil else {
            return .failure(.invalidInput)
        }
        guard Self.modelFile() != nil else { return .failure(.modelMissing) }
        guard Self.serverBinary() != nil else { return .failure(.serverMissing) }
        if !isRunning {
            // Cold or died: start it for the next dictation; this one falls back.
            prepareInBackground()
            return .failure(.notReady)
        }
        guard !inFlight else { return .failure(.busy) }
        guard runningModelURL == Self.modelFile(), runningChatProfile == Self.activeChatProfile,
              runningAdapterURLs == Self.servedAdapterFiles else {
            shutdown()
            prepareInBackground()
            return .failure(.notReady)
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        inFlight = true
        idleStop?.cancel()
        defer {
            inFlight = false
            scheduleIdleStop()
        }
        do {
            let prompt = Self.usesT4 ? Self.t4Prompt(input) : input
            let chosen = Self.usesT4 ? (adapter ?? Self.dictationAdapter(for: input)) : nil
            return .success(try await complete(prompt, port: port, budgetText: input, adapter: chosen))
        } catch let failure as Failure {
            if failure == .httpError || failure == .timeout, process?.isRunning != true { noteTermination() }
            return .failure(failure)
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .httpError)
        }
    }

    func cleanControlled(_ text: String, options: T2CleanupOptions) async -> Result<Reply, Failure> {
        guard Self.supportsCleanupControls else { return .failure(.modelMissing) }
        guard Self.activeChatProfile != nil else { return .failure(.templateMismatch) }
        guard options.isSupported(by: Self.activeT2Contracts),
              let input = options.userContent(transcript: text) else { return .failure(.invalidInput) }
        guard isRunning else {
            prepareInBackground()
            return .failure(.notReady)
        }
        guard !inFlight else { return .failure(.busy) }
        guard runningCleanupContract, runningModelURL == Self.modelFile(),
              runningChatProfile == Self.activeChatProfile else {
            shutdown()
            prepareInBackground()
            return .failure(.notReady)
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        inFlight = true
        idleStop?.cancel()
        defer {
            inFlight = false
            scheduleIdleStop()
        }
        do { return .success(try await complete(input, port: port, budgetText: text)) }
        catch let failure as Failure { return .failure(failure) }
        catch { return .failure(Task.isCancelled ? .cancelled : .httpError) }
    }

    /// A capable T2 uses its trained envelope. T1's clean() above stays byte-for-byte compatible.
    func polishSelected(_ text: String, options: T2PolishOptions) async -> Result<Reply, Failure> {
        guard Self.supportsSelectedTextPolish else { return .failure(.modelMissing) }
        guard Self.activeChatProfile != nil else { return .failure(.templateMismatch) }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Self.maximumInputCharacters,
              S1MiniPolisher.validateInput(text) == nil,
              let input = options.userPrompt(text: text) else { return .failure(.invalidInput) }
        guard isRunning else {
            prepareInBackground()
            return .failure(.notReady)
        }
        // An already-warm T1 server must never receive a newly activated T2 envelope.
        guard !inFlight else { return .failure(.busy) }
        guard runningSelectedTextContract, runningModelURL == Self.modelFile(),
              runningChatProfile == Self.activeChatProfile else {
            shutdown()
            prepareInBackground()
            return .failure(.notReady)
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        inFlight = true
        idleStop?.cancel()
        defer {
            inFlight = false
            scheduleIdleStop()
        }
        do { return .success(try await complete(input, port: port, budgetText: text)) }
        catch let failure as Failure { return .failure(failure) }
        catch { return .failure(Task.isCancelled ? .cancelled : .httpError) }
    }

    func quickPolish(_ text: String) async -> Result<Reply, Failure> {
        guard Self.hasQuickPolishAdapter,
              text.count <= Self.maximumInputCharacters,
              S1MiniPolisher.validateInput(text) == nil else { return .failure(.invalidInput) }
        guard isRunning else { prepareInBackground(); return .failure(.notReady) }
        guard runningQuickAdapter else { return .failure(.notReady) }
        guard !inFlight else { return .failure(.busy) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        inFlight = true
        idleStop?.cancel()
        defer {
            inFlight = false
            scheduleIdleStop()
        }
        do {
            return .success(try await complete("[Polish: light]\n" + text, port: port, budgetText: text, quickPolish: true))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .httpError)
        }
    }

    private func complete(_ input: String, port: Int, budgetText: String? = nil,
                          quickPolish: Bool = false, adapter: DictationAdapter? = nil) async throws -> Reply {
        guard let profile = runningChatProfile, profile == Self.activeChatProfile,
              runningModelURL == Self.modelFile() else { throw Failure.templateMismatch }
        var body = profile.completionBody(userContent: input, sourceText: budgetText ?? input)
        if quickPolish {
            guard runningQuickAdapter else { throw Failure.notReady }
            // Override the adapters only for this request: every dictation adapter off, the quick one on.
            body["lora"] = Self.loraScales(served: runningAdapters, adapter: nil, quickLoaded: true)
        } else if let adapter, !runningAdapters.isEmpty {
            // A served adapter on, every other one (and the quick one) off. Switching costs only the prompt cache.
            guard runningAdapters.contains(adapter) else { throw Failure.notReady }
            body["lora"] = Self.loraScales(served: runningAdapters, adapter: adapter, quickLoaded: runningQuickAdapter)
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = quickPolish ? 2 : Self.timeout(for: budgetText ?? input)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            if Task.isCancelled { throw Failure.cancelled }
            if (error as? URLError)?.code == .timedOut { throw Failure.timeout }
            throw Failure.httpError
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.httpError }
        return try Self.parseReply(data)
    }

    nonisolated static func parseReply(_ data: Data) throws -> Reply {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first else { throw Failure.badReply }
        if choice["finish_reason"] as? String == "length" { throw Failure.tokenLimit }
        let content = ((choice["message"] as? [String: Any])?["content"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty || content == "EMPTY" { return .empty }
        let lower = content.lowercased()
        if ["<|im_start|>", "<|im_end|>", "<think>", "</think>"].contains(where: lower.contains) { throw Failure.badReply }
        return .text(content)
    }

    private func health(port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["status"] as? String == "ok"
    }

    private func templateMatches(port: Int, profile: ModelChatProfile) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/apply-template")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: profile.probeBody)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let rendered = json["prompt"] as? String else { return false }
        return profile.matchesRenderedPrompt(rendered)
    }

    nonisolated static func watchedServer(binary: URL, arguments: [String], log: FileHandle? = nil) -> Process {
        // The watchdog shell stops llama-server when Flow exits for any reason (including a crash), and
        // forwards a normal terminate. `$0` is llama-server; the rest are its arguments.
        let watchdog = """
        "$0" "$@" & child=$!
        trap 'kill $child 2>/dev/null; exit 0' TERM INT HUP
        while kill -0 \(getpid()) 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 2; done
        kill $child 2>/dev/null; wait $child
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", watchdog, binary.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        return process
    }

    nonisolated static func freeLocalPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

// MARK: - Decision (model output -> guarded text)

/// What Flow does with a WhisperNow reply. Pure, so the rules are unit-tested without a model.
enum WhisperNowCleanupDecision {
    enum Outcome: Equatable, Sendable {
        /// The model's cleanup passed the content guard.
        case model
        /// EMPTY for a transcript of hesitation sounds only: paste nothing.
        case noSpeech
        /// The model failed or tripped the guard; S1-mini's output passed it.
        case s1mini(reason: String)
        /// Neither passed: the transcript with only clear hesitation sounds removed.
        case stripped(reason: String)

        var label: String {
            switch self {
            case .model: return "model"
            case .noSpeech: return "no-speech"
            case .s1mini: return "s1mini"
            case .stripped: return "stripped"
            }
        }

        var reason: String? {
            switch self {
            case .s1mini(let reason), .stripped(let reason): return reason
            default: return nil
            }
        }
    }

    /// `s1` is asked only when the model's output is not used; it returns S1-mini's candidate or nil.
    static func decide(source: String, reply: Result<WhisperNowTunedPolisher.Reply, WhisperNowTunedPolisher.Failure>,
                       s1: () async -> String?) async -> (text: String, outcome: Outcome) {
        let reason: String
        switch reply {
        case .success(.empty):
            if WhisperNowContentGuard.isNoiseOnly(source) { return ("", .noSpeech) }
            reason = WhisperNowContentGuard.Trip.empty.label
        case .success(.text(let output)):
            if let rejection = rejectionReason(source: source, output: output) {
                reason = rejection
            } else {
                return (output, .model)
            }
        case .failure(let failure):
            reason = "failure:" + failure.rawValue
        }
        if let candidate = await s1(), rejectionReason(source: source, output: candidate) == nil {
            return (candidate, .s1mini(reason: reason))
        }
        // The fallback still gets the deterministic word pass, so hesitations never reach the paste.
        // A transcript that talks about fillers keeps them: the final pass removes only real hesitations.
        let base = DictationFinalPass.fillerMentions(source).isEmpty
            ? WhisperNowContentGuard.stripHesitations(source) : WhisperNowContentGuard.capitalisingLines(source)
        return (DictationFinalPass.apply(base), .stripped(reason: reason))
    }

    private static func rejectionReason(source: String, output: String) -> String? {
        // A shortened long cleanup is a truncation, not an edit: fall back to the raw-but-formatted text (22 Nov 2026).
        if WhisperNowContentGuard.shortened(source: source, output: output) { return "shortened" }
        if let trip = WhisperNowContentGuard.trip(source: source, output: output) { return trip.label }
        if MeaningIntegrity.introducesNegation(original: source, candidate: output) { return "negation-added" }
        // "the word um", "when I say uh": the filler is the subject, so it must survive (22 Nov 2026).
        if DictationFinalPass.dropsFillerMention(source: source, output: output) { return "filler-mention" }
        return nil
    }

    /// The live finish task pastes nothing when the tuned model confirmed a transcript of hesitation sounds only.
    @MainActor static func isConfirmedNoSpeech(polished: String, formatted: String) -> Bool {
        polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Qwen3Polisher.effectiveAutomaticCleanupModel == WhisperNowTunedPolisher.settingValue
            && (WhisperNowTunedPolisher.usesT2Contracts
                ? T2ResponseSafety.isHesitationOnly(formatted) : WhisperNowContentGuard.isNoiseOnly(formatted))
    }
}

// MARK: - Length routing between the two dictation adapters

/// Which T4-base adapter cleans a dictation, by its word count. Both adapters stay loaded on one server, so a
/// switch is a per-request LoRA scale (no second model, no reload). `voice.cleanupAdapter` pins one instead.
///
/// OFF (22 Nov 2026). Replay of the 296 held-out test dictations through Flow's live finish path, edits per
/// 100 words against the reference (v3c / step 918): under 30 words 7.80 / 7.95, 30-120 words 8.50 / 8.18,
/// over 120 words 10.02 / 10.06. Meaning errors 0/0, 4/4, 1/2; median latency the same. No bucket's
/// difference is outside its 95% bootstrap interval (-0.43..0.10, -0.31..1.01, -0.56..0.54), so v3c stays
/// for every length. The earlier "v3c wins long, step 918 short" finding came from model-only scores; Flow's
/// paragraph pass evens out the difference.
enum DictationRouting {
    /// Off switch for the routing as a whole (false = every dictation uses the shipping adapter).
    static let enabled = false
    /// With routing on: calls with at least this many words use T5 v3c; shorter ones use T4 step 918.
    static let longWords = 120

    static func adapter(words: Int) -> WhisperNowTunedPolisher.DictationAdapter {
        words >= longWords ? .v3c : .t4
    }

    /// The whole rule: a pinned adapter wins; without the T5 file everything uses step 918; else by length
    /// when routing is on, or the shipping adapter.
    static func choose(words: Int, pinned: WhisperNowTunedPolisher.DictationAdapter?,
                       v3cInstalled: Bool, routing: Bool = enabled) -> WhisperNowTunedPolisher.DictationAdapter {
        if pinned == .t4 || !v3cInstalled { return .t4 }
        if let pinned { return pinned }
        return routing ? adapter(words: words) : WhisperNowTunedPolisher.shippingDictationAdapter
    }

    /// Adapters one server loads, in LoRA id order.
    static func served(pinned: WhisperNowTunedPolisher.DictationAdapter?, v3cInstalled: Bool,
                       routing: Bool = enabled) -> [WhisperNowTunedPolisher.DictationAdapter] {
        if pinned == .t4 || !v3cInstalled { return [.t4] }
        if let pinned { return [pinned] }
        return routing ? [.v3c, .t4] : [WhisperNowTunedPolisher.shippingDictationAdapter]
    }

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}
