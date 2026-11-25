import Foundation

#if canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXLLM
import MLXLMCommon
#endif

/// English ASR normalization only. S1-mini is not a general editing model.
/// The caller retains the original transcript for every non-accepted result.
actor S1MiniPolisher {
    static let shared = S1MiniPolisher()

    nonisolated static let displayName = "S1-mini"
    nonisolated static let attribution = "S1-mini by Superwhisper"
    nonisolated static let modelID = "mlx-community/S1-mini-MLX-4bit"
    nonisolated static let modelRevision = "5cbd7aec3401144f88a331d385c40b65fd2548eb"
    nonisolated static let weightsSHA256 = "284990f04854426d6164d634d8c472d7eb6e79c68f8fd8b4c8a80a4f234276ba"
    nonisolated static let weightsBytes = 335_450_548
    nonisolated static let maximumTranscriptTokens = 1_000
    nonisolated static let maximumInputCharacters = 4_000

    // Exact trained prompt from the upstream v1 model card. Do not append
    // custom instructions, context snippets or the generic cleanup prompt.
    nonisolated static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    enum Styling: String, CaseIterable, Codable, Sendable {
        case casual
        case semiCasual = "semi-casual"
        case semiFormal = "semi-formal"
        case formal
    }

    enum Structure: String, CaseIterable, Codable, Sendable {
        case prose
        case lists
    }

    enum Context: String, CaseIterable, Codable, Sendable {
        case general
        case email
    }

    struct Options: Equatable, Sendable {
        var styling: Styling = .semiFormal
        var structure: Structure = .prose
        var context: Context = .general

        var controlLine: String {
            "[Styling: \(styling.rawValue)] [Structure: \(structure.rawValue)] [Context: \(context.rawValue)]"
        }
    }

    enum Unavailability: String, Sendable {
        case unsupportedLanguage
        case missingOrInvalidCache
        case runtimeNotLinked
        case loadFailed
        case busy
    }

    enum Rejection: String, Sendable {
        case inputTooLong
        case invalidInput
        case cancelled
        case deadline
        case tokenLimit
        case generationFailed
        case emptyOutput
        case unexpectedWrapper
        case meaningChanged
        case protectedContentChanged
    }

    enum Result: Equatable, Sendable {
        /// An empty accepted string is permitted only for recognized filler-only input.
        case accepted(String)
        case unchanged
        case unavailable(Unavailability)
        case rejected(Rejection)

        func textPreservingOriginal(_ original: String) -> String {
            if case .accepted(let text) = self { return text }
            return original
        }
    }

    enum Readiness: String, Sendable {
        case missing
        case cached
        case loading
        case loaded
        case runtimeNotLinked
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/models/mlx-community/S1-mini-MLX-4bit", isDirectory: true)
    }

    private let directory: URL
    private var inferenceInFlight = false
    private var idleUnload: Task<Void, Never>?
    private static let idleLifetime: Duration = .seconds(75)

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private var container: ModelContainer?
    private var loading: (id: UUID, task: Task<ModelContainer, Error>)?
    #endif

    init(directory: URL = S1MiniPolisher.defaultDirectory) {
        self.directory = directory
    }

    func readiness() -> Readiness {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        if container != nil { return .loaded }
        if loading != nil { return .loading }
        return Self.isCompleteCache(at: directory) ? .cached : .missing
        #else
        return .runtimeNotLinked
        #endif
    }

    /// Explicit local preparation, with no ID-based downloader or cloud path.
    /// One cancelled waiter does not cancel a load shared by other waiters.
    @discardableResult
    func prepare() async -> Bool {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        guard !Task.isCancelled else { return false }
        let loaded = await localContainer() != nil
        if loaded { scheduleIdleUnload() }
        return loaded && !Task.isCancelled
        #else
        return false
        #endif
    }

    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        guard !inferenceInFlight else { return }
        idleUnload = Task { [weak self] in
            do { try await Task.sleep(for: Self.idleLifetime) } catch { return }
            guard !Task.isCancelled else { return }
            _ = await self?.unloadIfIdle()
        }
    }

    /// Only release an idle model. Calling this never cancels accepted work.
    @discardableResult
    func unloadIfIdle() -> Bool {
        guard !Task.isCancelled, !inferenceInFlight else { return false }
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        guard loading == nil else { return false }
        if container != nil {
            container = nil
            // Release allocator-held buffers after dropping the model reference.
            MLX.GPU.clearCache()
        }
        #endif
        idleUnload?.cancel()
        idleUnload = nil
        return true
    }

    func polish(_ transcript: String, language: String?, options: Options = Options()) async -> Result {
        guard Self.supports(language: language) else { return .unavailable(.unsupportedLanguage) }
        if let failure = Self.validateInput(transcript) { return .rejected(failure) }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unchanged }
        guard !Task.isCancelled else { return .rejected(.cancelled) }
        guard !inferenceInFlight else { return .unavailable(.busy) }
        inferenceInFlight = true
        idleUnload?.cancel()
        defer {
            inferenceInFlight = false
            scheduleIdleUnload()
        }

        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        guard Self.isCompleteCache(at: directory) else { return .unavailable(.missingOrInvalidCache) }
        guard let loaded = await localContainer() else {
            return Task.isCancelled ? .rejected(.cancelled) : .unavailable(.loadFailed)
        }
        guard !Task.isCancelled else { return .rejected(.cancelled) }
        // The token-boundary deadline starts after model preparation. Loading
        // and an individual GPU/prefill operation cannot be forcibly interrupted.
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000_000
        do {
            return try await loaded.perform { context -> Result in
                guard !Task.isCancelled else { return .rejected(.cancelled) }
                let transcriptTokens = context.tokenizer.encode(text: transcript).count
                guard transcriptTokens <= Self.maximumTranscriptTokens else { return .rejected(.inputTooLong) }
                let userInput = Self.modelInput(transcript: transcript, options: options)
                let input = try await context.processor.prepare(input: userInput)
                guard !Task.isCancelled else { return .rejected(.cancelled) }
                guard DispatchTime.now().uptimeNanoseconds < deadline else { return .rejected(.deadline) }
                let limit = Self.tokenBudget(inputTokens: transcriptTokens)
                var parameters = GenerateParameters(temperature: 0.0, topP: 1.0)
                parameters.maxTokens = limit
                var interruption: Rejection?
                let generated: GenerateResult = try MLXLMCommon.generate(
                    input: input, parameters: parameters, context: context
                ) { (_: [Int]) in
                    if Task.isCancelled { interruption = .cancelled; return .stop }
                    if DispatchTime.now().uptimeNanoseconds >= deadline { interruption = .deadline; return .stop }
                    return .more
                }
                if let interruption { return .rejected(interruption) }
                guard !Task.isCancelled else { return .rejected(.cancelled) }
                guard DispatchTime.now().uptimeNanoseconds < deadline else { return .rejected(.deadline) }
                guard generated.tokens.count < limit else { return .rejected(.tokenLimit) }
                return Self.assess(candidate: generated.output, original: transcript)
            }
        } catch {
            return Task.isCancelled ? .rejected(.cancelled) : .rejected(.generationFailed)
        }
        #else
        return .unavailable(.runtimeNotLinked)
        #endif
    }

    nonisolated static func supports(language: String?) -> Bool {
        guard let language else { return false }
        return language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first == "en"
    }

    nonisolated static func userPrompt(transcript: String, options: Options) -> String {
        options.controlLine + "\n" + transcript
    }

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    nonisolated static func modelInput(transcript: String, options: Options) -> UserInput {
        UserInput(chat: [.system(Self.systemPrompt), .user(Self.userPrompt(transcript: transcript, options: options))],
                  additionalContext: ["enable_thinking": false])
    }

    private func localContainer() async -> ModelContainer? {
        if let container { return container }
        guard Self.isCompleteCache(at: directory) else { return nil }
        let pending: (id: UUID, task: Task<ModelContainer, Error>)
        if let loading { pending = loading }
        else {
            let directory = self.directory
            pending = (UUID(), Task.detached(priority: .userInitiated) {
                try await loadModelContainer(directory: directory)
            })
            loading = pending
        }
        do {
            let loaded = try await pending.task.value
            container = loaded
            if loading?.id == pending.id { loading = nil }
            return loaded
        } catch {
            if loading?.id == pending.id { loading = nil }
            return nil
        }
    }
    #endif

    /// Completeness/architecture check only. The provisioning layer must verify
    /// the pinned revision and weight SHA before making this directory visible.
    nonisolated static func isCompleteCache(at directory: URL) -> Bool {
        let fm = FileManager.default
        for name in ["model.safetensors", "config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"] {
            let file = directory.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { return false }
            if name == "model.safetensors", size.int64Value != Int64(weightsBytes) { return false }
        }
        let config = directory.appendingPathComponent("config.json")
        guard let attributes = try? fm.attributesOfItem(atPath: config.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576,
              let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["model_type"] as? String == "qwen3",
              json["hidden_size"] as? Int == 1_024,
              json["num_hidden_layers"] as? Int == 28,
              let quantization = json["quantization"] as? [String: Any],
              quantization["bits"] as? Int == 4 else { return false }
        return true
    }

    nonisolated static func tokenBudget(inputTokens: Int) -> Int {
        min(1_024, max(64, Int(ceil(Double(max(0, min(inputTokens, maximumTranscriptTokens))) * 1.3)) + 32))
    }

    nonisolated static func validateInput(_ text: String) -> Rejection? {
        validateInput(text, maximumCharacters: maximumInputCharacters)
    }

    nonisolated static func validateInput(_ text: String, maximumCharacters: Int) -> Rejection? {
        guard text.count <= maximumCharacters else { return .inputTooLong }
        let lower = text.lowercased()
        if ["<|im_start|>", "<|im_end|>", "<think>", "</think>"].contains(where: lower.contains) { return .invalidInput }
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) { return .invalidInput }
        return nil
    }

    /// Conservative acceptance is not a full semantic equivalence proof.
    /// Legitimate normalization may be refused; the original remains available.
    nonisolated static func assess(candidate: String, original: String) -> Result {
        let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned == source { return .unchanged }
        if cleaned.isEmpty {
            return isFillerOnly(source) ? .accepted("") : .rejected(.emptyOutput)
        }
        let lower = cleaned.lowercased()
        if ["<think>", "</think>", "<|im_start|>", "<|im_end|>", "[styling:"].contains(where: lower.contains) {
            return .rejected(.unexpectedWrapper)
        }
        let wrappers = ["here is the cleaned", "here's the cleaned", "cleaned transcript:", "normalized transcript:"]
        if wrappers.contains(where: { lower.hasPrefix($0) && !source.lowercased().hasPrefix($0) }) {
            return .rejected(.unexpectedWrapper)
        }
        guard MeaningIntegrity.preservesMeaning(original: source, candidate: cleaned) else { return .rejected(.meaningChanged) }
        // Spoken paragraph/list commands have already been interpreted by the
        // shared formatter. Cleanup must not flatten that structure.
        if source.components(separatedBy: "\n\n").count > cleaned.components(separatedBy: "\n\n").count {
            return .rejected(.protectedContentChanged)
        }
        if source.lowercased().hasPrefix("do not "), !source.hasSuffix("?"), cleaned.hasSuffix("?") {
            return .rejected(.protectedContentChanged)
        }

        // Inspect existing fragile spans without feeding unsupported sentinel
        // tokens to this task-specific model.
        let fragile = EntityFreezer.freeze(source, mode: .minimal).entities.values
        guard fragile.allSatisfy({ cleaned.contains($0) }) else { return .rejected(.protectedContentChanged) }
        let exactPatterns = [#"\b[A-Za-z]+[A-Z][A-Za-z0-9_]*\b|\b[A-Z]{2,}[A-Z0-9]*\b"#,
                             #"(?<![\p{L}\d])\d+(?:[:/-]\d+)+(?:%|\b)"#]
        for pattern in exactPatterns {
            guard matches(pattern, source).allSatisfy({ cleaned.contains($0) }) else { return .rejected(.protectedContentChanged) }
        }
        let names = matches(#"(?<![.!?] )(?<!^)(?<!\n)\b[A-Z][a-z]{2,}\b"#, source)
        guard names.allSatisfy({ cleaned.range(of: $0, options: .caseInsensitive) != nil }) else { return .rejected(.protectedContentChanged) }
        // Protect uncertainty and time qualifiers, including the documented
        // small-model failure mode of dropping "tomorrow".
        let qualifiers = #"\b(?:today|tomorrow|yesterday|tonight|later|before|after|maybe|perhaps|probably|possibly|approximately|unless|only|except|without)\b"#
        let expected = matches(qualifiers, source, caseInsensitive: true).map { $0.lowercased() }
        let actual = matches(qualifiers, cleaned, caseInsensitive: true).map { $0.lowercased() }
        for qualifier in Set(expected) {
            guard actual.filter({ $0 == qualifier }).count >= expected.filter({ $0 == qualifier }).count else {
                return .rejected(.protectedContentChanged)
            }
        }
        return .accepted(cleaned)
    }

    nonisolated private static func isFillerOnly(_ text: String) -> Bool {
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "hmm", "ah"]
        return !words.isEmpty && words.allSatisfy(fillers.contains)
    }

    nonisolated private static func matches(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return [] }
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range) }
    }
}
