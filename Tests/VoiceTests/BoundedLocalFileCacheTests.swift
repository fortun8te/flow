import Foundation
import XCTest
@testable import Voice

final class BoundedLocalFileCacheTests: XCTestCase {
    private var directory: URL!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-snapshot-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testWarmReadsDecodeOnceAndAtomicReplacementInvalidates() throws {
        var decodes = 0
        let cache = BoundedLocalFileCache<String>(maximumBytes: 32) { data in
            decodes += 1
            return String(data: data, encoding: .utf8)
        }
        let url = directory.appendingPathComponent("terms")
        try Data("violet".utf8).write(to: url, options: .atomic)
        for _ in 0..<20 { XCTAssertEqual(cache.load(from: url), "violet") }
        XCTAssertEqual(decodes, 1)
        try Data("copper".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(cache.load(from: url), "copper")
        XCTAssertEqual(decodes, 2)
    }

    func testSameSizeEditWithRestoredModificationTimeInvalidates() throws {
        let cache = BoundedLocalFileCache<String>(maximumBytes: 32) { String(data: $0, encoding: .utf8) }
        let url = directory.appendingPathComponent("terms")
        try Data("violet".utf8).write(to: url)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]!
        XCTAssertEqual(cache.load(from: url), "violet")
        try Data("copper".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: url.path)
        XCTAssertEqual(cache.load(from: url), "copper")
    }

    func testMissingMalformedAndOversizedFilesNeverReuseOldValue() throws {
        var decodes = 0
        let cache = BoundedLocalFileCache<[String]>(maximumBytes: 32) { data in
            decodes += 1
            return try? JSONDecoder().decode([String].self, from: data)
        }
        let url = directory.appendingPathComponent("terms")
        XCTAssertNil(cache.load(from: url))
        try Data("[\"violet\"]".utf8).write(to: url)
        XCTAssertEqual(cache.load(from: url), ["violet"])
        try Data("broken".utf8).write(to: url)
        XCTAssertNil(cache.load(from: url))
        XCTAssertNil(cache.load(from: url))
        XCTAssertEqual(decodes, 2, "An unchanged malformed revision is not reparsed every call")
        try Data(repeating: 120, count: 33).write(to: url)
        XCTAssertNil(cache.load(from: url))
        XCTAssertEqual(decodes, 2, "Oversized content must not reach the decoder")
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(cache.load(from: url))
        try Data("[\"copper\"]".utf8).write(to: url)
        XCTAssertEqual(cache.load(from: url), ["copper"])
        XCTAssertNil(cache.load(from: directory), "A directory is not a personalization file")
    }

    func testConcurrentReadersShareOneDecodedRevision() throws {
        var decodes = 0
        let cache = BoundedLocalFileCache<String>(maximumBytes: 32) { data in
            decodes += 1 // The cache serializes decoder calls.
            return String(data: data, encoding: .utf8)
        }
        let url = directory.appendingPathComponent("terms")
        try Data("violet".utf8).write(to: url)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in XCTAssertEqual(cache.load(from: url), "violet") }
        XCTAssertEqual(decodes, 1)
    }

    func testDecodedSnapshotCountIsBounded() throws {
        var decodes = 0
        let cache = BoundedLocalFileCache<String>(maximumBytes: 32, capacity: 2) { data in
            decodes += 1
            return String(data: data, encoding: .utf8)
        }
        let urls = (0..<3).map { directory.appendingPathComponent("terms-\($0)") }
        for (index, url) in urls.enumerated() {
            try Data("violet\(index)".utf8).write(to: url)
            XCTAssertNotNil(cache.load(from: url))
        }
        XCTAssertNotNil(cache.load(from: urls[0]))
        XCTAssertEqual(decodes, 4)
    }
}
