import Foundation
import XCTest
@testable import Voice

final class PrivateDataFileTests: XCTestCase {
    private func withFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-private-file-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("fixture.jsonl"))
    }

    func testReplacementPublishesCompletePrivateFileAndChangesIdentity() throws {
        try withFile { file in
            try PrivateDataFile.withExclusiveAccess(to: file) {
                try PrivateDataFile.replace(Data("old".utf8), at: file)
            }
            let old = try XCTUnwrap(PrivateDataFile.identity(at: file))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.deletingLastPathComponent().path)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try PrivateDataFile.withExclusiveAccess(to: file) {
                try PrivateDataFile.replace(Data("new".utf8), at: file)
            }
            XCTAssertEqual(try PrivateDataFile.read(file), Data("new".utf8))
            XCTAssertNotEqual(try PrivateDataFile.identity(at: file), old)
            let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            let directoryMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(fileMode?.intValue, 0o600)
            XCTAssertEqual(directoryMode?.intValue, 0o700)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
                .contains(where: { $0.contains(".tmp-") }))
        }
    }

    func testInterruptedTailDoesNotConsumeNextRecord() throws {
        try withFile { file in
            let damaged = Data("{\"id\":\"unfinished".utf8)
            try PrivateDataFile.withExclusiveAccess(to: file) {
                try PrivateDataFile.replace(damaged, at: file)
                try PrivateDataFile.appendLine(Data("{\"id\":\"next\"}".utf8), at: file)
                try PrivateDataFile.appendLine(Data("{\"id\":\"last\"}\n".utf8), at: file)
            }
            XCTAssertEqual(try PrivateDataFile.read(file),
                           Data("{\"id\":\"unfinished\n{\"id\":\"next\"}\n{\"id\":\"last\"}\n".utf8))
        }
    }

    func testSymlinkTargetIsNeitherReadNorOverwritten() throws {
        try withFile { file in
            let destination = file.deletingLastPathComponent().appendingPathComponent("original")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep this fixture".utf8).write(to: destination)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: destination)
            XCTAssertThrowsError(try PrivateDataFile.identity(at: file))
            XCTAssertThrowsError(try PrivateDataFile.read(file))
            XCTAssertThrowsError(try PrivateDataFile.withExclusiveAccess(to: file) {
                try PrivateDataFile.replace(Data("replacement".utf8), at: file)
            })
            XCTAssertThrowsError(try PrivateDataFile.withExclusiveAccess(to: file) {
                try PrivateDataFile.appendLine(Data("replacement".utf8), at: file)
            })
            XCTAssertEqual(try Data(contentsOf: destination), Data("keep this fixture".utf8))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), destination.path)
        }
    }

    func testMissingAndNonRegularFilesAreDistinguished() throws {
        try withFile { file in
            XCTAssertNil(try PrivateDataFile.identity(at: file))
            XCTAssertNil(try PrivateDataFile.read(file))
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            XCTAssertThrowsError(try PrivateDataFile.read(file))
            XCTAssertThrowsError(try PrivateDataFile.withExclusiveAccess(to: file) {
                try PrivateDataFile.replace(Data(), at: file)
            })
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }
}
