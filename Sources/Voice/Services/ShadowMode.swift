// Flow — Shadow mode
// ============================================================
// Wispr Flow stays the app that pastes. On the same fn press, Flow records the
// same microphone audio, runs Parakeet and its own automatic cleanup, and
// appends one JSON line per capture so the pair can train the cleanup model.
// Pairing:
// scripts/pair-shadow-with-wispr.py.
//
// Invisible by construction: when shadow mode runs, AppDelegate starts ONLY
// this controller. No pill/overlay, menu bar item, sounds, paste, clipboard,
// output ducking, notices, history rows, learning or Companion commands. Cloud
// polish is forced off for the process. The fn tap is listen-only and never
// touches the fn/emoji system binding.
//
//   on:  defaults write com.example.flow voice.shadowMode -bool YES
//   off: defaults write com.example.flow voice.shadowMode -bool NO
//
// Storage (local only):
//   ~/Library/Application Support/VOICE/Shadow/              0700
//     shadow.jsonl                                           0600, fsync per line
//     audio/<yyyy-MM-dd UTC>/<uuid>.wav                      0600, 16 kHz mono PCM16
//     tmp/<uuid>.caf                                         working capture, deleted after use
// ============================================================

import AppKit
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import NaturalLanguage

// MARK: - Launch gate

enum FlowLaunchGate {
    enum Mode: Equatable { case normal, shadow, quit }

    static let enabledKey = "flow.enabled"
    static let shadowModeKey = "voice.shadowMode"

    /// flow.enabled == true always wins (normal mode, shadow off). Otherwise an
    /// explicit voice.shadowMode == true runs shadow mode. Otherwise
    /// an unset or false flow.enabled quits without installing dictation hotkeys.
    static func decide(flowEnabled: Bool?, shadowMode: Bool?) -> Mode {
        if flowEnabled == true { return .normal }
        if shadowMode == true { return .shadow }
        return .quit
    }

    static func decide(defaults: UserDefaults) -> Mode {
        decide(flowEnabled: defaults.object(forKey: enabledKey) as? Bool,
               shadowMode: defaults.object(forKey: shadowModeKey) as? Bool)
    }
}

// MARK: - Gesture state machine (pure, unit-tested)

/// Mirrors Wispr's fn gestures. Hold fn = capture until release. Double-tap fn
/// or fn+Space = hands-free until the next fn press. Captures shorter than
/// `minimumDuration` are dropped, as Wispr ignores taps.
struct ShadowGestureMachine: Equatable {
    enum Gesture: String, Codable, Sendable { case hold, handsfree }

    enum Event: Equatable {
        case fnDown, fnUp, fnSpace, chord, timeout, maxDuration
    }

    enum Action: Equatable {
        case start(at: Date)
        case finish(gesture: Gesture, startedAt: Date, endedAt: Date)
        case discard(reason: String, startedAt: Date, endedAt: Date)
        case armTimeout(deadline: Date)
    }

    enum State: Equatable {
        case idle
        /// fn is down; a capture is running.
        case holding(start: Date)
        /// A short first tap was released; waiting to see if a second tap makes it hands-free.
        case awaitingSecondTap(start: Date, deadline: Date)
        case handsFree(start: Date, fnHeld: Bool)
        /// The capture ended while fn is still down; swallow its release.
        case ignoringRelease
    }

    static let minimumDuration: TimeInterval = 0.5

    var doubleTapWindow: TimeInterval
    private(set) var state: State = .idle

    init(doubleTapWindow: TimeInterval = 0.45) {
        self.doubleTapWindow = doubleTapWindow
    }

    var isCapturing: Bool {
        switch state {
        case .holding, .awaitingSecondTap, .handsFree: return true
        case .idle, .ignoringRelease: return false
        }
    }

