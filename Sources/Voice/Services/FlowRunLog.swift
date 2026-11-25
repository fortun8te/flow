// Flow: one local training record per dictation and per Opt+1, with everything about how Flow handled it.
//
// A record holds the raw input (and, for dictation, the recogniser's words with their confidence), every
// stage's output in order with its word changes and time, the guard decisions and why, the models and
// settings, the timeout or fallback reason, the app the text went to, and the final text. Later lines of
// kind "followup" link back by `id`: Undo, the Changes card's Original toggle, an edit right after paste.
//
// File: ~/Library/Application Support/VOICE/training/runs.jsonl (folder 0700, file 0600), append-only.
// Rotates at 24 MB into runs-<sequence>-<date>.jsonl and keeps the newest 12 rotated files (about 300 MB at most).
// The training folder is excluded from backups (iCloud and Time Machine). Nothing here is ever sent anywhere.
// `scripts/export_flow_runs.py` turns the records into training pairs under ~/flow-train/.

import Foundation

/// One recognised word and how sure the recogniser was (the lowest confidence of its pieces).
struct ASRWordConfidence: Codable, Equatable, Sendable {
    var word: String
    var confidence: Float
    var start: Double?
    var end: Double?
}

/// One step of the pipeline: its output text (when it produces text), the words it changed, its time.
struct FlowRunStage: Codable, Equatable, Sendable {
    var name: String
    var text: String?
    var ms: Int?
    /// Word changes against the previous text stage ("from -> to").
    var changes: [String]?
    var detail: [String: String]?
}

/// A guard or gate that kept, rejected or changed something, and why.
struct FlowRunDecision: Codable, Equatable, Sendable {
    var stage: String
    var verdict: String
    var reason: String?
}

struct FlowRunRecord: Codable, Equatable, Sendable {
    static let currentSchema = 1

    var schemaVersion = FlowRunRecord.currentSchema
    /// "dictation", "opt1", or "followup" (a later line about an earlier run).
    var kind: String
    /// The run's id: the dictation's session id, or the Opt+1 operation id.
    var id: String
    var recordedAt: Date
    var startedAt: Date?
    /// Flow's build.
    var flowBuild: String?
    /// The app the text went to (bundle id).
    var app: String?
    /// Dictation: the raw ASR transcript. Opt+1: the selected text.
    var input: String?
    var audioPath: String?
    var audioSeconds: Double?
    var asrWords: [ASRWordConfidence]?
    var asrConfidence: Float?
    var suspectWords: [String]?
    var stages: [FlowRunStage] = []
    var decisions: [FlowRunDecision] = []
    /// Role -> model name or file ("cleanup": "dose1-t4", "opt1": "ExampleModel-1.5-9B-Q4.gguf").
    var models: [String: String] = [:]
    var settings: [String: String] = [:]
    /// Stage and total times in milliseconds.
    var timingsMs: [String: Int] = [:]
    var fallbackReason: String?
    /// Dictation: the paste verdict. Opt+1: applied, unchanged, rejected, unavailable, notApplied, unconfirmed, cancelled.
    var outcome: String?
    /// The text that was pasted or put in place of the selection.
    var output: String?
    /// For kind "followup": "undo", "original-shown", "edited", "undo-paste".
    var followup: String?
    /// For an "edited" follow-up: the field's text after the change.
    var editedText: String?
}

/// Collects one run's stages while it happens. Thread-safe; pass it down or reach it through the
/// task-local `current` from code that does not take it as a parameter.
final class FlowRunCollector: @unchecked Sendable {
    @TaskLocal static var current: FlowRunCollector?

    private let lock = NSLock()
    private var record: FlowRunRecord
    private var lastText: String?
    private let started = DispatchTime.now().uptimeNanoseconds
    private var written = false

    init(kind: String, id: String, app: String?, input: String?, startedAt: Date = Date()) {
        record = FlowRunRecord(kind: kind, id: id, recordedAt: startedAt, startedAt: startedAt,
                               flowBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                               app: app, input: input)
        lastText = input
    }

