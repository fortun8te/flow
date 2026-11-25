import AppKit
import Foundation
import GRDB
import Testing
@testable import Voice

@Suite("Flow commands for Companion")
struct FlowCommandContractTests {
    // MARK: Polish levels

    @Test("Option-1, 2 and 3 map to light, medium and heavy")
    func keyCodeToLevel() {
        #expect(PolishLevel(keyCode: 18) == .light)
        // Option-1 is the single Polish key; Option-2 and Option-3 are not intercepted.
        #expect(PolishLevel(keyCode: 19) == nil)
        #expect(PolishLevel(keyCode: 20) == nil)
        #expect(PolishLevel(keyCode: 21) == nil)
        #expect(PolishLevel(keyCode: 9) == nil)
        #expect(PolishLevel(keyCode: PolishLevel.light.keyCode) == .light)
    }

    @Test("Each level rides one existing preset")
    func levelToPreset() {
        #expect(PolishLevel.light.preset == PolishPreset.fix.rawValue)
        #expect(PolishLevel.medium.preset == PolishPreset.smooth.rawValue)
        #expect(PolishLevel.heavy.preset == PolishPreset.elevate.rawValue)
        #expect(PolishLevel(rawValue: "high") == nil)
    }

    @Test("The three levels give three different instructions")
    func levelToInstruction() {
        let light = Qwen3Polisher.buildPolishInPlacePrompt(preset: PolishLevel.light.preset, instructions: nil, level: .light)
        let medium = Qwen3Polisher.buildPolishInPlacePrompt(preset: PolishLevel.medium.preset, instructions: nil, level: .medium)
        let heavy = Qwen3Polisher.buildPolishInPlacePrompt(preset: PolishLevel.heavy.preset, instructions: nil, level: .heavy)
        #expect(Set([light, medium, heavy]).count == 3)

        // Opt+1 is reconstruction-capable for typed text: it repairs typos but keeps every fact.
        #expect(light.contains("Repair typos") && light.contains("punctuation"))
        #expect(light.contains("Keep every fact, number, name and negation"))
        #expect(light.contains("Do not copy the text back unchanged"))

        #expect(medium.contains("fix grammar") && medium.contains("remove filler"))
        #expect(medium.contains("Keep the meaning and the tone"))
        #expect(!medium.contains("Keep every word"))

        #expect(heavy.contains("Rewrite for clarity and flow"))
        #expect(heavy.contains("same meaning") && heavy.contains("same language"))

        // The shared safety wording stays on every level.
        for prompt in [light, medium, heavy] {
            #expect(prompt.contains("Return only the edited text"))
            #expect(prompt.contains("negations, names"))
        }
    }