    mutating func handle(_ event: Event, at now: Date) -> [Action] {
        switch (state, event) {
        case (.idle, .fnDown):
            state = .holding(start: now)
            return [.start(at: now)]

        case (.holding(let start), .fnUp):
            if now.timeIntervalSince(start) >= Self.minimumDuration {
                state = .idle
                return [.finish(gesture: .hold, startedAt: start, endedAt: now)]
            }
            let deadline = now.addingTimeInterval(doubleTapWindow)
            state = .awaitingSecondTap(start: start, deadline: deadline)
            return [.armTimeout(deadline: deadline)]

        case (.holding(let start), .fnSpace):
            state = .handsFree(start: start, fnHeld: true)
            return []

        case (.holding(let start), .chord):
            // fn+another key is a shortcut (fn+Delete, fn+arrows), not dictation.
            state = .ignoringRelease
            return [.discard(reason: "fn_chord", startedAt: start, endedAt: now)]

        case (.holding(let start), .maxDuration):
            state = .ignoringRelease
            return [.finish(gesture: .hold, startedAt: start, endedAt: now)]

        case (.awaitingSecondTap(let start, let deadline), .fnDown):
            if now <= deadline {
                state = .handsFree(start: start, fnHeld: true)
                return []
            }
            // The window already closed (late timer): drop the tap, start fresh.
            state = .holding(start: now)
            return [.discard(reason: "short_tap", startedAt: start, endedAt: deadline), .start(at: now)]

        case (.awaitingSecondTap(let start, let deadline), .timeout):
            guard now >= deadline else { return [] }
            state = .idle
            return [.discard(reason: "short_tap", startedAt: start, endedAt: deadline)]

        case (.awaitingSecondTap(let start, _), .maxDuration):
            state = .idle
            return [.discard(reason: "short_tap", startedAt: start, endedAt: now)]

        case (.handsFree(let start, true), .fnUp):
            state = .handsFree(start: start, fnHeld: false)
            return []

        case (.handsFree(let start, false), .fnDown):
            state = .ignoringRelease
            return [.finish(gesture: .handsfree, startedAt: start, endedAt: now)]

        case (.handsFree(let start, let fnHeld), .maxDuration):
            state = fnHeld ? .ignoringRelease : .idle
            return [.finish(gesture: .handsfree, startedAt: start, endedAt: now)]

        case (.ignoringRelease, .fnUp):
            state = .idle
            return []

        case (.ignoringRelease, .fnDown):
            // The release was lost (tap paused); treat this as a fresh press.
            state = .holding(start: now)
            return [.start(at: now)]

        default:
            return []
        }
    }
}

// MARK: - JSONL record (schema 1)

struct ShadowRecord: Codable, Equatable {
    var schema: Int = 1
    var id: String
    var startedAt: String
    var endedAt: String
    var durationS: Double
    var gesture: String
    var frontApp: String?
    var audio: String
    var audioSHA256: String
    var sampleRate: Int = 16_000
    var asrModel: String
    var parakeetRaw: String
    var asrMs: Int
    var cleanupInput: String
    var cleanupEngine: String
    var cleanupResult: String
    var cleanupMs: Int
    var flowCleaned: String
    var languageGuess: String
    var flowBuild: String
    /// Optional, still schema 1 (added 13 Nov 2026; older lines lack them).
    /// "s1" when S1-mini was asked to clean, else "skip:<reason>" (same
    /// vocabulary as `Flow --cleanup-prepare`). See ShadowCleanupObserver.route.
    var route: String? = nil
    /// The control line S1-mini actually received; only when route == "s1".
    var s1ControlLine: String? = nil
    /// Present only when a T2 response establishes that this task contract reached the engine.
    var cleanupContract: String? = nil
    var cleanupControlLine: String? = nil

    enum CodingKeys: String, CodingKey {
        case schema, id, gesture, audio
        case startedAt = "started_at", endedAt = "ended_at", durationS = "duration_s"
        case frontApp = "front_app", audioSHA256 = "audio_sha256", sampleRate = "sample_rate"
        case asrModel = "asr_model", parakeetRaw = "parakeet_raw", asrMs = "asr_ms"
        case cleanupInput = "cleanup_input", cleanupEngine = "cleanup_engine"
        case cleanupResult = "cleanup_result", cleanupMs = "cleanup_ms"
        case flowCleaned = "flow_cleaned", languageGuess = "language_guess", flowBuild = "flow_build"
        case route, s1ControlLine = "s1_control_line"
        case cleanupContract = "cleanup_contract", cleanupControlLine = "cleanup_control_line"
    }

    // front_app is always present (null when unknown), as in the spec.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(durationS, forKey: .durationS)
        try c.encode(gesture, forKey: .gesture)
        try c.encode(frontApp, forKey: .frontApp)
        try c.encode(audio, forKey: .audio)
        try c.encode(audioSHA256, forKey: .audioSHA256)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(asrModel, forKey: .asrModel)
        try c.encode(parakeetRaw, forKey: .parakeetRaw)
        try c.encode(asrMs, forKey: .asrMs)
        try c.encode(cleanupInput, forKey: .cleanupInput)
        try c.encode(cleanupEngine, forKey: .cleanupEngine)
        try c.encode(cleanupResult, forKey: .cleanupResult)
        try c.encode(cleanupMs, forKey: .cleanupMs)
        try c.encode(flowCleaned, forKey: .flowCleaned)
        try c.encode(languageGuess, forKey: .languageGuess)
        try c.encode(flowBuild, forKey: .flowBuild)
        try c.encodeIfPresent(route, forKey: .route)
        try c.encodeIfPresent(s1ControlLine, forKey: .s1ControlLine)
        try c.encodeIfPresent(cleanupContract, forKey: .cleanupContract)
        try c.encodeIfPresent(cleanupControlLine, forKey: .cleanupControlLine)
    }

    /// One line, no trailing newline. UTF-8, sorted keys, unescaped slashes.
    func jsonLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// UTC ISO 8601 with milliseconds, e.g. 2026-11-13T14:38:21.512Z.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func roundedSeconds(_ value: TimeInterval) -> Double {
        (value * 100).rounded() / 100
    }
}

