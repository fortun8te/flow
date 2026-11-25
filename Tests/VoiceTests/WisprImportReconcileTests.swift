import Foundation
import GRDB
import CryptoKit
import Testing
@testable import Voice

@Suite("Wispr import reconciliation")
struct WisprImportReconcileTests {
    private func fixture() throws -> (URL, URL, DatabaseQueue) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try DatabaseQueue(path: root.appendingPathComponent("source.sqlite").path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE Dictionary (id INTEGER, phrase TEXT, replacement TEXT, isDeleted INTEGER, isSnippet INTEGER, modifiedAt TEXT)")
            try db.execute(sql: "CREATE TABLE History (transcriptEntityId TEXT, timestamp TEXT, asrText TEXT, formattedText TEXT, editedText TEXT, audio BLOB)")
        }
        return (root, root.appendingPathComponent("archive"), db)
    }
    @Test("Deleted and cleared Wispr rules no longer apply; VOICE rules survive")
    func staleRules() throws {
        let (root, archive, db) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let file = archive.appendingPathComponent("replacements.json")
        let old: [WisprImportService.Replacement] = [.init(from: "old", to: "stale"), .init(from: "mine", to: "kept", source: "voice")]
        try JSONEncoder().encode(old).write(to: file)
        try db.write { db in try db.execute(sql: "INSERT INTO Dictionary VALUES (1, 'old', 'stale', 1, 0, '1'), (2, 'cleared', '', 0, 0, '1'), (3, 'fresh', 'new', 0, 0, '1')") }
        _ = try WisprImportService.run(words: true, history: false, sourceURL: root.appendingPathComponent("source.sqlite"), archiveURL: archive, dictionaryTerms: { [] }, addTerm: { _ in })
        let mappings = try JSONDecoder().decode([WisprImportService.Replacement].self, from: Data(contentsOf: file))
        #expect(WisprImportService.applyReplacements(to: "old mine fresh", using: mappings) == "old kept new")
        try db.write { db in try db.execute(sql: "UPDATE Dictionary SET replacement='' WHERE id=3") }
        _ = try WisprImportService.run(words: true, history: false, sourceURL: root.appendingPathComponent("source.sqlite"), archiveURL: archive, dictionaryTerms: { [] }, addTerm: { _ in })
        let updated = try JSONDecoder().decode([WisprImportService.Replacement].self, from: Data(contentsOf: file))
        #expect(WisprImportService.applyReplacements(to: "mine fresh", using: updated) == "kept fresh")
    }
    @Test("Read-only incremental vocabulary preserves local entries and remembers removed imports")
    func vocabularyRefresh() throws {
        let (root, _, db) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "WisprImportReconcileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["Local Spelling", "My word"], forKey: "voice.userDictionary")
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO Dictionary VALUES
                (1, 'local spelling', '', 0, 0, '1'),
                (2, 'misspelled', 'Corrected', 0, 0, '1'),
                (3, 'no', 'Snippet', 0, 1, '1'),
                (4, 'deleted', '', 1, 0, '1'),
                (5, 'Old import', '', 0, 0, '1')
                """)
        }
        let url = root.appendingPathComponent("source.sqlite")
        let before = try Data(contentsOf: url)
        #expect(WisprPersonalizationProfile.mergeWisprVocabulary(
            try WisprImportService.readVocabulary(sourceURL: url), preparedSeed: ["old import"], defaults: defaults))
        #expect(defaults.stringArray(forKey: "voice.userDictionary") == ["Local Spelling", "My word", "Corrected"])
        defaults.set(["My word"], forKey: "voice.userDictionary")
        #expect(!WisprPersonalizationProfile.mergeWisprVocabulary(
            try WisprImportService.readVocabulary(sourceURL: url), defaults: defaults))
        #expect(defaults.stringArray(forKey: "voice.userDictionary") == ["My word"])
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Corrupt recording at content path is preserved and a valid copy is written")
    func corruptWAV() throws {
        let (root, archive, db) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // 16-bit mono WAV, 8 kHz, two nonempty samples.
        let wav = Data([0x52,0x49,0x46,0x46,0x28,0,0,0,0x57,0x41,0x56,0x45,0x66,0x6d,0x74,0x20,16,0,0,0,1,0,1,0,0x40,0x1f,0,0,0x80,0x3e,0,0,2,0,16,0,0x64,0x61,0x74,0x61,4,0,0,0,1,0,2,0])
        try db.write { db in try db.execute(sql: "INSERT INTO History VALUES (?, ?, ?, ?, ?, ?)", arguments: ["x", "2026", "test", "test", nil, wav]) }
        let dir = archive.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined()
        let corrupt = dir.appendingPathComponent(hash + ".wav")
        try Data("corrupt".utf8).write(to: corrupt)
        _ = try WisprImportService.run(words: false, history: true, sourceURL: root.appendingPathComponent("source.sqlite"), archiveURL: archive)
        #expect(try Data(contentsOf: corrupt) == Data("corrupt".utf8))
        let entry = try #require(WisprImportService.entries(in: archive).first)
        let path = try #require(entry.audioFile)
        #expect(try Data(contentsOf: archive.appendingPathComponent(path)) == wav)
    }
}
