import Foundation
import CryptoKit

/// Imports only the explicitly prepared Wispr meeting export. Existing VOICE
/// records always win, including user edits. No audio is read or copied.
enum WisprMeetingImportService {
    static let sourceMarker = "wispr-flow-export-v1"
    static let maximumBytes = 32 * 1024 * 1024
    static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VOICE/WisprPersonalization/meetings.json")
    }
    struct Report { let imported: Int; let existing: Int; let skipped: Int }
    enum ImportError: Error { case tooLarge, unsupportedSchema }
    private struct Export: Decodable { let schema_version: Int; let meetings: [SourceMeeting] }
    private struct SourceMeeting: Decodable {
        let id: String
        let title: String?
        let created_at: String
        let recorded_ms: Double?
        let ended_at: String?
        let summary: String?
        let notes: String?
        let segments: [SourceSegment]?
    }
    private struct SourceSegment: Decodable {
        let timestamp: String?
        let text: String
        let speaker: Speaker?
    }
    private struct Speaker: Decodable {
        let id: String?
        let name: String?
        enum CodingKeys: String, CodingKey { case id, name }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decodeIfPresent(String.self, forKey: .name)
            if let text = try? values.decode(String.self, forKey: .id) { id = text }
            else if let number = try? values.decode(Int.self, forKey: .id) { id = String(number) }
            else { id = nil }
        }
    }

    /// Returns nil when no prepared export exists. Each meeting is committed
    /// atomically; if an error interrupts the import, a rerun safely resumes.
    static func run(storage: StorageService, file: URL = defaultFile) throws -> Report? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ImportError.tooLarge }
        let export = try JSONDecoder().decode(Export.self, from: data)
        guard export.schema_version == 1 else { throw ImportError.unsupportedSchema }
        var imported = 0, existing = 0, skipped = 0
        for source in export.meetings {
            guard !source.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let date = parseDate(source.created_at) else { skipped += 1; continue }
            let duration: Double
            if let ms = source.recorded_ms, ms.isFinite, ms >= 0 { duration = ms / 1000 }
            else if let ended = source.ended_at.flatMap(parseDate), ended >= date { duration = ended.timeIntervalSince(date) }
            else { duration = 0 }
            let segments = (source.segments ?? []).map { segment in
                let time = parseTimestamp(segment.timestamp) ?? 0
                let name = segment.speaker?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                return TranscriptSegment(speaker: (name?.isEmpty == false ? name! : "Unknown"),
                    speakerId: segment.speaker?.id, text: segment.text, startTime: time, endTime: time)
            }
            let overview = source.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = overview.flatMap { $0.isEmpty ? nil : MeetingSummary(overview: $0, keyDecisions: [], actionItems: [], openQuestions: []) }
            let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let meeting = Meeting(id: stableID(source.id), title: title?.isEmpty == false ? title! : "Untitled Meeting",
                date: date, duration: duration, segments: segments, summary: summary, kind: .meeting,
                pinnedNote: source.notes, sourceApp: sourceMarker)
            if try storage.insertImportedMeetingIfAbsent(meeting, source: sourceMarker) { imported += 1 } else { existing += 1 }
        }
        return Report(imported: imported, existing: existing, skipped: skipped)
    }
    static func stableID(_ sourceID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("VOICE.Wispr.meeting.v1:" + sourceID).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    private static func parseTimestamp(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let n = Double(part), n.isFinite, n >= 0 else { return nil }
            seconds = seconds * 60 + n
        }
        return seconds.isFinite ? seconds : nil
    }
}
