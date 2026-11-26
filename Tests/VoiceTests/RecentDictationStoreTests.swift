import Foundation
import XCTest
@testable import Voice

final class RecentDictationStoreTests: XCTestCase {
    private func withStore(_ body: (URL, UserDefaults, RecentDictationStore) throws -> Void) throws {
        let name = "flow-recent-tests-" + UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathComponent("history.json")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        try body(file, defaults, RecentDictationStore(file: file, defaults: defaults))
    }

    private func entry(_ id: String) -> RecentDictation {
        RecentDictation(text: "Synthetic " + id, timestamp: Date(timeIntervalSince1970: 1_700_000_000), recordingID: id)
    }

    func testLegacyHistoryMissingCancelledDecodesAndMigratesAfterSave() throws {
        try withStore { file, defaults, store in
            let legacy = Data("[{\"text\":\"violet kettle\",\"timestamp\":100}]".utf8)
            defaults.set(legacy, forKey: RecentDictationStore.legacyKey)
            let old = try XCTUnwrap(store.stored().first)
            XCTAssertFalse(old.cancelled)
            XCTAssertNil(old.recordingID)
            XCTAssertEqual(old.id, "\(old.timestamp.timeIntervalSince1970)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(defaults.data(forKey: RecentDictationStore.legacyKey), legacy)
            XCTAssertTrue(store.mutate { $0.append(entry("second")) })
            XCTAssertNil(defaults.data(forKey: RecentDictationStore.legacyKey))
            XCTAssertEqual(RecentDictationStore(file: file, defaults: defaults).stored().map(\.text), ["violet kettle", "Synthetic second"])
        }
    }

    func testCorruptHistoryIsPreservedAndCannotBecomeAnEmptyWrite() throws {
        try withStore { file, _, store in
            XCTAssertTrue(store.mutate { $0.append(entry("known")) })
            XCTAssertEqual(store.stored().map(\.id), ["known"])
            let damaged = Data("[{\"text\":\"interrupted".utf8)
            try damaged.write(to: file, options: .atomic)
            XCTAssertEqual(store.stored().map(\.id), ["known"])
            XCTAssertNotNil(store.lastError)
            XCTAssertFalse(store.mutate { $0.append(entry("new")) })
            XCTAssertEqual(try Data(contentsOf: file), damaged)
            XCTAssertNotNil(store.lastError)
        }
    }

    func testFailedMigrationRetainsLegacySource() throws {
        try withStore { file, defaults, store in
            let legacy = try JSONEncoder().encode([entry("legacy")])
            defaults.set(legacy, forKey: RecentDictationStore.legacyKey)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            XCTAssertFalse(store.mutate { $0.append(entry("new")) })
            XCTAssertEqual(defaults.data(forKey: RecentDictationStore.legacyKey), legacy)
            XCTAssertNotNil(store.lastError)
        }
    }

    func testCacheNoticesAtomicReplacementAndExternalDeletion() throws {
        try withStore { file, _, store in
            XCTAssertTrue(store.mutate { $0.append(entry("first")) })
            XCTAssertEqual(store.stored().map(\.id), ["first"])
            let oldDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            try JSONEncoder().encode([entry("other")]).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
            XCTAssertEqual(store.stored().map(\.id), ["other"])
            try FileManager.default.removeItem(at: file)
            XCTAssertTrue(store.stored().isEmpty)
            XCTAssertNil(store.lastError)
        }
    }

    func testConcurrentStoreInstancesDoNotLoseUpdates() throws {
        try withStore { file, defaults, first in
            let second = RecentDictationStore(file: file, defaults: defaults)
            let items = (0..<16).map { entry("entry-\($0)") }
            DispatchQueue.concurrentPerform(iterations: items.count) { index in
                let store = index.isMultiple(of: 2) ? first : second
                XCTAssertTrue(store.mutate { $0.append(items[index]) })
            }
            let recovered = RecentDictationStore(file: file, defaults: defaults).stored()
            XCTAssertEqual(Set(recovered.map(\.id)), Set(items.map(\.id)))
            XCTAssertEqual(recovered.count, items.count)
        }
    }

    func testPrivacyBlocksCollectionBeforeAndDuringMutation() throws {
        try withStore { file, defaults, store in
            defaults.set(true, forKey: "voice.privacyMode")
            XCTAssertFalse(store.mutate(collecting: true) { $0.append(entry("blocked")) })
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            defaults.set(false, forKey: "voice.privacyMode")
            XCTAssertFalse(store.mutate(collecting: true) {
                $0.append(entry("cancelled"))
                defaults.set(true, forKey: "voice.privacyMode")
            })
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            // Explicit management of existing history remains possible in privacy mode.
            XCTAssertTrue(store.mutate { $0.removeAll() })
            XCTAssertTrue(store.stored().isEmpty)
        }
    }

    func testRecordingIdentitySurvivesRoundTripAndTimestampCollisions() throws {
        let first = entry("recording-a")
        let second = entry("recording-b")
        XCTAssertEqual(first.timestamp, second.timestamp)
        XCTAssertNotEqual(first.id, second.id)
        let roundTrip = try JSONDecoder().decode([RecentDictation].self, from: JSONEncoder().encode([first, second]))
        XCTAssertEqual(roundTrip.map(\.id), ["recording-a", "recording-b"])
    }

    func testReadingExpiredTrashDoesNotRewriteStoredEvidence() throws {
        try withStore { file, _, store in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            var old = entry("expired")
            old.deletedAt = now.addingTimeInterval(-8 * 24 * 3600)
            var fresh = entry("retained")
            fresh.deletedAt = now.addingTimeInterval(-60)
            XCTAssertTrue(store.mutate(now: now) { $0 = [old, fresh, entry("active")] })
            let original = try Data(contentsOf: file)
            XCTAssertEqual(store.stored(now: now).map(\.id), ["retained", "active"])
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testFixCountingIncludesCapitalizationAndBoundsLongRewrites() {
        XCTAssertEqual(RecentDictations.countFixes(raw: "i think yeah", polished: "I think"), 2)
        XCTAssertEqual(RecentDictations.countFixes(raw: "violet\nkettle", polished: "violet kettle"), 0)
        let prefix = String(repeating: "unchanged ", count: 20_000)
        XCTAssertEqual(RecentDictations.countFixes(raw: prefix + "violet", polished: prefix + "silver"), 1)
        XCTAssertEqual(RecentDictations.countFixes(raw: String(repeating: "violet ", count: 2_000),
                                                  polished: String(repeating: "silver ", count: 2_000)), 1)
    }

    func testRecurringVocabularyUsesOnlyOtherCommittedRecognition() {
        var current = entry("current")
        current.parakeetRawText = "current recognition"
        var previous = entry("previous")
        previous.parakeetRawText = "actual recognizer words"
        var duplicate = previous
        duplicate.parakeetRawText = "duplicate changed snapshot"
        var cancelled = entry("cancelled")
        cancelled.cancelled = true
        cancelled.parakeetRawText = "cancelled recognition"
        var deleted = entry("deleted")
        deleted.deletedAt = Date()
        deleted.parakeetRawText = "deleted recognition"
        let cleanedOnly = entry("cleanup-only")
        var older = entry("older")
        older.parakeetRawText = "older recognizer words"
        let items = [current, previous, duplicate, cancelled, deleted, cleanedOnly, older]
        XCTAssertEqual(RecentDictations.recognitionHistory(items, excluding: "current"),
                       ["actual recognizer words", "older recognizer words"])
        XCTAssertEqual(RecentDictations.recognitionHistory(items, excluding: "current", limit: 1), ["actual recognizer words"])
        XCTAssertTrue(RecentDictations.recognitionHistory(items, excluding: "current", limit: 0).isEmpty)
    }

    func testRecurringVocabularyRecognizesTheSameUUIDWithDifferentCase() {
        let id = UUID().uuidString
        var item = entry(id.lowercased())
        item.parakeetRawText = "current recognition"
        XCTAssertTrue(RecentDictations.recognitionHistory([item], excluding: id).isEmpty)
    }
}
