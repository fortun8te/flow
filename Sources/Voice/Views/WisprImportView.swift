import SwiftUI

struct WisprImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vocabulary = true
    @State private var history = true
    @State private var preview: WisprImportService.Preview?
    @State private var message: String?
    @State private var importing = false
    var body: some View {
        VStack(spacing: 20) {
            Text("Bring your words and history from Wispr Flow")
                .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text("Your data stays on this Mac.").foregroundStyle(.secondary)
            if let preview {
                Label("Wispr Flow found on this Mac", systemImage: "waveform")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Vocabulary · \(preview.words) words", isOn: $vocabulary).disabled(importing)
                Toggle("History · \(preview.entries) entries, \(preview.recordings) recordings", isOn: $history).disabled(importing)
                Text("History is copied locally and can be opened from Imported Wispr history.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if message == nil { Text("Wispr Flow was not found on this Mac.").foregroundStyle(.secondary) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("Close") { dismiss() }.disabled(importing)
                Button(importing ? "Importing…" : "Import from Wispr Flow") {
                    importing = true
                    let includeVocabulary = vocabulary, includeHistory = history
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let result = try WisprImportService.run(words: includeVocabulary, history: includeHistory)
                            DispatchQueue.main.async {
                                message = "Added \(result.words) new words. Archive contains \(result.entries) history entries; copied \(result.audio) new recordings."; importing = false
                            }
                        } catch {
                            DispatchQueue.main.async { message = "Import could not finish. Some data may already have been copied. \(error.localizedDescription)"; importing = false }
                        }
                    }
                }.disabled(preview == nil || importing || (!vocabulary && !history))
            }
        }.padding(32).frame(width: 530)
        .interactiveDismissDisabled(importing)
        .onAppear {
            guard WisprImportService.isAvailable else { return }
            do { preview = try WisprImportService.preview() }
            catch { message = "Could not read Wispr data: \(error.localizedDescription)" }
        }
    }
}