// MARK: - Cleanup trace (filled by Qwen3Polisher through a task-local)

/// Records exactly what Flow's automatic cleanup did for one shadow capture.
/// Qwen3Polisher writes to it only when a shadow task bound it; normal
/// dictation never sets the task-local, so nothing changes there.
final class ShadowCleanupObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var _input: String?
    private var _engine: String?
    private var _result: String?
    private var _controlLine: String?

    var input: String? { lock.withLock { _input } }
    var engine: String? { lock.withLock { _engine } }
    var result: String? { lock.withLock { _result } }
    /// The exact control line associated with a received S1/T2 response; nil for a skipped task.
    var controlLine: String? { lock.withLock { _controlLine } }

    /// "s1" when S1-mini was asked to clean this text in a supported language,
    /// "skip:<reason>" when cleanup routed around it, nil when nothing was
    /// recorded. Matches scripts/pair-shadow-with-wispr.py `route_of`.
    var route: String? {
        lock.withLock { Self.route(engine: _engine, result: _result) }
    }

    static func route(engine: String?, result: String?) -> String? {
        guard let engine, let result else { return nil }
        if engine == "local:s1-mini" && !result.hasPrefix("unavailable:unsupportedLanguage") { return "s1" }
        if engine != "local:s1-mini" && engine != "rules" { return "skip:engine-" + engine }
        if let colon = result.firstIndex(of: ":") { return "skip:" + result[result.index(after: colon)...] }
        return "skip:" + result
    }

    func s1(input: String, result: S1MiniPolisher.Result, guardRefused: Bool,
            controlLine: String = S1MiniPolisher.Options().controlLine) {
        let label: String
        switch result {
        case .accepted: label = guardRefused ? "rejected:output_guard" : "accepted"
        case .unchanged: label = "unchanged"
        case .unavailable(let reason): label = "unavailable:\(reason.rawValue)"
        case .rejected(let reason): label = "rejected:\(reason.rawValue)"
        }
        set(input: input, engine: "local:s1-mini", result: label)
        lock.withLock { _controlLine = controlLine }
    }

    func skipped(input: String, reason: String) {
        set(input: input, engine: "rules", result: "unavailable:\(reason)")
    }

    func set(input: String, engine: String, result: String, controlLine: String? = nil) {
        lock.withLock { _input = input; _engine = engine; _result = result; _controlLine = controlLine }
    }
}

enum ShadowCleanupTrace {
    @TaskLocal static var observer: ShadowCleanupObserver?
}

/// A sectioned draft can use a model for one line and rules for another. Do
/// not label the whole training example with only the final line's engine.
private final class ShadowSectionCleanupObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: Set<String> = []
    private var controls: [String?] = []

    func record(_ observer: ShadowCleanupObserver, fallbackEngine: String) {
        let engine = observer.engine ?? fallbackEngine
        let control = observer.controlLine
        lock.withLock {
            engines.insert(engine)
            controls.append(control)
        }
    }

    var summary: (engine: String, controlLine: String?) {
        lock.withLock {
            let ordered = engines.sorted()
            let engine = ordered.isEmpty ? "rules" : (ordered.count == 1 ? ordered[0] : "mixed:" + ordered.joined(separator: "+"))
            let lines = Set(controls.compactMap { $0 })
            let control = controls.allSatisfy { $0 != nil } && lines.count == 1 ? lines.first : nil
            return (engine, control)
        }
    }
}

// MARK: - Storage

