import Foundation
import Testing
@testable import Voice

@Suite("Shadow mode launch gate")
struct ShadowLaunchGateTests {
    @Test("Shadow on keeps Flow alive while Companion has it switched off")
    func shadowOverridesDisabled() {
        #expect(FlowLaunchGate.decide(flowEnabled: false, shadowMode: true) == .shadow)
        #expect(FlowLaunchGate.decide(flowEnabled: nil, shadowMode: true) == .shadow)
    }

    @Test("Normal mode wins when Flow is enabled, even with shadow on")
    func normalWins() {
        #expect(FlowLaunchGate.decide(flowEnabled: true, shadowMode: true) == .normal)
        #expect(FlowLaunchGate.decide(flowEnabled: true, shadowMode: nil) == .normal)
        #expect(FlowLaunchGate.decide(flowEnabled: true, shadowMode: false) == .normal)
    }

    @Test("Switched off without shadow still quits; unset launches normally")
    func existingBehaviour() {
        #expect(FlowLaunchGate.decide(flowEnabled: false, shadowMode: nil) == .quit)
        #expect(FlowLaunchGate.decide(flowEnabled: false, shadowMode: false) == .quit)
        #expect(FlowLaunchGate.decide(flowEnabled: nil, shadowMode: nil) == .quit)
        #expect(FlowLaunchGate.decide(flowEnabled: nil, shadowMode: false) == .quit)
    }

    @Test("Reads the stored defaults")
    func readsDefaults() throws {
        let suite = "shadow-gate-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "flow.enabled")
        #expect(FlowLaunchGate.decide(defaults: defaults) == .quit)
        defaults.set(true, forKey: "voice.shadowMode")
        #expect(FlowLaunchGate.decide(defaults: defaults) == .shadow)
        defaults.set(true, forKey: "flow.enabled")
        #expect(FlowLaunchGate.decide(defaults: defaults) == .normal)
    }
}

@Suite("Shadow mode fn gestures")
struct ShadowGestureTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test("Hold fn captures until release")
    func hold() {
        var m = ShadowGestureMachine(doubleTapWindow: 0.45)
        #expect(m.handle(.fnDown, at: at(0)) == [.start(at: at(0))])
        #expect(m.handle(.fnUp, at: at(2)) == [.finish(gesture: .hold, startedAt: at(0), endedAt: at(2))])
        #expect(m.state == .idle)
    }

    @Test("A tap under 0.5 s with no second tap is dropped")
    func shortTapDropped() {
        var m = ShadowGestureMachine(doubleTapWindow: 0.5)
        _ = m.handle(.fnDown, at: at(0))
        #expect(m.handle(.fnUp, at: at(0.25)) == [.armTimeout(deadline: at(0.75))])
        #expect(m.handle(.timeout, at: at(0.6)) == [])  // early timer: ignored
        #expect(m.handle(.timeout, at: at(0.75)) == [.discard(reason: "short_tap", startedAt: at(0), endedAt: at(0.75))])
        #expect(m.state == .idle)
    }

    @Test("Exactly 0.5 s is long enough to keep")
    func boundary() {
        var m = ShadowGestureMachine()
        _ = m.handle(.fnDown, at: at(0))
        #expect(m.handle(.fnUp, at: at(0.5)) == [.finish(gesture: .hold, startedAt: at(0), endedAt: at(0.5))])
    }

    @Test("Double-tap fn is hands-free until the next fn press")
    func doubleTap() {
        var m = ShadowGestureMachine(doubleTapWindow: 0.45)
        _ = m.handle(.fnDown, at: at(0))
        _ = m.handle(.fnUp, at: at(0.1))
        #expect(m.handle(.fnDown, at: at(0.3)) == [])
        #expect(m.handle(.fnUp, at: at(0.4)) == [])
        #expect(m.isCapturing)
        #expect(m.handle(.fnDown, at: at(12)) == [.finish(gesture: .handsfree, startedAt: at(0), endedAt: at(12))])
        // The release of the ending press does not start anything.
        #expect(m.handle(.fnUp, at: at(12.1)) == [])
        #expect(m.state == .idle)
        #expect(m.handle(.fnDown, at: at(20)) == [.start(at: at(20))])
    }

    @Test("fn+Space is hands-free until the next fn press")
    func fnSpace() {
        var m = ShadowGestureMachine()
        _ = m.handle(.fnDown, at: at(0))
        #expect(m.handle(.fnSpace, at: at(0.2)) == [])
        #expect(m.handle(.fnUp, at: at(0.3)) == [])
        #expect(m.handle(.fnDown, at: at(5)) == [.finish(gesture: .handsfree, startedAt: at(0), endedAt: at(5))])
    }

    @Test("A second tap after the window starts a new capture and drops the first")
    func lateSecondTap() {
        var m = ShadowGestureMachine(doubleTapWindow: 0.5)
        _ = m.handle(.fnDown, at: at(0))
        _ = m.handle(.fnUp, at: at(0.25))
        #expect(m.handle(.fnDown, at: at(1)) == [
            .discard(reason: "short_tap", startedAt: at(0), endedAt: at(0.75)),
            .start(at: at(1)),
        ])
    }

    @Test("fn with another key is a shortcut, not dictation")
    func chord() {
        var m = ShadowGestureMachine()
        _ = m.handle(.fnDown, at: at(0))
        #expect(m.handle(.chord, at: at(0.8)) == [.discard(reason: "fn_chord", startedAt: at(0), endedAt: at(0.8))])
        #expect(m.handle(.fnUp, at: at(1)) == [])
        #expect(m.state == .idle)
    }

    @Test("The maximum length ends a capture")
    func maxDuration() {
        var m = ShadowGestureMachine()
        _ = m.handle(.fnDown, at: at(0))
        _ = m.handle(.fnSpace, at: at(0.1))
        _ = m.handle(.fnUp, at: at(0.2))
        #expect(m.handle(.maxDuration, at: at(600)) == [.finish(gesture: .handsfree, startedAt: at(0), endedAt: at(600))])
        #expect(m.state == .idle)
    }
}

