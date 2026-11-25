import Foundation
import GRDB
import Testing
@testable import Voice

@Suite("Wispr import isolation")
struct RebuildQAWisprImportTests {
    @Test("Replacements use whole words, longest match and do not cascade")
    func replacementBoundaries() {
        let mappings = [
            WisprImportService.Replacement(from: "foo", to: "bar"),
            WisprImportService.Replacement(from: "bar", to: "baz"),
            WisprImportService.Replacement(from: "foo bar", to: "long"),
            WisprImportService.Replacement(from: "C++", to: "C plus plus")
        ]
        let output = WisprImportService.applyReplacements(to: "foo foobar foo bar C++ caféfoo", using: mappings)
        #expect(output == "bar foobar long C plus plus caféfoo")
    }

    @Test("Replacement duplicates are case insensitive and latest wins")
    func duplicateMappings() {
        let mappings = [WisprImportService.Replacement(from: "qwen", to: "old"), WisprImportService.Replacement(from: "QWEN", to: "Qwen")]
        #expect(WisprImportService.applyReplacements(to: "QWEN qwen", using: mappings) == "Qwen Qwen")
    }

    private func fixture() throws -> (URL, URL, DatabaseQueue) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try DatabaseQueue(path: root.appendingPathComponent("source.sqlite").path)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE History (transcriptEntityId TEXT, timestamp TEXT, asrText TEXT, formattedText TEXT, editedText TEXT, audio BLOB)")
            try db.execute(sql: "CREATE TABLE Dictionary (id INTEGER, phrase TEXT, replacement TEXT, isDeleted INTEGER, isSnippet INTEGER, modifiedAt TEXT)")
            try db.execute(sql: "INSERT INTO History VALUES ('1', '2026-01-01', 'hello', 'Hello', NULL, NULL)")
            try db.execute(sql: "INSERT INTO Dictionary VALUES (1, 'qwen', 'Qwen', 0, 0, '1'), (2, 'deleted', 'ignored', 1, 0, '2'), (3, 'snippet', 'ignored', 0, 1, '3')")
        }
        return (root, root.appendingPathComponent("archive", isDirectory: true), database)
    }

    @Test("Repeated imports do not duplicate records or words")
    func repeatedImport() throws {
        let (root, archive, db) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = db
        var dictionary = Set<String>()
        let source = root.appendingPathComponent("source.sqlite")
        let first = try WisprImportService.run(words: true, history: true, sourceURL: source, archiveURL: archive, dictionaryTerms: { Array(dictionary) }, addTerm: { _ = dictionary.insert($0) })
        let second = try WisprImportService.run(words: true, history: true, sourceURL: source, archiveURL: archive, dictionaryTerms: { Array(dictionary) }, addTerm: { _ = dictionary.insert($0) })
        #expect(first.words == 1)
        #expect(second.words == 0)
        #expect(dictionary == Set(["Qwen"]))
        #expect(try WisprImportService.entries(in: archive).count == 1)
        #expect(second.entries == 1)
    }

    @Test("Vocabulary learns the corrected spelling, not the mishear")
    func correctedVocabularyHint() throws {
        let (root, archive, db) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try db.write { db in
            try db.execute(sql: "INSERT INTO Dictionary VALUES (4, 'cloud code', 'Claude Code', 0, 0, '4'), (5, '   ', '', 0, 0, '5')")
        }
        var dictionary = Set<String>()
        _ = try WisprImportService.run(words: true, history: false, sourceURL: root.appendingPathComponent("source.sqlite"), archiveURL: archive, dictionaryTerms: { Array(dictionary) }, addTerm: { _ = dictionary.insert($0) })
        #expect(dictionary.contains("Claude Code"))
        #expect(!dictionary.contains("cloud code"))
        #expect(!dictionary.contains("   "))
        let data = try Data(contentsOf: archive.appendingPathComponent("replacements.json"))
        let rules = try JSONDecoder().decode([WisprImportService.Replacement].self, from: data)
        #expect(WisprImportService.applyReplacements(to: "CLOUD CODE", using: rules) == "Claude Code")
    }

    @Test("Invalid existing history is not overwritten")
    func invalidArchiveIsPreserved() throws {
        let (root, archive, db) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = db
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let file = archive.appendingPathComponent("history.json")
        let original = Data("not-json".utf8)
        try original.write(to: file)
        #expect(throws: (any Error).self) {
            try WisprImportService.run(words: false, history: true, sourceURL: root.appendingPathComponent("source.sqlite"), archiveURL: archive)
        }
        #expect(try Data(contentsOf: file) == original)
    }
}
