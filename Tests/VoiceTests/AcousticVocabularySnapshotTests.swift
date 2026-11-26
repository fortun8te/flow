import Foundation
import XCTest
@testable import Voice

final class AcousticVocabularySnapshotTests: XCTestCase {
    func testGuardOnlyChangesDoNotRebuildAcousticSessionButKeepFreshEvidence() {
        let options = AcousticVocabularySnapshot.Options(cbw: nil, minimumSimilarity: nil)
        let original = AcousticVocabularySnapshot(terms: ["OrbitToy"], knownOther: ["kettle"], options: options)
        let changed = AcousticVocabularySnapshot(terms: ["OrbitToy"], knownOther: ["violet"], options: options)
        XCTAssertEqual(original.sessionKey, changed.sessionKey)
        XCTAssertEqual(original.knownOther, ["kettle"])
        XCTAssertEqual(changed.knownOther, ["violet"])
    }

    func testExactTokenBytesAndModelOptionsInvalidateSessionIdentity() {
        let options = AcousticVocabularySnapshot.Options(cbw: nil, minimumSimilarity: nil)
        let a = AcousticVocabularySnapshot(terms: ["Caf\u{00E9}"], knownOther: [], options: options)
        let b = AcousticVocabularySnapshot(terms: ["Cafe\u{0301}"], knownOther: [], options: options)
        XCTAssertEqual(a.terms, b.terms)
        XCTAssertNotEqual(a.sessionKey, b.sessionKey)
        let changed = AcousticVocabularySnapshot(terms: a.terms, knownOther: [],
            options: .init(cbw: -2, minimumSimilarity: 0.7))
        XCTAssertNotEqual(a.sessionKey, changed.sessionKey)
    }

    func testInvalidThresholdsUseExistingDefaultsAndNegativeAcousticMarginsRemainValid() {
        for invalid: Float in [.nan, .infinity, -.infinity] {
            let options = AcousticVocabularySnapshot.Options(cbw: invalid, minimumSimilarity: invalid)
            XCTAssertNil(options.cbw)
            XCTAssertEqual(options.minimumSimilarity, 0.6)
        }
        for invalid: Float in [-1, 2] {
            XCTAssertEqual(AcousticVocabularySnapshot.Options(cbw: nil, minimumSimilarity: invalid).minimumSimilarity, 0.6)
        }
        XCTAssertEqual(AcousticVocabularySnapshot.Options(cbw: -2, minimumSimilarity: 1).cbw, -2)
        XCTAssertEqual(AcousticVocabularySnapshot.Options(cbw: 0, minimumSimilarity: 0).minimumSimilarity, 0)
    }

    func testHorizontalWhitespaceIsNormalizedWithoutTurningSnippetsIntoNames() {
        XCTAssertEqual(AcousticVocabularySnapshot.normalizedTerm("  Orbit\t\u{00A0}Toy  "), "Orbit Toy")
        XCTAssertNil(AcousticVocabularySnapshot.normalizedTerm("Orbit\nToy"))
        XCTAssertNil(AcousticVocabularySnapshot.normalizedTerm("Orbit\rToy"))
        XCTAssertNil(AcousticVocabularySnapshot.normalizedTerm(" \t "))
    }
}