@Suite("Shadow mode JSONL")
struct ShadowRecordTests {
    func sample(frontApp: String? = "com.anthropic.claudefordesktop") -> ShadowRecord {
        let start = Date(timeIntervalSince1970: 1_794_580_701.512)
        let end = start.addingTimeInterval(21.508)
        return ShadowRecord(
            id: "0b3d2c4e-1111-4222-8333-944455556666",
            startedAt: ShadowRecord.timestamp(start), endedAt: ShadowRecord.timestamp(end),
            durationS: ShadowRecord.roundedSeconds(21.508), gesture: "hold", frontApp: frontApp,
            audio: "audio/2026-11-13/0b3d2c4e-1111-4222-8333-944455556666.wav",
            audioSHA256: String(repeating: "a", count: 64),
            asrModel: "parakeet-ultra@95eaa59a", parakeetRaw: "so um send it \"today\"\nok", asrMs: 310,
            cleanupInput: "So send it \"today\" ok", cleanupEngine: "local:s1-mini",
            cleanupResult: "accepted", cleanupMs: 92, flowCleaned: "So, send it today. OK.",
            languageGuess: "en", flowBuild: "e2470c0406")
    }

    @Test("One line with exactly the schema 1 keys")
    func keys() throws {
        let data = try sample().jsonLine()
        #expect(!data.contains(0x0A))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "schema", "id", "started_at", "ended_at", "duration_s", "gesture", "front_app", "audio",
            "audio_sha256", "sample_rate", "asr_model", "parakeet_raw", "asr_ms", "cleanup_input",
            "cleanup_engine", "cleanup_result", "cleanup_ms", "flow_cleaned", "language_guess", "flow_build",
        ])
        #expect(object["schema"] as? Int == 1)
        #expect(object["sample_rate"] as? Int == 16_000)
        #expect(object["duration_s"] as? Double == 21.51)
        #expect(object["parakeet_raw"] as? String == "so um send it \"today\"\nok")
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"audio\":\"audio/2026-11-13/"))  // slashes unescaped
    }

    @Test("Times are UTC ISO 8601 with milliseconds")
    func times() throws {
        let object = try #require(JSONSerialization.jsonObject(with: sample().jsonLine()) as? [String: Any])
        #expect(object["started_at"] as? String == "2026-11-13T14:38:21.512Z")
        #expect(object["ended_at"] as? String == "2026-11-13T14:38:43.020Z")
    }

    @Test("Unknown front app is written as null")
    func nullFrontApp() throws {
        let object = try #require(JSONSerialization.jsonObject(with: sample(frontApp: nil).jsonLine()) as? [String: Any])
        #expect(object.keys.contains("front_app"))
        #expect(object["front_app"] is NSNull)
    }

    @Test("Round-trips through Codable")
    func roundTrip() throws {
        let record = sample()
        #expect(try JSONDecoder().decode(ShadowRecord.self, from: record.jsonLine()) == record)
    }

    @Test("T2 controls are optional, exact, and separate from S1 metadata")
    func t2ControlReceipt() throws {
        var record = sample()
        record.cleanupEngine = "local:dose1-t2"
        record.cleanupContract = T2CleanupOptions.contract
        record.cleanupControlLine = T2CleanupOptions(level: .medium, styling: .excited).controlLine
        let encoded = try record.jsonLine()
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["cleanup_contract"] as? String == T2CleanupOptions.contract)
        #expect(object["cleanup_control_line"] as? String == record.cleanupControlLine)
        #expect(object["s1_control_line"] == nil)
        #expect(try JSONDecoder().decode(ShadowRecord.self, from: encoded) == record)
        let legacy = try JSONDecoder().decode(ShadowRecord.self, from: sample().jsonLine())
        #expect(legacy.cleanupContract == nil && legacy.cleanupControlLine == nil)
    }

    @Test("Audio path uses the UTC day and lowercase uuid")
    func audioPath() throws {
        let id = try #require(UUID(uuidString: "0B3D2C4E-1111-4222-8333-944455556666"))
        let late = Date(timeIntervalSince1970: 1_794_614_399)  // 2026-11-13T23:59:59Z
        #expect(ShadowStore.relativeAudioPath(id: id, startedAt: late)
                == "audio/2026-11-13/0b3d2c4e-1111-4222-8333-944455556666.wav")
    }
}

