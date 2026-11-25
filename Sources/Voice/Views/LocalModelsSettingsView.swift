import SwiftUI

/// These controls use the existing owner. Merely opening them does not load a model.
struct LocalModelsSettingsView: View {
    let coordinator: RecordingCoordinator
    @AppStorage("voice.cleanupModel") private var cleanupModel = "s1-mini"
    @State private var s1Available = false
    @AppStorage(HotkeyService.quickPolishEnabledKey) private var quickPolishEnabled = false
    @AppStorage(DraftDecisionGate.preference) private var draftDecisionEnabled = true
    @AppStorage(Opt1EvidenceLog.preference) private var saveOpt1Examples = true
    @AppStorage("voice.t2CleanupStructure.v3") private var t2Structure = "lists"
    @State private var polishOptions = T2PolishOptions.load(instructions: WisprPersonalizationProfile.load()?.instructions)

    var body: some View {
        let selection = coordinator.speechModels
        VStack(alignment: .leading, spacing: 10) {
            Picker("Speech recognition", selection: Binding(
                get: { selection.selectedID.rawValue },
                set: { coordinator.requestSpeechModelSelection($0) }
            )) {
                ForEach(SpeechModelCatalog.models()) { model in
                    Text(model.name + (model.languages.isEnglishOnly ? " · English" : "")
                         + (selection.availability[model.id] == .missing ? " · not installed" : ""))
                        .tag(model.id.rawValue)
                        .disabled(selection.availability[model.id] != .available)
                }
            }
            .pickerStyle(.menu)
            if SpeechModelCatalog.models().contains(where: { $0.id == .fluidSpeechPro }) {
                // Credit line required by the model's licence (CC BY 4.0).
                Text("Fluid Speech Pro by FluidVoice · CC BY 4.0")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Text(speechStatus).foregroundStyle(.secondary)
                Spacer()
                if selection.status == .failed {
                    Button("Try again") { coordinator.requestSpeechModelSelection(selection.selectedID.rawValue) }
                        .controlSize(.small)
                } else {
                    Button("Refresh models") { coordinator.refreshSpeechModelAvailability() }
                        .controlSize(.small)
                }
            }
            Picker("Automatic cleanup", selection: $cleanupModel) {
                Text(WhisperNowTunedPolisher.usesT4 ? WhisperNowTunedPolisher.displayName : (WhisperNowTunedPolisher.usesT2Contracts ? "DOSE1 T2" : "DOSE1 T1")).tag(WhisperNowTunedPolisher.settingValue).disabled(!WhisperNowTunedPolisher.isInstalled)
                Text("S1-mini by Superwhisper").tag("s1-mini").disabled(!s1Available)
                Text("Qwen3").tag("qwen3")
            }
            .pickerStyle(.menu)
            .help("A compatible DOSE1 T2 also polishes selected text.")
            // What really runs, from the same check the dictation trace uses.
            Text(engineLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("cleanupEngineStatus")
            if Qwen3Polisher.effectiveAutomaticCleanupModel == WhisperNowTunedPolisher.settingValue,
               WhisperNowTunedPolisher.supportsCleanupControls {
                if WhisperNowTunedPolisher.activeT2Contracts.contains(T2CleanupOptions.proseContract) {
                    Picker("Dictation layout", selection: $t2Structure) {
                        Text("Automatic").tag("lists")
                        Text("Keep prose").tag("prose")
                    }
                    .pickerStyle(.menu)
                } else {
                    LabeledContent("Dictation layout", value: "Automatic")
                    if t2Structure != "lists" {
                        Text("Your saved layout is unavailable. Cleanup will keep your words unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Use Automatic") { t2Structure = "lists" }
                            .controlSize(.small)
                    }
                }
            }
            Divider()
            Toggle("Polish selected text with ⌥1", isOn: $quickPolishEnabled)
                .help("Fix spelling, grammar and punctuation in selected text on this Mac.")
                .onChange(of: quickPolishEnabled) { _, enabled in
                    if enabled { Task { await Qwen3Polisher.shared.prewarmQuickPolish() } }
                }
            Toggle("Check meaning locally", isOn: $draftDecisionEnabled)
                .help("Use D1 to check wording changes in dictation and Polish when the model is ready.")
            Toggle("Save Opt+1 examples on this Mac", isOn: $saveOpt1Examples)
                .help("Keep selected text and edit outcomes for future training review. Privacy mode pauses collection.")
            if t2PolishAvailable {
                Text("Selected text").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Make more concise", isOn: $polishOptions.concise)
                    Toggle("Reword for clarity", isOn: $polishOptions.clarity)
                    Toggle("Reorder for readability", isOn: $polishOptions.reorder)
                    Toggle("Add structure for readability", isOn: $polishOptions.structure)
                    Toggle("Maintain your tone", isOn: $polishOptions.maintainYourTone)
                    TextField("Customize your Polish prompt", text: $polishOptions.editingPrompt, axis: .vertical)
                        .lineLimit(2...4)
                    if let problem = polishOptions.promptProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }
                .onChange(of: polishOptions) { _, options in options.save() }
            }
        }
        .task {
            coordinator.refreshSpeechModelAvailability()
            let readiness = await S1MiniPolisher.shared.readiness()
            s1Available = readiness == .cached || readiness == .loaded
        }
    }

    private var t2PolishAvailable: Bool {
        Qwen3Polisher.effectiveAutomaticCleanupModel == WhisperNowTunedPolisher.settingValue
            && WhisperNowTunedPolisher.supportsSelectedTextPolish
    }

    private var engineLine: String {
        let engine = CleanupEngineStatus.current(s1MiniReady: s1Available)
        return "Cleanup now: \(engine.name). \(engine.detail)"
    }

    private var speechStatus: String {
        let selection = coordinator.speechModels
        switch selection.status {
        case .ready: return "Ready to dictate"
        case .loading: return "Loading speech model…"
        case .waitingForIdle: return "Will switch when current work finishes"
        case .pendingActivation: return "Waiting to switch"
        case .missing: return "Selected model is not installed"
        case .unsupported: return "Selected model is unavailable on this version"
        case .failed:
            if let active = selection.activeID { return "Couldn’t switch. Using " + SpeechModelCatalog.descriptor(for: active).name }
            return "Couldn’t load the speech model"
        case .notChecked: return "Checking installed models…"
        }
    }
}
