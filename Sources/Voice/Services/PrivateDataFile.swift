import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Private local persistence with bounded cross-process coordination. Callers
/// hold their own memory lock while a read/modify/write transaction is open.
enum PrivateDataFile {
    enum PersistenceError: Error {
        /// Complete bytes were published, but synchronization of their directory
        /// entry failed. A caller must not claim the old contents are unchanged.
        case synchronizationAfterPublishFailed
    }

    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let bytes: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let changedSeconds: Int64
        let changedNanos: Int64
    }

    private static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func validate(_ descriptor: Int32, directory: Bool = false) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure() }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
            throw POSIXError(.EPERM)
        }
        return info
    }

    private static func openDirectory(_ directory: URL) throws -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        do { _ = try validate(descriptor, directory: true) }
        catch { close(descriptor); throw error }
        return descriptor
    }

    static func identity(at url: URL) throws -> Identity? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { if errno == ENOENT { return nil }; throw failure() }
        defer { close(descriptor) }
        let info = try validate(descriptor)
        #if canImport(Darwin)
        let modified = info.st_mtimespec, changed = info.st_ctimespec
        #else
        let modified = info.st_mtim, changed = info.st_ctim
        #endif
        return Identity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), bytes: Int64(info.st_size),
                        modifiedSeconds: Int64(modified.tv_sec), modifiedNanos: Int64(modified.tv_nsec),
                        changedSeconds: Int64(changed.tv_sec), changedNanos: Int64(changed.tv_nsec))
    }

    static func read(_ url: URL) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { if errno == ENOENT { return nil }; throw failure() }
        defer { close(descriptor) }
        _ = try validate(descriptor)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }

    static func withExclusiveAccess<T>(to url: URL, restrictDirectoryPermissions: Bool = true,
                                       _ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let parent = try openDirectory(directory)
        defer { close(parent) }
        // App-owned data directories are private by default. A CLI caller may
        // choose an existing general-purpose output directory; do not chmod
        // that whole directory merely to create its private result file.
        if restrictDirectoryPermissions, fchmod(parent, 0o700) != 0 { throw failure() }
        let name = "." + url.lastPathComponent + ".lock"
        let descriptor = openat(parent, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        _ = try validate(descriptor)
        guard fchmod(descriptor, 0o600) == 0 else { throw failure() }
        let deadline = ContinuousClock.now + .milliseconds(250)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { throw failure() }
            guard ContinuousClock.now < deadline else { throw POSIXError(.EBUSY) }
            usleep(5_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Must be called inside withExclusiveAccess. Preserve the old file until
    /// a complete, synchronized replacement is ready to publish atomically.
    static func replace(_ data: Data, at url: URL) throws {
        _ = try identity(at: url) // Refuse a symlink or special existing file.
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        let temporary = "." + url.lastPathComponent + ".tmp-" + UUID().uuidString
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor); _ = unlinkat(parent, temporary, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw failure() }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw failure() }
        guard renameat(parent, temporary, parent, url.lastPathComponent) == 0 else { throw failure() }
        guard fsync(parent) == 0 else { throw PersistenceError.synchronizationAfterPublishFailed }
    }

    /// Must be called inside withExclusiveAccess. Never join a new record to a
    /// crash-truncated tail; retain that tail as a separate, diagnosable line.
    static func appendLine(_ data: Data, at url: URL) throws {
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        var descriptor = openat(parent, url.lastPathComponent,
                                O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        let created = descriptor >= 0
        if descriptor < 0, errno == EEXIST {
            descriptor = openat(parent, url.lastPathComponent, O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        let info = try validate(descriptor)
        guard fchmod(descriptor, 0o600) == 0 else { throw failure() }
        if info.st_size > 0 {
            var last: UInt8 = 0
            let count = pread(descriptor, &last, 1, info.st_size - 1)
            guard count == 1 else { throw failure() }
            if last != 0x0A { try writeAll(Data([0x0A]), to: descriptor) }
        }
        var line = data
        if line.last != 0x0A { line.append(0x0A) }
        try writeAll(line, to: descriptor)
        guard fsync(descriptor) == 0 else { throw failure() }
        if created, fsync(parent) != 0 { throw PersistenceError.synchronizationAfterPublishFailed }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                #else
                let written = Glibc.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                #endif
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw failure() }
                offset += written
            }
        }
    }
}
