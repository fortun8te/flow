import Foundation
import XCTest
@testable import Voice

/// Invented observations; persistence failures are injected before publishing bytes.
final class AutoDictionaryPersistenceTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private var blocked: String?
        private var publishedFailure: String?
        private var externalReplacement: Data?
        private var writes: [String: Int] = [:]

        func block(_ filename: String?) {
            lock.lock(); defer { lock.unlock() }
            blocked = filename
        }

        func count(_ filename: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return writes[filename] ?? 0
        }

        func failAfterPublish(_ filename: String?) {
            lock.lock(); defer { lock.unlock() }
            publishedFailure = filename
        }

        func replaceImmediatelyAfterPublish(with data: Data) {
            lock.lock(); defer { lock.unlock() }
            externalReplacement = data
        }

        func write(_ data: Data, to url: URL) throws {
            lock.lock()
            writes[url.lastPathComponent, default: 0] += 1
            let shouldFail = blocked == url.lastPathComponent
            let failAfterWrite = publishedFailure == url.lastPathComponent
            let replacement = externalReplacement
            lock.unlock()
            if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
            try PrivateDataFile.replace(data, at: url)
            if url.lastPathComponent == "auto-dictionary.json", let replacement {
                try replacement.write(to: url, options: .atomic)
            }
            if failAfterWrite { throw PrivateDataFile.PersistenceError.synchronizationAfterPublishFailed }
        }
    }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-dictionary-persistence-\(UUID().uuidString)")
        suite = "flow-dictionary-persistence-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var judge: AutoDictionary.WordJudge {
        AutoDictionary.WordJudge(count: { $0 == "because" ? 6_000_000 : nil }, isKnown: { $0 == "because" })
    }

    private func store(writer: Writer? = nil) -> AutoDictionary {
        if let writer {
            return AutoDictionary(directory: directory, settings: defaults, writeData: { try writer.write($0, to: $1) })
        }
        return AutoDictionary(directory: directory, settings: defaults)
    }

    private func name(_ dictionary: AutoDictionary, heard: String = "zetavo", written: String = "OrbitToy", id: String = "first") {
        dictionary.observePair(heard: heard, written: written, source: .dictationEdit,
                               evidenceID: id, judge: judge)
    }

    private func spelling(_ dictionary: AutoDictionary, id: String) {
        dictionary.observe(before: "the toy stops becuase the axle is blue",
                           after: "the toy stops because the axle is blue", source: .dictationEdit,
                           evidenceID: id, judge: judge)
    }

    private func jsonLines(_ rows: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: url)
    }

    func testDuplicateObservationDoesNotRewriteOrInvalidateConsumers() throws {
        let writer = Writer(), observed = store(writer: writer)
        name(observed)
        let revision = observed.currentRevision
        let primary = try PrivateDataFile.identity(at: observed.storeURL)
        let overlay = try PrivateDataFile.identity(at: observed.overlayURL)
        for _ in 0..<5 { name(observed) }
        XCTAssertEqual(observed.currentRevision, revision)
        XCTAssertEqual(try PrivateDataFile.identity(at: observed.storeURL), primary)
        XCTAssertEqual(try PrivateDataFile.identity(at: observed.overlayURL), overlay)
        XCTAssertEqual(writer.count("auto-dictionary.json"), 1)
        XCTAssertEqual(writer.count("typo_dictionary.user.json"), 1)
    }

    func testSamePathInstancesMergeFreshObservationsBeforeWriting() throws {
        let first = store(), second = store()
        name(first)
        name(second, heard: "bentavo", written: "MoonToy", id: "second")
        let reloaded = store()
        XCTAssertEqual(reloaded.liveNames(), ["MoonToy", "OrbitToy"])
        XCTAssertEqual(reloaded.allEntries().map(\.count), [1, 1])
    }

    func testConcurrentSamePathWritersPreserveEveryIndependentObservation() throws {
        let dictionaries = (0..<12).map { _ in store() }
        let wordJudge = judge
        DispatchQueue.concurrentPerform(iterations: dictionaries.count) { index in
            dictionaries[index].observePair(heard: "zetavo", written: "OrbitToy", source: .dictationEdit,
                                             evidenceID: "independent-\(index)", judge: wordJudge)
        }
        let reloaded = store()
        XCTAssertEqual(reloaded.entry(heard: "zetavo", written: "OrbitToy")?.count, dictionaries.count)
        XCTAssertEqual(reloaded.liveNames(), ["OrbitToy"])
    }

    func testCorruptReloadRetainsKnownVocabularyAndCannotOverwriteBytes() throws {
        let dictionary = store()
        name(dictionary)
        let corrupt = Data("{\"version\":2,\"entries\":[".utf8)
        try corrupt.write(to: dictionary.storeURL, options: .atomic)
        name(dictionary, heard: "bentavo", written: "MoonToy", id: "second")
        XCTAssertEqual(dictionary.liveNames(), ["OrbitToy"])
        XCTAssertEqual(dictionary.persistenceState, .init(status: .readFailed, unsavedChanges: false))
        XCTAssertEqual(try Data(contentsOf: dictionary.storeURL), corrupt)
        XCTAssertEqual(defaults.dictionary(forKey: AutoDictionary.persistenceSettingsKey)?["status"] as? String, "readFailed")
    }

    func testUnreadableColdStoreDoesNotBecomeAnEmptyWritableStore() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("auto-dictionary.json")
        let corrupt = Data("not a dictionary".utf8)
        try corrupt.write(to: url)
        let dictionary = store()
        name(dictionary)
        XCTAssertTrue(dictionary.allEntries().isEmpty)
        XCTAssertEqual(dictionary.persistenceState.status, .readFailed)
        XCTAssertFalse(dictionary.flush())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testUnsupportedFutureVersionIsPreserved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("auto-dictionary.json")
        let future = Data("{\"version\":999,\"entries\":[]}".utf8)
        try future.write(to: url)
        let dictionary = store()
        name(dictionary)
        XCTAssertEqual(dictionary.persistenceState.status, .unsupportedVersion)
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testValidFileRestoredAfterReadFailureIsRetriedBeforeNextCorrection() throws {
        let dictionary = store()
        name(dictionary)
        let valid = try Data(contentsOf: dictionary.storeURL)
        try Data("corrupt".utf8).write(to: dictionary.storeURL, options: .atomic)
        name(dictionary, heard: "bentavo", written: "MoonToy", id: "second")
        XCTAssertEqual(dictionary.persistenceState.status, .readFailed)
        try valid.write(to: dictionary.storeURL, options: .atomic)
        name(dictionary, heard: "bentavo", written: "MoonToy", id: "second")
        XCTAssertEqual(dictionary.persistenceState, .init(status: .ready, unsavedChanges: false))
        XCTAssertEqual(store().liveNames(), ["MoonToy", "OrbitToy"])
    }

    func testFlushAloneRecoversARepairedStoreWithoutAnotherObservation() throws {
        let dictionary = store()
        name(dictionary)
        let valid = try Data(contentsOf: dictionary.storeURL)
        try Data("corrupt".utf8).write(to: dictionary.storeURL, options: .atomic)
        XCTAssertFalse(dictionary.flush())
        XCTAssertEqual(dictionary.persistenceState.status, .readFailed)
        try valid.write(to: dictionary.storeURL, options: .atomic)
        XCTAssertTrue(dictionary.flush())
        XCTAssertEqual(dictionary.persistenceState, .init(status: .ready, unsavedChanges: false))
        XCTAssertEqual(dictionary.liveNames(), ["OrbitToy"])
        XCTAssertEqual(dictionary.entry(heard: "zetavo", written: "OrbitToy")?.count, 1)
        XCTAssertEqual(store().liveNames(), ["OrbitToy"])
    }

    func testFailedSaveKeepsLearnedSpellingLiveAndRetriesWithoutAnotherVote() throws {
        let writer = Writer(), observed = store(writer: writer)
        spelling(observed, id: "first")
        XCTAssertNil(observed.liveSpellings()["becuase"])
        writer.block("auto-dictionary.json")
        spelling(observed, id: "second")
        XCTAssertEqual(observed.liveSpellings()["becuase"], "because")
        XCTAssertEqual(observed.persistenceState, .init(status: .writeFailed, unsavedChanges: true))
        XCTAssertEqual(defaults.dictionary(forKey: AutoDictionary.persistenceSettingsKey)?["unsavedChanges"] as? Bool, true)
        let disk = AutoDictionary(directory: observed.storeURL.deletingLastPathComponent(), settings: nil)
        XCTAssertNil(disk.liveSpellings()["becuase"])
        // Reading the old durable snapshot cannot erase the shared instance's unsaved new fix.
        XCTAssertEqual(observed.liveSpellings()["becuase"], "because")
        writer.block(nil)
        XCTAssertTrue(observed.flush())
        XCTAssertEqual(observed.persistenceState, .init(status: .ready, unsavedChanges: false))
        let reloaded = AutoDictionary(directory: observed.storeURL.deletingLastPathComponent(), settings: nil)
        XCTAssertEqual(reloaded.liveSpellings()["becuase"], "because")
        XCTAssertEqual(reloaded.entry(heard: "becuase", written: "because")?.count, 2)
    }

    func testOverlayFailureLeavesPrimaryDurableAndRepairsOnRestart() throws {
        let writer = Writer(), dictionary = store(writer: writer)
        spelling(dictionary, id: "first")
        writer.block("typo_dictionary.user.json")
        spelling(dictionary, id: "second")
        XCTAssertEqual(dictionary.persistenceState, .init(status: .overlayFailed, unsavedChanges: true))
        XCTAssertEqual(dictionary.liveSpellings()["becuase"], "because")
        let before = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: dictionary.overlayURL))
        XCTAssertNil(before["becuase"])
        let reloaded = store()
        XCTAssertEqual(reloaded.liveSpellings()["becuase"], "because")
        XCTAssertEqual(reloaded.persistenceState, .init(status: .ready, unsavedChanges: false))
        let repaired = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: dictionary.overlayURL))
        XCTAssertEqual(repaired["becuase"], "because")
    }

    func testPublishedButUnconfirmedPrimaryWriteCanRetryWithoutFalseConflict() throws {
        let writer = Writer(), dictionary = store(writer: writer)
        writer.failAfterPublish("auto-dictionary.json")
        name(dictionary)
        XCTAssertEqual(dictionary.persistenceState, .init(status: .writeFailed, unsavedChanges: true))
        XCTAssertEqual(dictionary.liveNames(), ["OrbitToy"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dictionary.storeURL.path))
        writer.failAfterPublish(nil)
        XCTAssertTrue(dictionary.flush())
        XCTAssertEqual(dictionary.persistenceState, .init(status: .ready, unsavedChanges: false))
        XCTAssertEqual(writer.count("auto-dictionary.json"), 2)
        XCTAssertEqual(store().liveNames(), ["OrbitToy"])
    }

    func testExternalReplacementImmediatelyAfterPublishCannotMasqueradeAsOurSave() throws {
        let external = AutoDictionary(directory: directory.appendingPathComponent("external-source"), settings: nil)
        name(external, heard: "bentavo", written: "MoonToy", id: "external")
        let externalBytes = try Data(contentsOf: external.storeURL)
        for unconfirmed in [false, true] {
            let writer = Writer()
            writer.replaceImmediatelyAfterPublish(with: externalBytes)
            if unconfirmed { writer.failAfterPublish("auto-dictionary.json") }
            let dictionary = AutoDictionary(directory: directory.appendingPathComponent("race-\(unconfirmed)"), settings: nil,
                                            writeData: { try writer.write($0, to: $1) })
            name(dictionary)
            XCTAssertEqual(dictionary.persistenceState, .init(status: .externalConflict, unsavedChanges: true))
            XCTAssertEqual(dictionary.liveNames(), ["OrbitToy"])
            XCTAssertFalse(dictionary.flush())
            XCTAssertEqual(try Data(contentsOf: dictionary.storeURL), externalBytes)
            let reloaded = AutoDictionary(directory: dictionary.storeURL.deletingLastPathComponent(), settings: nil)
            XCTAssertEqual(reloaded.liveNames(), ["MoonToy"])
        }
    }

    func testPendingSaveCannotEraseAChangedExternalStore() throws {
        let writer = Writer(), dictionary = store(writer: writer)
        writer.block("auto-dictionary.json")
        name(dictionary)
        XCTAssertTrue(dictionary.persistenceState.unsavedChanges)
        let external = store()
        name(external, heard: "bentavo", written: "MoonToy", id: "second")
        let committed = try Data(contentsOf: external.storeURL)
        writer.block(nil)
        XCTAssertFalse(dictionary.flush())
        XCTAssertEqual(dictionary.persistenceState, .init(status: .externalConflict, unsavedChanges: true))
        XCTAssertEqual(dictionary.liveNames(), ["OrbitToy"])
        XCTAssertEqual(try Data(contentsOf: external.storeURL), committed)
        XCTAssertEqual(store().liveNames(), ["MoonToy"])
    }

    func testNestedBatchPublishesOnlyAtOuterExit() throws {
        let writer = Writer(), dictionary = store(writer: writer)
        dictionary.batch {
            name(dictionary)
            dictionary.batch {
                name(dictionary, heard: "bentavo", written: "MoonToy", id: "second")
            }
            XCTAssertEqual(writer.count("auto-dictionary.json"), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dictionary.storeURL.path))
            XCTAssertEqual(dictionary.liveNames(), ["MoonToy", "OrbitToy"])
        }
        XCTAssertEqual(writer.count("auto-dictionary.json"), 1)
        XCTAssertEqual(writer.count("typo_dictionary.user.json"), 1)
        XCTAssertEqual(store().liveNames(), ["MoonToy", "OrbitToy"])
    }

    func testInPlaceExternalUpdateWithRestoredMtimeIsNotMistakenForUnchangedData() throws {
        let dictionary = store()
        name(dictionary)
        let originalIdentity = try XCTUnwrap(PrivateDataFile.identity(at: dictionary.storeURL))
        let attributes = try FileManager.default.attributesOfItem(atPath: dictionary.storeURL.path)
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let contents = try String(contentsOf: dictionary.storeURL, encoding: .utf8)
        let changed = contents.replacingOccurrences(of: "OrbitToy", with: "ORBITTOY")
        let handle = try FileHandle(forWritingTo: dictionary.storeURL)
        try handle.write(contentsOf: Data(changed.utf8))
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: dictionary.storeURL.path)
        let changedIdentity = try XCTUnwrap(PrivateDataFile.identity(at: dictionary.storeURL))
        XCTAssertEqual(changedIdentity.inode, originalIdentity.inode)
        XCTAssertEqual(changedIdentity.bytes, originalIdentity.bytes)
        name(dictionary, heard: "bentavo", written: "MoonToy", id: "second")
        XCTAssertEqual(dictionary.liveNames(), ["MoonToy", "ORBITTOY"])
        XCTAssertEqual(store().liveNames(), ["MoonToy", "ORBITTOY"])
    }

    func testUpdatedDictionaryRowRetractsEarlierTargetAndRejectsOlderReplay() throws {
        let dictionary = store(), first = Date(timeIntervalSince1970: 1_800_000_000)
        dictionary.observePair(heard: "zetavo", written: "OrbitToy", source: .wisprDictionary,
                               now: first, evidenceID: "dictionary-row", judge: judge)
        let events = dictionary.observePair(heard: "zetavo", written: "MoonToy", source: .wisprDictionary,
                                            now: first.addingTimeInterval(5), evidenceID: "dictionary-row", judge: judge)
        XCTAssertTrue(events.contains { $0.change == .removed && $0.written == "OrbitToy" })
        XCTAssertEqual(dictionary.liveNames(), ["MoonToy"])
        let reloaded = store()
        reloaded.observePair(heard: "zetavo", written: "OrbitToy", source: .wisprDictionary,
                             now: first, evidenceID: "dictionary-row", judge: judge)
        XCTAssertEqual(reloaded.liveNames(), ["MoonToy"])
        XCTAssertEqual(reloaded.entry(heard: "zetavo", written: "MoonToy")?.count, 1)
    }

    func testSeededUndoRetractsPreviouslyImportedKeepAndSurvivesReplay() throws {
        let voice = directory.appendingPathComponent("history")
        let url = voice.appendingPathComponent("opt1-evidence/attempts.jsonl")
        let applied: [String: Any] = ["operationID": "synthetic-operation", "outcome": "applied",
                                      "input": "the toy stops becuase the axle is blue",
                                      "proposedOutput": "the toy stops because the axle is blue",
                                      "recordedAt": "2026-11-22T10:00:00Z"]
        let undone: [String: Any] = ["operationID": "synthetic-operation", "outcome": "undone", "recordedAt": "2026-11-22T10:00:31Z"]
        try jsonLines([applied], to: url)
        let dictionary = store(), missing = directory.appendingPathComponent("missing.sqlite")
        _ = AutoDictionarySeed.run(into: dictionary, judge: judge, wispr: missing, voice: voice)
        XCTAssertEqual(dictionary.entry(heard: "becuase", written: "because")?.count, 1)
        try jsonLines([applied, undone], to: url)
        let reloaded = store()
        let report = AutoDictionarySeed.run(into: reloaded, judge: judge, wispr: missing, voice: voice)
        XCTAssertEqual(report.opt1Undone, 1)
        XCTAssertTrue(reloaded.allEntries().isEmpty)
        // A stale history export that omits Undo cannot restore its old vote.
        try jsonLines([applied], to: url)
        let replay = store()
        _ = AutoDictionarySeed.run(into: replay, judge: judge, wispr: missing, voice: voice)
        XCTAssertTrue(replay.allEntries().isEmpty)
    }

    func testMalformedSeedSourceDoesNotSilentlyDropAnUndoRecord() throws {
        let voice = directory.appendingPathComponent("history")
        let url = voice.appendingPathComponent("opt1-evidence/attempts.jsonl")
        try jsonLines([["operationID": "synthetic-operation", "outcome": "applied",
                        "input": "the toy stops becuase the axle is blue",
                        "proposedOutput": "the toy stops because the axle is blue"]], to: url)
        var data = try Data(contentsOf: url)
        data.append(Data("{\"outcome\":\"undone\",\"operationID\":".utf8))
        try data.write(to: url)
        let dictionary = store()
        let report = AutoDictionarySeed.run(into: dictionary, judge: judge,
                                            wispr: directory.appendingPathComponent("missing.sqlite"), voice: voice)
        XCTAssertEqual(report.unreadableSources, 1)
        XCTAssertEqual(report.opt1Kept, 0)
        XCTAssertTrue(dictionary.allEntries().isEmpty)
    }

    func testImportedOldUndoDoesNotRemoveNewerIndependentUserCorrection() throws {
        let dictionary = store(), old = Date(timeIntervalSince1970: 1_800_000_000)
        dictionary.observePair(heard: "zetavo", written: "OrbitToy", source: .opt1Kept,
                               now: old, evidenceID: "kept-operation", judge: judge)
        dictionary.observePair(heard: "zetavo", written: "OrbitToy", source: .dictationEdit,
                               now: old.addingTimeInterval(3600), evidenceID: "later-user-edit", judge: judge)
        let reloaded = store()
        reloaded.observeUndo(original: "open zetavo beside the blue toy", candidate: "open OrbitToy beside the blue toy",
                             evidenceID: "kept-operation", now: old.addingTimeInterval(30))
        XCTAssertEqual(reloaded.liveNames(), ["OrbitToy"])
        XCTAssertEqual(reloaded.entry(heard: "zetavo", written: "OrbitToy")?.count, 1)
        XCTAssertEqual(reloaded.entry(heard: "zetavo", written: "OrbitToy")?.sources[AutoDictionary.Source.opt1Kept.rawValue], 0)
        XCTAssertEqual(store().liveNames(), ["OrbitToy"])
    }

    func testPrivacyModeStopsPositiveLearningAndRetryButAllowsExplicitRemoval() throws {
        let previous = UserDefaults.standard.object(forKey: "voice.privacyMode")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "voice.privacyMode") }
            else { UserDefaults.standard.removeObject(forKey: "voice.privacyMode") }
        }
        UserDefaults.standard.set(false, forKey: "voice.privacyMode")
        let dictionary = store()
        name(dictionary)
        UserDefaults.standard.set(true, forKey: "voice.privacyMode")
        name(dictionary, heard: "bentavo", written: "MoonToy", id: "second")
        XCTAssertEqual(dictionary.liveNames(), ["OrbitToy"])
        XCTAssertFalse(dictionary.flush())
        dictionary.remove(written: "OrbitToy")
        let reloaded = store()
        XCTAssertTrue(reloaded.liveNames().isEmpty)
        XCTAssertNil(reloaded.entry(heard: "bentavo", written: "MoonToy"))
        XCTAssertEqual(reloaded.entry(heard: "zetavo", written: "OrbitToy")?.status, .removed)
    }

    func testPrivacyEnabledBeforeBatchPublishesPausesTheWrite() throws {
        let previous = UserDefaults.standard.object(forKey: "voice.privacyMode")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "voice.privacyMode") }
            else { UserDefaults.standard.removeObject(forKey: "voice.privacyMode") }
        }
        UserDefaults.standard.set(false, forKey: "voice.privacyMode")
        let writer = Writer(), dictionary = store(writer: writer)
        dictionary.batch {
            name(dictionary)
            UserDefaults.standard.set(true, forKey: "voice.privacyMode")
        }
        XCTAssertEqual(writer.count("auto-dictionary.json"), 0)
        XCTAssertEqual(dictionary.persistenceState, .init(status: .privacyPaused, unsavedChanges: true))
        XCTAssertFalse(dictionary.flush())
        UserDefaults.standard.set(false, forKey: "voice.privacyMode")
        XCTAssertTrue(dictionary.flush())
        XCTAssertEqual(store().liveNames(), ["OrbitToy"])
    }
}
