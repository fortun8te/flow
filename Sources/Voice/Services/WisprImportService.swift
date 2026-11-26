import Foundation
import GRDB
import CryptoKit
import AVFoundation

/// Copies only selected Wispr content. The live database is opened read-only,
/// including its WAL. Screenshots, app context and URLs are never selected.
enum WisprImportService {
    struct Preview { let words: Int; let recordings: Int; let entries: Int }
    struct Result { let words: Int; let entries: Int; let audio: Int; let archive: URL? }
    struct Replacement: Codable { let from: String; let to: String; var source: String? = nil }
    struct Entry: Codable { let sourceID: String; let timestamp: String?; let rawText: String?; let formattedText: String?; let editedText: String?; let audioFile: String? }
    static var archiveDirectory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Voice/Wispr Import", isDirectory: true) }
    static func entries(in directory: URL = archiveDirectory) throws -> [Entry] {
        let file = directory.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
    }
    private static let replacementCache = BoundedLocalFileCache<ImportedTextReplacementRules>(maximumBytes: 4 * 1024 * 1024) { data in
        guard let pairs = try? JSONDecoder().decode([Replacement].self, from: data) else { return nil }
        return ImportedTextReplacementRules(pairs.map { ($0.from, $0.to) })
    }

    /// Called on a utility task while recording. The release path rechecks the
    /// file identity, so a refreshed or deleted archive never leaves stale rules.
    static func prepareReplacements() {
        _ = replacementCache.load(from: archiveDirectory.appendingPathComponent("replacements.json"))
    }

    static func applyReplacements(to text: String) -> String {
        replacementCache.load(from: archiveDirectory.appendingPathComponent("replacements.json"))?.apply(to: text) ?? text
    }
    static func applyReplacements(to text: String, using replacements: [Replacement]) -> String {
        ImportedTextReplacementRules(replacements.map { ($0.from, $0.to) }).apply(to: text)
    }
    private static let importQueue = DispatchQueue(label: "voice.wispr.import")
    private static func preserveAndWrite(_ data: Data, to file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            let previous = try Data(contentsOf: file)
            guard previous != data else { return }
            let hash = SHA256.hash(data: previous).map { String(format: "%02x", $0) }.joined()
            let backup = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + "." + hash + ".backup")
            if FileManager.default.fileExists(atPath: backup.path) {
                guard try Data(contentsOf: backup) == previous else { throw CocoaError(.fileWriteFileExists) }
            } else {
                try previous.write(to: backup, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static var source: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite") }
    static var isAvailable: Bool { FileManager.default.isReadableFile(atPath: source.path) }
    private static func open(_ sourceURL: URL = source) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: sourceURL.path, configuration: configuration)
    }
    static func preview() throws -> Preview {
        try open().read { db in
            Preview(words: try Int.fetchOne(db, sql: "SELECT count(*) FROM Dictionary WHERE coalesce(isDeleted,0)=0 AND coalesce(isSnippet,0)=0") ?? 0,
                    recordings: try Int.fetchOne(db, sql: "SELECT count(*) FROM History WHERE length(audio)>44") ?? 0,
                    entries: try Int.fetchOne(db, sql: "SELECT count(*) FROM History") ?? 0)
        }
    }
    /// Recognition vocabulary only. Automatic refresh does not enable snippets
    /// or text replacements and never copies recordings or changes Wispr's DB.
    static func readVocabulary(sourceURL: URL = source) throws -> [String] {
        try open(sourceURL).read { db in
            try String.fetchAll(db, sql: """
                SELECT CASE WHEN length(trim(coalesce(replacement,''))) > 0
                            THEN substr(replacement,1,501) ELSE substr(phrase,1,501) END
                FROM Dictionary
                WHERE coalesce(isDeleted,0)=0 AND coalesce(isSnippet,0)=0
                  AND length(trim(coalesce(phrase,''))) > 0
                ORDER BY id LIMIT 5000
                """)
        }
    }

    @MainActor private static var lastVocabularyRead: Date?
    @MainActor static func refreshVocabulary() async {
        let now = Date()
        if let lastVocabularyRead, now.timeIntervalSince(lastVocabularyRead) < 30 { return }
        lastVocabularyRead = now
        guard let terms = await Task.detached(priority: .utility, operation: {
            try? Self.readVocabulary()
        }).value, !Task.isCancelled else { return }
        let defaults = UserDefaults.standard
        let needsLegacySeed = defaults.object(forKey: WisprPersonalizationProfile.wisprVocabularySeenKey) == nil
            && defaults.bool(forKey: "voice.wisprDictionaryImported")
        let seeded = needsLegacySeed ? WisprPersonalizationProfile.preparedVocabulary() ?? [] : []
        if WisprPersonalizationProfile.mergeWisprVocabulary(terms, preparedSeed: seeded, defaults: defaults) {
            FlowBroadcast.changed("dictionary")
        }
    }

