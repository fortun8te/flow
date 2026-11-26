import Foundation
import XCTest
@testable import Voice

final class RecordingAudioLookupTests: XCTestCase {
    func testRepeatedTextCannotSelectAnArbitraryRecording() {
        var index = LegacyAudioPathIndex()
        index.add(text: "Violet\n kettle", recordingID: "a", path: "/fixture/a.caf")
        index.add(text: "violet kettle", recordingID: "a", path: "/fixture/a.caf")
        XCTAssertEqual(index.paths["violet kettle"], "/fixture/a.caf")
        index.add(text: "violet kettle", recordingID: "b", path: "/fixture/b.caf")
        index.add(text: "violet kettle", recordingID: "a", path: "/fixture/a.caf")
        XCTAssertNil(index.paths["violet kettle"])
    }

    func testStoredPathAvoidsTextIndexAndExactIDIsNeverReplacedByTextMatch() {
        let path = RecordingAudioLookup.resolve(storedPath: "/fixture/exact.caf", recordingID: "a", rawText: nil, text: "violet",
            pathForID: { _ in XCTFail("Stored path already resolves"); return nil },
            legacyPaths: { XCTFail("Exact references must avoid the legacy scan"); return [:] }, exists: { _ in true })
        XCTAssertEqual(path, "/fixture/exact.caf")
        let missing = RecordingAudioLookup.resolve(storedPath: nil, recordingID: "deleted", rawText: "violet", text: "violet",
            pathForID: { _ in nil }, legacyPaths: { XCTFail("Never substitute another recording"); return ["violet": "/fixture/wrong.caf"] }, exists: { _ in true })
        XCTAssertNil(missing)
    }

    func testExactIDWorksAfterStoredPathBecomesUnavailable() {
        XCTAssertEqual(RecordingAudioLookup.resolve(storedPath: "/fixture/old.caf", recordingID: "a", rawText: nil, text: "violet",
            pathForID: { $0 == "a" ? "/fixture/current.caf" : nil }, legacyPaths: { [:] },
            exists: { $0 == "/fixture/current.caf" }), "/fixture/current.caf")
    }

    func testConflictingLegacyRawAndFinalMatchesAreRejected() {
        let paths = ["raw": "/fixture/a.caf", "final": "/fixture/b.caf"]
        XCTAssertNil(RecordingAudioLookup.resolve(storedPath: nil, recordingID: nil, rawText: "raw", text: "final",
            pathForID: { _ in nil }, legacyPaths: { paths }, exists: { _ in true }))
        XCTAssertEqual(RecordingAudioLookup.resolve(storedPath: nil, recordingID: nil, rawText: "raw", text: "unmatched",
            pathForID: { _ in nil }, legacyPaths: { paths }, exists: { _ in true }), "/fixture/a.caf")
    }
}
