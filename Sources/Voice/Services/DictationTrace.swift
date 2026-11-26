// Flow: one trace event per dictation, and the one deadline for the cleanup step.
//
// The trace holds numbers and labels only: which engine ran, why a fallback was
// used, and stage times in milliseconds from key release. It never holds text.
// Written as one JSON line per dictation to
// ~/Library/Application Support/VOICE/traces/dictations.jsonl (mode 0700 folder).
//
// Short dictation gets whatever remains of 1.5 s from key release. Long
// dictation gets a bounded editing pass after transcription. A timed-out
// section keeps its source text. Text is never swapped after paste.

import Foundation

struct DictationTrace: Codable, Equatable {
    /// Which cleanup engine was asked: "dose1-t1", "s1-mini", "qwen3", "rules-only" or "off".
    var engine: String
    /// Whether that engine was installed and ready when the dictation started.
    var engineReady: Bool
    /// nil when the engine answered and its answer was used. Otherwise a short code:
    /// "deadline", "engine-not-ready", "model-failed", "level-off", "short-clip", "empty-answer".
    var fallbackReason: String?
    var level: String
    var style: String
    /// Stage times in milliseconds. Keys ending in "AtMs" are time since key release.
    /// Keys ending in "Ms" are how long that stage took. A missing key means the stage did not run.
    var stagesMs: [String: Int]
    /// Verified readback, dispatch failure, or a skipped/unconfirmed delivery.
    /// Older records may omit this field.
    var pasteVerdict: String?
    var recordedAt: Date

    /// Stage keys, in pipeline order. Used by the latency summariser.
    /// holdMs: key down to key up. transcriptAtMs: key up to transcript. rulesMs and modelMs: stage durations.
    /// pasteSentAtMs: key up to the paste being handed to the cursor.
    static let stageOrder = ["holdMs", "transcriptAtMs", "rulesMs", "modelMs", "pasteSentAtMs"]
}

enum DictationTraceLog {
    /// Folder that holds the trace file. Overridable in tests.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VOICE/traces", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("dictations.jsonl") }

    /// Appends one event. Best effort: a failed write never blocks the paste.
    private static let writeLock = NSLock()

    static func append(_ trace: DictationTrace) {
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var line = try encoder.encode(trace)
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        } catch {
            print("[VOICE-TRACE] could not write trace event: \(error.localizedDescription)")
        }
    }

    /// Reads back every event, skipping lines that do not decode. Used by tests and the summariser.
    static func readAll() -> [DictationTrace] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(DictationTrace.self, from: Data($0.utf8)) }
    }
}

enum DictationDeadline {
    /// Base cap counted from key release, for short dictation. 25 Nov 2026: 1.5 -> 1.8 s and 12 -> 15 ms a word:
    /// 19 of 78 recorded dictations had pasted rules-only text because cleanup ran right up to the cap.
    static let totalSeconds: Double = 1.8
    /// Extra time per word for longer dictation: a 100-word text gets about 3.3 s.
    static let secondsPerWord: Double = 0.015
    /// Upper bound however long the dictation is.
    static let maxTotalSeconds: Double = 6
    /// Dictations above this many words are cleaned in sections and get the scaled budget.
    static let longWordThreshold = 60

    /// Cap counted from key release for a dictation of `words` words: 1.8 s plus 15 ms per word, at most 6 s.
    static func budgetSeconds(words: Int) -> Double {
        // A general model chosen in Companion gets its own time on top, so DOSE1 still has the usual budget when it
        // fails or is too slow (24 Nov 2026).
        min(maxTotalSeconds, totalSeconds + secondsPerWord * Double(max(0, words)))
            + GeneralCleanupModel.liveExtraSeconds(words: words)
    }

    static func isLong(words: Int) -> Bool { words > longWordThreshold }

    /// Time the cleanup model may still use, given how long ago the key was released.
    static func remainingSeconds(sinceKeyRelease elapsed: Double, words: Int = 0) -> Double {
        max(0.05, budgetSeconds(words: words) - elapsed)
    }

