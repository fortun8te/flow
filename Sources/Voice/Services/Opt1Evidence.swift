import Darwin
import Foundation

/// Private evidence from an explicit Opt+1 operation. A verified paste proves
/// delivery only. These rows require review before any output can be used as a target.
struct Opt1Evidence: Codable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case applied, unchanged, rejected, unavailable, notApplied, unconfirmed, cancelled, undone
    }

    let schemaVersion: Int
    let engineBuild: String?
    let operationID: UUID
    let recordedAt: Date
    let outcome: Outcome
    let input: String?
    let proposedOutput: String?
    let verifiedTrainingTarget: Bool

    init(operationID: UUID, recordedAt: Date, outcome: Outcome,
         input: String? = nil, proposedOutput: String? = nil) {
        schemaVersion = 1
        engineBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        self.operationID = operationID
        self.recordedAt = recordedAt
        self.outcome = outcome
        self.input = input
        self.proposedOutput = proposedOutput
        verifiedTrainingTarget = false
    }
}

enum Opt1EvidenceLog {
    private static let queue = DispatchQueue(label: "voice.opt1.evidence", qos: .utility)
    static let preference = "voice.saveOpt1TrainingExamples"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: preference) as? Bool ?? true }

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VOICE/opt1-evidence", isDirectory: true)

    static func enqueue(_ record: Opt1Evidence) {
        queue.async {
            do { try append(record, in: directory) }
            catch { print("[VOICE-OPT1-EVIDENCE] Could not save a private local evidence row.") }
        }
    }

    /// Open only private, owned destinations. No text goes through telemetry.
    static func append(_ record: Opt1Evidence, in directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(parentFD) }

        let name = directory.lastPathComponent
        guard mkdirat(parentFD, name, 0o700) == 0 || errno == EEXIST else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let folderFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folderFD >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(folderFD) }
        var info = stat()
        guard fstat(folderFD, &info) == 0, info.st_uid == getuid(), fchmod(folderFD, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let file = openat(folderFD, "attempts.jsonl", O_WRONLY | O_CREAT | O_APPEND | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(file, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, fchmod(file, 0o600) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(record)
        line.append(0x0A)
        try handle.write(contentsOf: line)
    }
}
