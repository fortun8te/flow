import Foundation

/// One immutable, indexed snapshot of the user-edited cleanup catalog. Warm
/// selection/readiness/deadline checks inspect file metadata, not all JSON rows.
/// A changed or invalid revision never reuses settings from the previous one.
final class CleanupModelCatalog: @unchecked Sendable {
    static let maximumBytes = 4 * 1024 * 1024
    private static let cache = BoundedLocalFileCache<CleanupModelCatalog>(maximumBytes: maximumBytes) {
        CleanupModelCatalog(data: $0)
    }

    let prompt: String?
    private let rows: [String: [String: Any]]

    static func load(from url: URL) -> CleanupModelCatalog? { cache.load(from: url) }

    func row(id: String) -> [String: Any]? { rows[id] }

    private init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        prompt = json["prompt"] as? String
        var rows: [String: [String: Any]] = [:]
        rows.reserveCapacity(models.count)
        for row in models {
            guard let id = row["id"] as? String, rows[id] == nil else { continue }
            // Preserve the former first(where:) behavior for duplicate IDs,
            // including an invalid first row. Do not silently select another model.
            rows[id] = row
        }
        self.rows = rows
    }
}
