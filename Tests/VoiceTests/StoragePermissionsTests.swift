import Foundation
import Testing
@testable import Voice

struct StoragePermissionsTests {
    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func historyFilesAndBackupHavePrivateModes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let storage = StorageService(directory: root)
        try storage.initialize()
        let directoryMode = try mode(root)
        #expect(directoryMode == 0o700)
        for name in ["voice.db", "voice.db-wal", "voice.db-shm", "voice.db.backup"] {
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                let fileMode = try mode(file)
                #expect(fileMode == 0o600)
            }
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("voice.db.backup").path))
    }

    @Test func symlinkDirectoryIsRejectedWithoutChangingItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let storage = StorageService(directory: link)
        #expect(throws: NSError.self) { try storage.initialize() }
        let targetMode = try mode(target)
        #expect(targetMode == 0o755)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("voice.db").path))
    }

    @Test func symlinkDatabaseIsRejectedWithoutChangingItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("store", isDirectory: true)
        let target = root.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("fixture original preserved".utf8)
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: store.appendingPathComponent("voice.db"), withDestinationURL: target)
        let storage = StorageService(directory: store)
        #expect(throws: NSError.self) { try storage.initialize() }
        let targetMode = try mode(target)
        let retained = try Data(contentsOf: target)
        #expect(targetMode == 0o644)
        #expect(retained == original)
    }
}
