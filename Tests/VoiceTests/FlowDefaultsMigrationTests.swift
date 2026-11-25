import XCTest
@testable import Voice

final class FlowDefaultsMigrationTests: XCTestCase {
    func testAllowlistPreservesFalseAndExistingValuesAndRunsOnce() throws {
        let name = "flow.migration.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("existing", forKey: "cleanupLevel")
        FlowDefaultsMigration.migrate(into: defaults, legacy: [
            "autoPaste": false, "cleanupLevel": "old", "unrelated": "secret",
            "voice.wakeWordEnabled": true, "voice.enableMeetingDetection": true
        ])
        XCTAssertEqual(defaults.object(forKey: "autoPaste") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "cleanupLevel"), "existing")
        XCTAssertNil(defaults.object(forKey: "unrelated"))
        XCTAssertFalse(defaults.bool(forKey: "voice.wakeWordEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "voice.enableMeetingDetection"))
        defaults.set(true, forKey: "voice.wakeWordEnabled")
        FlowDefaultsMigration.migrate(into: defaults, legacy: [:])
        XCTAssertTrue(defaults.bool(forKey: "voice.wakeWordEnabled"))
    }
    func testExistingFlowOptInsSurviveFirstMigration() throws {
        let name = "flow.migration.existing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "voice.enableMeetingDetection")
        defaults.set(true, forKey: "voice.wakeWordEnabled")
        defaults.set("activatedWindow", forKey: "voice.wakeWordMode")
        FlowDefaultsMigration.migrate(into: defaults, legacy: [:])
        XCTAssertTrue(defaults.bool(forKey: "voice.enableMeetingDetection"))
        XCTAssertTrue(defaults.bool(forKey: "voice.wakeWordEnabled"))
        XCTAssertEqual(defaults.string(forKey: "voice.wakeWordMode"), "activatedWindow")
    }

}