final class ShadowStore: @unchecked Sendable {
    static let defaultAudioCapBytes: Int64 = 3 * 1024 * 1024 * 1024

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VOICE/Shadow", isDirectory: true)
    }

    let root: URL
    let audioCapBytes: Int64
    private let lock = NSLock()

    init(root: URL = ShadowStore.defaultRoot, audioCapBytes: Int64 = ShadowStore.defaultAudioCapBytes) {
        self.root = root
        self.audioCapBytes = audioCapBytes
    }

    var jsonlURL: URL { root.appendingPathComponent("shadow.jsonl") }
    var audioRoot: URL { root.appendingPathComponent("audio", isDirectory: true) }
    var tmpRoot: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    func prepare() throws {
        for dir in [root, audioRoot, tmpRoot] { try Self.privateDirectory(dir) }
        // Leftover working files from a crash are not usable captures.
        for leftover in (try? FileManager.default.contentsOfDirectory(at: tmpRoot, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: leftover)
        }
        if FileManager.default.fileExists(atPath: jsonlURL.path) {
            chmod(jsonlURL.path, 0o600)
        }
    }

    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(url.path, 0o700) == 0 else {
            throw NSError(domain: "Flow.Shadow", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Shadow folder permissions could not be set."])
        }
    }

    static func dayFolder(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Relative path stored in the JSONL `audio` field.
    static func relativeAudioPath(id: UUID, startedAt: Date) -> String {
        "audio/\(dayFolder(startedAt))/\(id.uuidString.lowercased()).wav"
    }

    /// 16 kHz mono PCM16 little-endian WAV.
    static func wavData(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let dataBytes = samples.count * 2
        var data = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                                   // PCM
        u16(1)                                   // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))              // byte rate
        u16(2)                                   // block align
        u16(16)                                  // bits per sample
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        for sample in samples {
            let clipped = sample.isFinite ? max(-1, min(1, sample)) : 0
            let value = Int16((clipped * 32767).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Writes the WAV (0600) and returns its SHA-256 hex digest.
    @discardableResult
    func writeWAV(samples: [Float], relativePath: String) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        try Self.privateDirectory(url.deletingLastPathComponent())
        let data = Self.wavData(samples: samples)
        try Self.writePrivate(data, to: url, append: false)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Appends one line and fsyncs before returning.
    func append(_ record: ShadowRecord) throws {
        var line = try record.jsonLine()
        line.append(0x0A)
        try lock.withLock { try Self.writePrivate(line, to: jsonlURL, append: true) }
    }

    private static func writePrivate(_ data: Data, to url: URL, append: Bool) throws {
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (append ? O_APPEND : O_TRUNC)
        let fd = open(url.path, flags, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: "Flow.Shadow", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Shadow file could not be opened."])
        }
        defer { close(fd) }
        fchmod(fd, 0o600)
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: "Flow.Shadow", code: Int(errno),
                                  userInfo: [NSLocalizedDescriptionKey: "Shadow file could not be written."])
                }
                offset += written
            }
        }
        guard fsync(fd) == 0 else {
            throw NSError(domain: "Flow.Shadow", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Shadow file could not be synced."])
        }
    }

    /// Deletes the oldest WAVs until the audio folder is within the cap.
    /// shadow.jsonl is never touched. Returns the deleted files.
    @discardableResult
    func pruneAudio() -> [URL] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: audioRoot, includingPropertiesForKeys: keys) else { return [] }
        var files: [(url: URL, size: Int64, date: Date)] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "wav" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > audioCapBytes else { return [] }
        // Oldest first; the day folder + name break ties deterministically.
        files.sort { $0.date != $1.date ? $0.date < $1.date : $0.url.path < $1.url.path }
        var deleted: [URL] = []
        for file in files where total > audioCapBytes {
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                total -= file.size
                deleted.append(file.url)
                let folder = file.url.deletingLastPathComponent()
                if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
        return deleted
    }
}

// MARK: - Bounded work queue (pure, unit-tested)

/// Finished captures waiting for ASR + cleanup. At most `limit` wait; adding
/// one more drops the oldest waiting capture.
struct ShadowWorkQueue<Item> {
    let limit: Int
    private(set) var items: [Item] = []

    init(limit: Int = 3) { self.limit = limit }

    /// Returns the items dropped to make room.
    mutating func enqueue(_ item: Item) -> [Item] {
        items.append(item)
        guard items.count > limit else { return [] }
        let overflow = items.count - limit
        let dropped = Array(items.prefix(overflow))
        items.removeFirst(overflow)
        return dropped
    }

    mutating func next() -> Item? { items.isEmpty ? nil : items.removeFirst() }
    var isEmpty: Bool { items.isEmpty }
}

// MARK: - Controller

@MainActor
final class ShadowModeController: @preconcurrency FnKeyTapDelegate {
    struct Context {
        let frontApp: String?
        let polishContext: LLMPolisher.PolishContext
        let appContextLabel: String?
        let personality: String
        let cleanupLevel: String
    }

    struct Finished {
        let id: UUID
        let gesture: ShadowGestureMachine.Gesture
        let startedAt: Date
        let endedAt: Date
        let workingFile: URL
        let context: Context?
        let voicedSeconds: Double
        let quietVoicedSeconds: Double
        let peakRMS: Float
        let capturedSeconds: Double
        let mediaPlaying: Bool
    }

    private struct Active {
        let id: UUID
        let startedAt: Date
        let workingFile: URL
        var context: Context?
    }

    static let maximumCaptureSeconds: TimeInterval = 10 * 60

    private let tap = FnKeyTap(listenOnly: true)
    private var machine: ShadowGestureMachine
    private let audio = AudioCaptureService()
    private let transcription = TranscriptionService()
    private let store = ShadowStore()
    private let formatter = TextFormatter()
    private let paster = CursorPaster()
    private var active: Active?
    private var closingToken: UUID?
    private var queue = ShadowWorkQueue<Finished>(limit: 3)
    private var worker: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var timeoutTimer: Timer?
    private var maxTimer: Timer?
    private var watchdog: Timer?
    private var storeReady = false
    private var flowBuild = "unknown"

