// Flow — remote control for Companion
// ============================================================
// Companion (the companion app) drives Flow and follows what it is doing through
// distributed notifications. The message contract follows.
//
//   in   com.example.flow.command   {cmd, id?, value?, nonce}
//   out  com.example.flow.result    {nonce, cmd, ok, message}
//   out  com.example.flow.state     {version, phase, meetingActive, meetingId, elapsed, micName}
//   out  com.example.flow.changed   {what}
//   out  com.example.flow.pure.open      {page, section}
//
// SECURITY: these are unauthenticated local messages. Any process running as
// the same user can send a command or fake a state. Nothing here carries
// transcript text, and no command pastes, types or reads the screen. Every
// command runs the same code path as the matching button or key in Flow.
//
// Every userInfo value is a String: distributed notifications only carry
// property-list values, and strings keep both ends simple.
// ============================================================

import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import Foundation

// MARK: - Names

enum FlowIPC {
    static let command = Notification.Name("com.example.flow.command")
    static let result = Notification.Name("com.example.flow.result")
    static let state = Notification.Name("com.example.flow.state")
    static let changed = Notification.Name("com.example.flow.changed")
    static let openCompanion = Notification.Name("com.example.flow.pure.open")
    static let stateVersion = "1"
    /// Longest accepted value for any incoming field. Longer input is dropped.
    static let maxFieldLength = 256
}

// MARK: - Commands

enum FlowCommand: String, CaseIterable, Sendable {
    case startMeeting = "start_meeting"
    case stopMeeting = "stop_meeting"
    case importMeetingAudio = "import_meeting_audio"
    case retranscribeMeeting = "retranscribe_meeting"
    case deleteMeeting = "delete_meeting"
    case retryDictation = "retry_dictation"
    case deleteDictation = "delete_dictation"
    case cancel
    case toggleHandsfree = "toggle_handsfree"
    case rebindHotkeys = "rebind_hotkeys"
    case reconcileSettings = "reconcile_settings"
    case selectSpeechModel = "select_speech_model"
    case ping

    /// Commands that act on one saved row and need its id.
    var needsID: Bool {
        switch self {
        case .retranscribeMeeting, .deleteMeeting, .retryDictation, .deleteDictation: return true
        default: return false
        }
    }

    var needsValue: Bool { self == .selectSpeechModel }
}

/// What came in, reduced to strings. `command` is nil for an unknown name.
struct FlowCommandRequest: Equatable, Sendable {
    let name: String
    let command: FlowCommand?
    let id: String?
    let value: String?
    let nonce: String

    /// Reads only string values and ignores everything else. Returns nil when
    /// there is no usable `cmd`, because then there is nothing to answer.
    static func parse(_ userInfo: [AnyHashable: Any]?) -> FlowCommandRequest? {
        func field(_ key: String) -> String? {
            guard let raw = userInfo?[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= FlowIPC.maxFieldLength else { return nil }
            return trimmed
        }
        guard let name = field("cmd") else { return nil }
        return FlowCommandRequest(name: name, command: FlowCommand(rawValue: name),
                                  id: field("id"), value: field("value"), nonce: field("nonce") ?? "")
    }

    /// Checks done before Flow is asked to act. Nil means the request is well formed.
    var rejection: FlowCommandReply? {
        guard let command else { return .failed("Unknown command") }
        if command == .importMeetingAudio, id != nil || value != nil { return .failed("Choose the audio file in Flow") }
        if command.needsID, id.flatMap(UUID.init(uuidString:)) == nil { return .failed("A valid id is required") }
        if command.needsValue, value == nil { return .failed("A value is required") }
        return nil
    }
}

struct FlowCommandReply: Equatable, Sendable {
    let ok: Bool
    let message: String
    static func done(_ message: String = "OK") -> Self { .init(ok: true, message: message) }
    static func failed(_ message: String) -> Self { .init(ok: false, message: message) }

    func userInfo(for request: FlowCommandRequest) -> [String: String] {
        ["nonce": request.nonce, "cmd": request.name, "ok": ok ? "1" : "0", "message": message]
    }
}

// MARK: - State

/// One status message. `elapsed` is the meeting's seconds while a meeting is
/// recording, otherwise the current dictation's seconds, otherwise 0.
struct FlowStateSnapshot: Equatable, Sendable {
    var phase: String
    var meetingActive: Bool
    var meetingId: String
    var elapsed: Int
    var micName: String
    var meetingCaptureStatus: String = "idle"
    var meetingCaptureProblem: String = ""
    var dictationAvailability: String? = nil
    var activeSpeechModel: String? = nil
    var speechModelStatus: String? = nil

