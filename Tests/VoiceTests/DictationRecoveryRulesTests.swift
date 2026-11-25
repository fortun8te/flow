import XCTest
@testable import Voice

final class DictationRecoveryRulesTests: XCTestCase {
    private func meeting(
        kind: MeetingKind = .meeting,
        duration: TimeInterval = 30,
        segments: [TranscriptSegment] = [],
        audioPath: String? = "/tmp/meeting.wav"
    ) -> Meeting {
        Meeting(duration: duration, segments: segments, audioFilePath: audioPath, kind: kind)
    }

    func testLongEmptyMeetingWithAudioIsRetranscribed() {
        XCTAssertTrue(DictationRecoveryRules.needsAutoRetranscribe(meeting(), audioFileExists: true))
    }

    func testHalfSecondStubIsNotRetriedOnEveryLaunch() {
        // Six 0.0-1.4 s stubs from 20 Nov produced "Recovered 0 of 6" on every launch.
        for d in [0.0, 0.47, 0.56, 1.0, 1.33] {
            XCTAssertFalse(
                DictationRecoveryRules.needsAutoRetranscribe(meeting(duration: d), audioFileExists: true),
                "duration \(d) should be skipped"
            )
        }
    }

    func testMissingAudioIsSkipped() {
        XCTAssertFalse(DictationRecoveryRules.needsAutoRetranscribe(meeting(), audioFileExists: false))
        XCTAssertFalse(DictationRecoveryRules.needsAutoRetranscribe(meeting(audioPath: nil), audioFileExists: true))
    }

    func testDictationsAndFilledMeetingsAreSkipped() {
        XCTAssertFalse(DictationRecoveryRules.needsAutoRetranscribe(meeting(kind: .dictation), audioFileExists: true))
    }

    func testEmptyTranscriptMessageNamesTheMicrophone() {
        let message = DictationRecoveryRules.emptyTranscriptMessage
        XCTAssertTrue(message.contains("microphone"))
        XCTAssertFalse(message.contains("recovery"))
    }

    func testEmptyTranscriptMessageNamesTheRecordingMicrophone() {
        let message = DictationRecoveryRules.emptyTranscriptMessage(mic: "MacBook Pro Microphone")
        XCTAssertTrue(message.contains("MacBook Pro Microphone"))
        XCTAssertTrue(message.contains("Sound settings"))
        XCTAssertEqual(DictationRecoveryRules.emptyTranscriptMessage(mic: nil), DictationRecoveryRules.emptyTranscriptMessage)
        XCTAssertEqual(DictationRecoveryRules.emptyTranscriptMessage(mic: "  "), DictationRecoveryRules.emptyTranscriptMessage)
    }
}
