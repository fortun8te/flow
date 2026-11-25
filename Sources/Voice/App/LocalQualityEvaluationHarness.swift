import Foundation
import Darwin

/// Private, bounded comparison of selected-text editing with historical Wispr edits. The injected runner
/// must be the explicitly local, cached-model-only production polish path.
@MainActor
enum LocalQualityEvaluationHarness {
    struct Example: Decodable {
        let input: String
        let output: String
    }
    struct Dataset: Decodable {
        let schema_version: Int
        let examples: [Example]
    }
    struct Counts: Codable, Equatable {
        var applicable = 0
        var preserved = 0
        mutating func add(expected: Set<String>, actual: Set<String>) {
            guard !expected.isEmpty else { return }
            applicable += 1
            if expected.isSubset(of: actual) { preserved += 1 }
        }
    }
    static let numberPattern = #"\b\d+(?:[.,:]\d+)*\b"#
    static let negationPattern = #"\b(?:not|no|never|none|neither|nor|cannot|can't|won't|don't|doesn't|didn't|isn't|aren't|wasn't|weren't|shouldn't|wouldn't|couldn't|niet|geen|nooit)\b"#
    static let entityPattern = #"(?:https?://[^\s]+|\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b|\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)+\b)"#
    struct Metrics: Codable {
        var numbers = Counts()
        var negations = Counts()
        var namesAndURLs = Counts()
        mutating func add(reference: String, actual: String) {
            numbers.add(expected: tokens(reference, pattern: numberPattern),
                        actual: tokens(actual, pattern: numberPattern))
            negations.add(expected: tokens(reference, pattern: negationPattern), actual: tokens(actual, pattern: negationPattern))
            namesAndURLs.add(expected: tokens(reference, pattern: entityPattern, caseInsensitive: false),
                             actual: tokens(actual, pattern: entityPattern, caseInsensitive: false))
        }
    }
    struct Comparison: Codable {
        var referenceWords = 0
        var originalEdits = 0
        var deliveredEdits = 0
        var improved = 0
        var regressed = 0
        var tied = 0
        var changed = 0
        var exactMatches = 0

        mutating func add(input: String, reference: String, delivered: String) {
            let expected = Self.words(reference)
            let before = Self.distance(Self.words(input), expected)
            let after = Self.distance(Self.words(delivered), expected)
            referenceWords += expected.count
            originalEdits += before
            deliveredEdits += after
            if after < before { improved += 1 }
            else if after > before { regressed += 1 }
            else { tied += 1 }
            if input != delivered { changed += 1 }
            if reference == delivered { exactMatches += 1 }
        }

        private static func words(_ value: String) -> [String] {
            value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
                .map { $0.replacingOccurrences(of: "’", with: "'") }
        }

