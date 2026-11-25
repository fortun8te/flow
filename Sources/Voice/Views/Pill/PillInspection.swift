import SwiftUI
import AppKit

/// Offscreen inspection only: pins the idle bar open or a tooltip in place.
struct PillInspectionHooks: Equatable {
    var idleExpanded = false
    var tip: String?
    /// The Changes card open, on its Original side, with one change hovered (its tooltip shown).
    var changesOpen = false
    var changesOriginal = false
    var changesHover: Int?
    /// A fixed glow frame for the working faces (progress renders).
    var glow: PillGlowFrame?
}

private struct PillInspectionKey: EnvironmentKey {
    static let defaultValue = PillInspectionHooks()
}

extension EnvironmentValues {
    var pillInspection: PillInspectionHooks {
        get { self[PillInspectionKey.self] }
        set { self[PillInspectionKey.self] = newValue }
    }
}

#if DEBUG
/// `Flow --render-pill-inspection DIR` renders the real `OverlayPillView` on a stand-in screen:
///   DIR/<skin>-<dock>/<state>.png   every state on the bottom and left docks, key states elsewhere
///   DIR/transitions/<skin>-<name>.png   frame strips at 0, 25, 50, 75, 100% of each spring
/// Glass skins refract a still of the stand-in screen, as they refract the live screen.
/// FLOW_INSPECTION_SKIN / FLOW_INSPECTION_DOCK narrow the run, FLOW_INSPECTION_WAIT (seconds) lets
/// content fades finish, FLOW_INSPECTION_STRIPS=0 / FLOW_INSPECTION_STATES=0 skip a part.
@MainActor
func renderPillInspection(to directory: URL) async throws {
    let env = ProcessInfo.processInfo.environment
    let wait = Double(env["FLOW_INSPECTION_WAIT"] ?? "") ?? 0.6
    let skins = env["FLOW_INSPECTION_SKIN"].map { id in PillSkin.all.filter { $0.id == id } } ?? PillSkin.all
    let docks: [PillDockEdge] = env["FLOW_INSPECTION_DOCK"].map { [PillDockEdge.from(anchor: $0)] } ?? PillDockEdge.allCases
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let telemetry = Telemetry.isSuppressed
    Telemetry.isSuppressed = true
    defer { Telemetry.isSuppressed = telemetry }

    if env["FLOW_INSPECTION_STRIPS"] != "0" && env["FLOW_INSPECTION_ONLY"] == nil {
        let strips = directory.appendingPathComponent("transitions", isDirectory: true)
        try FileManager.default.createDirectory(at: strips, withIntermediateDirectories: true)
        for skin in skins {
            for transition in PillTransitionStrip.all {
                let data = try await PillTransitionStrip.render(transition, skin: skin)
                try data.write(to: strips.appendingPathComponent("\(skin.id)-\(transition.name).png"), options: .atomic)
            }
        }
    }
    if env["FLOW_INSPECTION_STATES"] == "0" { return }

    let keyScenes: Set<String> = ["01-resting", "03-ready", "04-ready-tip", "07-listening", "09-hands-free", "13-polishing",
                                  "17-pasted", "19-line-error", "25-card-microphone", "27-card-cancelled", "30-meeting"]
    for skin in skins {
        for dock in docks {
            let folder = directory.appendingPathComponent("\(skin.id)-\(dock.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let every = dock == .bottom || dock == .left
            // FLOW_INSPECTION_ONLY=34,35: only scenes whose names start with one of these.
            let only = env["FLOW_INSPECTION_ONLY"]?.split(separator: ",").map(String.init)
            for scene in PillInspectionScene.all where only.map({ $0.contains { scene.name.hasPrefix($0) } })
                ?? (every || keyScenes.contains(scene.name)) {
                for backdrop in scene.backdrops(glass: skin.isGlass) {
                    let suite = "flow.inspection." + UUID().uuidString
                    let defaults = UserDefaults(suiteName: suite)!
                    defer { defaults.removePersistentDomain(forName: suite) }
                    defaults.set(dock.anchor, forKey: "voice.pillPosition")
                    defaults.set(skin.id, forKey: "pillSkin")
                    let state = scene.state()
                    let image = try await PillInspectionStage.render(state: state, scene: scene, dock: dock,
                                                                     backdrop: backdrop, defaults: defaults, wait: wait)
                    let suffix = backdrop == scene.backdrop ? "" : "-" + backdrop.rawValue
                    try image.write(to: folder.appendingPathComponent(scene.name + suffix + ".png"), options: .atomic)
                }
            }
        }
    }
}

/// The stand-in screens behind the pill.
enum PillInspectionBackdrop: String, CaseIterable {
    /// A dark desktop with a soft wallpaper.
    case dark
    /// A light app window: text and a grid.
    case light
    /// A busy, colourful page.
    case busy

    @ViewBuilder func view(size: CGSize) -> some View {
        switch self {
        case .dark:
            ZStack {
                LinearGradient(colors: [Color(red: 0.20, green: 0.22, blue: 0.27), Color(red: 0.08, green: 0.09, blue: 0.11)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                PillInspectionText(color: .white.opacity(0.10))
            }
        case .light:
            ZStack {
                Color(white: 0.97)
                PillInspectionGrid(color: .black.opacity(0.06))
                PillInspectionText(color: .black.opacity(0.55))
            }
        case .busy:
            ZStack {
                LinearGradient(colors: [Color(red: 0.98, green: 0.45, blue: 0.30), Color(red: 0.42, green: 0.25, blue: 0.85),
                                        Color(red: 0.10, green: 0.65, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(0..<7, id: \.self) { i in
                    Circle().fill([Color.yellow, .pink, .mint, .orange, .blue, .white, .green][i].opacity(0.75))
                        .frame(width: CGFloat(60 + i * 22), height: CGFloat(60 + i * 22))
                        .offset(x: CGFloat(i * 97 % 520) - 240, y: CGFloat(i * 61 % 300) - 120)
                        .blur(radius: 1)
                }
                PillInspectionText(color: .white.opacity(0.85))
            }
        }
    }
}

private struct PillInspectionText: View {
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<16, id: \.self) { i in
                Text(["The quick brown fox jumps over the lazy dog, again and again.",
                      "Notes from Thursday: send the draft, book the studio, call Ana.",
                      "Q4 numbers look steady; the new edit is in the shared folder."][i % 3])
                    .font(.system(size: 13, weight: i % 4 == 0 ? .semibold : .regular))
                    .foregroundStyle(color)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PillInspectionGrid: View {
    let color: Color
    var body: some View {
        Canvas { context, size in
            var path = Path()
            stride(from: 0, through: size.width, by: 24).forEach { x in path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)) }
            stride(from: 0, through: size.height, by: 24).forEach { y in path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)) }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}

/// One state to render: how to set up the engine flags, and any pinned hover or tooltip.
private struct PillInspectionScene {
    let name: String
    var hooks = PillInspectionHooks()
    var backdrop: PillInspectionBackdrop = .dark
    var after: (@MainActor (RecordingState) -> Void)?
    let state: @MainActor () -> RecordingState

    static let levels: [Float] = (0..<32).map { Float(0.15 + 0.45 * abs(sin(Double($0) * 0.4))) }

    /// Glass is shown over all three screens; flat skins over the scene's own.
    func backdrops(glass: Bool) -> [PillInspectionBackdrop] {
        glass && backdrop == .dark ? [.dark, .light, .busy] : [backdrop]
    }

    @MainActor static func make(_ configure: (RecordingState) -> Void = { _ in }) -> RecordingState {
        let state = RecordingState()
        state.audioLevels = levels
        configure(state)
        return state
    }

    @MainActor static var all: [PillInspectionScene] {
        [
            .init(name: "01-resting") { make() },
            .init(name: "02-resting-light", backdrop: .light) { make() },
            .init(name: "03-ready", hooks: .init(idleExpanded: true)) { make() },
            .init(name: "04-ready-tip", hooks: .init(idleExpanded: true, tip: "dictate")) { make() },
            .init(name: "05-ready-tip-wand", hooks: .init(idleExpanded: true, tip: "wand")) { make() },
            .init(name: "06-starting") { make { $0.pendingRecordingStart = true } },
            .init(name: "07-listening") { make { $0.isRecording = true; $0.barLevel = 0.55 } },
            .init(name: "08-listening-light", backdrop: .light) { make { $0.isRecording = true; $0.barLevel = 0.55 } },
            .init(name: "09-hands-free") { make { $0.isRecording = true; $0.isLocked = true; $0.barLevel = 0.4 } },
            .init(name: "10-hands-free-tip", hooks: .init(tip: "handsFree")) {
                make { $0.isRecording = true; $0.isLocked = true; $0.barLevel = 0.3 }
            },
            .init(name: "12-thinking") { make { $0.transcribingCount = 1 } },
            .init(name: "13-polishing") {
                make {
                    $0.isPolishingSelection = true
                    $0.polishWorkStage = .checkingDraft
                    $0.polishWorkEstimate = .init(stageStartedAt: .now - .seconds(2), finishAt: .now + .seconds(3), range: 0.5...0.9)
                }
            },
            .init(name: "14-polished") { make { $0.polishDiff = PolishDiff(original: "a", polished: "b") } },
            .init(name: "15-cleaned-up") { make { $0.polishDiff = PolishDiff(original: "a", polished: "b", autoCleanup: true) } },
            .init(name: "16-cancelled") { make { $0.showingCancelledToast = true; $0.cancelToastShownAt = Date() } },
            .init(name: "17-pasted") { make { $0.showingUndoPasteToast = true; $0.undoPasteToastShownAt = Date() } },
            .init(name: "18-error") { make { $0.showingErrorPill = true } },
            .init(name: "19-line-error") {
                make { $0.flowNotice = FlowPillNotice.wispr(forToast: "Couldn't read selected text. Select text to polish.") }
            },
            .init(name: "20-line-info") { make { $0.flowNotice = FlowPillNotice.wispr(forToast: "Already looks great") } },
            .init(name: "21-line-warning") {
                make { $0.flowNotice = FlowPillNotice.wispr(forToast: "You have <1 minute left before you reach the 20 minute limit!") }
            },
            .init(name: "22-line-preparing") { make { $0.flowNotice = FlowPillNotice.speechNotReady(.loading) } },
            .init(name: "23-mic-hint") { make { $0.micHint = "Built-in mic" } },
            .init(name: "24-polishing-with-line") {
                make {
                    $0.isPolishingSelection = true
                    $0.flowNotice = FlowPillNotice.wispr(forToast: "Selection changed. Select the text again.")
                }
            },
            .init(name: "25-card-microphone") {
                make { $0.flowNotice = FlowPillNotice(kind: .microphone, message: "Microphone not responding. Check your microphone and permissions.") }
            },
            .init(name: "26-card-paste") {
                make { $0.flowNotice = FlowPillNotice.pasteRecovery("Please send the notes when you’re ready.") }
            },
            .init(name: "27-card-cancelled") {
                make {
                    $0.flowNotice = FlowPillNotice(kind: .cancelled, message: "We noticed you cancelled your transcription",
                                                   title: "You can recover your cancelled transcript", status: .alert, timeout: 8)
                }
            },
            .init(name: "28-card-tip") {
                make {
                    $0.flowNotice = FlowPillNotice(kind: .general, message: "Double tap fn to start hands-free mode.",
                                                   title: "Switch to hands-free mode", status: .info, timeout: 6, badge: "Tip")
                }
            },
            .init(name: "29-card-permission") { make { $0.flowNotice = FlowPillNotice.permission(.accessibility) } },
            .init(name: "30-meeting") { make { $0.isCapturingMeeting = true } },
            .init(name: "31-meeting-tip", hooks: .init(tip: "meeting")) { make { $0.isCapturingMeeting = true } },
            .init(name: "32-meeting-and-hands-free") {
                make { $0.isCapturingMeeting = true; $0.isRecording = true; $0.isLocked = true; $0.barLevel = 0.3 }
            },
            .init(name: "33-hidden-for-an-hour", after: { _ in
                NotificationCenter.default.post(name: Notification.Name("flow.barHiddenCard"), object: nil, userInfo: ["show": true])
            }) { make() },
            // The glow bar: dictation processing and Opt+1 polishing at 15, 50 and 90 %, and the finish flash.
            .init(name: "42-glow-dictation-15", hooks: .init(glow: .init(fill: 0.15, sheen: 0.35, flash: 0, strength: 1))) {
                make { $0.transcribingCount = 1 }
            },
            .init(name: "42-glow-dictation-50", hooks: .init(glow: .init(fill: 0.5, sheen: 0.55, flash: 0, strength: 1))) {
                make { $0.transcribingCount = 1 }
            },
            .init(name: "42-glow-dictation-90", hooks: .init(glow: .init(fill: 0.9, sheen: 0.7, flash: 0, strength: 1))) {
                make { $0.transcribingCount = 1 }
            },
            .init(name: "43-glow-polish-15", hooks: .init(glow: .init(fill: 0.15, sheen: 0.35, flash: 0, strength: 1))) {
                make { $0.isPolishingSelection = true }
            },
            .init(name: "43-glow-polish-50", hooks: .init(glow: .init(fill: 0.5, sheen: 0.55, flash: 0, strength: 1))) {
                make { $0.isPolishingSelection = true }
            },
            .init(name: "43-glow-polish-90", hooks: .init(glow: .init(fill: 0.9, sheen: 0.7, flash: 0, strength: 1))) {
                make { $0.isPolishingSelection = true }
            },
            .init(name: "44-glow-done-flash", hooks: .init(glow: .init(fill: 1, sheen: 0.8, flash: 0.85, strength: 1))) {
                make { $0.isPolishingSelection = true }
            },
            .init(name: "34-changes-short", hooks: .init(changesOpen: true)) { make { $0.polishDiff = Self.shortDiff } },
            .init(name: "35-changes-medium", hooks: .init(changesOpen: true)) { make { $0.polishDiff = Self.mediumDiff } },
            .init(name: "36-changes-sample", hooks: .init(changesOpen: true)) { make { $0.polishDiff = Self.sampleDiff } },
            .init(name: "37-changes-long", hooks: .init(changesOpen: true)) { make { $0.polishDiff = Self.longDiff } },
            .init(name: "38-changes-tooltip", hooks: .init(changesOpen: true, changesHover: 3)) { make { $0.polishDiff = Self.sampleDiff } },
            .init(name: "39-changes-tooltip-top", hooks: .init(changesOpen: true, changesHover: 0)) { make { $0.polishDiff = Self.sampleDiff } },
            .init(name: "40-changes-original", hooks: .init(changesOpen: true, changesOriginal: true)) { make { $0.polishDiff = Self.sampleDiff } },
            .init(name: "41-changes-cleanup", hooks: .init(changesOpen: true)) { make { $0.polishDiff = Self.cleanupDiff } },
        ]
    }

    // Invented text for the Changes card.
    static let shortDiff = PolishDiff(original: "Move the lamp by the window please.",
                                      polished: "Please move the lamp by the window.")
    static let mediumDiff = PolishDiff(
        original: "The prop cupboard has three brass keys and uh two paper maps. Put the maps on the lower shelf.",
        polished: "The prop cupboard has three brass keys and two paper maps. Put the maps on the lower shelf.")
    static let sampleDiff = PolishDiff(
        original: "For the winter exhibit start with the glass birds then put the clay fox near the exit. Also leave space for a label by both cases.",
        polished: "For the winter exhibit, start with the glass birds. Put the clay fox near the exit and leave space for a label by both cases.")
    static let longDiff = PolishDiff(
        original: "Set up the miniature greenhouse with two trays per shelf. Put the mint on top and the thyme just below. We need a small note for each plant, include the watering day and which shelf it lives on. When the doors open hand out the notes before we start the demonstration.",
        polished: "Set up the miniature greenhouse with two trays per shelf. Put the mint on top and the thyme below. Write a note for each plant with its watering day and shelf. Hand out the notes when the doors open, before the demonstration.")
    static let cleanupDiff = PolishDiff(
        original: "Um put the spare lantern on the left no wait on the right.",
        polished: "Put the spare lantern on the right.", autoCleanup: true)
}

/// Draws one scene on a stand-in screen: the panel sits where the panel would sit for that dock,
/// and a glass skin refracts the part of the screen the panel covers.
@MainActor
private enum PillInspectionStage {
    static let screen = CGSize(width: 620, height: 400)

    static func render(state: RecordingState, scene: PillInspectionScene, dock: PillDockEdge,
                       backdrop: PillInspectionBackdrop, defaults: UserDefaults, wait: Double) async throws -> Data {
        let panelSize = PillLayout.panelSize
        let visible = CGRect(origin: .zero, size: screen)
        let origin = PillLayout.panelOrigin(dock: dock, sideFraction: 0.5, visible: visible, bottomY: 0)
        // NS coordinates (bottom-left) to the canvas (top-left).
        let panelRect = CGRect(x: origin.x, y: screen.height - origin.y - panelSize.height,
                               width: panelSize.width, height: panelSize.height)
        let still = PillBackdropFrame.still(backdrop.view(size: screen).offset(x: -panelRect.minX, y: -panelRect.minY)
                                                .frame(width: screen.width, height: screen.height, alignment: .topLeading),
                                            size: panelSize)
        let pill = OverlayPillView(state: state, onTap: {}, onPolish: { _ in }, onCancel: {}, onConfirm: {},
                                   onUndoCancel: {}, onUndoPaste: {}, onStopMeeting: {})
            .environment(\.pillInspection, scene.hooks)
            .environment(\.pillRendersOffscreen, true)
            .environment(\.pillBackdrop, still)
            .defaultAppStorage(defaults)
            .frame(width: panelSize.width, height: panelSize.height)
        let content = ZStack(alignment: .topLeading) {
            backdrop.view(size: screen).frame(width: screen.width, height: screen.height)
            pill.offset(x: panelRect.minX, y: panelRect.minY)
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
        .transaction { $0.disablesAnimations = true }
        return try await snapshot(content, size: screen, wait: wait) { scene.after?(state) }
    }

    /// Renders with SwiftUI's own renderer (the window snapshot path drops Metal shader effects).
    /// The view is first hosted for `wait` seconds so appear-time work and fades settle.
    static func snapshot<V: View>(_ content: V, size: CGSize, wait: Double, after: () -> Void = {}) async throws -> Data {
        let panel = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        try await Task.sleep(for: .seconds(0.12))
        after()
        try await Task.sleep(for: .seconds(wait))
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NotificationCenter.default.post(name: Notification.Name("flow.barHiddenCard"), object: nil, userInfo: ["show": false])
        return data
    }
}

/// Frame strips of the key transitions: the one body at 0, 25, 50, 75 and 100% of its spring,
/// pieces budding off and melting back with their necks, faces cross-fading as they do live.
@MainActor
private struct PillTransitionStrip {
    let name: String
    let from: PillLookInput
    let to: PillLookInput
    var dock: PillDockEdge = .bottom

    static var all: [PillTransitionStrip] {
        func input(_ phase: PillPhase, _ dock: PillDockEdge = .bottom, _ change: (inout PillLookInput) -> Void = { _ in }) -> PillLookInput {
            var value = PillLookInput(phase: phase)
            value.dock = dock
            change(&value)
            return value
        }
        let selectText = FlowPillNotice.wispr(forToast: "Couldn't read selected text. Select text to polish.")
        let micCard = FlowPillNotice(kind: .microphone, message: "Microphone not responding. Check your microphone and permissions.")
        let cancelCard = FlowPillNotice(kind: .cancelled, message: "We noticed you cancelled your transcription",
                                        title: "You can recover your cancelled transcript", status: .alert, timeout: 8)
        return [
            .init(name: "01-resting-ready", from: input(.idle), to: input(.idle) { $0.hovered = true }),
            .init(name: "02-ready-tip", from: input(.idle) { $0.hovered = true },
                  to: input(.idle) { $0.hovered = true; $0.hoveredSegment = .dictate; $0.tipVisible = true }),
            .init(name: "03-ready-listening", from: input(.idle) { $0.hovered = true }, to: input(.recording)),
            .init(name: "04-listening-handsfree", from: input(.recording), to: input(.locked)),
            .init(name: "05-handsfree-thinking", from: input(.locked), to: input(.transcribing)),
            .init(name: "06-thinking-pasted", from: input(.transcribing), to: input(.undoPaste)),
            .init(name: "07-pasted-resting", from: input(.undoPaste), to: input(.idle)),
            .init(name: "08-listening-card", from: input(.recording), to: input(.idle) { $0.notice = micCard }),
            .init(name: "09-card-card", from: input(.idle) { $0.notice = micCard }, to: input(.idle) { $0.notice = cancelCard }),
            .init(name: "10-card-resting", from: input(.idle) { $0.notice = cancelCard }, to: input(.idle)),
            .init(name: "11-resting-line", from: input(.idle), to: input(.idle) { $0.notice = selectText }),
            .init(name: "12-polishing-polished",
                  from: input(.polishingSelection) { $0.polishProgress = 0.7; $0.polishTitle = "Checking" }, to: input(.polishDone)),
            .init(name: "13-left-ready", from: input(.idle, .left), to: input(.idle, .left) { $0.hovered = true }, dock: .left),
            .init(name: "14-left-handsfree-card", from: input(.locked, .left), to: input(.idle, .left) { $0.notice = micCard }, dock: .left),
            .init(name: "15-topright-listening", from: input(.idle, .topRight), to: input(.locked, .topRight), dock: .topRight),
            .init(name: "16-polished-changes", from: input(.polishDone),
                  to: input(.polishDone) { $0.changes = PillInspectionScene.sampleDiff }),
            .init(name: "17-changes-polished", from: input(.polishDone) { $0.changes = PillInspectionScene.sampleDiff },
                  to: input(.idle)),
        ]
    }

    static let fractions: [Double] = [0, 0.25, 0.5, 0.75, 1]

    static func render(_ strip: PillTransitionStrip, skin: PillSkin) async throws -> Data {
        let bounds = PillLayout.panelSize
        let a = PillLookBuilder.look(strip.from, skin: skin)
        let b = PillLookBuilder.look(strip.to, skin: skin)
        let ga = PillLayoutEngine.geometry(a, dock: strip.dock, in: bounds, skin: skin)
        let gb = PillLayoutEngine.geometry(b, dock: strip.dock, in: bounds, skin: skin)
        let motion = PillTransitions.motion(from: strip.from.phase, to: strip.to.phase)
        let s: PillSkin.Motion.Spring = motion == .instant ? skin.motion.quick : motion == .morph ? skin.motion.morph : skin.motion.settle
        let spring = Spring(response: s.response, dampingRatio: s.damping)
        let duration = spring.settlingDuration
        // Each frame shows the part of the panel the pill uses, at full size.
        func area(_ g: PillGeometry) -> CGRect {
            PillSlot.allCases.reduce(CGRect.null) { r, slot in
                let f = g.slot(slot)
                return f.presence > 0 || slot == .body ? r.union(f.rect) : r
            }
        }
        let focus = area(ga).union(area(gb)).insetBy(dx: -28, dy: -22).intersection(CGRect(origin: .zero, size: bounds))
        let cell = focus.size
        let still = PillBackdropFrame.still(PillInspectionBackdrop.busy.view(size: bounds), size: bounds)
        let live = PillLiveValues(levels: PillInspectionScene.levels, barLevel: 0.45)
        let m = skin.motion
        let frames = HStack(spacing: 2) {
            ForEach(Array(fractions.enumerated()), id: \.offset) { _, fraction in
                // Frames at 0, 25, 50, 75 and 100% of the shape's travel; content fades at the
                // time the spring reaches that point.
                let p = fraction
                let time = fraction == 0 ? 0 : fraction == 1 ? duration
                    : stride(from: 0.0, through: duration, by: 0.002).first { spring.value(target: 1.0, time: $0) >= fraction } ?? duration
                var g = gb - ga
                let _ = g.scale(by: p)
                let geometry = ga + g
                let same = a.face.key == b.face.key
                let outOpacity = same ? 0 : max(0, 1 - time / m.fadeOut)
                // One label at a time: the old one is gone before the new one starts.
                let inOpacity = same ? 1.0 : min(1, max(0, (time - m.fadeInDelay) / m.fadeIn))
                let body = geometry.slot(.body)
                ZStack(alignment: .topLeading) {
                    (skin.isGlass ? AnyView(PillInspectionBackdrop.busy.view(size: bounds)) : AnyView(PillInspectionBackdrop.dark.view(size: bounds)))
                        .frame(width: bounds.width, height: bounds.height)
                    PillBlobView(geometry: geometry, look: b, shownLead: b.lead ?? a.lead, shownTrail: b.trail ?? a.trail,
                                 shownTip: b.tip ?? a.tip, live: live, actions: PillActions(), pointer: PillPointer(),
                                 contentOpacity: inOpacity)
                    if !same {
                        PillFaceView(face: a.face, size: a.size, live: live, actions: PillActions())
                            .frame(width: body.rect.width, height: body.rect.height)
                            .clipShape(PillShape(radius: body.radius))
                            .offset(x: body.rect.minX, y: body.rect.minY)
                            .opacity(outOpacity)
                    }
                    Text("\(Int(fraction * 100))%").font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white).padding(3).background(Color.black.opacity(0.55))
                        .offset(x: focus.minX + 4, y: focus.minY + 4)
                }
                .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
                .environment(\.pillBackdrop, still)
                .offset(x: -focus.minX, y: -focus.minY)
                .frame(width: cell.width, height: cell.height, alignment: .topLeading)
                .clipped()
            }
        }
        .environment(\.pillSkin, skin.adapted(toBackdropLuma: skin.isGlass ? still?.luma : nil))
        .environment(\.pillRendersOffscreen, true)
        .environment(\.colorScheme, .dark)
        .transaction { $0.disablesAnimations = true }
        let size = CGSize(width: cell.width * CGFloat(fractions.count) + 2 * CGFloat(fractions.count - 1), height: cell.height)
        return try await PillInspectionStage.snapshot(frames, size: size, wait: 0.3)
    }
}
#endif
