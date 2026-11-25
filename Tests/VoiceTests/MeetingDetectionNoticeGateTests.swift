import Testing
@testable import Voice

@Suite("Call detection notices")
struct MeetingDetectionNoticeGateTests {
    @Test func overlappingDetectorsOnlyAnnounceOnce() {
        var gate = MeetingDetectionNoticeGate()
        let announced1 = gate.begin("bridge")
        #expect(announced1)
        let announced2 = gate.begin("bridge")
        #expect(!announced2)
        let announced3 = gate.begin("native")
        #expect(!announced3)
        gate.end("bridge")
        let announced4 = gate.begin("bridge")
        #expect(!announced4)
        gate.end("native")
        gate.end("bridge")
        let announced5 = gate.begin("native")
        #expect(announced5)
    }

    @Test func disablingDetectionClearsActiveSources() {
        var gate = MeetingDetectionNoticeGate()
        let announced6 = gate.begin("bridge")
        #expect(announced6)
        gate.reset()
        let announced7 = gate.begin("bridge")
        #expect(announced7)
    }
}