    /// Milliseconds since the run started.
    var elapsedMs: Int { Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) }

    func update(_ change: (inout FlowRunRecord) -> Void) {
        lock.withLock { change(&record) }
    }

    /// A stage that produced text. Word changes are taken against the previous text stage.
    func stage(_ name: String, text: String?, ms: Int? = nil, detail: [String: String]? = nil) {
        lock.withLock {
            var changes: [String]?
            if let text, let before = lastText, before != text {
                changes = FlowRunDiff.changes(from: before, to: text)
            }
            record.stages.append(FlowRunStage(name: name, text: text, ms: ms, changes: changes, detail: detail))
            if let text { lastText = text }
        }
    }

    /// The input a following stage is compared with (e.g. after a branch that skipped a stage).
    func setBaseline(_ text: String) {
        lock.withLock { lastText = text }
    }

    func decision(_ stage: String, _ verdict: String, reason: String? = nil) {
        lock.withLock { record.decisions.append(FlowRunDecision(stage: stage, verdict: verdict, reason: reason)) }
    }

    func model(_ role: String, _ name: String?) {
        guard let name, !name.isEmpty else { return }
        lock.withLock { record.models[role] = name }
    }

    func timing(_ key: String, _ ms: Int) {
        lock.withLock { record.timingsMs[key] = ms }
    }

    var snapshot: FlowRunRecord { lock.withLock { record } }

    /// Writes the record once (later calls do nothing) and returns it.
    /// `secureField`: the text went to, or was refused for, a secure (password) field. Every text field is dropped.
    @discardableResult
    func finish(outcome: String?, output: String?, fallback: String? = nil, secureField: Bool = false) -> FlowRunRecord? {
        let done: FlowRunRecord? = lock.withLock {
            guard !written else { return nil }
            written = true
            record.outcome = outcome
            record.output = output
            if let fallback { record.fallbackReason = fallback }
            record.timingsMs["totalMs"] = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            record.recordedAt = Date()
            if secureField { record = FlowRunLog.withoutText(record) }
            return record
        }
        if let done { FlowRunLog.append(done) }
        return done
    }

    // Task-local shortcuts: do nothing outside a run.
    static func stage(_ name: String, text: String?, ms: Int? = nil, detail: [String: String]? = nil) {
        current?.stage(name, text: text, ms: ms, detail: detail)
    }

    static func note(_ name: String, _ detail: [String: String]) {
        current?.stage(name, text: nil, detail: detail)
    }

    static func decision(_ stage: String, _ verdict: String, reason: String? = nil) {
        current?.decision(stage, verdict, reason: reason)
    }

    static func model(_ role: String, _ name: String?) {
        current?.model(role, name)
    }
}

/// Word-level changes between two texts, as "from -> to" lines (at most 40; long texts are compared
/// by a common prefix and suffix only, so this stays cheap).
enum FlowRunDiff {
    static func changes(from a: String, to b: String, limit: Int = 40) -> [String] {
        let x = a.split(whereSeparator: \.isWhitespace).map(String.init)
        let y = b.split(whereSeparator: \.isWhitespace).map(String.init)
        if x == y { return a == b ? [] : ["(spacing or line breaks)"] }
        var prefix = 0
        while prefix < min(x.count, y.count), x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(x.count, y.count) - prefix, x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        let xs = Array(x[prefix..<(x.count - suffix)])
        let ys = Array(y[prefix..<(y.count - suffix)])
        guard xs.count * ys.count <= 250_000 else {
            return [xs.joined(separator: " ") + " -> " + ys.joined(separator: " ")]
        }
        // LCS over the middle, then group runs of removed and added words into one change each.
        var table = Array(repeating: Array(repeating: 0, count: ys.count + 1), count: xs.count + 1)
        for i in stride(from: xs.count - 1, through: 0, by: -1) {
            for j in stride(from: ys.count - 1, through: 0, by: -1) {
                table[i][j] = xs[i] == ys[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [String] = []
        var removed: [String] = [], added: [String] = []
        func flush() {
            if !removed.isEmpty || !added.isEmpty {
                out.append(removed.joined(separator: " ") + " -> " + added.joined(separator: " "))
            }
            removed.removeAll(); added.removeAll()
        }
        var i = 0, j = 0
        while i < xs.count || j < ys.count {
            if i < xs.count, j < ys.count, xs[i] == ys[j] {
                flush(); i += 1; j += 1
            } else if j < ys.count, i == xs.count || table[i][j + 1] >= table[i + 1][j] {
                added.append(ys[j]); j += 1
            } else {
                removed.append(xs[i]); i += 1
            }
        }
        flush()
        return Array(out.prefix(limit))
    }
}

enum FlowRunLog {
    nonisolated(unsafe) static var directoryOverride: URL?
    /// On by default. Off: no run records are written (privacy mode also stops them).
    static let preference = "flow.saveRunRecords"
    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: preference) as? Bool ?? true) && !BackgroundActivityGate.privacyMode
    }

