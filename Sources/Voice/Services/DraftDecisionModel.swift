import Darwin
import Foundation

/// A local, optional D1 process. Only one request is in flight and no draft is queued.
actor DraftDecisionModel {
    static let shared = DraftDecisionModel(configuration: localConfiguration())

    struct Question: Encodable, Sendable {
        enum Kind: String, Encodable, Sendable { case choice, noul }

        let type: Kind
        let instructions: String
        var criteria: [String: String]? = nil

        fileprivate var expectedLabels: Set<String>? {
            guard (1...500).contains(instructions.utf8.count) else { return nil }
            switch type {
            case .noul:
                return criteria == nil ? ["yes", "no"] : nil
            case .choice:
                guard let criteria, (2...6).contains(criteria.count),
                      criteria.allSatisfy({ DraftDecisionModel.isLabel($0.key) && (1...300).contains($0.value.utf8.count) }) else { return nil }
                return Set(criteria.keys)
            }
        }
    }

    typealias Probabilities = [String: [String: Double]]

    struct Configuration {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        var idleTimeout: Duration = .seconds(60)
    }

    private struct Request: Encodable {
        let id: UUID
        let state: String
        let questions: [String: Question]
    }

    private struct Reply: Decodable {
        let ready: Bool?
        let id: UUID?
        let answers: Probabilities?
    }

    private struct Worker {
        let id: UUID
        let process: Process
        let input: FileHandle
        let reader: Task<Void, Never>
        var ready = false
        var buffer = Data()
    }

    private struct Pending {
        let id: UUID
        let expectedLabels: [String: Set<String>]
        var continuation: CheckedContinuation<Probabilities?, Never>?
    }

    private static let maximumFrame = 8192
    private let configuration: Configuration?
    private var worker: Worker?
    private var pending: Pending?
    private var lifecycleTimer: Task<Void, Never>?
    private var lifecycleGeneration = 0
    private var requestTimer: Task<Void, Never>?
    private var nextStart: ContinuousClock.Instant?

    init(configuration: Configuration?) {
        self.configuration = configuration
    }

    var isReady: Bool { worker?.ready == true }

    /// Starts loading asynchronously without sending a draft. Cold decisions skip the model.
    func prewarm() {
        guard worker == nil else { return }
        startWorker()
    }

    func decide(state: String, questions: [String: Question], timeout: Duration = .milliseconds(350)) async -> Probabilities? {
        guard !Task.isCancelled, timeout > .zero, (1...6000).contains(state.utf8.count),
              (1...8).contains(questions.count), pending == nil else { return nil }

        var expectedLabels: [String: Set<String>] = [:]
        for (name, question) in questions {
            guard Self.isLabel(name), let labels = question.expectedLabels else { return nil }
            expectedLabels[name] = labels
        }
        let request = Request(id: UUID(), state: state, questions: questions)
        guard var data = try? JSONEncoder().encode(request), data.count < Self.maximumFrame else { return nil }
        data.append(10)

        guard let worker else {
            startWorker()
            return nil
        }
        guard worker.ready else { return nil }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, pending == nil, self.worker?.id == worker.id else {
                    continuation.resume(returning: nil)
                    return
                }
                pending = Pending(id: request.id, expectedLabels: expectedLabels, continuation: continuation)
                let written = data.withUnsafeBytes { bytes in
                    Darwin.write(worker.input.fileDescriptor, bytes.baseAddress, bytes.count)
                }
                guard written == data.count else {
                    stopWorker(worker.id, cooldown: true)
                    return
                }
                // Keep a late request marked busy until its reply arrives. Otherwise
                // a caller could queue a second draft behind a stalled inference.
                requestTimer = Task { [weak self] in
                    do { try await Task.sleep(for: min(timeout, .seconds(1))) } catch { return }
                    await self?.expire(request.id)
                }
                scheduleWorkerTimeout(worker.id, after: .seconds(2), cooldown: true)
            }
        } onCancel: {
            Task { await self.expire(request.id) }
        }
    }

    private func expire(_ id: UUID) {
        guard pending?.id == id else { return }
        let continuation = pending?.continuation
        pending?.continuation = nil
        continuation?.resume(returning: nil)
    }

    private func startWorker() {
        guard let configuration, nextStart.map({ $0 <= .now }) != false else { return }
        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let writer = input.fileHandleForWriting
        let fd = writer.fileDescriptor
        guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return }
        do {
            try process.run()
        } catch {
            nextStart = .now + .seconds(30)
            return
        }
        // The child owns these ends after launch. Closing the parent's copies
        // means a worker exit is visible as EOF and a Flow exit closes its stdin.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()

        let id = UUID()
        let (stream, source) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let reader = Task { [weak self] in
            for await bytes in stream {
                guard let self else { return }
                await self.receive(bytes, from: id)
            }
            await self?.stopWorker(id, cooldown: true)
        }
        worker = Worker(id: id, process: process, input: writer, reader: reader)
        let stdout = output.fileHandleForReading
        Thread.detachNewThread {
            defer { source.finish() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                // One pipe read returns the bytes already available. Foundation's
                // read(upToCount:) can wait to fill the buffer until the child exits.
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(stdout.fileDescriptor, bytes.baseAddress, bytes.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                if case .enqueued = source.yield(Data(buffer.prefix(count))) { continue }
                return
            }
        }
        scheduleWorkerTimeout(id, after: .seconds(18), cooldown: true)
    }

    private func receive(_ bytes: Data, from id: UUID) {
        guard worker?.id == id else { return }
        worker?.buffer.append(bytes)
        guard let buffer = worker?.buffer, buffer.count <= Self.maximumFrame else {
            stopWorker(id, cooldown: true)
            return
        }
        guard buffer.last == 10 else { return }
        worker?.buffer.removeAll(keepingCapacity: true)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: buffer) else {
            stopWorker(id, cooldown: true)
            return
        }
        if worker?.ready == false, reply.ready == true, reply.id == nil, reply.answers == nil {
            worker?.ready = true
            scheduleIdle(id)
            return
        }
        guard let pending, reply.id == pending.id, reply.ready == nil, let answers = reply.answers,
              Self.matches(answers, expected: pending.expectedLabels) else {
            stopWorker(id, cooldown: true)
            return
        }
        self.pending = nil
        requestTimer?.cancel()
        requestTimer = nil
        pending.continuation?.resume(returning: answers)
        scheduleIdle(id)
    }

    private func scheduleIdle(_ id: UUID) {
        scheduleWorkerTimeout(id, after: configuration?.idleTimeout ?? .seconds(60), cooldown: false)
    }

    private func scheduleWorkerTimeout(_ id: UUID, after delay: Duration, cooldown: Bool) {
        lifecycleTimer?.cancel()
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        lifecycleTimer = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.workerTimedOut(id, generation: generation, cooldown: cooldown)
        }
    }

    private func workerTimedOut(_ id: UUID, generation: Int, cooldown: Bool) {
        guard generation == lifecycleGeneration else { return }
        stopWorker(id, cooldown: cooldown)
    }

    private func stopWorker(_ id: UUID, cooldown: Bool) {
        guard let worker, worker.id == id else { return }
        self.worker = nil
        lifecycleTimer?.cancel()
        lifecycleTimer = nil
        requestTimer?.cancel()
        requestTimer = nil
        let continuation = pending?.continuation
        pending = nil
        continuation?.resume(returning: nil)
        worker.reader.cancel()
        try? worker.input.close()
        if worker.process.isRunning { worker.process.terminate() }
        if cooldown { nextStart = .now + .seconds(30) }
    }

    private static func matches(_ answers: Probabilities, expected: [String: Set<String>]) -> Bool {
        guard Set(answers.keys) == Set(expected.keys) else { return false }
        return answers.allSatisfy { name, distribution in
            Set(distribution.keys) == expected[name] &&
                distribution.values.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
                abs(distribution.values.reduce(0, +) - 1) <= 0.01
        }
    }

    private static func isLabel(_ value: String) -> Bool {
        (1...32).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }
    }

    private static func localConfiguration() -> Configuration? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = home.appendingPathComponent(".ocu-referee/candidates", isDirectory: true)
        let python = candidates.appendingPathComponent("lfm3-vl-2b-mlx4/venv/bin/python")
        let checkpoint = candidates.appendingPathComponent("d1-2B-mlx8bit", isDirectory: true)
        let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.isExecutableFile(atPath: sandbox.path),
              FileManager.default.isReadableFile(atPath: checkpoint.appendingPathComponent("model.safetensors").path),
              let script = bundledScript() else { return nil }
        return Configuration(executable: sandbox,
            arguments: ["-p", "(version 1) (allow default) (deny network*)", python.path, "-I", "-B", "-u", script.path, checkpoint.path],
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "TMPDIR": FileManager.default.temporaryDirectory.path,
                          "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TRANSFORMERS_OFFLINE": "1",
                          "TOKENIZERS_PARALLELISM": "false"])
    }

    private static func bundledScript() -> URL? {
        let name = "draft_decision_worker"
        if let direct = Bundle.main.url(forResource: name, withExtension: "py") { return direct }
        let bundled = Bundle.main.url(forResource: "Voice_Voice", withExtension: "bundle")
        let adjacent = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("Voice_Voice.bundle")
        for url in [bundled, adjacent].compactMap({ $0 }) {
            if let script = Bundle(url: url)?.url(forResource: name, withExtension: "py") { return script }
        }
        return nil
    }
}