    init() {
        machine = ShadowGestureMachine(doubleTapWindow: HotkeyService.resolvedDoubleTapWindow(
            storedMs: UserDefaults.standard.object(forKey: HotkeyService.doubleTapWindowKey) as? Double))
    }

    func start() {
        // Local only for the whole process: no cloud cleanup, summaries or detectors.
        // The argument domain is in-memory and outranks the saved settings.
        UserDefaults.standard.setVolatileDomain([
            "voice.allowCloudPolishing": false, "voice.allowCloudMeetingSummary": false,
            "voice.privacyMode": true,
        ], forName: UserDefaults.argumentDomain)

        do { try store.prepare(); storeReady = true }
        catch { Telemetry.log("shadow.store_failed", properties: ["error": error.localizedDescription]) }

        tap.delegate = self
        let tapOK = tap.start()
        Telemetry.log("shadow.started", properties: [
            "tap": tapOK ? "listen_only" : "failed", "store": storeReady,
            "double_tap_ms": Int(machine.doubleTapWindow * 1000),
        ])

        // Keep the tap alive and leave if the mode is switched off or normal Flow is enabled.
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }

        let capture = audio
        Task.detached(priority: .utility) { capture.warmup() }
        modelTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do { try await self.transcription.prepare() }
            catch { Telemetry.log("shadow.asr_unavailable", properties: ["error": error.localizedDescription]) }
            Qwen3Polisher.shared.prewarm()
        }
        Task(priority: .background) { [weak self] in
            let build = await Task.detached(priority: .background) { Self.executableDigestPrefix() }.value
            self?.flowBuild = build
        }
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        timeoutTimer?.invalidate(); timeoutTimer = nil
        maxTimer?.invalidate(); maxTimer = nil
        tap.stop()
        if active != nil {
            audio.stopCapture()
            audio.stopWritingToFile()
            active = nil
        }
        worker?.cancel()
        modelTask?.cancel()
    }

    private func checkHealth() {
        if FlowLaunchGate.decide(defaults: .standard) != .shadow {
            Telemetry.log("shadow.mode_exit", properties: [:])
            stop()
            NSApp.terminate(nil)
            return
        }
        if !tap.isAlive() {
            tap.rearm()
            if !tap.isAlive() {
                let ok = tap.start()
                Telemetry.log("shadow.tap_restarted", properties: ["ok": ok])
            }
        }
    }

    // MARK: FnKeyTapDelegate

    func fnKeyDown() { drive(.fnDown) }
    func fnKeyUp() { drive(.fnUp) }
    func fnSpacePressed() { drive(.fnSpace) }
    func fnChordKeyPressed() { drive(.chord) }

    private func drive(_ event: ShadowGestureMachine.Event) {
        for action in machine.handle(event, at: Date()) { perform(action) }
    }

    private func perform(_ action: ShadowGestureMachine.Action) {
        switch action {
        case .start(let at):
            beginCapture(at: at)
        case .armTimeout(let deadline):
            timeoutTimer?.invalidate()
            timeoutTimer = Timer.scheduledTimer(withTimeInterval: max(0, deadline.timeIntervalSinceNow) + 0.01,
                                                repeats: false) { [weak self] _ in
                Task { @MainActor in self?.drive(.timeout) }
            }
        case .discard(let reason, let startedAt, let endedAt):
            timeoutTimer?.invalidate(); timeoutTimer = nil
            maxTimer?.invalidate(); maxTimer = nil
            if let capture = endCapture() { try? FileManager.default.removeItem(at: capture.workingFile) }
            dropped(reason: reason, duration: endedAt.timeIntervalSince(startedAt))
        case .finish(let gesture, let startedAt, let endedAt):
            timeoutTimer?.invalidate(); timeoutTimer = nil
            maxTimer?.invalidate(); maxTimer = nil
            finishCapture(gesture: gesture, startedAt: startedAt, endedAt: endedAt)
        }
    }

    // MARK: Capture

    private func beginCapture(at startedAt: Date) {
        guard storeReady else { dropped(reason: "store_unavailable", duration: 0); return }
        closePendingFileNow()
        let id = UUID()
        let file = store.tmpRoot.appendingPathComponent("\(id.uuidString.lowercased()).caf")
        let front = NSWorkspace.shared.frontmostApplication
        do {
            // Production capture path (same DSP and file format), mic only, no output ducking.
            try audio.startWritingToFile(url: file)
            try audio.startMicrophoneCapture()
        } catch {
            audio.stopCapture()
            audio.stopWritingToFile()
            try? FileManager.default.removeItem(at: file)
            dropped(reason: "mic_unavailable", duration: 0)
            return
        }
        active = Active(id: id, startedAt: startedAt, workingFile: file, context: nil)
        maxTimer = Timer.scheduledTimer(withTimeInterval: Self.maximumCaptureSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.drive(.maxDuration) }
        }
        // Context is read after the mic is running so capture never waits on AX.
        let bundle = front?.bundleIdentifier
        active?.context = Context(
            frontApp: bundle,
            polishContext: paster.currentPolishContext(),
            appContextLabel: AppDelegate.buildEnrichedAppContextLabel(bundleID: bundle, front: front),
            personality: AppWritingCategory.style(for: bundle),
            cleanupLevel: CleanupLevel.current.rawValue)
    }

    /// Stops the mic and returns the active capture. The file is closed after a
    /// short drain so the last buffers land, or at once if a new capture starts.
    private func endCapture() -> Active? {
        guard let capture = active else { return nil }
        active = nil
        audio.stopCapture()
        let token = UUID()
        closingToken = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, self.closingToken == token else { return }
            self.closingToken = nil
            self.audio.stopWritingToFile()
        }
        return capture
    }

    private func closePendingFileNow() {
        guard closingToken != nil else { return }
        closingToken = nil
        audio.stopWritingToFile()
    }

    private func finishCapture(gesture: ShadowGestureMachine.Gesture, startedAt: Date, endedAt: Date) {
        let voiced = audio.voicedDurationSeconds
        let quietVoiced = audio.quietVoicedDurationSeconds
        let peak = audio.recordingPeakRMSValue
        let captured = audio.capturedDurationSeconds
        let media = DictationAudioDucker.mediaPlayingOnOutput()
        guard let capture = endCapture() else { return }
        let duration = endedAt.timeIntervalSince(startedAt)
        guard duration >= ShadowGestureMachine.minimumDuration else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                try? FileManager.default.removeItem(at: capture.workingFile)
            }
            dropped(reason: "short_tap", duration: duration)
            return
        }
        let finished = Finished(id: capture.id, gesture: gesture, startedAt: startedAt, endedAt: endedAt,
                                workingFile: capture.workingFile, context: capture.context,
                                voicedSeconds: voiced, quietVoicedSeconds: quietVoiced,
                                peakRMS: peak, capturedSeconds: captured, mediaPlaying: media)
        for old in queue.enqueue(finished) {
            try? FileManager.default.removeItem(at: old.workingFile)
            dropped(reason: "queue_full", duration: old.endedAt.timeIntervalSince(old.startedAt))
        }
        pump()
    }

    private func dropped(reason: String, duration: TimeInterval) {
        Telemetry.log("shadow.capture_dropped", properties: [
            "reason": reason, "duration_s": ShadowRecord.roundedSeconds(duration),
        ])
    }

    // MARK: Processing (one at a time, utility priority)

    private func pump() {
        guard worker == nil, let next = queue.next() else { return }
        worker = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            // Let the drain close the working file first.
            while self.closingToken != nil, self.active == nil {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            await self.process(next)
            self.worker = nil
            self.pump()
        }
    }

    private func process(_ capture: Finished) async {
        defer { try? FileManager.default.removeItem(at: capture.workingFile) }
        let fileURL = capture.workingFile
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0

        // 1. The exact 16 kHz mono samples Parakeet reads, saved as PCM16 WAV.
        let samples: [Float]
        do {
            samples = try await Task.detached(priority: .utility) {
                try TranscriptionService.readSamplesAt16kMono(url: fileURL)
            }.value
        } catch {
            dropped(reason: "audio_unreadable", duration: capture.endedAt.timeIntervalSince(capture.startedAt))
            return
        }
        let relative = ShadowStore.relativeAudioPath(id: capture.id, startedAt: capture.startedAt)
        let store = self.store
        let sha: String
        do {
            sha = try await Task.detached(priority: .utility) {
                let digest = try store.writeWAV(samples: samples, relativePath: relative)
                let pruned = store.pruneAudio()
                if !pruned.isEmpty { Telemetry.log("shadow.audio_pruned", properties: ["files": pruned.count]) }
                return digest
            }.value
        } catch {
            Telemetry.log("shadow.write_failed", properties: ["what": "wav", "error": error.localizedDescription])
            return
        }

        // 2. Parakeet, selected model, same file path as production.
        var raw = ""
        var asrMs = 0
        var segments: [TranscriptSegment] = []
        var asrFailure: String?
        do {
            try await transcription.prepare()
            let started = Date()
            segments = try await transcription.transcribeFile(url: fileURL)
            asrMs = Int(Date().timeIntervalSince(started) * 1000)
            raw = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            asrFailure = "asr_failed"
        }
        let asrModel: String = {
            guard let id = transcription.activeModelID else { return "unknown" }
            let revision = SpeechModelCatalog.descriptor(for: id).pinnedRevision.map { "@" + $0.prefix(8) } ?? ""
            return id.rawValue + revision
        }()

        // 3. Flow's automatic cleanup, as the live paste path would run it.
        let cleanup = await cleanUp(raw: raw, segments: segments, capture: capture,
                                    fileSize: fileSize, asrFailure: asrFailure)

        let record = ShadowRecord(
            id: capture.id.uuidString.lowercased(),
            startedAt: ShadowRecord.timestamp(capture.startedAt),
            endedAt: ShadowRecord.timestamp(capture.endedAt),
            durationS: ShadowRecord.roundedSeconds(capture.endedAt.timeIntervalSince(capture.startedAt)),
            gesture: capture.gesture.rawValue,
            frontApp: capture.context?.frontApp,
            audio: relative, audioSHA256: sha,
            asrModel: asrModel, parakeetRaw: raw, asrMs: asrMs,
            cleanupInput: cleanup.input, cleanupEngine: cleanup.engine, cleanupResult: cleanup.result,
            cleanupMs: cleanup.ms, flowCleaned: cleanup.final,
            languageGuess: Self.languageGuess(raw), flowBuild: flowBuild,
            route: cleanup.route, s1ControlLine: cleanup.route == "s1" ? cleanup.controlLine : nil,
            cleanupContract: cleanup.engine == "local:dose1-t2" && cleanup.controlLine != nil ? T2CleanupOptions.contract : nil,
            cleanupControlLine: cleanup.engine == "local:dose1-t2" ? cleanup.controlLine : nil)
        do {
            try await Task.detached(priority: .utility) { try store.append(record) }.value
            Telemetry.log("shadow.capture_saved", properties: [
                "id": String(record.id.prefix(8)), "gesture": record.gesture, "duration_s": record.durationS,
                "asr_ms": asrMs, "cleanup_ms": cleanup.ms, "cleanup_result": cleanup.result,
                "words": raw.split(separator: " ").count,
            ])
        } catch {
            Telemetry.log("shadow.write_failed", properties: ["what": "jsonl", "error": error.localizedDescription])
        }
    }

    private struct Cleanup {
        let input: String; let engine: String; let result: String; let ms: Int; let final: String
        var controlLine: String? = nil
        var routeOverride: String? = nil
        var route: String { routeOverride ?? ShadowCleanupObserver.route(engine: engine, result: result) ?? "skip:unknown" }
    }

    private func cleanUp(raw: String, segments: [TranscriptSegment], capture: Finished,
                         fileSize: Int, asrFailure: String?) async -> Cleanup {
        func skipped(_ reason: String, input: String = raw, final: String = "") -> Cleanup {
            Cleanup(input: input, engine: "rules", result: "unavailable:\(reason)", ms: 0, final: final)
        }
        if let asrFailure { return skipped(asrFailure) }
        if raw.isEmpty { return skipped("empty_transcript") }
        if let reason = SpeechPresenceGate.dropReason(joinedText: raw, voicedSeconds: capture.voicedSeconds,
                                                      peakRMS: capture.peakRMS, quietVoicedSeconds: capture.quietVoicedSeconds,
                                                      recognitionConfidence: segments.compactMap(\.confidence).min(),
                                                      mediaPlaying: capture.mediaPlaying) {
            return skipped("speech_gate_\(reason)")
        }
        if SpeechPresenceGate.mediaLeakDropReason(joinedText: raw, voicedSeconds: capture.voicedSeconds,
                                                  capturedSeconds: capture.capturedSeconds,
                                                  mediaPlaying: capture.mediaPlaying) != nil {
            return skipped("media_leak")
        }
        let autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true
        let context = capture.context
        let cleanupLevel = context?.cleanupLevel ?? CleanupLevel.current.rawValue
        let usesTunedCleanup = Qwen3Polisher.effectiveAutomaticCleanupModel == WhisperNowTunedPolisher.settingValue
        let recognizedT2 = usesTunedCleanup && WhisperNowTunedPolisher.usesT2Contracts
        let usesModelTranscript = recognizedT2 || (usesTunedCleanup && WhisperNowTunedPolisher.usesT4)
        if usesModelTranscript && DictationTextPreparation.predominantlyNonLatin(raw) { return skipped("non_latin") }
        let preparation = T2CleanupOptions.preparationTranscript(rawASR: raw, recognizedT2: usesModelTranscript).map { text in
            // Shadow recordings are stopped by the observed key gesture, not the spoken stop command.
            let commandText = formatter.config.interpretVoiceCommands
                ? TextFormatter.interpretLineBreakCommands(text) : text
            return DictationTextPreparation.Prepared(rawText: text, command: TrailingPressEnter.parse(commandText,
                enabled: UserDefaults.standard.bool(forKey: "voice.pressEnterCommandEnabled") && autoPaste), rejection: nil)
        } ?? DictationTextPreparation.prepare(segments: segments, formatter: formatter,
            pressEnterEnabled: UserDefaults.standard.bool(forKey: "voice.pressEnterCommandEnabled"),
            autoPaste: autoPaste)
        if preparation.rejection == .nonLatin { return skipped("non_latin") }
        if preparation.rejection == .empty { return skipped("empty_transcript") }
        let formatted = preparation.command.text
        func finalize(_ candidate: String) -> String {
            let result = T2CleanupOptions.finalizedTranscript(candidate: candidate, preparedASR: formatted,
                level: cleanupLevel, recognizedT2: usesModelTranscript)
                .map { DictationLayout.preservingLineBreaks(in: $0, from: formatted) }
                ?? DictationTextPreparation.finalize(polished: candidate, formatted: formatted)
            return DictationFinalPass.apply(DictationLayout.restoringBoundaryBreaks(in: result, from: formatted))
        }
        if DictationLayout.isBreakOnly(formatted) {
            return skipped("layout-command", input: formatted, final: formatted)
        }
        let polishEnabled = UserDefaults.standard.object(forKey: "polishEnabled") as? Bool ?? true
        if cleanupLevel == CleanupLevel.none.rawValue || !polishEnabled {
            return skipped("polish_off", input: formatted,
                           final: finalize(formatted))
        }
        if fileSize < 36_000 {
            // The live path skips the model for very short clips.
            return skipped("short_clip", input: formatted,
                           final: finalize(formatted))
        }
        let suspects = Array(Set(segments.compactMap(\.suspectWords).flatMap { $0 }
                                 + TextFormatter.suspectsForPolish(formatted)))
        let vocabulary = Array(Set(ProperNounVocabulary.current() + CombinedDictionary.terms()))
        let observer = ShadowCleanupObserver()
        let sectionObservations = ShadowSectionCleanupObservations()
        let polishContext = context?.polishContext ?? .default
        let appContextLabel = context?.appContextLabel ?? Qwen3Polisher.appContextLabel(forBundleID: context?.frontApp)
        let personality = context?.personality ?? PersonalityStyle.current.rawValue
        let qwenEngine = Qwen3Polisher.effectiveAutomaticCleanupModel == "qwen3" ? "local:qwen3" : "rules"
        let polishDraft: @Sendable (String, Bool) async -> String = { text, isSection in
            let requestObserver = isSection ? ShadowCleanupObserver() : observer
            let result = await ShadowCleanupTrace.$observer.withValue(requestObserver) {
                await Qwen3Polisher.shared.polish(text,
                    context: polishContext,
                    suspectWords: isSection || suspects.isEmpty ? nil : suspects,
                    userVocabulary: vocabulary.isEmpty ? nil : vocabulary,
                    fieldContext: nil,  // text before the cursor is never read in shadow mode
                    appContextLabel: appContextLabel, cleanupLevel: cleanupLevel,
                    personalityStyle: personality)
            }
            if isSection { sectionObservations.record(requestObserver, fallbackEngine: qwenEngine) }
            return result
        }
        let started = Date()
        let sectioned = polishContext != .code && Qwen3Polisher.isEnabled && formatted.contains(where: \.isNewline)
        var sectionTimedOut = false
        var polished: String
        if sectioned {
            let ranges = DictationTextPreparation.cleanupSections(in: formatted)
            let deadline = ContinuousClock.now + .seconds(DictationDeadline.sectionBudgetSeconds(count: ranges.count))
            let result = await DictationTextPreparation.cleanSections(in: formatted, ranges: ranges, deadline: deadline,
                review: { original, edited in
                    await DraftDecisionGate.shouldKeepOriginal(original, edited: edited, deadline: deadline)
                }) { section in await polishDraft(section, true) }
            polished = result.text
            sectionTimedOut = result.timedOut
        } else {
            polished = await polishDraft(formatted, false)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let confirmedT2NoSpeech = recognizedT2 && observer.engine == "local:dose1-t2"
            && observer.result == "no-speech" && T2ResponseSafety.isHesitationOnly(formatted)
        if !confirmedT2NoSpeech, polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            polished = formatted
        }
        let final = confirmedT2NoSpeech ? "" : finalize(polished)
        if sectioned {
            let summary = sectionObservations.summary
            let result = sectionTimedOut ? (polished == formatted ? "deadline" : "partial-deadline")
                : (polished == formatted ? "unchanged" : "accepted")
            return Cleanup(input: formatted, engine: summary.engine, result: "sections:" + result,
                           ms: ms, final: final, controlLine: summary.controlLine, routeOverride: "sections")
        }
        return Cleanup(input: observer.input ?? formatted,
                       engine: observer.engine ?? qwenEngine,
                       result: observer.result ?? (polished == formatted ? "unchanged" : "accepted"),
                       ms: ms, final: final, controlLine: observer.controlLine)
    }

    // MARK: Helpers

    static func languageGuess(_ text: String) -> String {
        guard !text.isEmpty else { return "und" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "und"
    }

    /// First 10 hex characters of the running executable's SHA-256, matching
    /// executableSHA256 in build/build-receipt.json.
    nonisolated static func executableDigestPrefix() -> String {
        guard let url = Bundle.main.executableURL,
              let handle = try? FileHandle(forReadingFrom: url) else { return "unknown" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(10))
    }
}
