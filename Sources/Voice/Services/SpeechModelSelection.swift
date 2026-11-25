import Foundation
import Observation

/// Selection policy only. It neither loads models nor owns capture/decoders.
/// The single runtime owner supplies observed availability and idle state.
@MainActor @Observable
final class SpeechModelSelection {
    static let preferenceKey = "voice.speechModelID"

    enum Availability: Equatable, Sendable {
        case notChecked
        case missing
        /// Required local artifacts were verified by the runtime owner.
        /// This does not imply that a model is loaded or usable by an engine.
        case available
        case unsupported
    }

    enum Status: String, Codable, Sendable {
        case notChecked, missing, unsupported, waitingForIdle, pendingActivation
        case loading, ready, failed
    }

    enum Failure: String, Codable, Sendable {
        case loadingFailed, cancelled
    }

    struct BusyState: Equatable, Sendable {
        var recording = false
        var transcribing = false
        var meeting = false
        var recovery = false
        var isBusy: Bool { recording || transcribing || meeting || recovery }
    }

    struct Activation: Equatable, Sendable {
        let operationID: UUID
        let generation: UInt64
        /// Freeze all source/cache/compute metadata for this operation.
        let model: SpeechModelDescriptor
    }

    enum Completion: Equatable, Sendable {
        case applied, deferredWhileBusy, stale
    }

    enum SelectionError: Error { case unknownModel }

    private(set) var selectedID: SpeechModelID
    private(set) var activeID: SpeechModelID?
    private(set) var generation: UInt64 = 0
    private(set) var availability: [SpeechModelID: Availability] = [:]
    private(set) var busy = BusyState()
    private(set) var inFlight: Activation?
    private(set) var failure: Failure?
    private(set) var hadInvalidSavedSelection: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let homeDirectory: URL

    init(defaults: UserDefaults = .standard,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        let saved = defaults.string(forKey: Self.preferenceKey)
        // With nothing chosen yet, prefer Parakeet Ultra when its verified files are already on disk: on this Mac
        // it decoded the saved English and Dutch clips about three times faster than v3 (12 Nov 2026 benchmark).
        // Nothing is downloaded or loaded here, and an explicit choice always wins.
        let ultra = SpeechModelCatalog.descriptor(for: .parakeetUltra, homeDirectory: homeDirectory)
        let ultraInstalled = FileManager.default.fileExists(atPath: ultra.directory.appendingPathComponent(".voice-model.json").path)
        selectedID = saved.flatMap(SpeechModelID.init(rawValue:)) ?? (ultraInstalled ? .parakeetUltra : SpeechModelCatalog.defaultID)
        hadInvalidSavedSelection = saved != nil && SpeechModelID(rawValue: saved!) == nil
        // No active model is inferred from a saved setting or existing files.
        activeID = nil
    }

    var selectedModel: SpeechModelDescriptor {
        SpeechModelCatalog.descriptor(for: selectedID, homeDirectory: homeDirectory)
    }

    var status: Status {
        if let operation = inFlight, operation.generation == generation, operation.model.id == selectedID {
            return .loading
        }
        if failure != nil { return .failed }
        if activeID == selectedID { return .ready }
        switch availability[selectedID] ?? .notChecked {
        case .notChecked: return .notChecked
        case .missing: return .missing
        case .unsupported: return .unsupported
        case .available: return busy.isBusy || inFlight != nil ? .waitingForIdle : .pendingActivation
        }
    }

    /// Saves intent only. Repeated identical requests coalesce; failed requests
    /// can be deliberately retried without changing their persistent ID.
    @discardableResult
    func requestSelection(rawID: String) throws -> Bool {
        guard let id = SpeechModelID(rawValue: rawID) else { throw SelectionError.unknownModel }
        guard id != selectedID || failure != nil else { return false }
        selectedID = id
        generation &+= 1
        failure = nil
        hadInvalidSavedSelection = false
        defaults.set(id.rawValue, forKey: Self.preferenceKey)
        return true
    }

    func observeAvailability(_ value: Availability, for id: SpeechModelID) {
        availability[id] = value
    }

    func updateBusyState(_ value: BusyState) { busy = value }

    /// Called only after the actual runtime has loaded its startup model.
    func observeActiveModel(_ id: SpeechModelID?) {
        activeID = id
        if id == selectedID { failure = nil }
    }

    /// The runtime owner calls this while idle, prepares the returned frozen
    /// model asynchronously, and then commits through completeActivation.
    func beginActivation() -> Activation? {
        guard !busy.isBusy, inFlight == nil, activeID != selectedID,
              availability[selectedID] == .available, failure == nil else { return nil }
        let operation = Activation(operationID: UUID(), generation: generation, model: selectedModel)
        inFlight = operation
        return operation
    }

    /// Install the prepared engine synchronously in the same MainActor turn as
    /// the final generation/idle checks. A stale candidate never reaches install.
    @discardableResult
    func completeActivation(_ operation: Activation, install: () -> Void) -> Completion {
        completeActivationIfIdle(operation) { install(); return true }
    }

    /// The runtime's decoder lease check and handle swap are atomic. If work
    /// starts outside the UI owner, preserve intent and retry after it drains.
    @discardableResult
    func completeActivationIfIdle(_ operation: Activation, install: () -> Bool) -> Completion {
        guard inFlight?.operationID == operation.operationID else { return .stale }
        inFlight = nil
        guard operation.generation == generation, operation.model.id == selectedID else { return .stale }
        guard !busy.isBusy else { return .deferredWhileBusy }
        guard availability[selectedID] == .available else { return .stale }
        guard install() else { return .deferredWhileBusy }
        activeID = operation.model.id
        failure = nil
        return .applied
    }

    /// A failed or stale attempt never clears the previously working engine.
    func failActivation(_ operation: Activation, reason: Failure) {
        guard inFlight?.operationID == operation.operationID else { return }
        inFlight = nil
        guard operation.generation == generation, operation.model.id == selectedID else { return }
        failure = reason
    }
}