    static func run(words: Bool, history: Bool, sourceURL: URL = source, archiveURL: URL = archiveDirectory,
                    dictionaryTerms: () -> [String] = { UserDictionary.terms() },
                    addTerm: (String) -> Void = { UserDictionary.add($0) }) throws -> Result {
        try importQueue.sync { try performImport(words: words, history: history, sourceURL: sourceURL, archiveURL: archiveURL, dictionaryTerms: dictionaryTerms, addTerm: addTerm) }
    }
    private static func performImport(words: Bool, history: Bool, sourceURL: URL, archiveURL: URL,
                                      dictionaryTerms: () -> [String], addTerm: (String) -> Void) throws -> Result {
        let db = try open(sourceURL)
        var added = 0
        if words {
            // A correction's phrase is the misheard form, while replacement
            // is the intended spelling. Bias recognition toward the intended
            // term, keeping the separate phrase -> replacement rule below.
            let items = try db.read { try String.fetchAll($0, sql: """
                SELECT CASE WHEN length(trim(coalesce(replacement,''))) > 0
                            THEN replacement ELSE phrase END
                FROM Dictionary
                WHERE coalesce(isDeleted,0)=0 AND coalesce(isSnippet,0)=0
                  AND length(trim(coalesce(phrase,''))) > 0
                """) }
            let mappings = try db.read { db in
                try Row.fetchAll(db, sql: "SELECT phrase, replacement FROM Dictionary WHERE coalesce(isDeleted,0)=0 AND coalesce(isSnippet,0)=0 AND length(phrase)>0 AND length(replacement)>0 ORDER BY modifiedAt, id").compactMap { row -> Replacement? in
                    guard let from: String = row["phrase"], let to: String = row["replacement"],
                          !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return Replacement(from: from, to: to, source: "wispr")
                }
            }
            do {
                let directory = archiveURL
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let path = directory.appendingPathComponent("replacements.json")
                let previous: [Replacement] = FileManager.default.fileExists(atPath: path.path) ? try JSONDecoder().decode([Replacement].self, from: Data(contentsOf: path)) : []
                var merged = [String: Replacement]()
                // Legacy records without an owner were created by this importer.
                // Refresh those from Wispr; explicitly VOICE-owned entries win.
                for pair in mappings { merged[pair.from.lowercased()] = pair }
                for pair in previous where pair.source != nil && pair.source != "wispr" {
                    merged[pair.from.lowercased()] = pair
                }
                let ordered = merged.keys.sorted().compactMap { merged[$0] }
                try preserveAndWrite(JSONEncoder().encode(ordered), to: path)
            }
            let before = dictionaryTerms().count
            for item in items { addTerm(item) }
            added = dictionaryTerms().count - before
        }
        guard history else { return Result(words: added, entries: 0, audio: 0, archive: nil) }
        let base = archiveURL
        let recordings = base.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = base.appendingPathComponent("history.json")
        var entries = try self.entries(in: base)
        var known = [String: Int]()
        for (index, entry) in entries.enumerated() where known[entry.sourceID] == nil { known[entry.sourceID] = index }
        var count = 0
        try db.read { db in
            let rows = try Row.fetchCursor(db, sql: "SELECT transcriptEntityId, timestamp, asrText, formattedText, editedText, audio FROM History WHERE transcriptEntityId IS NOT NULL")
            while let row = try rows.next() {
                let id: String = row["transcriptEntityId"]
                let raw: String? = row["asrText"], formatted: String? = row["formattedText"], edited: String? = row["editedText"]
                let timestamp: String? = row["timestamp"]
                let audio: Data? = row["audio"]
                var name: String?
                if let audio, audio.count > 44, audio.prefix(4) == Data("RIFF".utf8), audio.dropFirst(8).prefix(4) == Data("WAVE".utf8) {
                    let hash = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
                    var filename = hash + ".wav"
                    var audioPath = recordings.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: audioPath.path), try Data(contentsOf: audioPath) != audio {
                        // Never overwrite a corrupted or unrelated existing file.
                        filename = hash + ".recovered.wav"
                        audioPath = recordings.appendingPathComponent(filename)
                        if FileManager.default.fileExists(atPath: audioPath.path), try Data(contentsOf: audioPath) != audio {
                            filename = hash + "." + UUID().uuidString + ".wav"
                            audioPath = recordings.appendingPathComponent(filename)
                        }
                    }
                    let wasNew = !FileManager.default.fileExists(atPath: audioPath.path)
                    if wasNew {
                        try audio.write(to: audioPath, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioPath.path)
                    }
                    if let file = try? AVAudioFile(forReading: audioPath), file.length >  0 {
                        name = "Recordings/" + filename
                        if wasNew { count += 1 }
                    }
                }
                if let index = known[id] {
                    let old = entries[index]
                    entries[index] = Entry(sourceID: id, timestamp: timestamp ?? old.timestamp,
                        rawText: raw ?? old.rawText, formattedText: formatted ?? old.formattedText,
                        editedText: edited ?? old.editedText, audioFile: name ?? old.audioFile)
                } else {
                    known[id] = entries.count
                    entries.append(Entry(sourceID: id, timestamp: timestamp, rawText: raw, formattedText: formatted, editedText: edited, audioFile: name))
                }
            }
        }
        try preserveAndWrite(JSONEncoder().encode(entries), to: file)
        return Result(words: added, entries: entries.count, audio: count, archive: base)
    }
}
