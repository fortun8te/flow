import Foundation
import Testing
@testable import Voice

@Suite("Dictation and polish never run together (sol/01 finding 2)")
struct OperationAdmissionTests {
    @Test("A polish is admitted only when nothing is dictating or polishing")
    func polishAdmittedWhenIdle() {
        #expect(OperationAdmission.forPolish(isRecording: false, pendingStart: false, isTranscribing: false, isPolishing: false) == .admitted)
    }

    @Test("A polish is refused while recording, starting or transcribing")
    func polishRefusedDuringDictation() {
        #expect(OperationAdmission.forPolish(isRecording: true, pendingStart: false, isTranscribing: false, isPolishing: false) == .refusedBecauseDictating)
        #expect(OperationAdmission.forPolish(isRecording: false, pendingStart: true, isTranscribing: false, isPolishing: false) == .refusedBecauseDictating)
        #expect(OperationAdmission.forPolish(isRecording: false, pendingStart: false, isTranscribing: true, isPolishing: false) == .refusedBecauseDictating)
    }

    @Test("A second polish is refused while one runs")
    func overlappingPolishRefused() {
        #expect(OperationAdmission.forPolish(isRecording: false, pendingStart: false, isTranscribing: false, isPolishing: true) == .refusedBecauseAlreadyPolishing)
    }

    @Test("A dictation is refused while a polish runs, and admitted otherwise")
    func dictationWaitsForPolish() {
        #expect(OperationAdmission.forDictation(isPolishing: true) == .refusedBecausePolishing)
        #expect(OperationAdmission.forDictation(isPolishing: false) == .admitted)
    }

    @Test("Every refusal has a short plain notice that says Flow's word, and admission has none")
    func noticesArePlain() {
        #expect(OperationAdmission.notice(for: .admitted) == nil)
        for verdict in [OperationAdmission.Verdict.refusedBecausePolishing, .refusedBecauseDictating, .refusedBecauseAlreadyPolishing] {
            let text = OperationAdmission.notice(for: verdict) ?? ""
            #expect(!text.isEmpty)
            #expect(text.count <= 70)
            #expect(!text.contains("VOICE"))
        }
    }
}

@Suite("A cancelled polish cannot touch a newer one (sol/01 finding 1)")
struct OperationGateTests {
    @Test("A new operation makes the old one stale")
    func newOperationSupersedesOld() {
        var gate = OperationGate()
        let first = gate.begin()
        let second = gate.begin()
        #expect(!gate.isCurrent(first))
        #expect(gate.isCurrent(second))
    }

    @Test("An old operation ending does not clear the newer one")
    func oldEndDoesNotClearNew() {
        var gate = OperationGate()
        let first = gate.begin()
        let second = gate.begin()
        let endedOld = gate.end(first)
        #expect(endedOld == false)
        #expect(gate.isCurrent(second))
    }

    @Test("After cancel, a restarted polish is admitted and can finish")
    func cancelThenRestart() {
        var gate = OperationGate()
        let cancelled = gate.begin()
        gate.cancel()
        #expect(!gate.isCurrent(cancelled))
        let restarted = gate.begin()
        #expect(gate.isCurrent(restarted))
        let endedRestarted = gate.end(restarted)
        #expect(endedRestarted)
        #expect(gate.current == nil)
    }
}

/// Exercise the same token retained by the delayed delivery closure.
@Suite("Overlapping dictation cancellation")
struct DictationWorkRegistryTests {
    @MainActor @Test func cancelledTokenDoesNotReviveWhenAnotherRecordingStarts() {
        let registry = DictationWorkRegistry()
        let first = registry.begin(UUID())
        let second = registry.begin(UUID())
        #expect(registry.activeCount == 2)
        #expect(registry.cancelLatest(preferred: first.session) === first)
        let third = registry.begin(UUID())
        #expect(!first.mayDeliver)
        #expect(second.mayDeliver && third.mayDeliver)
        #expect(registry.activeCount == 2)
        registry.finish(first)
        registry.finish(first)
        #expect(registry.activeCount == 2)
        #expect(!first.mayDeliver)
    }

    @MainActor @Test func cancellationFallsBackToNewestOutstandingAndExpiryIsLocal() {
        let registry = DictationWorkRegistry()
        let first = registry.begin(UUID())
        let second = registry.begin(UUID())
        #expect(registry.cancelLatest(preferred: UUID()) === second)
        #expect(first.mayDeliver && !second.mayDeliver)
        first.expireDelivery()
        #expect(!first.mayDeliver)
        let next = registry.begin(UUID())
        #expect(next.mayDeliver)
        registry.cancelAll()
        #expect(registry.activeCount == 0)
        #expect(!next.mayDeliver)
    }
}