    var userInfo: [String: String] {
        var info = ["version": FlowIPC.stateVersion, "phase": phase, "meetingActive": meetingActive ? "1" : "0",
         "meetingId": meetingId, "elapsed": String(max(0, elapsed)), "micName": micName,
         "meetingCaptureStatus": meetingCaptureStatus, "meetingCaptureProblem": meetingCaptureProblem]
        info["dictationAvailability"] = dictationAvailability
        info["activeSpeechModel"] = activeSpeechModel
        info["speechModelStatus"] = speechModelStatus
        return info
    }

    /// Same snapshot without the clock, used to tell a real change from a tick.
    var withoutClock: FlowStateSnapshot { var copy = self; copy.elapsed = 0; return copy }

    static let off = FlowStateSnapshot(phase: "off", meetingActive: false, meetingId: "", elapsed: 0, micName: "")

    /// idle | starting | recording | handsfree | processing | meeting.
    /// A dictation wins over a meeting, because the two can run together;
    /// `meetingActive` says separately whether a meeting is being recorded.
    static func phase(pendingStart: Bool, recording: Bool, locked: Bool,
                      processing: Bool, meeting: Bool) -> String {
        if pendingStart && !recording { return "starting" }
        if recording { return locked ? "handsfree" : "recording" }
        if processing { return "processing" }
        if meeting { return "meeting" }
        return "idle"
    }
}

// MARK: - Sending

/// The outgoing side. Safe to call from any thread. Nothing is sent until the
/// running app turns it on, so tests and command-line tools stay silent.
enum FlowBroadcast {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live = false
    nonisolated(unsafe) private static var pendingChanges: Set<String> = []

    static func setLive(_ value: Bool) {
        lock.lock(); live = value; if !value { pendingChanges.removeAll() }; lock.unlock()
    }

    static var isLive: Bool { lock.lock(); defer { lock.unlock() }; return live }

    static func post(_ name: Notification.Name, _ userInfo: [String: String]) {
        guard isLive else { return }
        send(name, userInfo)
    }

    /// "dictations", "meetings" or "dictionary" changed. A burst (an import of
    /// many rows, a save followed by its cleaned text) becomes one message.
    static func changed(_ what: String) {
        lock.lock()
        guard live else { lock.unlock(); return }
        let first = pendingChanges.insert(what).inserted
        lock.unlock()
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            lock.lock()
            let stillWanted = live && pendingChanges.remove(what) != nil
            lock.unlock()
            if stillWanted { send(FlowIPC.changed, ["what": what]) }
        }
    }

    /// Ask Companion to show its Voice tab. Sent whether or not the rest is live:
    /// it is a request to Companion, not a report about Flow.
    static func openCompanion(section: String) {
        send(FlowIPC.openCompanion, ["page": "voice", "section": section == "meetings" ? "meetings" : "dictations"])
    }

    private static func send(_ name: Notification.Name, _ userInfo: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: userInfo, deliverImmediately: true)
    }
}

// MARK: - Host

/// What the listener needs from the app. AppDelegate implements it in VoiceApp.swift.
@MainActor
protocol FlowCommandHost: AnyObject {
    var recordingState: RecordingState { get }
    var coordinator: RecordingCoordinator { get }
    /// Run one well-formed command through the app's existing path.
    func flowPerform(_ command: FlowCommand, id: UUID?, value: String?) async -> FlowCommandReply
}

// MARK: - Listener

@MainActor
final class FlowCommandListener: NSObject {
    static let shared = FlowCommandListener()

    private weak var host: FlowCommandHost?
    private var started = false
    private var lastSent: FlowStateSnapshot?
    private var micName = ""
    private var meetingTicker: Task<Void, Never>?
    private var micObserver: NSObjectProtocol?