        private static func distance(_ source: [String], _ target: [String]) -> Int {
            var previous = Array(0...target.count)
            for (i, word) in source.enumerated() {
                var row = [i + 1]
                for (j, expected) in target.enumerated() {
                    row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (word == expected ? 0 : 1)))
                }
                previous = row
            }
            return previous[target.count]
        }
    }

    struct Receipt: Codable {
        let schemaVersion = 1
        let reference = "Historical Wispr selected-text edits, not human ground truth or ASR accuracy"
        let selection = "Short examples selected for protected tokens and varied lengths from the eligible export records"
        let qualityCaveat = "Token-preservation proxies only; casing, spelling and equivalent wording can affect results. Names are limited to capitalized multiword names, email and URLs."
        let wisprSpeed = "Unavailable: the evaluation export has no latency field"
        let timingCaveat = "Wall-clock times include successful and failed selected-text calls and may include model loading; metrics include successful calls only"
        let selectedCount: Int
        let completedCount: Int
        let failedCalls: Int
        let unavailableCalls: Int
        let rejectedCalls: Int
        let otherFailedCalls: Int
        let stoppedAfterConsecutiveUnavailable: Bool
        let modelTimeoutObserved: Bool
        let allCallsTotalMilliseconds: Int
        let allCallsMedianMilliseconds: Int?
        let allCallsMaxMilliseconds: Int?
        let inputMetrics: Metrics
        let localMetrics: Metrics
        let deliveredComparison: Comparison
    }
    enum CallFailure: Error { case unavailable, rejected }
    enum Failure: Error { case unsupportedSchema, noEligibleExamples, outputCreationFailed }

    nonisolated static func tokens(_ text: String, pattern: String, caseInsensitive: Bool = true) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(re.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).lowercased() }
        })
    }

    static func select(_ examples: [Example], limit: Int = 6) -> [Example] {
        let eligible = examples.enumerated().filter { _, example in
            let inputWords = example.input.split(whereSeparator: \.isWhitespace).count
            let outputWords = example.output.split(whereSeparator: \.isWhitespace).count
            return (5...55).contains(inputWords) && outputWords > 0 && example.input.count <= 400 && example.output.count <= 500
        }.sorted { a, b in
            let ac = a.element.input.count, bc = b.element.input.count
            return ac == bc ? a.offset < b.offset : ac < bc
        }
        let count = min(max(0, limit), 40, eligible.count)
        guard count > 0 else { return [] }
        var picked: [Int] = []
        // Pick a middle-length representative of each available anchor category.
        // The reference is used only for selection and aggregate checks.
        for (pattern, insensitive) in [(numberPattern, true), (negationPattern, true), (entityPattern, false)] {
            guard picked.count < count else { break }
            if picked.contains(where: { !tokens(eligible[$0].element.output, pattern: pattern, caseInsensitive: insensitive).isEmpty }) { continue }
            let candidates = eligible.indices.filter {
                !picked.contains($0) && !tokens(eligible[$0].element.output, pattern: pattern, caseInsensitive: insensitive).isEmpty
            }
            if !candidates.isEmpty { picked.append(candidates[candidates.count / 2]) }
        }
        // Fill remaining slots across the available length range.
        while picked.count < count {
            let remaining = eligible.indices.filter { !picked.contains($0) }
            let candidate = remaining.max { a, b in
                let distanceA = picked.map { abs(a - $0) }.min() ?? eligible.count
                let distanceB = picked.map { abs(b - $0) }.min() ?? eligible.count
                return distanceA == distanceB ? a > b : distanceA < distanceB
            }!
            picked.append(candidate)
        }
        return picked.sorted().map { eligible[$0].element }
    }

    static func lfmPolish(_ source: String, port: UInt16, tagged: Bool) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            throw CallFailure.unavailable
        }
        let body = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = tagged ? WhisperNowTunedPolisher.t4Prompt(body) : body
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": [["role": "user", "content": prompt]], "temperature": 0,
            "repeat_penalty": 1.05, "repeat_last_n": 4096, "cache_prompt": false,
            "max_tokens": min(2048, max(96, body.utf8.count / 2 + 64))
        ])
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CallFailure.unavailable }
        guard case .text(let raw) = try WhisperNowTunedPolisher.parseReply(bytes) else {
            throw CallFailure.rejected
        }
        let result = PolishNormalizer.normalize(polish: raw, original: body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result == body { return source }
        guard Qwen3Polisher.selectedTextResultIsSafe(result, original: body, preset: "fix") else {
            throw CallFailure.rejected
        }
        return String(source.prefix(while: \.isWhitespace)) + result
            + String(source.reversed().prefix(while: \.isWhitespace).reversed())
    }

    /// Runner must enforce no cloud and no downloads, and must suppress any
    /// production logs containing source text. This function never logs inputs.
    /// A slow completed call stops further examples; the runner must itself bound
    /// inference to at most 60 seconds. It is not safe to race uncancellable GPU work.
    static func run(datasetURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VOICE/WisprPersonalization/evaluation.json"),
        receiptDirectory: URL, limit: Int = 6,
        localPolish: (String) async throws -> String) async throws -> URL {
        let dataset = try JSONDecoder().decode(Dataset.self, from: Data(contentsOf: datasetURL))
        guard dataset.schema_version == 1 else { throw Failure.unsupportedSchema }
        let examples = select(dataset.examples, limit: limit)
        guard !examples.isEmpty else { throw Failure.noEligibleExamples }
        var inputMetrics = Metrics()
        var localMetrics = Metrics()
        var comparison = Comparison()
        var times: [Int] = []
        var slow = false
        var failedCalls = 0
        var consecutiveFailures = 0
        var unavailableCalls = 0
        var rejectedCalls = 0
        var otherFailedCalls = 0
        for example in examples {
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                let result = try await localPolish(example.input)
                inputMetrics.add(reference: example.output, actual: example.input)
                localMetrics.add(reference: example.output, actual: result)
                comparison.add(input: example.input, reference: example.output, delivered: result)
                consecutiveFailures = 0
            } catch {
                // Errors may include private text, so never print or store them.
                failedCalls += 1
                comparison.add(input: example.input, reference: example.output, delivered: example.input)
                switch error as? CallFailure {
                case .some(.unavailable):
                    unavailableCalls += 1
                    consecutiveFailures += 1
                case .some(.rejected):
                    rejectedCalls += 1
                    consecutiveFailures = 0
                case nil:
                    otherFailedCalls += 1
                    consecutiveFailures = 0
                }
            }
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            times.append(elapsed)
            if elapsed >= 60_000 { slow = true; break }
            if consecutiveFailures >= 3 { break }
        }
        let sorted = times.sorted()
        let receipt = Receipt(selectedCount: examples.count, completedCount: times.count - failedCalls,
                              failedCalls: failedCalls, unavailableCalls: unavailableCalls, rejectedCalls: rejectedCalls, otherFailedCalls: otherFailedCalls, stoppedAfterConsecutiveUnavailable: consecutiveFailures >= 3,
                              modelTimeoutObserved: slow, allCallsTotalMilliseconds: times.reduce(0, +),
                              allCallsMedianMilliseconds: sorted.isEmpty ? nil : sorted[sorted.count / 2],
                              allCallsMaxMilliseconds: sorted.last, inputMetrics: inputMetrics, localMetrics: localMetrics, deliveredComparison: comparison)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let destination = receiptDirectory.appendingPathComponent("local-quality-\(UUID().uuidString).json")
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw Failure.outputCreationFailed }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try file.write(contentsOf: data); try file.close() }
        catch { try? file.close(); try? FileManager.default.removeItem(at: destination); throw error }
        return destination
    }
}