@Suite("Shadow mode storage")
struct ShadowStoreTests {
    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shadow-\(UUID().uuidString)", isDirectory: true)
    }

    func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("WAV is 16 kHz mono PCM16")
    func wavHeader() {
        let data = ShadowStore.wavData(samples: [0, 1, -1, 0.5, 2])
        #expect(data.count == 44 + 10)
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        #expect(u16(20) == 1)        // PCM
        #expect(u16(22) == 1)        // mono
        #expect(u32(24) == 16_000)
        #expect(u16(34) == 16)
        #expect(u32(40) == 10)
        #expect(Int16(bitPattern: UInt16(u16(46))) == 32767)
        #expect(Int16(bitPattern: UInt16(u16(48))) == -32767)
        #expect(Int16(bitPattern: UInt16(u16(52))) == 32767)  // clipped
    }

    @Test("Folders are 0700 and files 0600; lines are appended")
    func permissions() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShadowStore(root: root)
        try store.prepare()
        #expect(try mode(root) == 0o700)
        #expect(try mode(store.audioRoot) == 0o700)
        let sha = try store.writeWAV(samples: [0, 0.1], relativePath: "audio/2026-11-13/a.wav")
        #expect(sha.count == 64)
        #expect(try mode(root.appendingPathComponent("audio/2026-11-13/a.wav")) == 0o600)
        #expect(try mode(root.appendingPathComponent("audio/2026-11-13")) == 0o700)
        let record = ShadowRecordTests().sample()
        try store.append(record)
        try store.append(record)
        #expect(try mode(store.jsonlURL) == 0o600)
        let lines = try String(contentsOf: store.jsonlURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
    }

    @Test("Audio over the cap deletes the oldest WAVs first and keeps the JSONL")
    func pruning() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShadowStore(root: root, audioCapBytes: 2_500)
        try store.prepare()
        try store.append(ShadowRecordTests().sample())
        let samples = [Float](repeating: 0.1, count: 478)   // 44 + 956 = 1,000 bytes each
        let names = ["audio/2026-11-11/old.wav", "audio/2026-11-12/mid.wav", "audio/2026-11-13/new.wav"]
        for (index, name) in names.enumerated() {
            try store.writeWAV(samples: samples, relativePath: name)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 * (index + 1)))],
                                                  ofItemAtPath: root.appendingPathComponent(name).path)
        }
        let deleted = store.pruneAudio()
        #expect(deleted.map(\.lastPathComponent) == ["old.wav"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("audio/2026-11-11").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(names[1]).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(names[2]).path))
        #expect(FileManager.default.fileExists(atPath: store.jsonlURL.path))
        #expect(store.pruneAudio().isEmpty)  // already within the cap
    }

    @Test("At most three captures wait; the oldest is dropped")
    func queue() {
        var queue = ShadowWorkQueue<Int>(limit: 3)
        #expect(queue.enqueue(1).isEmpty)
        #expect(queue.enqueue(2).isEmpty)
        #expect(queue.enqueue(3).isEmpty)
        #expect(queue.enqueue(4) == [1])
        #expect(queue.next() == 2)
        #expect(queue.items == [3, 4])
    }
}