    /// Start once at launch. Sends the first state straight away.
    func start(host: FlowCommandHost) {
        guard !started else { return }
        started = true
        self.host = host
        FlowBroadcast.setLive(true)
        host.coordinator.storage.onChange = { kind in
            FlowBroadcast.changed(kind == .dictation ? "dictations" : "meetings")
        }
        // deliverImmediately: Flow is a background app, and the default would
        // hold commands until it is next brought to the front.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: FlowIPC.command, object: nil,
            suspensionBehavior: .deliverImmediately)
        micObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("flow.micSwitched"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMicName() }
        }
        observeState()
        emitState(force: true)
        refreshMicName()
    }

    /// Called on quit: says "off" and stops listening.
    func stop() {
        guard started else { return }
        started = false
        meetingTicker?.cancel(); meetingTicker = nil
        DistributedNotificationCenter.default().removeObserver(self)
        if let micObserver { NotificationCenter.default.removeObserver(micObserver) }
        micObserver = nil
        host?.coordinator.storage.onChange = nil
        FlowBroadcast.post(FlowIPC.state, FlowStateSnapshot.off.userInfo)
        FlowBroadcast.setLive(false)
        host = nil
    }

    // MARK: Commands

    @objc nonisolated private func received(_ note: Notification) {
        // Reduce to plain strings before leaving this thread.
        guard let request = FlowCommandRequest.parse(note.userInfo) else { return }
        Task { @MainActor in await self.handle(request) }
    }

    private func handle(_ request: FlowCommandRequest) async {
        guard started, let host else { return }
        let reply: FlowCommandReply
        if let rejection = request.rejection {
            reply = rejection
        } else if let command = request.command {
            reply = await host.flowPerform(command, id: request.id.flatMap(UUID.init(uuidString:)), value: request.value)
        } else {
            reply = .failed("Unknown command")
        }
        print("[FLOW-CMD] \(request.name) ok=\(reply.ok) \(reply.message)")
        FlowBroadcast.post(FlowIPC.result, reply.userInfo(for: request))
        if request.command == .ping {
            emitState(force: true)
            refreshMicName()
        }
    }

    // MARK: State

    private func snapshot() -> FlowStateSnapshot? {
        guard let host else { return nil }
        let state = host.recordingState
        let transcription = host.coordinator.transcription
        let model = host.coordinator.speechModels
        let availability: String
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            availability = "microphone"
        } else if !AXIsProcessTrusted() {
            availability = "accessibility"
        } else if transcription.isReady {
            availability = "ready"
        } else {
            switch transcription.modelState {
            case .error, .notDownloaded:
                availability = host.coordinator.isPreparingServices ? "loadingSpeech" : "speechUnavailable"
            case .downloading, .loading, .ready:
                availability = "loadingSpeech"
            }
        }
        let meeting = state.isCapturingMeeting && state.meetingCaptureStatus == "recording"
        return FlowStateSnapshot(
            phase: FlowStateSnapshot.phase(
                pendingStart: state.pendingRecordingStart, recording: state.isRecording, locked: state.isLocked,
                processing: state.isTranscribing || state.isPolishingSelection, meeting: meeting),
            meetingActive: meeting,
            meetingId: meeting ? (state.activeMeetingId?.uuidString ?? "") : "",
            elapsed: meeting ? state.meetingDurationSeconds : (state.isRecording ? state.elapsedSeconds : 0),
            micName: micName,
            meetingCaptureStatus: state.meetingCaptureStatus,
            meetingCaptureProblem: state.meetingCaptureProblem ?? "",
            dictationAvailability: availability,
            activeSpeechModel: model.activeID?.rawValue ?? "",
            speechModelStatus: model.status.rawValue)
    }

    /// Sends the state. Without `force` it is sent only when something other
    /// than the clock changed.
    func emitState(force: Bool) {
        guard started, let now = snapshot() else { return }
        if !force, lastSent?.withoutClock == now.withoutClock { return }
        lastSent = now
        FlowBroadcast.post(FlowIPC.state, now.userInfo)
        updateMeetingTicker(active: now.meetingActive)
    }

    /// Re-arms after every change; Observation fires once per registration.
    private func observeState() {
        guard started, let host else { return }
        let state = host.recordingState
        withObservationTracking {
            _ = host.coordinator.isPreparingServices
            _ = host.coordinator.transcription.isReady
            _ = host.coordinator.transcription.modelState
            _ = host.coordinator.speechModels.activeID
            _ = host.coordinator.speechModels.status
            _ = PermissionsService.shared.accessibility
            _ = PermissionsService.shared.microphone
            _ = state.pendingRecordingStart
            _ = state.isRecording
            _ = state.isLocked
            _ = state.transcribingCount
            _ = state.isPolishingSelection
            _ = state.isCapturingMeeting
            _ = state.activeMeetingId
            _ = state.meetingCaptureStatus
            _ = state.meetingCaptureProblem
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeState()
                self?.emitState(force: false)
            }
        }
    }

    /// Every 5 s while a meeting is recording, so Companion's clock stays right.
    private func updateMeetingTicker(active: Bool) {
        if !active {
            meetingTicker?.cancel(); meetingTicker = nil
            return
        }
        guard meetingTicker == nil else { return }
        meetingTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.host?.recordingState.isCapturingMeeting == true else { return }
                self.emitState(force: true)
            }
        }
    }

    // MARK: Microphone name

    /// Looked up off the main thread: the audio system can be slow to answer
    /// while a recording is starting. A new name is sent as its own state.
    private func refreshMicName() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let name = Self.currentMicName()
            Task { @MainActor [weak self] in
                guard let self, self.started, self.micName != name else { return }
                self.micName = name
                self.emitState(force: true)
            }
        }
    }

    /// The microphone Flow would record from: the chosen one when it is
    /// plugged in, otherwise the system's input. Empty when there is none.
    nonisolated private static func currentMicName() -> String {
        let inputs = MicrophonePreference.inputs()
        if let uid = UserDefaults.standard.string(forKey: MicrophonePreference.key), !uid.isEmpty,
           let chosen = inputs.first(where: { $0.uid == uid }) {
            return chosen.name
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return "" }
        return inputs.first(where: { $0.deviceID == device })?.name ?? ""
    }
}
