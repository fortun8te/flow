// Synthetic catalog lookup microbenchmark. It does not load or run a model.
// Build from the repository root:
// swiftc -O Sources/Voice/Services/BoundedLocalFileCache.swift \
//   Sources/Voice/Services/CleanupModelCatalog.swift scripts/benchmark_cleanup_catalog.swift \
//   -o /tmp/flow-catalog-benchmark
// Run: /tmp/flow-catalog-benchmark [model-count=64] [lookups=2000] [repeats=5]

import Foundation

@main
enum CleanupCatalogBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        let values = arguments.compactMap(Int.init)
        guard arguments.count == values.count, values.count <= 3,
              values.allSatisfy({ $0 > 0 }) else {
            throw NSError(domain: "CleanupCatalogBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected up to three positive integers: model count, lookups, repeats"])
        }
        let modelCount = values.first ?? 64
        let lookups = values.count > 1 ? values[1] : 2000
        let repeats = values.count > 2 ? values[2] : 5
        guard modelCount <= 10_000, lookups <= 1_000_000, repeats <= 100 else {
            throw NSError(domain: "CleanupCatalogBenchmark", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Workload exceeds the benchmark bounds"])
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-catalog-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cleanup-models.json")
        let rows = (0..<modelCount).map { index in
            ["id": "model-\(index)", "name": "Synthetic model \(index)", "file": "model-\(index).gguf",
             "timeoutBase": 3, "timeoutPerWord": 0.12, "timeoutMax": 25, "contextSize": 8192] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["models": rows, "prompt": "Keep the words."], options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        let selected = "model-\(modelCount - 1)"

        // This is the former GeneralCleanupModel.entry(id:) lookup path, before
        // Entry construction, retained here only as the explicit baseline.
        func uncached() throws -> String? {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["models"] as? [[String: Any]]
            return models?.first(where: { $0["id"] as? String == selected })?["file"] as? String
        }
        func cached() -> String? { CleanupModelCatalog.load(from: url)?.row(id: selected)?["file"] as? String }
        let expected = "model-\(modelCount - 1).gguf"
        guard try uncached() == expected, cached() == expected else {
            throw NSError(domain: "CleanupCatalogBenchmark", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Lookup paths disagree"])
        }

        var checksum = 0
        func measure(_ lookup: () throws -> String?) rethrows -> Double {
            let clock = ContinuousClock()
            let started = clock.now
            for _ in 0..<lookups {
                let result = try lookup()
                precondition(result == expected)
                checksum += result!.utf8.count
            }
            let elapsed = started.duration(to: clock.now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        var baseline: [Double] = [], snapshot: [Double] = []
        for iteration in 0..<repeats {
            // Alternate order after warming both paths to reduce order bias.
            if iteration.isMultiple(of: 2) {
                baseline.append(try measure(uncached))
                snapshot.append(measure(cached))
            } else {
                snapshot.append(measure(cached))
                baseline.append(try measure(uncached))
            }
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted(), middle = values.count / 2
            return values.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        let old = median(baseline), new = median(snapshot)
        let report: [String: Any] = [
            "scope": "synthetic catalog lookup only; no model or end-to-end dictation timing",
            "models": modelCount, "catalog_bytes": data.count, "lookups_per_repeat": lookups, "repeats": repeats,
            "uncached_median_ms": old * 1000, "cached_median_ms": new * 1000,
            "speedup": old / new, "checksum": checksum,
            "uncached_samples_ms": baseline.map { $0 * 1000 }, "cached_samples_ms": snapshot.map { $0 * 1000 }
        ]
        let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }
}
