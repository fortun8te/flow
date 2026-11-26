import Foundation
import Testing
@testable import Voice

@MainActor
struct LocalQualityEvaluationTests {
    @Test func preservationCountsAreOnlyApplicableWhenReferenceContainsTokens() {
        var metrics = LocalQualityEvaluationHarness.Metrics()
        metrics.add(reference: "Do not send 42 to Jane Smith.", actual: "Do not send 42 to Jane Smith.")
        metrics.add(reference: "Send 8 to Jane Smith.", actual: "Send 9 to someone.")
        #expect(metrics.numbers.applicable == 2)
        #expect(metrics.numbers.preserved == 1)
        #expect(metrics.negations.applicable == 1)
        #expect(metrics.negations.preserved == 1)
        #expect(metrics.namesAndURLs.applicable == 2)
        #expect(metrics.namesAndURLs.preserved == 1)
    }
    @Test func selectionIsBoundedAndDeterministic() {
        let examples = (1...30).map { n in
            LocalQualityEvaluationHarness.Example(input: Array(repeating: "word", count: n).joined(separator: " "), output: "edited")
        }
        let first = LocalQualityEvaluationHarness.select(examples)
        #expect(first.count == 6)
        #expect(first.map(\.input) == LocalQualityEvaluationHarness.select(examples).map(\.input))
        #expect(first.allSatisfy { $0.input.split(separator: " ").count >= 5 })
    }
}

@MainActor
struct LocalQualityEvaluationSelectionTests {
    @Test func includesAvailableProtectedAnchorsAndVariedLengths() {
        let examples = [
            LocalQualityEvaluationHarness.Example(input: "Please send this tomorrow morning", output: "Please send this tomorrow morning"),
            LocalQualityEvaluationHarness.Example(input: "Please send this to the team", output: "Please send 42 to the team"),
            LocalQualityEvaluationHarness.Example(input: "Please send this to the team soon", output: "Please do not send this to the team"),
            LocalQualityEvaluationHarness.Example(input: "Please send this over to the team soon", output: "Please send this to Jane Smith"),
            LocalQualityEvaluationHarness.Example(input: "Please send this to the team and ask them for their feedback", output: "Please send this to the team"),
            LocalQualityEvaluationHarness.Example(input: "Please send this to the team and ask them for their feedback by tomorrow morning", output: "Please send this to the team"),
            LocalQualityEvaluationHarness.Example(input: "Please send this to the team and ask them for their feedback by tomorrow morning before the meeting", output: "Please send this to the team")
        ]
        let selected = LocalQualityEvaluationHarness.select(examples)
        #expect(selected.count == 6)
        #expect(selected.contains { $0.output.contains("42") })
        #expect(selected.contains { $0.output.contains("not") })
        #expect(selected.contains { $0.output.contains("Jane Smith") })
        #expect(Set(selected.map(\.input)).count == selected.count)
    }
}

@MainActor
struct LocalQualityEvaluationFailureTests {
    @Test func emptyCleanupDoesNotCountAsACompletedOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.json")
        let examples = [["input": "The violet kettle sits on shelf 2", "output": "The violet kettle sits on shelf 2."]]
        try JSONSerialization.data(withJSONObject: ["schema_version": 1, "examples": examples]).write(to: source)
        let receiptURL = try await LocalQualityEvaluationHarness.run(datasetURL: source, receiptDirectory: directory) { _ in " \n" }
        let receipt = try JSONDecoder().decode(LocalQualityEvaluationHarness.Receipt.self, from: Data(contentsOf: receiptURL))
        #expect(receipt.completedCount == 0)
        #expect(receipt.rejectedCalls == 1)
        #expect(receipt.localMetrics.numbers.applicable == 0)
    }

    @Test func failuresAreCountedAndNeverScoredAsOutputs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.json")
        let examples = (0..<6).map { ["input": "Please send the message tomorrow morning \($0)", "output": "Please send the message tomorrow morning \($0)"] }
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "examples": examples])
        try data.write(to: source)
        var calls = 0
        let receiptURL = try await LocalQualityEvaluationHarness.run(datasetURL: source, receiptDirectory: directory) { text in
            calls += 1
            if calls == 1 { return text }
            throw LocalQualityEvaluationHarness.CallFailure.unavailable
        }
        let receipt = try JSONDecoder().decode(LocalQualityEvaluationHarness.Receipt.self, from: Data(contentsOf: receiptURL))
        #expect(receipt.completedCount == 1)
        #expect(receipt.failedCalls == 3)
        #expect(receipt.unavailableCalls == 3)
        #expect(receipt.stoppedAfterConsecutiveUnavailable)
        #expect(receipt.localMetrics.numbers.applicable == 1)
    }
}