    static func sectionBudgetSeconds(count: Int) -> Double {
        min(12, max(4, Double(count) * 3.0)) + GeneralCleanupModel.liveExtraSeconds(words: 0, sections: count)
    }

    /// Runs `work` and returns its value, or nil once `seconds` have passed.
    /// Unlike a task group, this returns on time even when `work` ignores cancellation.
    /// A late value is dropped.
    static func run<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        guard seconds.isFinite, seconds > 0, !Task.isCancelled else { return nil }
        // AsyncStream.next() wakes on parent cancellation as well as timeout.
        // A child that ignores cancellation cannot keep the caller suspended.
        let (stream, continuation) = AsyncStream<T>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let operation = Task {
            guard !Task.isCancelled else { return }
            let result = await work()
            guard !Task.isCancelled else { return }
            continuation.yield(result)
            continuation.finish()
        }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            continuation.finish()
        }
        defer {
            operation.cancel()
            timer.cancel()
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        return Task.isCancelled ? nil : value
    }
}

/// Lets exactly one caller through. Used so a deadline and a result never both resume.
final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// One dictation's place in paste order. Created at key release, before any transcription or cleanup.
/// The next dictation waits for `task`, which ends only after `finish()` is called (once this dictation has
/// pasted, or has ended without pasting). `finish()` may be called more than once.
final class DeliverySlot: @unchecked Sendable {
    let task: Task<Void, Never>
    private let continuation: AsyncStream<Void>.Continuation

    init(after prior: Task<Void, Never>?) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.continuation = continuation
        self.task = Task {
            _ = await prior?.value
            for await _ in stream {}
        }
    }

    func finish() { continuation.finish() }
}

// MARK: - Training record (text included)

/// One line per dictation with everything needed to train cleanup later: the recording, what the
/// recogniser heard, the rules text, what the model proposed, what was pasted, the app, and the
/// outcome. A later "edit" line holds the field after Jordan changed the pasted text.
/// voice.db keeps raw ASR, final text, app and audio path too; this file adds the model output and
/// labels, and it is never trimmed (recent_dictations.json keeps 100 items and drops raw text after
/// 7 days). About 1-3 KB a dictation, so roughly 40 MB a year at 50 dictations a day.
/// File: ~/Library/Application Support/VOICE/training/dictations.jsonl (folder 0700, file 0600).
struct DictationTrainingRecord: Codable, Equatable {
    var kind = "dictation"
    var id: String?
    var recordedAt: Date
    var app: String?
    var audioPath: String?
    var durationSeconds: Int?
    var asrRaw: String?
    var rulesText: String?
    var modelOutput: String?
    var finalText: String?
    var engine: String?
    var fallbackReason: String?
    var level: String?
    var style: String?
    var pasteVerdict: String?
    /// For kind "edit": the field's text after the user changed the pasted dictation.
    var editedField: String?
}

enum DictationTrainingLog {
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VOICE/training", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("dictations.jsonl") }

    private static let queue = DispatchQueue(label: "flow.training-log", qos: .utility)

    /// Best effort and off the main thread: a failed write never blocks the paste.
    static func append(_ record: DictationTrainingRecord, synchronously: Bool = false) {
        guard UserDefaults.standard.object(forKey: "flow.saveRunRecords") as? Bool ?? true,
              !BackgroundActivityGate.privacyMode else { return }
        let work = {
            // Recheck on the writer queue: a pending write must respect a later opt-out.
            guard UserDefaults.standard.object(forKey: "flow.saveRunRecords") as? Bool ?? true,
                  !BackgroundActivityGate.privacyMode else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                var line = try encoder.encode(record)
                line.append(0x0A)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: fileURL, options: [.atomic])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                }
            } catch {
                print("[VOICE-TRAINING] could not write record: \(error.localizedDescription)")
            }
        }
        if synchronously { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    static func readAll() -> [DictationTrainingRecord] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(DictationTrainingRecord.self, from: Data($0.utf8)) }
    }
}
