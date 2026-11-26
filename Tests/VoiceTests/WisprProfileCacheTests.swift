import Foundation
import XCTest
@testable import Voice

final class WisprProfileCacheTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-cache-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "WisprProfileCacheTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func testProfileCacheRefreshesAndNeverRetainsDeletedOrMalformedPreferences() throws {
        let url = directory.appendingPathComponent("profile.json")
        try Data(#"{"schema_version":1,"auto_cleanup_level":"light"}"#.utf8).write(to: url, options: .atomic)
        XCTAssertEqual(WisprPersonalizationProfile.load(from: url)?.cleanupLevel, "light")
        try Data(#"{"schema_version":1,"auto_cleanup_level":"high"}"#.utf8).write(to: url, options: .atomic)
        XCTAssertEqual(WisprPersonalizationProfile.load(from: url)?.cleanupLevel, "high")
        try Data("broken".utf8).write(to: url, options: .atomic)
        XCTAssertNil(WisprPersonalizationProfile.load(from: url))
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(WisprPersonalizationProfile.load(from: url))
    }

    func testDictionaryCacheRefreshesAfterSourceReplacement() throws {
        let url = directory.appendingPathComponent("dictionary.json")
        XCTAssertNil(WisprPersonalizationProfile.preparedVocabulary(from: directory))
        try Data(#"{"schema_version":1,"entries":[{"word":"old","replacement":"Corrected"}]}"#.utf8).write(to: url, options: .atomic)
        XCTAssertEqual(WisprPersonalizationProfile.preparedVocabulary(from: directory), ["Corrected"])
        try Data(#"{"schema_version":1,"entries":[{"word":"new","replacement":null}]}"#.utf8).write(to: url, options: .atomic)
        XCTAssertEqual(WisprPersonalizationProfile.preparedVocabulary(from: directory), ["new"])
        try Data(#"{"schema_version":2,"entries":[]}"#.utf8).write(to: url, options: .atomic)
        XCTAssertNil(WisprPersonalizationProfile.preparedVocabulary(from: directory))
    }

    func testLiveImportHonorsNormalizedDuplicatesAndExclusions() {
        defaults.set(["Michael's Project"], forKey: "voice.userDictionary")
        defaults.set(["Hidden  Project"], forKey: "voice.dictionaryExcludedTerms")
        XCTAssertTrue(WisprPersonalizationProfile.mergeWisprVocabulary(
            ["Michael’s   Project", "hidden project", "New Project"], defaults: defaults))
        XCTAssertEqual(defaults.stringArray(forKey: "voice.userDictionary"), ["Michael's Project", "New Project"])
        defaults.set([], forKey: "voice.dictionaryExcludedTerms")
        XCTAssertFalse(WisprPersonalizationProfile.mergeWisprVocabulary(["hidden project"], defaults: defaults),
                       "A source refresh must not resurrect a previously excluded import")
    }

    func testPreparedImportHonorsTheSameExclusionsAndNormalization() throws {
        defaults.set(["Michael's Project"], forKey: "voice.userDictionary")
        defaults.set(["Hidden  Project"], forKey: "voice.dictionaryExcludedTerms")
        let json = #"{"schema_version":1,"entries":[{"word":"Michael’s   Project"},{"word":"hidden project"},{"word":"Added"}]}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("dictionary.json"))
        XCTAssertTrue(WisprPersonalizationProfile.importPreparedDictionary(from: directory, defaults: defaults))
        XCTAssertEqual(defaults.stringArray(forKey: "voice.userDictionary"), ["Michael's Project", "Added"])
    }

    func testConcurrentSourceMergesCannotLoseDictionaryEntries() {
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            _ = WisprPersonalizationProfile.mergeWisprVocabulary(["Project \(index)"], defaults: defaults)
        }
        XCTAssertEqual(Set(defaults.stringArray(forKey: "voice.userDictionary") ?? []), Set((0..<64).map { "Project \($0)" }))
        XCTAssertEqual(defaults.stringArray(forKey: WisprPersonalizationProfile.wisprVocabularySeenKey)?.count, 64)
    }
}
