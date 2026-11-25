import SwiftUI
import AVFoundation

/// Full imported history lives separately from VOICE's capped recent list.
struct WisprImportHistoryView: View {
    @State private var entries: [WisprImportService.Entry] = []
    @State private var query = ""
    @State private var error: String?
    @State private var playback = ImportedHistoryPlayback()
    private var filtered: [WisprImportService.Entry] {
        let sorted = entries.sorted { ($0.timestamp ?? "") > ($1.timestamp ?? "") }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { [$0.rawText, $0.formattedText, $0.editedText].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Imported Wispr history").font(.title2.weight(.semibold))
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            if let message = error ?? playback.error { Text(message).foregroundStyle(.secondary) }
            if !entries.isEmpty && filtered.isEmpty { Text("No results.").foregroundStyle(.secondary) }
            if entries.isEmpty && error == nil { Text("No imported history yet.").foregroundStyle(.secondary) }
            List(filtered, id: \.sourceID) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.timestamp ?? "Date unavailable").font(.caption).foregroundStyle(.secondary)
                    if let text = entry.editedText ?? entry.formattedText ?? entry.rawText, !text.isEmpty { Text(text).textSelection(.enabled) }
                    if let formatted = entry.formattedText, let edited = entry.editedText, formatted != edited {
                        DisclosureGroup("Wispr formatted text") { Text(formatted).textSelection(.enabled) }
                    }
                    if let raw = entry.rawText, raw != entry.editedText {
                        DisclosureGroup("Original transcript") { Text(raw).textSelection(.enabled) }
                    }
                    if let path = entry.audioFile {
                        HStack {
                            Button("Play recording", systemImage: "play.fill") { playback.play(path, entryID: entry.sourceID) }
                            if playback.activeID == entry.sourceID {
                                Button("Stop", systemImage: "stop.fill") { playback.stop() }
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }
        }.padding(24).frame(minWidth: 500, minHeight: 400)
        .onAppear { do { entries = try WisprImportService.entries() } catch { self.error = "Could not read imported history: \(error.localizedDescription)" } }
        .onDisappear { playback.stop() }
    }
}

@MainActor @Observable
private final class ImportedHistoryPlayback: NSObject, AVAudioPlayerDelegate {
    var activeID: String?
    var error: String?
    private var player: AVAudioPlayer?
    func stop() { player?.stop(); player = nil; activeID = nil }
    func play(_ path: String, entryID: String) {
        let components = path.split(separator: "/")
        guard components.count == 2, components[0] == "Recordings", !components[1].contains("..") else { error = "Invalid recording path."; return }
        stop()
        do {
            let next = try AVAudioPlayer(contentsOf: WisprImportService.archiveDirectory.appendingPathComponent(path))
            next.delegate = self
            guard next.play() else { error = "Could not start playback."; return }
            player = next; activeID = entryID; error = nil
        } catch { self.error = "Could not play this recording." }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === finished else { return }
            self.player = nil; self.activeID = nil
            if !flag { self.error = "Recording playback stopped." }
        }
    }
}
