import Foundation

/// Deterministic checks only. No capture, inference, paste, permissions prompts or writes to personal history.
enum FlowSelfTest {
    static func checks() -> [(String, Bool)] {
        let item = RecentDictation(text: "Cleaned", timestamp: Date(timeIntervalSince1970: 1), rawText: "raw")
        let encoded = try? JSONEncoder().encode(item)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(RecentDictation.self, from: $0) }
        return [
            ("Formal style", StyleTransform.apply("hello", style: .formal) == "Hello."),
            ("Casual style", StyleTransform.apply("hello.", style: .casual) == "Hello"),
            ("Personal app category", AppWritingCategory.category(for: "com.apple.MobileSMS") == .personal),
            ("Work app category", AppWritingCategory.category(for: "com.tinyspeck.slackmacgap") == .work),
            ("Code style bypass", AppWritingCategory.style(for: "com.apple.Terminal").isEmpty),
            ("History round trip", decoded?.rawText == "raw" && decoded?.text == "Cleaned"),
            ("Off and Light controls", CleanupLevel.offered == [.none, .light])
        ]
    }
    static func run() -> Bool {
        let results = checks()
        for (name, passed) in results { print("\(passed ? "PASS" : "FAIL") \(name)") }
        return results.allSatisfy { $0.1 }
    }
}
