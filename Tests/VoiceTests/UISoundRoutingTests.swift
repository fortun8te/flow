import CoreAudio
import XCTest
@testable import Voice

/// Earcons go to the system alert output; AirPlay and Bluetooth give way to the built-in speakers (22 Nov 2026).
final class UISoundRoutingTests: XCTestCase {
    private let builtIn = UISoundDevice(id: 10, transport: kAudioDeviceTransportTypeBuiltIn)
    private let airPlay = UISoundDevice(id: 20, transport: kAudioDeviceTransportTypeAirPlay)
    private let usb = UISoundDevice(id: 30, transport: kAudioDeviceTransportTypeUSB)

    func testAirPlaySystemOutputRoutesToBuiltInSpeakers() {
        XCTAssertEqual(UISoundRouting.target(systemOutput: airPlay, defaultOutput: airPlay, builtIn: builtIn), builtIn)
    }

    func testAirPlayDefaultWithSameSystemOutputRoutesToBuiltIn() {
        XCTAssertEqual(UISoundRouting.target(systemOutput: nil, defaultOutput: airPlay, builtIn: builtIn), builtIn)
    }

    func testBluetoothTargetGivesWayToBuiltIn() {
        let bluetooth = UISoundDevice(id: 40, transport: kAudioDeviceTransportTypeBluetooth)
        XCTAssertEqual(UISoundRouting.target(systemOutput: bluetooth, defaultOutput: bluetooth, builtIn: builtIn), builtIn)
    }

    func testAirPlayWithoutBuiltInKeepsAirPlay() {
        XCTAssertEqual(UISoundRouting.target(systemOutput: airPlay, defaultOutput: airPlay, builtIn: nil), airPlay)
    }

    func testLowLatencySystemOutputIsUsedDirectly() {
        XCTAssertEqual(UISoundRouting.target(systemOutput: usb, defaultOutput: builtIn, builtIn: builtIn), usb)
    }

    func testMainOutputIsUsedOnlyWhenNoSystemOutputIsReported() {
        XCTAssertEqual(UISoundRouting.target(systemOutput: nil, defaultOutput: usb, builtIn: builtIn), usb)
        XCTAssertNil(UISoundRouting.target(systemOutput: nil, defaultOutput: nil, builtIn: builtIn))
    }

    func testHighLatencyTransports() {
        XCTAssertTrue(UISoundRouting.isHighLatency(kAudioDeviceTransportTypeAirPlay))
        XCTAssertTrue(UISoundRouting.isHighLatency(kAudioDeviceTransportTypeBluetooth))
        XCTAssertTrue(UISoundRouting.isHighLatency(kAudioDeviceTransportTypeBluetoothLE))
        XCTAssertFalse(UISoundRouting.isHighLatency(kAudioDeviceTransportTypeBuiltIn))
        XCTAssertFalse(UISoundRouting.isHighLatency(kAudioDeviceTransportTypeUSB))
    }

    /// Trigger-to-play-call time. Cold is the first render of a cue; warm is after prewarm.
    /// Printed so the before and after numbers can be read from the test log.
    func testEarconPlayCallIsFastAfterPrewarm() throws {
        SoundEffects.resetCueCacheForTesting()
        SoundEffects.playStop()
        Thread.sleep(forTimeInterval: 0.6)
        let cold = SoundEffects.recentPlayLatenciesMs.last
        SoundEffects.prewarm()
        Thread.sleep(forTimeInterval: 0.3)
        SoundEffects.playStop()
        Thread.sleep(forTimeInterval: 0.6)
        guard let warm = SoundEffects.recentPlayLatenciesMs.last, let cold else {
            throw XCTSkip("No play call reached the sound engine on this machine.")
        }
        print("[SFX-PROBE] cold trigger-to-play \(String(format: "%.2f", cold)) ms, warm \(String(format: "%.2f", warm)) ms")
        XCTAssertLessThan(warm, 20)
    }
}