    @Test("A chosen level wins over imported style choices; no level keeps the old behaviour")
    func levelPrecedence() {
        let data = Data(#"{"schema_version":1,"polish_instructions":{"default":{"Make more concise":true,"Reword for clarity":true,"Reorder for readability":false,"Add structure for readability":false}}}"#.utf8)
        let profile = WisprPersonalizationProfile.decode(data)!
        let chosen = Qwen3Polisher.buildPolishInPlacePrompt(preset: "fix", instructions: profile.instructions, level: .light)
        #expect(chosen.contains("Keep every fact"))
        #expect(!chosen.contains("Make the text more concise"))
        let saved = Qwen3Polisher.buildPolishInPlacePrompt(preset: "fix", instructions: nil)
        #expect(saved.contains(Qwen3Polisher.polishPresetInstruction("fix")))
    }

    @Test("A polish key that is also a recording shortcut is left alone")
    func polishKeyConflicts() {
        let option = NSEvent.ModifierFlags.option.rawValue
        let command = NSEvent.ModifierFlags.command.rawValue
        #expect(HotkeyService.polishKeysInConflict(with: []).isEmpty)
        #expect(HotkeyService.polishKeysInConflict(with: [CapturedHotkey(keyCode: 18, modifiersRaw: option)]) == [18])
        // Left/right device bits on the same Option key still count.
        #expect(HotkeyService.polishKeysInConflict(with: [CapturedHotkey(keyCode: 18, modifiersRaw: option | 0x20)]) == [18])
        // Option-2 and Option-3 are no longer polish keys, so they never clash.
        #expect(HotkeyService.polishKeysInConflict(with: [CapturedHotkey(keyCode: 19, modifiersRaw: option)]).isEmpty)
        #expect(HotkeyService.polishKeysInConflict(with: [CapturedHotkey(keyCode: 18, modifiersRaw: option | command)]).isEmpty)
        #expect(HotkeyService.polishKeysInConflict(with: [CapturedHotkey(keyCode: 49, modifiersRaw: option)]).isEmpty)
        #expect(HotkeyService.polishKeysInConflict(with: [CapturedHotkey(keyCode: nil, modifiersRaw: option)]).isEmpty)
    }

    // MARK: Commands

    @Test("Commands are read from string fields only")
    func parsing() {
        let id = UUID().uuidString
        let request = FlowCommandRequest.parse(["cmd": "retry_dictation", "id": id, "nonce": "n1"])
        #expect(request?.command == .retryDictation)
        #expect(request?.id == id)
        #expect(request?.nonce == "n1")
        #expect(request?.rejection == nil)

        #expect(FlowCommandRequest.parse(nil) == nil)
        #expect(FlowCommandRequest.parse(["cmd": 7]) == nil)
        #expect(FlowCommandRequest.parse(["cmd": String(repeating: "x", count: 300)]) == nil)

        let unknown = FlowCommandRequest.parse(["cmd": "format_disk", "nonce": "n2"])
        #expect(unknown?.command == nil)
        #expect(unknown?.rejection?.ok == false)
        #expect(unknown?.rejection?.userInfo(for: unknown!) == ["nonce": "n2", "cmd": "format_disk", "ok": "0", "message": "Unknown command"])

        #expect(FlowCommandRequest.parse(["cmd": "delete_meeting", "id": "not-a-uuid"])?.rejection?.ok == false)
        #expect(FlowCommandRequest.parse(["cmd": "delete_meeting"])?.rejection?.ok == false)
        #expect(FlowCommandRequest.parse(["cmd": "select_speech_model"])?.rejection?.ok == false)
        #expect(FlowCommandRequest.parse(["cmd": "select_speech_model", "value": "parakeet-v3"])?.rejection == nil)
        #expect(FlowCommandRequest.parse(["cmd": "import_meeting_audio"])?.rejection == nil)
        #expect(FlowCommandRequest.parse(["cmd": "import_meeting_audio", "value": "/tmp/example.wav"])?.rejection?.ok == false)
        #expect(FlowCommandRequest.parse(["cmd": "import_meeting_audio", "id": UUID().uuidString])?.rejection?.ok == false)
        #expect(FlowCommandRequest.parse(["cmd": "ping"])?.nonce == "")
    }

    @Test("Every command in the contract has a name")
    func commandNames() {
        let names = Set(FlowCommand.allCases.map(\.rawValue))
        #expect(names == ["start_meeting", "stop_meeting", "import_meeting_audio", "retranscribe_meeting", "delete_meeting",
                          "retry_dictation", "delete_dictation", "cancel", "toggle_handsfree",
                          "rebind_hotkeys", "reconcile_settings", "select_speech_model", "ping"])
        #expect(FlowIPC.command.rawValue == "com.example.flow.command")
        #expect(FlowIPC.result.rawValue == "com.example.flow.result")
        #expect(FlowIPC.state.rawValue == "com.example.flow.state")
        #expect(FlowIPC.changed.rawValue == "com.example.flow.changed")
        #expect(FlowIPC.openCompanion.rawValue == "com.example.flow.pure.open")
    }

    // MARK: State

    @Test("Phase names and the state message")
    func state() {
        func phase(_ pending: Bool, _ recording: Bool, _ locked: Bool, _ processing: Bool, _ meeting: Bool) -> String {
            FlowStateSnapshot.phase(pendingStart: pending, recording: recording, locked: locked, processing: processing, meeting: meeting)
        }
        #expect(phase(false, false, false, false, false) == "idle")
        #expect(phase(true, false, false, false, false) == "starting")
        #expect(phase(true, true, false, false, false) == "recording")
        #expect(phase(false, true, true, false, false) == "handsfree")
        #expect(phase(false, false, false, true, false) == "processing")
        #expect(phase(false, false, false, false, true) == "meeting")
        // A dictation inside a meeting shows as the dictation.
        #expect(phase(false, true, false, false, true) == "recording")

        let id = UUID().uuidString
        let snapshot = FlowStateSnapshot(phase: "meeting", meetingActive: true, meetingId: id, elapsed: 65, micName: "MacBook Pro Microphone")
        #expect(snapshot.userInfo == ["version": "1", "phase": "meeting", "meetingActive": "1",
                                      "meetingId": id, "elapsed": "65", "micName": "MacBook Pro Microphone",
                                      "meetingCaptureStatus": "idle", "meetingCaptureProblem": ""])
        var later = snapshot; later.elapsed = 70
        #expect(later.withoutClock == snapshot.withoutClock)
        #expect(FlowStateSnapshot.off.userInfo["phase"] == "off")
        later.meetingCaptureStatus = "failed"
        later.meetingCaptureProblem = "Could not open the input."
        #expect(later.withoutClock != snapshot.withoutClock)
        #expect(later.userInfo["meetingCaptureProblem"] == "Could not open the input.")
        later.dictationAvailability = "ready"
        later.activeSpeechModel = "fluid-speech-pro"
        later.speechModelStatus = "ready"
        #expect(later.userInfo["dictationAvailability"] == "ready")
        #expect(later.userInfo["activeSpeechModel"] == "fluid-speech-pro")
        #expect(later.userInfo["speechModelStatus"] == "ready")
    }

    // MARK: Storage

    private func temporaryStorage() throws -> (StorageService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = StorageService(directory: root)
        try storage.initialize()
        return (storage, root)
    }

    @Test("The cleaned text is stored beside the heard text and survives a later save")
    func finalTextColumn() throws {
        let (storage, root) = try temporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let heard = TranscriptSegment(speaker: "You", text: "um so send it tomorrow", startTime: 0, endTime: 2)
        try storage.saveMeeting(Meeting(id: id, title: "Note", duration: 2, segments: [heard], kind: .dictation))
        #expect(try storage.fetchMeeting(id: id)?.finalText == nil)

        #expect(try storage.setFinalText(meetingId: id, text: "Send it tomorrow."))
        #expect(try storage.fetchMeeting(id: id)?.finalText == "Send it tomorrow.")
        #expect(try storage.meetingsByKind(.dictation).first?.finalText == "Send it tomorrow.")

        // A save that does not know the cleaned text must not erase it.
        try storage.saveMeeting(Meeting(id: id, title: "Renamed", duration: 2, segments: [heard], kind: .dictation))
        let stored = try #require(try storage.fetchMeeting(id: id))
        #expect(stored.title == "Renamed")
        #expect(stored.finalText == "Send it tomorrow.")

        // Meetings and unknown ids are left alone.
        let meetingID = UUID()
        try storage.saveMeeting(Meeting(id: meetingID, title: "Call", kind: .meeting))
        #expect(try !storage.setFinalText(meetingId: meetingID, text: "x"))
        #expect(try storage.fetchMeeting(id: meetingID)?.finalText == nil)
        #expect(try !storage.setFinalText(meetingId: UUID(), text: "x"))
        #expect(try storage.fetchMeeting(id: UUID()) == nil)
    }

    @Test("An older database gains the column without losing rows")
    func finalTextMigration() throws {
        let (first, root) = try temporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        var legacy: StorageService? = first
        let id = UUID()
        try legacy?.saveMeeting(Meeting(id: id, title: "Before", kind: .dictation))
        legacy = nil

        // Put a temporary store back to the version before this column.
        var setup: DatabaseQueue? = try DatabaseQueue(path: root.appendingPathComponent("voice.db").path)
        try setup?.write { db in
            try db.execute(sql: "ALTER TABLE meetings DROP COLUMN finalText")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: ["v8_meeting_final_text"])
        }
        setup = nil

        let upgraded = StorageService(directory: root)
        try upgraded.initialize()
        let row = try #require(try upgraded.fetchMeeting(id: id))
        #expect(row.title == "Before")
        #expect(row.finalText == nil)
        #expect(try upgraded.setFinalText(meetingId: id, text: "After"))
        #expect(try upgraded.fetchMeeting(id: id)?.finalText == "After")
    }

    @Test("A retry replaces the heard and cleaned text together and reports the change")
    func replaceTranscript() throws {
        let (storage, root) = try temporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let changes = ChangeLog()
        storage.onChange = { changes.add($0) }

        let id = UUID()
        let old = [TranscriptSegment(speaker: "You", text: "old one", startTime: 0, endTime: 1),
                   TranscriptSegment(speaker: "You", text: "old two", startTime: 1, endTime: 2)]
        let audioPath = storage.audioDirectoryURL.appendingPathComponent("dictation-\(id.uuidString).caf").path
        try Data([0]).write(to: URL(fileURLWithPath: audioPath))
        try storage.saveMeeting(Meeting(id: id, title: "Note", segments: old, audioFilePath: audioPath, kind: .dictation))
        let fresh = [TranscriptSegment(speaker: "You", text: "new words", startTime: 0, endTime: 2)]
        #expect(try storage.replaceDictationTranscript(id: id, segments: fresh, finalText: "New words."))

        let row = try #require(try storage.fetchMeeting(id: id))
        #expect(row.segments.map(\.text) == ["new words"])
        #expect(row.finalText == "New words.")
        #expect(row.title == "Note")
        #expect(row.audioFilePath == audioPath)
        #expect(try storage.searchTranscripts(query: "old", limit: 5).isEmpty)
        #expect(try storage.searchTranscripts(query: "new", limit: 5).count == 1)
        #expect(try !storage.replaceDictationTranscript(id: UUID(), segments: fresh, finalText: "x"))

        // Deleting the row also removes its audio.
        try storage.deleteMeeting(id: id)
        #expect(try storage.fetchMeeting(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: audioPath))
        #expect(changes.all == [.dictation, .dictation, .dictation])
    }

    @Test("A retry without saved audio says so")
    @MainActor func retryWithoutAudio() throws {
        let (storage, root) = try temporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = UUID(), noPath = UUID(), meeting = UUID(), present = UUID()
        let audio = root.appendingPathComponent("kept.caf")
        try Data([0]).write(to: audio)
        try storage.saveMeeting(Meeting(id: missing, audioFilePath: root.appendingPathComponent("gone.caf").path, kind: .dictation))
        try storage.saveMeeting(Meeting(id: noPath, kind: .dictation))
        try storage.saveMeeting(Meeting(id: meeting, audioFilePath: audio.path, kind: .meeting))
        try storage.saveMeeting(Meeting(id: present, audioFilePath: audio.path, kind: .dictation))

        #expect(DictationRetryService.audioURL(for: missing, storage: storage) == .failure(.audioMissing))
        #expect(DictationRetryService.audioURL(for: noPath, storage: storage) == .failure(.audioMissing))
        #expect(DictationRetryService.Failure.audioMissing.message == "Audio is no longer saved")
        #expect(DictationRetryService.audioURL(for: meeting, storage: storage) == .failure(.notADictation))
        #expect(DictationRetryService.audioURL(for: UUID(), storage: storage) == .failure(.notFound))
        #expect(DictationRetryService.audioURL(for: present, storage: storage) == .success(audio))
    }
}

private final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [MeetingKind] = []
    func add(_ kind: MeetingKind) { lock.lock(); kinds.append(kind); lock.unlock() }
    var all: [MeetingKind] { lock.lock(); defer { lock.unlock() }; return kinds }
}
