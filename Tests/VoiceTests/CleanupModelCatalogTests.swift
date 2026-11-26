import Foundation
import XCTest
@testable import Voice

final class CleanupModelCatalogTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-catalog-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private var url: URL { directory.appendingPathComponent("cleanup-models.json") }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: url, options: .atomic)
    }

    func testIndexesModelsAndRetainsFirstDuplicateAndSharedPrompt() throws {
        try write(#"{"prompt":"Keep the words.","models":[{"id":"violet","file":"violet.gguf","prompt":"Keep names."},{"id":"violet","file":"wrong.gguf"},{"id":"copper","file":"copper.gguf"},{"file":"no-id.gguf"}]}"#)
        let catalog = try XCTUnwrap(CleanupModelCatalog.load(from: url))
        XCTAssertEqual(catalog.prompt, "Keep the words.")
        XCTAssertEqual(catalog.row(id: "violet")?["file"] as? String, "violet.gguf")
        XCTAssertEqual(catalog.row(id: "violet")?["prompt"] as? String, "Keep names.")
        XCTAssertEqual(catalog.row(id: "copper")?["file"] as? String, "copper.gguf")
        XCTAssertNil(catalog.row(id: "copper")?["prompt"])
        XCTAssertNil(catalog.row(id: "missing"))
    }

    func testInvalidFirstDuplicateDoesNotSilentlyChooseDifferentWeights() throws {
        try write(#"{"models":[{"id":"violet"},{"id":"violet","file":"wrong.gguf"}]}"#)
        let catalog = try XCTUnwrap(CleanupModelCatalog.load(from: url))
        XCTAssertNotNil(catalog.row(id: "violet"))
        XCTAssertNil(catalog.row(id: "violet")?["file"])
    }

    func testConcurrentWarmLookupsReuseTheSameDecodedSnapshot() throws {
        try write(#"{"models":[{"id":"violet","file":"violet.gguf"}]}"#)
        let catalog = try XCTUnwrap(CleanupModelCatalog.load(from: url))
        let url = self.url
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            XCTAssertTrue(CleanupModelCatalog.load(from: url) === catalog)
        }
    }

    func testAtomicReplacementUsesNewPromptAndWeightsWithoutMutatingCapturedSnapshot() throws {
        try write(#"{"prompt":"Violet","models":[{"id":"local","file":"violet.gguf"}]}"#)
        let before = try XCTUnwrap(CleanupModelCatalog.load(from: url))
        try write(#"{"prompt":"Copper","models":[{"id":"local","file":"copper.gguf"}]}"#)
        let after = try XCTUnwrap(CleanupModelCatalog.load(from: url))
        XCTAssertFalse(before === after)
        XCTAssertEqual(after.prompt, "Copper")
        XCTAssertEqual(after.row(id: "local")?["file"] as? String, "copper.gguf")
        XCTAssertEqual(before.prompt, "Violet")
        XCTAssertEqual(before.row(id: "local")?["file"] as? String, "violet.gguf")
    }

    func testMalformedMissingAndOversizedCatalogsInvalidateOldSelection() throws {
        try write(#"{"models":[{"id":"violet","file":"violet.gguf"}]}"#)
        XCTAssertNotNil(CleanupModelCatalog.load(from: url))
        for invalid in ["broken", "{}", #"{"models":[null]}"#, #"{"models":[{"id":"violet"},7]}"#] {
            try write(invalid)
            XCTAssertNil(CleanupModelCatalog.load(from: url))
            XCTAssertNil(CleanupModelCatalog.load(from: url))
        }
        try Data(repeating: 32, count: CleanupModelCatalog.maximumBytes + 1).write(to: url, options: .atomic)
        XCTAssertNil(CleanupModelCatalog.load(from: url))
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(CleanupModelCatalog.load(from: url))
        XCTAssertNil(CleanupModelCatalog.load(from: directory))
        try write(#"{"models":[{"id":"copper","file":"copper.gguf"}]}"#)
        let recovered = try XCTUnwrap(CleanupModelCatalog.load(from: url))
        XCTAssertNil(recovered.row(id: "violet"))
        XCTAssertEqual(recovered.row(id: "copper")?["file"] as? String, "copper.gguf")
    }

    func testNamedPipeCatalogDoesNotWaitForAWriter() async throws {
        let url = self.url
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        let finished = expectation(description: "non-regular catalog rejected without a writer")
        let read = Task.detached {
            let result = CleanupModelCatalog.load(from: url)
            finished.fulfill()
            return result
        }
        await fulfillment(of: [finished], timeout: 1)
        // Unblock a regressed blocking open after the failed expectation, so
        // this regression reports a failure instead of hanging the whole suite.
        let writer = open(url.path, O_RDWR | O_NONBLOCK)
        if writer >= 0 {
            let handle = FileHandle(fileDescriptor: writer, closeOnDealloc: true)
            try? handle.write(contentsOf: Data("invalid".utf8))
            try? handle.close()
        }
        let result = await read.value
        XCTAssertNil(result)
    }
}