    static let isRunningTests = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static var maxFileBytes: Int = 24 * 1024 * 1024
    static var keepRotated = 12

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VOICE/training", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("runs.jsonl") }

    private static let queue = DispatchQueue(label: "flow.run-log", qos: .utility)

    /// Best effort, off the main thread: a failed write never blocks a paste.
    static func append(_ record: FlowRunRecord, synchronously: Bool = false) {
        // Tests never write into the real store unless they point it at a folder of their own.
        if directoryOverride == nil, !isEnabled || isRunningTests { return }
        let work = { write(record) }
        if synchronously { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// Waits for queued writes (tests).
    static func flush() { queue.sync {} }

    /// A copy of `record` with every field that holds typed or spoken text removed: input, output, ASR words,
    /// suspect words, edited text, and each stage's text, word changes and detail. Timings, models, labels and
    /// decisions stay. Used for dictation into a secure (password) field, so a password never reaches runs.jsonl.
    static func withoutText(_ record: FlowRunRecord) -> FlowRunRecord {
        var clean = record
        clean.input = nil
        clean.output = nil
        clean.editedText = nil
        clean.asrWords = nil
        clean.suspectWords = nil
        clean.stages = record.stages.map { stage in
            var scrubbed = stage
            scrubbed.text = nil
            scrubbed.changes = nil
            scrubbed.detail = nil
            return scrubbed
        }
        return clean
    }

    private static func write(_ record: FlowRunRecord) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            excludeFromBackup(directory)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var line = try encoder.encode(record)
            line.append(0x0A)
            rotateIfNeeded(adding: line.count)
            if fm.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: [.atomic])
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        } catch {
            print("[FLOW-RUNS] could not write a run record: \(error.localizedDescription)")
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        var target = url
        if (try? target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    /// Moves a full file aside as runs-<timestamp>.jsonl and drops the oldest rotated files past the cap.
    static func rotateIfNeeded(adding bytes: Int = 0) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
              size + bytes > maxFileBytes else { return }
        // runs-<sequence>-<date>.jsonl: the sequence keeps the names in age order.
        let sequence = (rotatedFiles().compactMap { Int($0.lastPathComponent.dropFirst(5).prefix(6)) }.max() ?? 0) + 1
        let stamp = rotationFormatter.string(from: Date())
        let target = directory.appendingPathComponent(String(format: "runs-%06d-", sequence) + stamp + ".jsonl")
        try? fm.moveItem(at: fileURL, to: target)
        let rotated = rotatedFiles()
        if rotated.count > keepRotated {
            for old in rotated.prefix(rotated.count - keepRotated) { try? fm.removeItem(at: old) }
        }
    }

    /// Rotated files, oldest first.
    static func rotatedFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("runs-") && $0.hasSuffix(".jsonl") }.sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private static let rotationFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Every record in the current file and the rotated ones, oldest first.
    static func readAll() -> [FlowRunRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (rotatedFiles() + [fileURL]).flatMap { url -> [FlowRunRecord] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? decoder.decode(FlowRunRecord.self, from: Data($0.utf8)) }
        }
    }

    /// A later line about an earlier run (Undo, Original shown, edited after paste).
    static func followup(id: String, kind: String, followup: String, app: String? = nil, editedText: String? = nil) {
        append(FlowRunRecord(kind: "followup", id: id, recordedAt: Date(), app: app,
                             input: nil, outcome: kind, followup: followup, editedText: editedText))
    }
}
