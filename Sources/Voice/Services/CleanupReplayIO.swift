import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The headless replay uses the same private, synchronized storage primitive as
/// live run records. JSONL has one delimiter byte (LF); Unicode line separators
/// inside a JSON string are transcript data, not record boundaries.
enum CleanupReplayIO {
    /// Keep two proof processes from resuming/writing the same journal. The
    /// short per-append lock still protects each durable write; this separate
    /// lease owns the experiment across awaits and fails promptly if occupied.
    final class OutputLease {
        private let lock = NSLock()
        private var descriptor: Int32

        init(at url: URL) throws {
            descriptor = try PrivateDataFile.withExclusiveAccess(to: url, restrictDirectoryPermissions: false) {
                let leaseURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).replay-session")
                let fd = open(leaseURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                do {
                    var info = stat()
                    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                          info.st_uid == getuid(), fchmod(fd, 0o600) == 0 else { throw POSIXError(.EPERM) }
                    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
                    return fd
                } catch { close(fd); throw error }
            }
        }

        func release() {
            lock.withLock {
                guard descriptor >= 0 else { return }
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
                descriptor = -1
            }
        }

        deinit { release() }
    }

    enum Failure: Error, LocalizedError {
        case missingInput, changedInput, changedPersonalization, invalidRecord(Int), invalidID, duplicateID, incompatibleResume, unsupportedModel

        var errorDescription: String? {
            switch self {
            case .missingInput: return "Replay input does not exist."
            case .changedInput: return "Replay input changed while it was being read; use a stable snapshot."
            case .changedPersonalization: return "Replay personalization/settings changed while collecting evidence."
            case .invalidRecord(let line): return "Replay JSONL has an invalid record at line \(line); retain the file and use a new output."
            case .invalidID: return "Replay jobs require a nonempty identifier."
            case .duplicateID: return "Replay jobs contain a duplicate identifier."
            case .incompatibleResume: return "Replay output belongs to different input, settings, or executable bytes; use a new output."
            case .unsupportedModel: return "cleanup_model must be s1-mini, qwen3, dose1, or the legacy whispernow-tuned alias."
            }
        }
    }

    static func inputData(at url: URL) throws -> Data {
        guard let before = try PrivateDataFile.identity(at: url),
              let data = try PrivateDataFile.read(url) else { throw Failure.missingInput }
        guard data.count == before.bytes, try PrivateDataFile.identity(at: url) == before else { throw Failure.changedInput }
        return data
    }

    private static func forEachLine(in data: Data, _ body: (Int, Data) throws -> Void) rethrows {
        for (index, bytes) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            // Only JSON's horizontal padding and the CR in CRLF may be ignored.
            guard bytes.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { continue }
            try body(index + 1, Data(bytes))
        }
    }

    static func decode<T: Decodable>(_ data: Data) throws -> [T] {
        let decoder = JSONDecoder()
        var values: [T] = []
        try forEachLine(in: data) { number, line in
            do { values.append(try decoder.decode(T.self, from: line)) }
            catch { throw Failure.invalidRecord(number) }
        }
        return values
    }

    static func validateIDs(_ identifiers: [String]) throws {
        var seen = Set<String>()
        for identifier in identifiers {
            guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidID }
            guard seen.insert(identifier).inserted else { throw Failure.duplicateID }
        }
    }

    static func canonicalCleanupModel(_ value: String?) throws -> String? {
        guard let value else { return nil }
        switch value {
        case "s1-mini", "qwen3", "dose1": return value
        case "whispernow-tuned": return "dose1"
        default: throw Failure.unsupportedModel
        }
    }

    /// Existing results are reusable only for the same workload and process
    /// identity. An unreadable/corrupt journal is never mistaken for an empty one.
    static func completedIDs(at url: URL, replayKey: String? = nil,
                             isDone: ([String: Any]) -> Bool) throws -> Set<String> {
        guard let data = try PrivateDataFile.read(url) else { return [] }
        var identifiers = Set<String>()
        try forEachLine(in: data) { number, line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let identifier = object["id"] as? String,
                  !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.invalidRecord(number)
            }
            if let replayKey, object["replay_key"] as? String != replayKey { throw Failure.incompatibleResume }
            if isDone(object), !identifiers.insert(identifier).inserted { throw Failure.duplicateID }
        }
        return identifiers
    }

    static func append(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try PrivateDataFile.withExclusiveAccess(to: url, restrictDirectoryPermissions: false) {
            try PrivateDataFile.appendLine(data, at: url)
        }
    }

    /// Canonical JSON-compatible representation of property-list preferences.
    /// Data and dates are represented explicitly instead of dropping settings
    /// from the resume identity when JSONSerialization cannot encode them.
    static func preferenceIdentity(_ value: Any) -> Any {
        if let data = value as? Data { return ["$data": data.base64EncodedString()] }
        if let date = value as? Date { return ["$date": date.timeIntervalSince1970] }
        if let dictionary = value as? [String: Any] { return ["$dictionary": dictionary.mapValues(preferenceIdentity)] }
        if let array = value as? [Any] { return ["$array": array.map(preferenceIdentity)] }
        return ["$scalar": value]
    }

    static func identityData<Configuration: Encodable>(mode: String, configuration: Configuration, inputHash: String,
                             settings: [String: Any], executableHash: String,
                             artifacts: [String: String] = [:]) throws -> Data {
        // Hash the values the typed decoder actually selected. Foundation's two
        // JSON decoders can choose different values for duplicate object keys.
        let encoded = try JSONEncoder().encode(configuration)
        guard var config = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw Failure.invalidRecord(1)
        }
        // A resumed small proof may change its cap or output location without
        // changing the experiment. Input *bytes*, not its path, bind the jobs.
        for key in ["limit", "allow_while_flow_running", "input", "output"] { config.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: [
            "schema": 1, "mode": mode, "configuration": config,
            "input_sha256": inputHash, "settings": preferenceIdentity(settings),
            "executable_sha256": executableHash, "artifacts": artifacts,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Cheap checks before/after native work detect changed personalization
    /// without hashing the executable or all audio again for every case.
    static func stateIdentity(settings: [String: Any], learnedRevision: Int,
                              vocabulary: [String], files: [URL]) throws -> Data {
        var identities: [String: Any] = [:]
        for url in files {
            if let item = try PrivateDataFile.identity(at: url) {
                identities[url.path] = ["device": item.device, "inode": item.inode, "bytes": item.bytes,
                    "mtimeSeconds": item.modifiedSeconds, "mtimeNanos": item.modifiedNanos,
                    "ctimeSeconds": item.changedSeconds, "ctimeNanos": item.changedNanos] as [String: Any]
            } else { identities[url.path] = "missing" }
        }
        return try JSONSerialization.data(withJSONObject: [
            "settings": preferenceIdentity(settings), "learnedRevision": learnedRevision,
            "vocabulary": vocabulary.map { Data($0.utf8).base64EncodedString() }, "files": identities,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
