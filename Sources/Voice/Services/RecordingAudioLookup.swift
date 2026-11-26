import Foundation

/// Text is only a compatibility hint for history written before recording IDs.
/// Repeated words must never silently attach one recording's text to another's audio.
enum RecordingAudioLookup {
    static func normalizedText(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func resolve(storedPath: String?, recordingID: String?, rawText: String?, text: String,
                        pathForID: (String) -> String?, legacyPaths: () -> [String: String],
                        exists: (String) -> Bool) -> String? {
        if let path = storedPath, !path.isEmpty, exists(path) { return path }
        if let id = recordingID, !id.isEmpty {
            // An identified recording may be deleted or its audio unavailable.
            // A text match cannot substitute a different recording in either case.
            guard let path = pathForID(id), !path.isEmpty, exists(path) else { return nil }
            return path
        }
        let candidates = legacyPaths()
        let paths = Set([rawText, text].compactMap { value -> String? in
            guard let value else { return nil }
            return candidates[normalizedText(value)]
        })
        guard paths.count == 1, let path = paths.first, exists(path) else { return nil }
        return path
    }
}

struct LegacyAudioPathIndex {
    private var entries: [String: (recordingID: String, path: String)] = [:]
    private var ambiguous: Set<String> = []

    mutating func add(text: String, recordingID: String, path: String) {
        let key = RecordingAudioLookup.normalizedText(text)
        guard !key.isEmpty, !path.isEmpty, !ambiguous.contains(key) else { return }
        if let old = entries[key], old.recordingID != recordingID || old.path != path {
            entries.removeValue(forKey: key)
            ambiguous.insert(key)
        } else {
            entries[key] = (recordingID, path)
        }
    }

    var paths: [String: String] { entries.mapValues(\.path) }
}
