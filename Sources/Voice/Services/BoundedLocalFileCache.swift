import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Small read-only snapshots for local personalization files. Opening/fstat is
/// cheap on a warm path; reading, decoding and compiling rules happen once per
/// file revision. Missing, oversized or malformed files never return stale rules.
final class BoundedLocalFileCache<Value>: @unchecked Sendable {
    private struct Revision: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init?(descriptor: Int32) {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else { return nil }
            device = UInt64(truncatingIfNeeded: info.st_dev)
            inode = UInt64(truncatingIfNeeded: info.st_ino)
            size = Int64(info.st_size)
            #if canImport(Darwin)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
            #else
            modifiedSeconds = Int64(info.st_mtim.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
            changedSeconds = Int64(info.st_ctim.tv_sec)
            changedNanoseconds = Int64(info.st_ctim.tv_nsec)
            #endif
        }
    }

    private struct Entry {
        let revision: Revision
        let value: Value?
        var access: UInt64
    }
    private let lock = NSLock()
    private let maximumBytes: Int
    private let capacity: Int
    private let decode: (Data) -> Value?
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0

    init(maximumBytes: Int, capacity: Int = 4, decode: @escaping (Data) -> Value?) {
        precondition(maximumBytes > 0 && maximumBytes < Int.max && capacity > 0)
        self.maximumBytes = maximumBytes
        self.capacity = capacity
        self.decode = decode
    }

    func load(from url: URL) -> Value? {
        lock.lock(); defer { lock.unlock() }
        let key = url.standardizedFileURL.path
        guard url.isFileURL else { return nil }
        // A malformed import path can be a FIFO. Open nonblocking before the
        // regular-file check so it cannot stall dictation waiting for a writer.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            entries.removeValue(forKey: key)
            return nil
        }
        defer { close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let before = Revision(descriptor: handle.fileDescriptor), before.size >= 0,
              before.size <= maximumBytes else {
            entries.removeValue(forKey: key)
            return nil
        }
        clock &+= 1
        if var cached = entries[key], cached.revision == before {
            cached.access = clock
            entries[key] = cached
            return cached.value
        }
        // Do not trust a size check alone: an external writer can grow the file.
        var data = Data()
        do {
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                guard let next = try handle.read(upToCount: min(65_536, remaining)), !next.isEmpty else { break }
                data.append(next)
            }
        } catch {
            entries.removeValue(forKey: key)
            return nil
        }
        guard data.count <= maximumBytes, data.count == before.size,
              Revision(descriptor: handle.fileDescriptor) == before else {
            entries.removeValue(forKey: key)
            return nil
        }
        let value = decode(data)
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(revision: before, value: value, access: clock)
        return value
    }
}
