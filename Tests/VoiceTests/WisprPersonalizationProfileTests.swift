import Foundation
import Testing
@testable import Voice

@Suite("Wispr local personalization")
struct WisprPersonalizationProfileTests {
    private func profile(_ extra: String = "") -> WisprPersonalizationProfile {
        let json = """
        {"schema_version":1,"auto_cleanup_level":"light",
         "personalization_styles":{"work":"excited","email":"excited","other":"excited","personal":"veryCasual","unset":"default"},
         "polish_instructions":{"default":{"Make more concise":true,"Reword for clarity":false,"Reorder for readability":true,"Add structure for readability":false}}\(extra)}
        """
        return WisprPersonalizationProfile.decode(Data(json.utf8))!
    }

    @Test func mappingsAndFlags() {
        let p = profile()
        #expect(p.cleanupLevel == "light")
        #expect(p.style(for: .work) == "excited")
        #expect(p.style(for: .email) == "excited")
        #expect(p.style(for: .other) == "excited")
        #expect(p.style(for: .personal) == "veryCasual")
        #expect(p.style(for: .unset) == "neutral")
        #expect(p.instructions?.concise == true)
        #expect(p.instructions?.clarity == false)
        #expect(p.instructions?.reorder == true)
        #expect(p.instructions?.structure == false)
    }

    @Test func invalidDataAndUnknownValues() {
        #expect(WisprPersonalizationProfile.decode(Data("{\"schema_version\":2}".utf8)) == nil)
        #expect(WisprPersonalizationProfile.decode(Data(repeating: 32, count: 65_537)) == nil)
        let p = WisprPersonalizationProfile.decode(Data("{\"schema_version\":1,\"auto_cleanup_level\":\"bad\",\"personalization_styles\":{\"work\":\"bad\"}}".utf8))!
        #expect(p.cleanupLevel == nil)
        #expect(p.style(for: .work) == "neutral")
    }

    @Test func importDoesNotReplaceExistingOrLaterPreferences() {
        let name = "WisprPersonalizationProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("high", forKey: "cleanupLevel")
        defaults.set("formal", forKey: "personalityStyle")
        #expect(profile().applyInitialPreferences(to: defaults))
        #expect(defaults.string(forKey: "cleanupLevel") == "high")
        #expect(!defaults.bool(forKey: "voice.wisprContextStylesEnabled"))
        defaults.set("medium", forKey: "cleanupLevel")
        #expect(!profile().applyInitialPreferences(to: defaults))
        #expect(defaults.string(forKey: "cleanupLevel") == "medium")
    }

    @Test func freshPreferencesAndLegacyToggle() {
        let name = "WisprPersonalizationProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "llmPolishEnabled")
        #expect(profile().applyInitialPreferences(to: defaults))
        #expect(defaults.object(forKey: "cleanupLevel") == nil)
        #expect(defaults.bool(forKey: "voice.wisprContextStylesEnabled"))
    }

    @Test func preparedDictionaryMergesOnceAndRetriesMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "WisprPersonalizationProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["Existing"], forKey: "voice.userDictionary")
        #expect(!WisprPersonalizationProfile.importPreparedDictionary(from: directory, defaults: defaults))
        let json = """
        {"schema_version":1,"entries":[
          {"word":"  raw  ","replacement":"  Corrected  "},
          {"word":"corrected","replacement":""},
          {"word":" Existing ","replacement":null},
          {"word":"  Other  ","replacement":null},
          {"word":" ","replacement":" "}]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("dictionary.json"))
        #expect(WisprPersonalizationProfile.importPreparedDictionary(from: directory, defaults: defaults))
        #expect(defaults.stringArray(forKey: "voice.userDictionary") == ["Existing", "Corrected", "Other"])
        defaults.set(["Edited"], forKey: "voice.userDictionary")
        #expect(!WisprPersonalizationProfile.importPreparedDictionary(from: directory, defaults: defaults))
        #expect(defaults.stringArray(forKey: "voice.userDictionary") == ["Edited"])
    }

    @Test func contextStylesFollowTheCapturedApp() {
        let p = profile()
        #expect(p.style(forBundleID: "ru.keepcoder.Telegram") == p.style(for: .personal))
        #expect(p.style(forBundleID: "com.apple.mail") == p.style(for: .email))
        #expect(p.style(forBundleID: "com.tinyspeck.slackmacOS") == p.style(for: .work))
        #expect(p.style(forBundleID: "unknown.app") == p.style(for: .other))
    }
}
