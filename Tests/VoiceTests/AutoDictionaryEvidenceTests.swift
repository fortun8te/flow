import Foundation
import XCTest
@testable import Voice

/// Invented fixtures and an in-memory word judge: these checks need no private vocabulary or model.
final class AutoDictionaryEvidenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-evidence-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var judge: AutoDictionary.WordJudge {
        AutoDictionary.WordJudge(count: { ["because", "weather", "whether"].contains($0) ? 6_000_000 : nil },
                                 isKnown: { ["because", "weather", "whether"].contains($0) })
    }

    private func store() -> AutoDictionary { AutoDictionary(directory: directory, settings: nil) }

    func testPassiveModelKeepsCannotPromoteWithoutAUserEdit() throws {
        let dictionary = store()
        for index in 0..<6 {
            dictionary.observe(before: "the toy stops becuase the axle is blue",
                               after: "the toy stops because the axle is blue", source: .opt1Kept,
                               evidenceID: "passive-\(index)", judge: judge)
        }
        XCTAssertEqual(dictionary.entry(heard: "becuase", written: "because")?.status, .pending)
        XCTAssertTrue(dictionary.liveSpellings().isEmpty)
        dictionary.observe(before: "the box opens becuase the moon is square",
                           after: "the box opens because the moon is square", source: .dictationEdit,
                           evidenceID: "user-edit", judge: judge)
        XCTAssertEqual(dictionary.entry(heard: "becuase", written: "because")?.status, .live)
    }

    func testOneOperationCannotVoteTwiceAcrossSnapshotsOrReloads() throws {
        let dictionary = store()
        dictionary.observe(before: "the toy stops becuase the axle is blue",
                           after: "the toy stops because the axle is blue", source: .dictationEdit,
                           evidenceID: "recording-one", judge: judge)
        let reloaded = store()
        reloaded.observe(before: "the toy stops becuase the axle is blue again",
                         after: "the toy stops because the axle is blue again", source: .flowHistory,
                         evidenceID: "recording-one", judge: judge)
        XCTAssertEqual(reloaded.entry(heard: "becuase", written: "because")?.count, 1)
        XCTAssertEqual(reloaded.entry(heard: "becuase", written: "because")?.status, .pending)
        reloaded.observe(before: "the toy stops becuase the axle is blue",
                         after: "the toy stops because the axle is blue", source: .dictationEdit,
                         evidenceID: "recording-two", judge: judge)
        XCTAssertEqual(reloaded.entry(heard: "becuase", written: "because")?.count, 2)
        XCTAssertEqual(reloaded.entry(heard: "becuase", written: "because")?.status, .live)
    }

    func testRepeatedWordInOneObservationCountsOnce() {
        let dictionary = store()
        dictionary.observe(before: "it spins becuase the toy is round and stops becuase the axle is blue",
                           after: "it spins because the toy is round and stops because the axle is blue",
                           source: .dictationEdit, evidenceID: "one-edit", judge: judge)
        XCTAssertEqual(dictionary.entry(heard: "becuase", written: "because")?.count, 1)
        XCTAssertEqual(dictionary.entry(heard: "becuase", written: "because")?.status, .pending)
    }

    func testPassiveOutputCannotUndoOrRecaseAUserLearnedName() throws {
        let dictionary = store()
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open OrbitToy beside the blue toy",
                           source: .dictationEdit, evidenceID: "typed-name", judge: judge)
        dictionary.observe(before: "open OrbitToy beside the blue toy", after: "open zetavo beside the blue toy",
                           source: .opt1Kept, evidenceID: "model-reverse", judge: judge)
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open ORBITTOY beside the blue toy",
                           source: .opt1Kept, evidenceID: "model-case", judge: judge)
        let entry = try XCTUnwrap(dictionary.entry(heard: "zetavo", written: "OrbitToy"))
        XCTAssertEqual(entry.status, .live)
        XCTAssertEqual(entry.written, "OrbitToy")
        XCTAssertEqual(entry.undos, 0)
    }

    func testUndoAfterRestartRemovesKeepAndBlocksLateReplay() {
        let operation = UUID()
        store().observe(before: "the toy stops becuase the axle is blue",
                        after: "the toy stops because the axle is blue", source: .opt1Kept,
                        operation: operation, judge: judge)
        let reloaded = store()
        reloaded.observeUndo(original: "the toy stops becuase the axle is blue",
                             candidate: "the toy stops because the axle is blue", operation: operation)
        XCTAssertNil(reloaded.entry(heard: "becuase", written: "because"))
        let afterUndo = store()
        afterUndo.observe(before: "the toy stops becuase the axle is blue",
                          after: "the toy stops because the axle is blue", source: .opt1Kept,
                          operation: operation, judge: judge)
        XCTAssertNil(afterUndo.entry(heard: "becuase", written: "because"))
    }

    func testRepeatedUndoIsOneVetoAndFreshEvidenceIsRequiredAfterCooldown() throws {
        let dictionary = store()
        let now = Date()
        for index in 0..<2 {
            dictionary.observe(before: "the toy stops becuase the axle is blue",
                               after: "the toy stops because the axle is blue", source: .dictationEdit,
                               now: now, evidenceID: "initial-\(index)", judge: judge)
        }
        let operation = UUID()
        for _ in 0..<2 {
            dictionary.observeUndo(original: "the toy stops becuase the axle is blue",
                                   candidate: "the toy stops because the axle is blue", operation: operation, now: now)
        }
        XCTAssertEqual(dictionary.entry(heard: "becuase", written: "because")?.undos, 1)
        let later = now.addingTimeInterval(AutoDictionary.Rules.undoCooldownSeconds + 1)
        dictionary.observe(before: "the toy stops becuase the axle is blue",
                           after: "the toy stops because the axle is blue", source: .opt1Kept,
                           now: later, evidenceID: "passive-later", judge: judge)
        XCTAssertEqual(dictionary.entry(heard: "becuase", written: "because")?.status, .removed)
        dictionary.observe(before: "the toy stops becuase the axle is blue",
                           after: "the toy stops because the axle is blue", source: .dictationEdit,
                           now: later, evidenceID: "fresh-one", judge: judge)
        let entry = try XCTUnwrap(dictionary.entry(heard: "becuase", written: "because"))
        XCTAssertEqual(entry.count, 1)
        XCTAssertEqual(entry.sources[AutoDictionary.Source.dictationEdit.rawValue], 1)
        XCTAssertEqual(entry.status, .pending)
    }

    func testLegacyPassiveOnlyLiveEntryIsDemotedAndOverlayRebuilt() throws {
        let now = Date()
        let entry = AutoDictionaryEntry(heard: "becuase", written: "because", kind: .spelling, status: .live,
                                        count: 2, undos: 0, firstSeen: now, lastSeen: now, liveSince: now,
                                        removedAt: nil, replaces: true, examples: [], sources: ["Opt+1 kept": 2])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(entry))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [object]])
            .write(to: directory.appendingPathComponent("auto-dictionary.json"))
        let dictionary = store()
        XCTAssertEqual(dictionary.entry(heard: "becuase", written: "because")?.status, .pending)
        XCTAssertTrue(dictionary.liveSpellings().isEmpty)
        let overlay = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: dictionary.overlayURL))
        XCTAssertTrue(overlay.isEmpty)
    }

    func testRecurringNameNeedsIndependentContexts() {
        let dictionary = store()
        for _ in 0..<3 {
            dictionary.observeRecurringName("OrbitToy", context: "the OrbitToy floats beside the blue moon", judge: judge)
        }
        XCTAssertEqual(dictionary.entry(heard: "OrbitToy", written: "OrbitToy")?.count, 1)
        XCTAssertTrue(dictionary.liveNames().isEmpty)
        dictionary.observeRecurringName("OrbitToy", context: "the OrbitToy spins beside the red moon", judge: judge)
        dictionary.observeRecurringName("OrbitToy", context: "the OrbitToy rests beside the green moon", judge: judge)
        XCTAssertEqual(dictionary.liveNames(), ["OrbitToy"])
        XCTAssertTrue(dictionary.liveReplacements().isEmpty)
    }

    func testOldHistoryCannotOverwriteNewerUserCasing() throws {
        let dictionary = store()
        let now = Date()
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open OrbitToy beside the blue toy",
                           source: .dictationEdit, now: now, evidenceID: "newer-name", judge: judge)
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open ORBITTOY beside the blue toy",
                           source: .opt1Kept, now: now.addingTimeInterval(120), evidenceID: "passive-newer", judge: judge)
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open orbitTOY beside the blue toy",
                           source: .flowHistory, now: now.addingTimeInterval(-60), evidenceID: "old-import", judge: judge)
        XCTAssertEqual(dictionary.entry(heard: "zetavo", written: "OrbitToy")?.written, "OrbitToy")
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open OrbitTOY beside the blue toy",
                           source: .flowHistory, now: now.addingTimeInterval(60), evidenceID: "new-own-edit", judge: judge)
        let entry = try XCTUnwrap(dictionary.entry(heard: "zetavo", written: "OrbitToy"))
        XCTAssertEqual(entry.written, "OrbitTOY", "newer own spelling wins even when weak evidence was later")
        XCTAssertEqual(entry.lastSeen, now.addingTimeInterval(120))
    }

    func testFullEvidenceLedgerStillAcceptsNewerUserCasingWithoutAddingVotes() throws {
        let dictionary = store()
        let now = Date()
        for index in 0..<AutoDictionary.Rules.maxEvidenceRecords {
            dictionary.observe(before: "open zetavo beside the blue toy", after: "open OrbitToy beside the blue toy",
                               source: .dictationEdit, now: now.addingTimeInterval(Double(index)),
                               evidenceID: "name-\(index)", judge: judge)
        }
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open OrbitTOY beside the blue toy",
                           source: .dictationEdit, now: now.addingTimeInterval(500), evidenceID: "fresh-casing", judge: judge)
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open ORBITTOY beside the blue toy",
                           source: .flowHistory, now: now.addingTimeInterval(20), evidenceID: "old-casing", judge: judge)
        let entry = try XCTUnwrap(dictionary.entry(heard: "zetavo", written: "OrbitToy"))
        XCTAssertEqual(entry.written, "OrbitTOY")
        XCTAssertEqual(entry.count, AutoDictionary.Rules.maxEvidenceRecords)
        XCTAssertEqual(entry.lastSeen, now.addingTimeInterval(500))
    }

    func testOlderImportedReversalCannotUndoNewerUserSpelling() {
        let dictionary = store()
        let now = Date()
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open OrbitToy beside the blue toy",
                           source: .dictationEdit, now: now, evidenceID: "new-user-spelling", judge: judge)
        dictionary.observe(before: "open OrbitToy beside the blue toy", after: "open zetavo beside the blue toy",
                           source: .flowHistory, now: now.addingTimeInterval(-60), evidenceID: "old-reversal", judge: judge)
        XCTAssertEqual(dictionary.entry(heard: "zetavo", written: "OrbitToy")?.status, .live)
        XCTAssertEqual(dictionary.entry(heard: "zetavo", written: "OrbitToy")?.undos, 0)
        dictionary.observe(before: "open OrbitToy beside the blue toy", after: "open zetavo beside the blue toy",
                           source: .dictationEdit, now: now.addingTimeInterval(60), evidenceID: "new-reversal", judge: judge)
        XCTAssertEqual(dictionary.entry(heard: "zetavo", written: "OrbitToy")?.status, .removed)
        XCTAssertEqual(dictionary.entry(heard: "zetavo", written: "OrbitToy")?.undos, 1)
    }

    func testLaterSnapshotSupersedesEarlierTargetWithoutTwoLiveMappings() {
        let dictionary = store()
        let now = Date()
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open OrbitToy beside the blue toy",
                           source: .dictationEdit, now: now, evidenceID: "one-recording", judge: judge)
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open MoonToy beside the blue toy",
                           source: .dictationEdit, now: now.addingTimeInterval(20), evidenceID: "one-recording", judge: judge)
        dictionary.observe(before: "open zetavo beside the blue toy", after: "open OrbitToy beside the blue toy",
                           source: .flowHistory, now: now, evidenceID: "one-recording", judge: judge)
        XCTAssertNil(dictionary.entry(heard: "zetavo", written: "OrbitToy"))
        XCTAssertEqual(dictionary.liveReplacements().map(\.written), ["MoonToy"])
        XCTAssertEqual(dictionary.entry(heard: "zetavo", written: "MoonToy")?.count, 1)
    }

    func testAmbiguousTargetsWithinOneObservationAreNotLearned() {
        let dictionary = store()
        dictionary.observe(before: "put zetavo by the blue toy and zetavo by the green toy",
                           after: "put OrbitToy by the blue toy and MoonToy by the green toy",
                           source: .dictationEdit, evidenceID: "ambiguous-edit", judge: judge)
        XCTAssertTrue(dictionary.allEntries().isEmpty)
    }

    func testIndependentConflictingAliasesKeepVocabularyButCannotRewrite() throws {
        let dictionary = store()
        for index in 0..<2 {
            dictionary.observe(before: "the toy stops becuase the axle is blue",
                               after: "the toy stops because the axle is blue", source: .dictationEdit,
                               evidenceID: "spelling-\(index)", judge: judge)
        }
        XCTAssertEqual(dictionary.liveSpellings()["becuase"], "because")
        for name in ["OrbitToy", "MoonToy"] {
            dictionary.observe(before: "open becuase beside the blue toy", after: "open \(name) beside the blue toy",
                               source: .dictationEdit, evidenceID: "name-\(name)", judge: judge)
        }
        XCTAssertEqual(dictionary.liveNames(), ["MoonToy", "OrbitToy"])
        XCTAssertTrue(dictionary.liveReplacements().isEmpty)
        XCTAssertTrue(dictionary.liveSpellings().isEmpty)
        XCTAssertEqual(dictionary.allEntries().filter { $0.status == .live }.count, 3)
        let overlay = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: dictionary.overlayURL))
        XCTAssertTrue(overlay.isEmpty)
        // An overlay written by an older build is repaired on reload as well.
        try JSONEncoder().encode(["becuase": "because"]).write(to: dictionary.overlayURL)
        let reloaded = store()
        XCTAssertEqual(reloaded.liveNames(), ["MoonToy", "OrbitToy"])
        XCTAssertTrue(reloaded.liveReplacements().isEmpty)
        let repairedOverlay = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: reloaded.overlayURL))
        XCTAssertTrue(repairedOverlay.isEmpty)
    }

    func testHistorySeedRejectsWholeFieldsAndDoesNotRecountRuns() throws {
        let voice = directory.appendingPathComponent("history")
        let training = voice.appendingPathComponent("training")
        try FileManager.default.createDirectory(at: training, withIntermediateDirectories: true)
        let legacy: [String: Any] = ["kind": "edit", "id": "legacy", "finalText": "the toy stops becuase it is blue",
                                     "editedField": "Earlier notes. The toy stops because it is blue."]
        let scoped: [String: Any] = ["kind": "edit", "id": "recording-one", "finalText": "the toy stops becuase it is blue",
                                     "editedField": "the toy stops because it is blue", "feedbackSource": "observed-edit",
                                     "targetScope": "pasted-span", "recordedAt": ISO8601DateFormatter().string(from: Date())]
        let rows = try [legacy, scoped, scoped].map { try JSONSerialization.data(withJSONObject: $0) }
        var contents = Data()
        for row in rows { contents.append(row); contents.append(10) }
        try contents.write(to: training.appendingPathComponent("dictations.jsonl"))
        let dictionary = store()
        let missingWispr = directory.appendingPathComponent("missing.sqlite")
        let report = AutoDictionarySeed.run(into: dictionary, judge: judge, wispr: missingWispr, voice: voice)
        XCTAssertEqual(report.flowEdits, 2)
        XCTAssertEqual(dictionary.entry(heard: "becuase", written: "because")?.count, 1)
        _ = AutoDictionarySeed.run(into: dictionary, judge: judge, wispr: missingWispr, voice: voice)
        XCTAssertEqual(dictionary.entry(heard: "becuase", written: "because")?.count, 1)
        XCTAssertEqual(dictionary.entry(heard: "becuase", written: "because")?.status, .pending)
    }
}
