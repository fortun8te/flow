import Testing
import Foundation
@testable import Voice

struct AppExtrasTests {
    @Test func headlessChecksPass() { #expect(FlowSelfTest.checks().allSatisfy { $0.1 }) }
    @Test func categoryMappingAndControls() {
        #expect(AppWritingCategory.category(for: "com.apple.mail") == .email)
        #expect(AppWritingCategory.category(for: "unknown") == .other)
        #expect(!AppWritingCategory.offered.contains(.email))
        #expect(AppWritingCategory.s1Styling(for: "verycasual") == .casual)
        #expect(AppWritingCategory.s1Styling(for: "casual") == .semiCasual)
        #expect(AppWritingCategory.s1Styling(for: "formal") == .formal)
        #expect(AppWritingCategory.s1Styling(for: "excited") == .semiFormal)
    }
    @Test func trashRetention() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let active = RecentDictation(text: "active", timestamp: now)
        var fresh = RecentDictation(text: "fresh", timestamp: now)
        fresh.deletedAt = now.addingTimeInterval(-6 * 24 * 3600)
        var expired = RecentDictation(text: "expired", timestamp: now)
        expired.deletedAt = now.addingTimeInterval(-7 * 24 * 3600)
        #expect(RecentDictations.retainingHistory([active, fresh, expired], now: now).map(\.text) == ["active", "fresh"])
    }
    @Test func legacyHistoryDecodesWithoutTrashField() throws {
        let item = try JSONDecoder().decode(RecentDictation.self, from: Data(#"{"text":"hello","timestamp":0,"cancelled":false}"#.utf8))
        #expect(item.deletedAt == nil)
    }
}
