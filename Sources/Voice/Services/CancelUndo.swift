// Flow — what Undo does after a cancelled dictation.
import Foundation

/// A cancelled dictation keeps its audio and whatever text was heard so far. Undo prefers the audio (the
/// partial text is often cut short or empty, which is why Undo used to paste nothing), and falls back to the text.
enum CancelUndoPlan: Equatable {
    case transcribeAudio(URL, fallbackText: String)
    case pasteText(String)
    case nothing

    static func make(text: String, audioURL: URL?, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> CancelUndoPlan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let audioURL, fileExists(audioURL) { return .transcribeAudio(audioURL, fallbackText: trimmed) }
        return trimmed.isEmpty ? .nothing : .pasteText(trimmed)
    }
}
