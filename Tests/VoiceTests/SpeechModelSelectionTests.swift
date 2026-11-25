import Foundation
import Testing
@testable import Voice

@MainActor @Suite("Speech model selection policy")
struct SpeechModelSelectionTests {
    private func withSelection(_ action: (SpeechModelSelection, UserDefaults) throws -> Void) rethrows {
        let suite = "SpeechModelSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try action(SpeechModelSelection(defaults: defaults, homeDirectory: URL(fileURLWithPath: "/test-home")), defaults)
    }

    @Test func savedIntentIsNotReadiness() throws {
        try withSelection { selection, defaults in
            #expect(selection.selectedID == .parakeetV3)
            #expect(selection.activeID == nil)
            #expect(selection.status == .notChecked)
            let changed = try selection.requestSelection(rawID: "parakeet-ultra")
            #expect(changed)
            #expect(defaults.string(forKey: SpeechModelSelection.preferenceKey) == "parakeet-ultra")
            #expect(selection.activeID == nil)
            selection.observeAvailability(.missing, for: .parakeetUltra)
            #expect(selection.status == .missing)
            #expect(selection.beginActivation() == nil)
            selection.observeAvailability(.unsupported, for: .parakeetUltra)
            #expect(selection.status == .unsupported)
            #expect(selection.beginActivation() == nil)
        }
    }

    @Test func everyBusyWorkflowDefersWithoutChangingActiveEngine() throws {
        try withSelection { selection, _ in
            selection.observeActiveModel(.parakeetV3)
            try selection.requestSelection(rawID: "parakeet-ultra")
            selection.observeAvailability(.available, for: .parakeetUltra)
            for busy in [SpeechModelSelection.BusyState(recording: true), .init(transcribing: true), .init(meeting: true), .init(recovery: true)] {
                selection.updateBusyState(busy)
                #expect(selection.status == .waitingForIdle)
                #expect(selection.beginActivation() == nil)
                #expect(selection.activeID == .parakeetV3)
            }
            selection.updateBusyState(.init())
            #expect(selection.status == .pendingActivation)
        }
    }

    @Test func rapidSelectionsRejectStalePreparedModels() throws {
        try withSelection { selection, _ in
            selection.observeActiveModel(.parakeetV3)
            try selection.requestSelection(rawID: "parakeet-ultra")
            selection.observeAvailability(.available, for: .parakeetUltra)
            selection.observeAvailability(.available, for: .phonon2)
            let old = try #require(selection.beginActivation())
            try selection.requestSelection(rawID: "phonon-2")
            #expect(selection.beginActivation() == nil)
            var installed = false
            let discarded = selection.completeActivation(old) { installed = true }
            #expect(discarded == .stale)
            #expect(!installed)
            #expect(selection.activeID == .parakeetV3)
            let newest = try #require(selection.beginActivation())
            #expect(newest.model.id == .phonon2)
            let applied = selection.completeActivation(newest) { installed = true }
            #expect(applied == .applied)
            #expect(installed)
            #expect(selection.activeID == .phonon2)
            #expect(selection.status == .ready)
        }
    }

    @Test func becomingBusyDuringPreparationPreventsInstall() throws {
        try withSelection { selection, _ in
            selection.observeActiveModel(.parakeetV3)
            try selection.requestSelection(rawID: "parakeet-ultra")
            selection.observeAvailability(.available, for: .parakeetUltra)
            let operation = try #require(selection.beginActivation())
            selection.updateBusyState(.init(recording: true))
            var installed = false
            let completion = selection.completeActivation(operation) { installed = true }
            #expect(completion == .deferredWhileBusy)
            #expect(!installed)
            #expect(selection.activeID == .parakeetV3)
            #expect(selection.status == .waitingForIdle)
            selection.updateBusyState(.init())
            #expect(selection.beginActivation() != nil)
        }
    }

    @Test func failedActivationKeepsFallbackAndNeedsExplicitRetry() throws {
        try withSelection { selection, _ in
            selection.observeActiveModel(.parakeetV3)
            try selection.requestSelection(rawID: "parakeet-ultra")
            selection.observeAvailability(.available, for: .parakeetUltra)
            let operation = try #require(selection.beginActivation())
            selection.failActivation(operation, reason: .loadingFailed)
            #expect(selection.activeID == .parakeetV3)
            #expect(selection.status == .failed)
            #expect(selection.beginActivation() == nil)
            let retry = try selection.requestSelection(rawID: "parakeet-ultra")
            #expect(retry)
            #expect(selection.beginActivation() != nil)
        }
    }

    @Test func unknownSelectionDoesNotWritePreferences() throws {
        try withSelection { selection, defaults in
            do {
                try selection.requestSelection(rawID: "arbitrary/repository")
                Issue.record("An unknown model must be refused")
            } catch SpeechModelSelection.SelectionError.unknownModel { }
            #expect(defaults.object(forKey: SpeechModelSelection.preferenceKey) == nil)
            #expect(selection.selectedID == .parakeetV3)
        }
    }

    @Test func staleFailureCannotPoisonNewSelection() throws {
        try withSelection { selection, _ in
            selection.observeActiveModel(.parakeetV3)
            try selection.requestSelection(rawID: "parakeet-ultra")
            selection.observeAvailability(.available, for: .parakeetUltra)
            selection.observeAvailability(.available, for: .phonon2)
            let old = try #require(selection.beginActivation())
            try selection.requestSelection(rawID: "phonon-2")
            selection.failActivation(old, reason: .loadingFailed)
            #expect(selection.failure == nil)
            #expect(selection.activeID == .parakeetV3)
            let latest = try #require(selection.beginActivation())
            #expect(latest.model.id == .phonon2)
        }
    }

    @Test func invalidSavedPreferenceFallsBackWithoutPretendingReady() {
        let suite = "SpeechModelSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unregistered-model", forKey: SpeechModelSelection.preferenceKey)
        // A home without installed candidates: the fallback is then the baseline, whatever this Mac has on disk.
        let selection = SpeechModelSelection(defaults: defaults, homeDirectory: URL(fileURLWithPath: "/test-home"))
        #expect(selection.hadInvalidSavedSelection)
        #expect(selection.selectedID == .parakeetV3)
        #expect(selection.activeID == nil)
        #expect(defaults.string(forKey: SpeechModelSelection.preferenceKey) == "unregistered-model")
    }

    @Test func catalogPinsCandidatesWithoutInventingBaselineRevision() {
        let models = SpeechModelCatalog.models(homeDirectory: URL(fileURLWithPath: "/test-home"))
        #expect(models.count == SpeechModelID.allCases.count)
        #expect(Set(models.map(\.id)).count == models.count)
        #expect(models[0].pinnedRevision == nil)
        #expect(models[0].requiredDownloadBytes == nil)
        #expect(models[0].directory.path == "/test-home/Library/Application Support/FluidAudio/Models/parakeet-v3")
        #expect(models[1].pinnedRevision == "95eaa59a39d4394f047a4dc5cce480388a60d1b6")
        #expect(models[1].requiredDownloadBytes == 632_163_378)
        #expect(!models[1].languages.isEnglishOnly)
        #expect(models[2].languages.isEnglishOnly)
        #expect(models[2].computePolicy == .cpuAndNeuralEngine)
    }
}
