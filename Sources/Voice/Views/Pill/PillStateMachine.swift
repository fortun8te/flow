import Foundation
import CoreGraphics

// MARK: - Pill states
//
// The pill has two layers of state:
//   1. `PillPhase`: what the dictation engine is doing, resolved from `RecordingState` by
//      `PillPhaseResolver`. `PillTransitions` names the spring for every pair of phases.
//   2. Inside `.idle`, `FlowPillMachine` (FlowPillState.swift) handles hover: resting <-> ready.
// `PillLookBuilder` (PillLook.swift) turns both, plus any notice, into the one look on screen.

enum PillPhase: Equatable, CaseIterable {
    /// Resting sliver, or the ready pill under the pointer.
    case idle
    /// The microphone is opening.
    case starting
    /// Push-to-talk: bars follow the voice.
    case recording
    /// Hands-free: cancel, bars, finish.
    case locked
    /// Writing the dictation.
    case transcribing
    /// Opt+1: polishing the selected text.
    case polishingSelection
    /// "Polished": a click shows the changes.
    case polishDone
    /// "Transcript cancelled" with Undo.
    case cancelled
    /// "Pasted" with Undo (off by default).
    case undoPaste

    /// Phases that say something in words.
    var hasWords: Bool {
        switch self {
        case .polishingSelection, .polishDone, .cancelled, .undoPaste, .transcribing, .starting: return true
        case .idle, .recording, .locked: return false
        }
    }

}

/// Which phase to show for the engine's flags.
enum PillPhaseResolver {
    static func phase(isRecording: Bool, isLocked: Bool, pendingStart: Bool,
                      isTranscribing: Bool, isPolishingSelection: Bool,
                      showingCancelled: Bool, showingUndoPaste: Bool,
                      showingPolishDone: Bool = false) -> PillPhase {
        // A latched lock always shows its cancel and finish, even if the engine stopped
        // underneath it, so the user can still get out.
        if isLocked { return .locked }
        if isRecording { return .recording }
        if pendingStart { return .starting }
        if isTranscribing { return .transcribing }
        if isPolishingSelection { return .polishingSelection }
        if showingPolishDone { return .polishDone }
        if showingCancelled { return .cancelled }
        if showingUndoPaste { return .undoPaste }
        return .idle
    }
}

/// How one phase change moves on screen. The skin turns it into an animation.
enum PillMotion: Equatable {
    /// No animation: the hotkey must feel instant.
    case instant
    /// The shape morphs to the next size.
    case morph
    /// A calmer ease back to rest.
    case settle
}

/// Every transition, spelled out.
enum PillTransitions {
    static func motion(from: PillPhase, to: PillPhase) -> PillMotion {
        if from == to { return .instant }
        switch (from, to) {
        // The hotkey: the bar must answer on the very next frame.
        case (.idle, .starting), (.idle, .recording), (.idle, .locked):
            return .instant
        // A new dictation interrupts whatever the pill was saying.
        case (.polishDone, .starting), (.cancelled, .starting), (.undoPaste, .starting),
             (.polishDone, .recording), (.cancelled, .recording), (.undoPaste, .recording),
             (.transcribing, .starting), (.transcribing, .recording):
            return .instant
        case (_, .idle):
            return .settle
        default:
            return .morph
        }
    }
}
