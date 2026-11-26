// Flow · App Entry Point
// ============================================================
// Menu bar only. No main window, no dashboard.
// The ENTIRE UI is the floating dictation pill at bottom-center.
//
// fn hold       = push-to-talk (record while held, transcribe on release)
// fn double-tap = lock recording (stays on; press fn again to transcribe)
// Tap pill      = same as double-tap (enter lock mode)
// ============================================================

import SwiftUI
import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import UserNotifications
import UniformTypeIdentifiers
import FluidAudio

// MARK: - Verbose logging gate
// `vlog` compiles to a no-op in release builds and is gated by `voiceVerbose`
// in debug. Hot-path code uses this instead of `print` to keep CPU off the
// audio + recording threads. Flip `voiceVerbose` to true when diagnosing.
@inline(__always) func vlog(_ message: @autoclosure () -> String) {
    #if DEBUG
    if voiceVerbose { print(message()) }
    #endif
}
let voiceVerbose: Bool = false

struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - Background-activity opt-out flags
    //
    // These @AppStorage flags surface user-facing toggles for every optional
    // background subsystem. Defaults favor OFF for anything non-essential so
    // a fresh install only spins up the core dictation pipeline. AppDelegate
    // reads the same UserDefaults keys directly at startup via the
    // `BackgroundActivityGate` helper (since @AppStorage only resolves inside
    // SwiftUI scope — AppDelegate is AppKit-bound).
    //
    // `privacyMode` is an emergency "all off" master switch. When true it
    // overrides every other flag and forces local-only / minimal-CPU mode.

    /// CallAppDetector polls SCShareableContent + CoreAudio every ~2s to detect
    /// Discord/Zoom/Teams/Slack/FaceTime calls. Off by default — opt-in for
    /// auto meeting capture.
    @AppStorage("voice.enableMeetingDetection") private var enableMeetingDetection: Bool = false
    /// Master kill switch for *automatic* meeting detection. When true, every
    /// auto-start path (CallAppDetector, Chrome MeetBridge, voiceAutoStartMeeting
    /// notification) is short-circuited regardless of the per-detector flags.
    /// Manual meeting capture from the UI still works. AppDelegate reads the
    /// raw key via `kDisableMeetingDetectionKey` so the gate also applies
    /// outside SwiftUI scope. Surfaced here so a settings UI can bind to it.
    @AppStorage("voice.disableMeetingDetection") private var disableMeetingDetection: Bool = false
    /// Core dictation (hotkey + transcription + paste). On by default — this
    /// is the app's primary purpose. Flipping false disables hotkey handling.
    @AppStorage("voice.enableRecording") private var enableRecording: Bool = true
    /// Emergency "all off" master toggle. When true, overrides every other
    /// background flag: wake word OFF, meeting detection OFF, cloud polish
    /// forced OFF (local-only), Aurora animation OFF (static idle pill).
    @AppStorage("voice.privacyMode") private var privacyMode: Bool = false

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Centralized gate for optional background subsystems. AppDelegate consults
/// these helpers at startup (and on UserDefaults-change notifications) to
/// decide whether to call `.start()` / `.enable()` on each service. Single
/// source of truth for "should this subsystem run right now?".
///
/// `privacyMode` is the master kill switch — when on, every helper returns
/// false regardless of the per-feature flags.
enum BackgroundActivityGate {
    static var privacyMode: Bool {
        UserDefaults.standard.bool(forKey: "voice.privacyMode")
    }

    static var wakeWordEnabled: Bool {
        if privacyMode { return false }
        // The Settings Enable toggle (`voice.wakeWordEnabled`) is the master.
        // It must be ON *and* the mode picker must be a non-"off" value.
        // Using AND (not OR) closes the "recording when it shouldn't" bug:
        // when the user turns the Enable toggle OFF, `voice.wakeWordMode` can
        // retain a stale "alwaysOn"/"activatedWindow" value (the picker is
        // merely hidden, not reset), and an OR would keep the mic tap alive.
        // The toggle's onChange also forces mode→"off" on disable as a second
        // line of defense. Privacy mode still kills everything.
        guard UserDefaults.standard.bool(forKey: "voice.wakeWordEnabled") else { return false }
        let mode = UserDefaults.standard.string(forKey: "voice.wakeWordMode") ?? "off"
        return mode != "off"
    }

    /// Activation strategy for the wake word listener. Reads
    /// `voice.wakeWordMode`. Defaults to "off" — a fresh install never
    /// taps the mic from the wake-word path until the user opts in.
    static var wakeWordMode: String {
        if privacyMode { return "off" }
        return UserDefaults.standard.string(forKey: "voice.wakeWordMode") ?? "off"
    }

    static var meetingDetectionEnabled: Bool {
        if privacyMode { return false }
        // Inverted kill switch — explicit OFF wins.
        if UserDefaults.standard.bool(forKey: "voice.disableMeetingDetection") { return false }
        // Default to OFF if unset. Meeting/call auto-detection polls
        // SCShareableContent (ScreenCaptureKit), which lights the macOS
        // screen-recording indicator — too alarming to enable for everyone by
        // default. It is now strictly opt-in from Settings.
        if UserDefaults.standard.object(forKey: "voice.enableMeetingDetection") == nil { return false }
        return UserDefaults.standard.bool(forKey: "voice.enableMeetingDetection")
    }

    static var recordingEnabled: Bool {
        if privacyMode { return false }
        // Default to true if unset — core dictation is the product.
        if UserDefaults.standard.object(forKey: "voice.enableRecording") == nil { return true }
        return UserDefaults.standard.bool(forKey: "voice.enableRecording")
    }

    /// Cloud polish (Cerebras/Groq) — forced OFF in privacy mode. Callers
    /// must also check `CerebrasPolisher.isEnabled` for the per-provider flag.
    static var cloudPolishAllowed: Bool { !privacyMode }

    /// Aurora animation on the idle pill. Off in privacy mode for visible
    /// confirmation the app is in minimal-CPU state.
    static var auroraAnimationAllowed: Bool { !privacyMode }
}

/// Top-level entry point. Branches on CLI args:
///   --cleanup-prepare CONFIG → saved audio through Flow's production path (CleanupReplayHarness)
///   --cleanup-run CONFIG     → stored S1 inputs through Flow's production cleanup
///   --polish-harness [dir]   → run the headless golden-case polish harness
///   (anything else)          → boot the SwiftUI app as normal
///
/// Lives here (rather than as a separate target) because the polish pipeline
/// (`Qwen3Polisher`, `RestartCorrectionPreprocessor`, `PolishPostprocessor`,
/// `LLMPolisher`) uses internal access across `Sources/Voice/Services/` and
/// is referenced extensively from the rest of the Voice target. Splitting it
/// out would mean making dozens of types public — too invasive for what is
/// a read-only test harness. See PolishHarness.swift.
@main
struct VoiceEntryPoint {
    @MainActor static func main() {
        let args = CommandLine.arguments
        #if DEBUG
        if args.dropFirst().first == "--render-pill-inspection", args.count == 3 {
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApplication.shared.finishLaunching()
            Task { @MainActor in
                do {
                    try await renderPillInspection(to: URL(fileURLWithPath: args[2], isDirectory: true))
                    exit(0)
                } catch { fputs("Pill inspection failed.\n", stderr); exit(1) }
            }
            RunLoop.main.run()
            return
        }
        // Text-only diagnostics (no models, servers or capture): the deterministic typo repair and the
        // Opt+1 referee on fixture files. [{id, input, model?}] -> [{id, out, ms}].
        if args.count == 4, args[1] == "--typo-repair-eval" {
            struct Fixture: Decodable { let id: String; let input: String; let model: String? }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[2])),
                  let fixtures = try? JSONDecoder().decode([Fixture].self, from: data) else { exit(2) }
            _ = TypoRepair.shared.lexicon(wait: true)
            _ = TinyNextScorer.shared.ready(wait: true)
            var rows: [[String: Any]] = []
            for f in fixtures {
                let start = DispatchTime.now().uptimeNanoseconds
                let out: String
                if let model = f.model {
                    out = OptOneReferee.finish(source: f.input, model: model, protectedTerms: [], wait: true).text
                } else {
                    out = OptOneReferee.deterministic(f.input, protectedTerms: [], wait: true)
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                rows.append(["id": f.id, "out": out, "ms": ms])
            }
            guard let bytes = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
                  (try? bytes.write(to: URL(fileURLWithPath: args[3]))) != nil else { exit(1) }
            exit(0)
        }
        #endif

        if args.dropFirst().first == "--self-test" {
            exit(FlowSelfTest.run() ? 0 : 1)
        }

        if args.dropFirst().first == "--check-permissions" {
            let microphone: String
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: microphone = "authorized"
            case .notDetermined: microphone = "not-requested"
            case .denied: microphone = "denied"
            case .restricted: microphone = "restricted"
            @unknown default: microphone = "unknown"
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["microphone": microphone,
                    "accessibility": AXIsProcessTrusted()], options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }

        // Headless production replay for the cleanup-model data.
        // Claims sole ownership itself: it refuses while Flow runs, except for a
        // proof of at most 5 items that opts in. See CleanupReplayHarness.swift.
        if args.count == 3, args[1] == "--cleanup-prepare" || args[1] == "--cleanup-run" {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let mode = args[1]
            let config = args[2]
            Task { @MainActor in
                let status = mode == "--cleanup-prepare"
                    ? await CleanupReplayHarness.runPrepare(configPath: config)
                    : await CleanupReplayHarness.runCleanup(configPath: config)
                exit(status)
            }
            RunLoop.main.run()
            return
        }

        // No backend, including a CLI harness, may run before sole ownership.
        if let reason = FlowOwnership.shared.acquire() {
            if args.count > 1 { fputs("Flow unavailable: \(reason)\n", stderr); exit(75) }
            FlowBlockedApplication.run(reason: reason)
            return
        }
        if args.dropFirst().first == "--check-startup" {
            guard Bundle.module.url(forResource: "ModelManifests", withExtension: nil) != nil else {
                fputs("Flow backend resources are missing.\n", stderr); exit(1)
            }
            print("Flow startup check passed: sole ownership and backend resources; no models or capture started.")
            exit(0)
        }
        FlowDefaultsMigration.migrate(into: .standard,
            legacy: UserDefaults.standard.persistentDomain(forName: "com.example.flow.voice") ?? [:])
        if args.dropFirst().first == "--evaluate-saved-dictation" {
            guard args.count == 3 else { exit(2) }
            Task { @MainActor in
                do {
                    let configuration = try JSONDecoder().decode(SavedDictationEvaluationHarness.Configuration.self,
                        from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                    try await SavedDictationEvaluationHarness.run(configuration)
                    print("Saved dictation pipeline evaluation finished; private receipts written.")
                    exit(0)
                } catch { fputs("Saved dictation pipeline evaluation failed.\n", stderr); exit(1) }
            }
            RunLoop.main.run()
            return
        }

        if args.dropFirst().first == "--evaluate-local-cleanup" {
            guard args.count == 3 else { exit(2) }
            struct CleanupConfiguration: Decodable {
                let manifest: String
                let receiptDirectory: String
                let model: String
            }
            Task { @MainActor in
                do {
                    let config = try JSONDecoder().decode(CleanupConfiguration.self,
                        from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                    guard ["qwen3", "s1-mini"].contains(config.model) else { exit(2) }
                    UserDefaults.standard.setVolatileDomain([
                        "voice.allowCloudPolishing": false, "voice.allowCloudMeetingSummary": false,
                        "voice.privacyMode": true, "llmPolishEnabled": true,
                        "voice.cleanupModel": "qwen3"
                    ], forName: UserDefaults.argumentDomain)
                    if config.model == "qwen3" {
                        guard await Qwen3Polisher.shared.prepareCachedAutomaticModel() else { exit(1) }
                    } else {
                        guard await S1MiniPolisher.shared.prepare() else { exit(1) }
                    }
                    _ = try await LocalCleanupEvaluationHarness.run(
                        manifestURL: URL(fileURLWithPath: config.manifest),
                        receiptDirectory: URL(fileURLWithPath: config.receiptDirectory, isDirectory: true),
                        modelLabel: config.model, passes: 1, includeAuthored: true,
                        maximumElapsedSeconds: 180
                    ) { item in
                        if item.expectsBypass { return .bypassed }
                        if config.model == "s1-mini" {
                            switch await S1MiniPolisher.shared.polish(item.input, language: item.language) {
                            case .accepted(let output): return .accepted(output)
                            case .unchanged: return .unchanged
                            case .unavailable: return .unavailable
                            case .rejected: return .refused
                            }
                        }
                        let output = await Qwen3Polisher.shared.polish(item.input, context: .default,
                            cleanupLevel: "light", personalityStyle: "neutral")
                        return output == item.input ? .unchanged : .accepted(output)
                    }
                    print("Local cleanup evaluation finished; private receipts written.")
                    exit(0)
                } catch { fputs("Local cleanup evaluation failed.\n", stderr); exit(1) }
            }
            RunLoop.main.run()
            return
        }

        if args.dropFirst().first == "--evaluate-local-asr" {
            guard args.count == 3 else { exit(2) }
            struct Configuration: Decodable {
                let manifest: String
                let models: String
                let receiptDirectory: String
                let version: String
                let passes: Int
                let label: String
            }
            Task { @MainActor in
                do {
                    let config = try JSONDecoder().decode(Configuration.self,
                        from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                    let modelID: SpeechModelID
                    switch config.version {
                    case "v3": modelID = .parakeetV3
                    case "ultra": modelID = .parakeetUltra
                    case "phonon2": modelID = .phonon2
                    default: exit(2)
                    }
                    let descriptor = SpeechModelCatalog.descriptor(for: modelID)
                    let localLoader: (() async throws -> AsrModels)?
                    if modelID == .parakeetV3 { localLoader = nil }
                    else {
                        guard URL(fileURLWithPath: config.models).standardizedFileURL == descriptor.directory.standardizedFileURL else { exit(2) }
                        localLoader = { try SpeechModelLoader.load(descriptor) }
                    }
                    _ = try await LocalASREvaluationHarness.run(
                        manifestURL: URL(fileURLWithPath: config.manifest),
                        modelDirectory: URL(fileURLWithPath: config.models, isDirectory: true),
                        version: SpeechModelLoader.version(for: modelID),
                        receiptDirectory: URL(fileURLWithPath: config.receiptDirectory, isDirectory: true),
                        passes: config.passes, modelLabel: config.label, localModelsLoader: localLoader)
                    print("Local saved-audio evaluation finished; private receipts written.")
                    exit(0)
                } catch {
                    fputs("Local saved-audio evaluation failed; original data unchanged.\n", stderr)
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }

        if args.count == 4, ["--compare-polish-fixtures", "--replay-opt1"].contains(args[1]) {
            struct Fixture: Decodable { let id: String; let input: String }
            Task { @MainActor in
                do {
                    let fixtures = try JSONDecoder().decode([Fixture].self,
                        from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                    guard (1...12).contains(fixtures.count),
                          fixtures.allSatisfy({ !$0.input.isEmpty && !PolishTransaction.isTooLong($0.input) }) else { exit(2) }
                    // Opt+1 on the typing-repair route needs only the 9B: one model at a time.
                    if !(args[1] == "--replay-opt1" && TypoFixModel.isAvailable) {
                        await Qwen3Polisher.shared.prewarmQuickPolish()
                    }
                    _ = await TypoFixModel.shared.prepare()
                    var results: [[String: Any]] = []
                    for fixture in fixtures {
                        if args[1] == "--replay-opt1" {
                            // The pill's progress signal, as the pill would receive it (ms since start, fraction).
                            final class Samples: @unchecked Sendable { var items: [[Double]] = [] }
                            let samples = Samples()
                            let start = DispatchTime.now().uptimeNanoseconds
                            let token = NotificationCenter.default.addObserver(forName: PillPolishSignal.notification,
                                                                               object: nil, queue: .main) { note in
                                guard let fraction = PillPolishSignal(notification: note).fraction else { return }
                                samples.items.append([Double((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000), fraction])
                            }
                            let result = await Qwen3Polisher.shared.polishShortcut(fixture.input)
                            let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                            try? await Task.sleep(for: .milliseconds(50))
                            NotificationCenter.default.removeObserver(token)
                            results.append(["id": fixture.id, "delivered": result.text as Any? ?? NSNull(),
                                            "preview": result.preview, "routedMs": elapsed,
                                            "budgetMs": Int(PolishTransaction.shortcutBudgetSeconds(for: fixture.input) * 1000),
                                            "progress": samples.items, "route": Qwen3Polisher.lastOpt1Route as Any? ?? NSNull(),
                                            "reviewRejection": result.text == nil ? Qwen3Polisher.lastSelectedRejection as Any? ?? NSNull() : NSNull()])
                            continue
                        }
                        let quickAt = DispatchTime.now().uptimeNanoseconds
                        let quick = await Qwen3Polisher.shared.quickPolish(fixture.input)
                        let quickMs = (DispatchTime.now().uptimeNanoseconds - quickAt) / 1_000_000
                        let reviewAt = DispatchTime.now().uptimeNanoseconds
                        let review = await Qwen3Polisher.shared.reviewablePolish(fixture.input)
                        let reviewMs = (DispatchTime.now().uptimeNanoseconds - reviewAt) / 1_000_000
                        results.append(["id": fixture.id, "quick": quick as Any? ?? NSNull(), "quickMs": quickMs,
                                        "review": review as Any? ?? NSNull(), "reviewMs": reviewMs,
                                        "reviewRejection": review == nil ? Qwen3Polisher.lastSelectedRejection as Any? ?? NSNull() : NSNull()])
                    }
                    let bytes = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                    try bytes.write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
                    exit(0)
                } catch {
                    fputs("Fixture comparison failed.\n", stderr)
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }

        // Private local diagnostics: run the real Opt+1 path on a file and print the result.
        if args.count == 3, args[1] == "--polish-shortcut" {
            Task { @MainActor in
                let appPreferences = UserDefaults.standard.persistentDomain(forName: "com.example.flow.voice") ?? [:]
                UserDefaults.standard.setVolatileDomain(appPreferences, forName: UserDefaults.argumentDomain)
                guard let input = try? String(contentsOfFile: args[2], encoding: .utf8) else { exit(2) }
                await Qwen3Polisher.shared.prewarmQuickPolish()
                if ProcessInfo.processInfo.environment["FLOW_OPT1_COLD"] == nil { _ = await TypoFixModel.shared.prepare() }
                let start = DispatchTime.now().uptimeNanoseconds
                let out = await Qwen3Polisher.shared.polishShortcut(input)
                let ms = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                print("ms=\(ms) rejection=\(Qwen3Polisher.lastSelectedRejection ?? "-")")
                print(out.text ?? "<nil>")
                exit(0)
            }
            RunLoop.main.run()
            return
        }

        // Private local diagnostics: same selection passed to the two installed editing paths.
        if args.count == 4, args[1] == "--compare-polish-selection" {
            Task { @MainActor in
                do {
                    let input = try String(contentsOfFile: args[2], encoding: .utf8)
                    guard !input.isEmpty, !PolishTransaction.isTooLong(input) else { exit(2) }
                    await Qwen3Polisher.shared.prewarmQuickPolish()
                    let quickStart = DispatchTime.now().uptimeNanoseconds
                    let quick = await Qwen3Polisher.shared.quickPolish(input)
                    let quickMs = (DispatchTime.now().uptimeNanoseconds - quickStart) / 1_000_000
                    let selectedStart = DispatchTime.now().uptimeNanoseconds
                    let selected = await Qwen3Polisher.shared.polishInPlaceLocally(input, preset: "smooth")
                    let selectedMs = (DispatchTime.now().uptimeNanoseconds - selectedStart) / 1_000_000
                    var local: Any = NSNull()
                    if case .success(let text) = selected { local = text }
                    let result: [String: Any] = [
                        "quickOutput": quick as Any? ?? NSNull(), "quickMs": quickMs,
                        "localOutput": local, "localMs": selectedMs
                    ]
                    let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    try bytes.write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
                    exit(0)
                } catch {
                    fputs("Selection comparison failed.\n", stderr)
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }

        if ((3...4).contains(args.count) && ["--evaluate-local-polish", "--evaluate-quick-polish"].contains(args[1]))
            || (args.count == 6 && args[1] == "--evaluate-lfm-polish") {
            let limit = args.count >= 4 ? (Int(args[3]) ?? 0) : 6
            guard (1...40).contains(limit) else { exit(2) }
            Task { @MainActor in
                // A bare CLI binary can have a different defaults domain from the app.
                // This is process-local and does not write or alter the app's settings.
                let appPreferences = UserDefaults.standard.persistentDomain(forName: "com.example.flow.voice") ?? [:]
                UserDefaults.standard.setVolatileDomain(appPreferences, forName: UserDefaults.argumentDomain)
                do {
                    if args[1] == "--evaluate-quick-polish", args.count == 4 {
                        await Qwen3Polisher.shared.prewarmQuickPolish()
                    }
                    _ = try await LocalQualityEvaluationHarness.run(
                        receiptDirectory: URL(fileURLWithPath: args[2], isDirectory: true), limit: limit) { text in
                        if args[1] == "--evaluate-lfm-polish" {
                            guard let port = UInt16(args[4]), args[5] == "stock" || args[5] == "t4" else {
                                throw LocalQualityEvaluationHarness.CallFailure.unavailable
                            }
                            return try await LocalQualityEvaluationHarness.lfmPolish(text, port: port, tagged: args[5] == "t4")
                        }
                        if args[1] == "--evaluate-quick-polish" {
                            guard let result = await Qwen3Polisher.shared.quickPolish(text) else {
                                throw LocalQualityEvaluationHarness.CallFailure.rejected
                            }
                            return result
                        }
                        switch await Qwen3Polisher.shared.polishInPlaceLocally(text, preset: "smooth") {
                        case .success(let result): return result
                        case .unavailable: throw LocalQualityEvaluationHarness.CallFailure.unavailable
                        case .rejected: throw LocalQualityEvaluationHarness.CallFailure.rejected
                        }
                    }
                    print("Local-only editing evaluation finished; private aggregate receipt written.")
                    exit(0)
                } catch { fputs("Local editing evaluation could not finish.\n", stderr); exit(1) }
            }
            RunLoop.main.run()
            return
        }

        if args.dropFirst().first == "--diagnose-storage-copy" || args.dropFirst().first == "--import-wispr-prepared-copy" {
            #if DEBUG
            // Diagnostic initialization is confined to the private copied DB.
            // Never fall through to AppDelegate for malformed diagnostic args.
            let importing = args.dropFirst().first == "--import-wispr-prepared-copy"
            let alreadyImported = importing && args.count == 4 && args[3] == "--already-imported"
            guard args.count == 3 || alreadyImported else { exit(2) }
            let allowed = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("diagnostics/startup-diagnosis-copy", isDirectory: true)
                .standardizedFileURL
            let directory = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
            let database = directory.appendingPathComponent("voice.db")
            do {
                guard directory == allowed,
                      directory.resolvingSymlinksInPath() == directory,
                      database.resolvingSymlinksInPath() == database else { exit(2) }
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: database.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      fileAttributes[.type] as? FileAttributeType == .typeRegular,
                      attributes[.ownerAccountName] as? String == NSUserName(),
                      fileAttributes[.ownerAccountName] as? String == NSUserName(),
                      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                      (fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { exit(2) }
                let storage = StorageService(directory: directory)
                try storage.initialize()
                if importing {
                    let prepared = directory.appendingPathComponent("prepared-meetings.json")
                    guard prepared.resolvingSymlinksInPath() == prepared else { exit(2) }
                    let preparedAttributes = try FileManager.default.attributesOfItem(atPath: prepared.path)
                    guard preparedAttributes[.type] as? FileAttributeType == .typeRegular,
                          preparedAttributes[.ownerAccountName] as? String == NSUserName(),
                          (preparedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                          let preferences = UserDefaults(suiteName: "voice.storage-copy.\(UUID().uuidString)") else { exit(2) }
                    // Argument-domain values are process-only. No profile,
                    // dictionary or persistent application preferences change.
                    let marker = "voice.wisprMeetingsImported"
                    preferences.setVolatileDomain([marker: alreadyImported], forName: UserDefaults.argumentDomain)
                    if !preferences.bool(forKey: marker),
                       let report = try WisprMeetingImportService.run(storage: storage, file: prepared) {
                        print("Prepared copy import: imported=\(report.imported), existing=\(report.existing), skipped=\(report.skipped)")
                    } else {
                        print("Prepared copy import skipped: isolated marker already set.")
                    }
                } else {
                    print("Storage copy initialization succeeded.")
                }
                exit(0)
            } catch {
                // DatabaseError bridges its extended SQLite result code to
                // NSError.code. Never print SQL, arguments or source text.
                let failure = error as NSError
                let domain = failure.domain.range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil
                    ? failure.domain : "unknown"
                fputs("Storage copy initialization failed: domain=\(domain) code=\(failure.code)\n", stderr)
                exit(1)
            }
            #else
            fputs("Storage copy diagnostic is available in debug builds only.\n", stderr)
            exit(2)
            #endif
        }

        if args.dropFirst().first == "--import-wispr-prepared", args.count == 2 {
            Task { @MainActor in
                let preferences = UserDefaults.standard
                WisprPersonalizationProfile.load()?.applyInitialPreferences(to: preferences)
                WisprPersonalizationProfile.importPreparedDictionary(defaults: preferences)
                do {
                    let storage = StorageService()
                    try storage.initialize()
                    if !preferences.bool(forKey: "voice.wisprMeetingsImported"),
                       let report = try WisprMeetingImportService.run(storage: storage) {
                        if report.skipped == 0 { preferences.set(true, forKey: "voice.wisprMeetingsImported") }
                        print("Prepared meetings: imported=\(report.imported), existing=\(report.existing), skipped=\(report.skipped)")
                    }
                    exit(0)
                } catch {
                    let failure = error as NSError
                    let domain = failure.domain.range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil
                        ? failure.domain : "unknown"
                    fputs("Prepared import failed; original export preserved. domain=\(domain) code=\(failure.code)\n", stderr)
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }


        if args.dropFirst().first == "--polish-harness" {
            let dir = args.count > 2 ? args[2] : "Sources/Voice/Resources/GoldenCases"
            // Use RunLoop.main so the @MainActor task actually gets to run.
            // sema.wait() would deadlock because it blocks the very thread
            // the main actor needs to schedule work on.
            Task { @MainActor in
                await PolishHarness.run(goldenCasesDir: dir)
                exit(0)
            }
            RunLoop.main.run()   // spins until exit(0) above fires
            return
        }
        if args.dropFirst().first == "--polish-eval", args.count > 3 {
            // Cloud-only polish eval: `Flow --polish-eval CASES.json OUT.json` (see PolishHarness.swift).
            let casesPath = args[2]
            let outPath = args[3]
            Task { @MainActor in
                await PolishHarness.runCloudEval(casesPath: casesPath, outPath: outPath)
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        if args.dropFirst().first == "--rerun-audio" {
            // Re-transcribe + re-polish the last N saved dictations from their
            // retained .caf audio, comparing OLD vs NEW output + latency.
            // `swift run -c release Voice --rerun-audio [N]` (default 10).
            let n = (args.count > 2 ? Int(args[2]) : nil) ?? 10
            Task { @MainActor in
                await RerunAudioHarness.run(limit: n)
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        VoiceApp.main()
    }
}

// MARK: - Global notification names

extension Notification.Name {
    /// Posted by services with userInfo["message": String] when something
    /// goes wrong the user should see (mic denied, paste failed, etc.).
    /// Surfaced as a top-right toast — independent of the dictation pill.
    static let voiceError = Notification.Name("voice.error")
    /// Posted from the idle pill's context menu to bring up the BigMenu window.
    static let voiceOpenBigMenu = Notification.Name("voice.openBigMenu")
    /// Posted by the BigMenu toolbar's "…" → Settings… item. The SwiftUI root
    /// view observes this and flips its `showSettings` state to present the
    /// sheet, since AppKit can't reach SwiftUI @State directly.
    static let voiceOpenBigMenuSettings = Notification.Name("voice.openBigMenuSettings")
    /// Posted when the cloud polish path failed (timeout / rate-limit / network)
    /// and we silently fell back to the local model. `userInfo["reason"]`
    /// carries a short human-readable cause.
    static let voiceCloudFellBackToLocal = Notification.Name("voice.cloudFellBackToLocal")
    /// Posted by OverlayPanel's meeting-poll timer when a meeting app is newly
    /// detected (false → true). AppDelegate observes this and auto-starts capture.
    /// Auto-stop is intentionally NOT done via poll — the user taps the pill to stop
    /// so that tabbing away from Chrome mid-meeting doesn't kill the capture.
    static let voiceAutoStartMeeting = Notification.Name("voice.autoStartMeeting")
    /// Posted by the menu bar's "Stop meeting recording" item. AppDelegate
    /// observes this and calls the existing `stopMeetingCapture()` flow.
    static let voiceStopMeetingRequested = Notification.Name("voice.stopMeetingRequested")
    /// Posted by MeetingCaptureService's audio watchdog when no fresh samples
    /// have arrived for >5s while `isCapturing == true`. AppDelegate observes
    /// this and prints a toast so the user knows recording may be incomplete.
    static let voiceMeetingAudioStalled = Notification.Name("voice.meetingAudioStalled")
    /// Posted by the BigMenu meeting row when the user clicks "Transcribe now".
    /// userInfo: ["meetingId": String]. AppDelegate handles it.
    static let voiceTranscribeMeetingRequested = Notification.Name("voice.transcribeMeetingRequested")
    /// Posted back by AppDelegate when a manual re-transcribe finishes (success
    /// OR failure). userInfo: ["meetingId": String, "success": Bool, "error": String?].
    /// The row observes this to clear its "Transcribing…" state.
    static let voiceTranscribeMeetingFinished = Notification.Name("voice.transcribeMeetingFinished")
    /// Posted by the BigMenu meetings empty-state "Start meeting manually"
    /// button. AppDelegate observes this and runs the same flow as the menu
    /// bar's "Start Meeting Recording" item so there's one code path.
    static let voiceStartMeetingManual = Notification.Name("voice.startMeetingManual")
}

/// Lifecycle of the persisted-meetings fetch. The BigMenuWindow Meetings tab
/// reads this off `RecordingState` to decide between skeleton-loader, the
/// list, the empty state, and an error state with a Retry button.
enum MeetingsLoadState: Equatable {
    /// No load attempt has run yet. Visually identical to `.loading` in the UI
    /// so the very first frame doesn't flash an empty state.
    case initial
    /// A fetch is in flight. Drives the skeleton-row loader.
    case loading
    /// At least one fetch has completed successfully. `recordingState.meetings`
    /// is the source of truth for what to display — this state just lets the
    /// UI know "we tried, and it worked" so empty vs. populated is unambiguous.
    case loaded
    /// The fetch threw. The carried string is a short, human-readable reason
    /// surfaced verbatim in the error view ("Couldn't load meetings — <reason>").
    case error(String)
}

/// Persisted history of the last dictations. Capped at 100 (see
/// `RecentDictations.limit`). Lives here (not in a service) because it's
/// UI-shaped state for the menu.
///
/// `text` is the polished (final) version that was actually pasted at the cursor.
/// `rawText` is the pre-polish formatted version (optional for backward compat —
/// older persisted entries didn't capture it). When both are present the UI can
/// show a before/after compare.
struct RecentDictation: Codable, Identifiable {
    let text: String
    let timestamp: Date
    /// Pre-polish formatted text. Optional so we don't break decoding of older
    /// entries written before this field existed.
    var rawText: String? = nil
    /// Bundle ID of the app text was pasted into (e.g. "com.tinyspeck.slackmacgap").
    var pasteTargetBundleID: String? = nil
    /// Milliseconds the Qwen3 polish stage took. Nil if polish was skipped/disabled.
    var polishMs: Int? = nil
    /// Raw transcript from Granite 4.0 1B (second ASR), captured at the moment
    /// of dictation. Optional for backward compat with older entries.
    var graniteText: String? = nil
    /// Raw transcript from Moonshine Tiny (third ASR), captured at the moment
    /// of dictation. Optional for backward compat with older entries.
    var moonshineText: String? = nil
    /// Raw Parakeet ASR before TextFormatter ran — the actual speech recognizer output.
    /// Stored to let the pipeline view show all 3 stages: ASR → Formatter → Polish.
    var parakeetRawText: String? = nil
    /// Low-confidence words flagged by Parakeet's per-token confidence scoring.
    /// Passed to Qwen3 as hints; shown in the pipeline view.
    var parakeetSuspects: [String]? = nil
    /// Recording duration in seconds. Optional for back-compat with older entries
    /// captured before this field existed. Used by the BigMenu stats row to
    /// compute words-per-minute over recent dictations.
    var durationSeconds: Int? = nil
    /// Number of spoken punctuation/formatting commands the TextFormatter
    /// converted to characters (period, comma, new line, exclamation, etc.).
    /// Surfaced as "fixes made by voice" in the BigMenu stats row.
    // NOTE: BigMenuWindow's computeStats() should sum `polishFixCount` (not
    // `voiceCommandCount`) for the "fixes by voice" stat card. Keep this field
    // around for back-compat but the UI now prefers polishFixCount.
    var voiceCommandCount: Int? = nil
    /// Number of fix-events the polish stage applied (spelling/capitalization/grammar/filler).
    /// Computed by diffing raw → polished at finishRecording time.
    var polishFixCount: Int? = nil
    /// Cleanup level the polish stage was running on when this dictation was captured.
    /// Optional for back-compat with older entries. Display value: "None" / "Light" / "Medium" / "High".
    var cleanupLevelUsed: String? = nil
    /// Personality preset in effect when the polish ran. "Neutral" / "Formal" / "Casual" / "Excited".
    var personalityStyleUsed: String? = nil
    /// Engine that actually polished this dictation. Tagged by Qwen3Polisher
    /// during polish so the history view can show "Cloud (Qwen 235B)" vs
    /// "Local (Qwen3 4B)". Optional for back-compat with older entries.
    /// Format: "cloud:qwen-3-235b" / "local:qwen3-4b" / "local:qwen3-1.7b" / "rules-only"
    var polishEngine: String? = nil
    /// True when this dictation was CANCELLED rather than committed. Cancelled
    /// dictations are retained (audio kept on disk, transcript saved) but were
    /// never pasted at the cursor and were not fully polished. Optional /
    /// defaults false for back-compat with older entries.
    var cancelled: Bool = false
    /// On-disk path to the retained .caf audio for this dictation. Populated for
    /// cancelled dictations so the user can recover / re-process the recording
    /// from History. Optional for back-compat with older entries (committed
    /// dictations don't set this — their audio is referenced via the Meeting row).
    var audioFilePath: String? = nil
    var deletedAt: Date? = nil
    var id: String { "\(timestamp.timeIntervalSince1970)" }

    /// True when raw differs meaningfully from polished — i.e. polish actually
    /// changed something. Used by the UI to decide whether to show a compare
    /// affordance.
    var hasPolishDiff: Bool {
        guard let raw = rawText else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when we have a raw transcript to show, regardless of whether
    /// polish changed anything. Used to enable the "show raw" affordance
    /// on every entry that has the pre-polish text available.
    var hasRawText: Bool {
        guard let raw = rawText else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

fileprivate extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

enum RecentDictations {
    private static let key = "recentDictations"
    private static let limit = 100

    /// File at ~/Library/Application Support/Voice/recent_dictations.json.
    /// Mirrors the pattern used by StorageService / Telemetry.
    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let voiceDir = appSupport.appendingPathComponent("Voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        return voiceDir.appendingPathComponent("recent_dictations.json")
    }

    /// Read items from disk. On first run, migrate any legacy UserDefaults
    /// blob to the new file and delete the old key.
    static func all() -> [RecentDictation] { stored().filter { $0.deletedAt == nil } }

    static func retainingHistory(_ items: [RecentDictation], now: Date) -> [RecentDictation] {
        items.filter { $0.deletedAt.map { now.timeIntervalSince($0) < 7 * 24 * 3600 } ?? true }
    }

    static func trash(now: Date = Date()) -> [RecentDictation] {
        stored().filter { item in
            item.deletedAt.map { now.timeIntervalSince($0) < 7 * 24 * 3600 } ?? false
        }
    }

    static func restore(id: String) {
        var items = stored()
        guard let index = items.firstIndex(where: { $0.id == id }),
              trash().contains(where: { $0.id == id }) else { return }
        items[index].deletedAt = nil
        save(items)
    }

    private static func stored() -> [RecentDictation] {
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let items = try JSONDecoder().decode([RecentDictation].self, from: data)
                let retained = retainingHistory(items, now: Date())
                if retained.count != items.count { save(retained) }
                return retained
            } catch {
                NSLog("[VOICE-STORAGE] failed to read recent_dictations.json: \(error)")
                return []
            }
        }
        // No file yet — try migrating from UserDefaults.
        if let legacy = UserDefaults.standard.data(forKey: key),
           let items = try? JSONDecoder().decode([RecentDictation].self, from: legacy) {
            do {
                let encoded = try JSONEncoder().encode(items)
                try encoded.write(to: url, options: .atomic)
                UserDefaults.standard.removeObject(forKey: key)
                NSLog("[VOICE-STORAGE] migrated \(items.count) dictations from UserDefaults to file")
            } catch {
                NSLog("[VOICE-STORAGE] migration write failed: \(error)")
            }
            return items
        }
        return []
    }

    /// Write items to disk, silently swallowing errors after logging.
    private static func save(_ items: [RecentDictation]) {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[VOICE-STORAGE] failed to write recent_dictations.json: \(error)")
        }
    }

    /// Back-compat single-text add — used by code paths that don't know the
    /// pre-polish version. Newer callers should use `add(raw:polished:)`.
    static func add(_ text: String) {
        add(raw: nil, polished: text)
    }

    /// Add a dictation with both the pre-polish formatted text and the final
    /// polished text. `raw` is optional — pass nil if polish was skipped /
    /// disabled / unchanged, and only the polished version will be stored.
    static func delete(id: String) {
        var items = stored()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].deletedAt = Date()
        save(items)
    }

    static func add(raw: String?, polished: String, pasteTargetBundleID: String? = nil, polishMs: Int? = nil,
                    granite: String? = nil, moonshine: String? = nil,
                    parakeetRaw: String? = nil, suspects: [String]? = nil,
                    durationSeconds: Int? = nil, voiceCommandCount: Int? = nil,
                    cleanupLevelUsed: String? = nil,
                    personalityStyleUsed: String? = nil,
                    polishFixCount: Int? = nil,
                    polishEngine: String? = nil,
                    cancelled: Bool = false,
                    audioFilePath: String? = nil) {
        let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let trimmedRaw = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Always persist `rawText` when it's non-empty (even when identical to
        // the polished version). The History UI uses `hasPolishDiff` to gate
        // the compare button — keeping `rawText` populated lets us surface
        // "polish was a no-op for this one" cleanly, and means users who want
        // to see the raw transcript always can.
        let rawForStorage: String? = {
            guard let r = trimmedRaw, !r.isEmpty else { return nil }
            return r
        }()
        var items = stored()
        items.insert(
            RecentDictation(text: trimmed, timestamp: Date(), rawText: rawForStorage,
                            pasteTargetBundleID: pasteTargetBundleID, polishMs: polishMs,
                            graniteText: granite?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                            moonshineText: moonshine?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                            parakeetRawText: parakeetRaw?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                            parakeetSuspects: (suspects?.isEmpty == false) ? suspects : nil,
                            durationSeconds: durationSeconds,
                            voiceCommandCount: voiceCommandCount,
                            polishFixCount: polishFixCount,
                            cleanupLevelUsed: cleanupLevelUsed,
                            personalityStyleUsed: personalityStyleUsed,
                            polishEngine: polishEngine,
                            cancelled: cancelled,
                            audioFilePath: audioFilePath),
            at: 0
        )
        let retainedTrash = items.filter { $0.deletedAt.map { Date().timeIntervalSince($0) < 7 * 24 * 3600 } ?? false }
        items = Array(items.filter { $0.deletedAt == nil }.prefix(limit)) + retainedTrash
        // Raw per-engine ASR alternatives are kept for every item: they are training data, and the 7-day trim
        // removed them (25 Nov 2026). The 100-item cap above still bounds the history.
        save(items)
    }

    /// Count distinct fix events between raw and polished text. A "fix event" is
    /// any contiguous run of words that differs between the two. This collapses
    /// e.g. "i think" → "I think" + "yeah" → "" into 2 fixes, not 2.5.
    static func countFixes(raw: String, polished: String) -> Int {
        let rawTokens = raw.lowercased().split(separator: " ").map(String.init)
        let polTokens = polished.lowercased().split(separator: " ").map(String.init)

        // Myers-lite: count edit runs via 2D LCS-style backtrack.
        let m = rawTokens.count
        let n = polTokens.count
        if m == 0 { return n > 0 ? 1 : 0 }
        if n == 0 { return 1 }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if rawTokens[i] == polTokens[j] {
                    dp[i+1][j+1] = dp[i][j] + 1
                } else {
                    dp[i+1][j+1] = max(dp[i][j+1], dp[i+1][j])
                }
            }
        }

        // Backtrack to count edit runs (contiguous mismatch streaks).
        var i = m, j = n
        var runs = 0
        var inMismatch = false
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && rawTokens[i-1] == polTokens[j-1] {
                if inMismatch { runs += 1; inMismatch = false }
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                inMismatch = true; j -= 1
            } else {
                inMismatch = true; i -= 1
            }
        }
        if inMismatch { runs += 1 }
        return runs
    }
}

// MARK: - Cleanup Level

enum CleanupLevel: String, CaseIterable, Identifiable {
    case none   = "none"
    case light  = "light"
    case medium = "medium"
    case high   = "high"

    var id: String { rawValue }

    /// The levels Settings offers. Medium is hidden until its own eval proves it (A3 of the plan).
    static var offered: [CleanupLevel] {
        let choice = UserDefaults.standard.string(forKey: "voice.cleanupModel")
        let selected = choice == WhisperNowTunedPolisher.settingValue || choice == WhisperNowTunedPolisher.legacySettingValue
            || (choice == nil && WhisperNowTunedPolisher.isDefaultEngine) || GeneralCleanupModel.isGeneralChoice(choice)
        return selected && WhisperNowTunedPolisher.supportsCleanupControls ? [.none, .light, .medium] : [.none, .light]
    }

    var displayName: String {
        switch self {
        case .none:   return "Off"
        case .light:  return "Light"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    var settingsDescription: String {
        switch self {
        case .none:   return "Your words as spoken. Only spoken commands apply."
        case .light:  return "Removes filler words and fixes capitals."
        case .medium: return "Edits for clarity and punctuation."
        case .high:   return "Rewrites for clarity."
        }
    }

    var tagline: String {
        switch self {
        case .none:    return "Transcribes exactly what you said, including mistakes"
        case .light:   return "Cleans up filler words and grammar"
        case .medium:  return "Edits for clarity and conciseness"
        case .high:    return "Rewrites for brevity and polish"
        }
    }

    var example: (before: String, after: String) {
        // Same raw dictation — shows exactly what each level removes or rewrites.
        let before = "um so like i was thinking maybe we could grab coffee tomorrow if you're free i mean only if you want"
        switch self {
        case .none:
            // Zero changes — exactly what was said, mistakes and all.
            return (before, "um so like i was thinking maybe we could grab coffee tomorrow if you're free i mean only if you want")
        case .light:
            // Strips um/uh, fixes punctuation. Keeps "like" and "i mean" — those are voice.
            return (before, "So like I was thinking maybe we could grab coffee tomorrow if you're free, I mean only if you want.")
        case .medium:
            // Removes fillers, cleans sentence. Word choice preserved.
            return (before, "I was thinking we could grab coffee tomorrow if you're free.")
        case .high:
            // Full rewrite to the clearest possible form of the intent.
            return (before, "Want to grab coffee tomorrow if you're free?")
        }
    }

    static var current: CleanupLevel {
        get {
            if let raw = UserDefaults.standard.string(forKey: "cleanupLevel"),
               let level = CleanupLevel(rawValue: raw) { return level == .none ? .none : .light }
            // Migration: old llmPolishEnabled bool (default was ON → medium)
            let wasEnabled = UserDefaults.standard.object(forKey: "llmPolishEnabled") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "llmPolishEnabled")
            return wasEnabled ? .light : .none
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "cleanupLevel") }
    }
}

// MARK: - Personality Style

/// The four styles, named as Wispr names them. Each one is a rule (StyleTransform), never a rewrite.
/// `neutral` is the old default. It is no longer offered and reads as `casual` (see `current`).
enum PersonalityStyle: String, CaseIterable, Identifiable {
    case neutral = "neutral"
    case formal  = "formal"
    case casual  = "casual"
    case veryCasual = "verycasual"
    case excited = "excited"

    var id: String { rawValue }

    /// The styles Settings offers, in order.
    static let offered: [PersonalityStyle] = [.formal, .casual, .veryCasual, .excited]

    var displayName: String {
        switch self {
        case .neutral, .casual: return "Casual"
        case .formal:  return "Formal"
        case .veryCasual: return "Very casual"
        case .excited: return "Excited"
        }
    }

    var settingsDescription: String {
        switch self {
        case .neutral, .casual: return "A capital at the start, no full stop at the end."
        case .formal:  return "Capitals and full stops. The words stay as you said them."
        case .veryCasual: return "All lower case, no full stops."
        case .excited: return "Ends on an exclamation mark."
        }
    }

    var tagline: String {
        switch self {
        case .neutral, .casual: return "Light caps, light punctuation"
        case .formal:  return "Capitals and full stops"
        case .veryCasual: return "All lower case"
        case .excited: return "Ends on an exclamation mark"
        }
    }

    var bubbleTint: Color {
        switch self {
        case .neutral, .casual: return Color.pink.opacity(0.10)
        case .formal:  return Color.purple.opacity(0.10)
        case .veryCasual: return Color.gray.opacity(0.12)
        case .excited: return Color.orange.opacity(0.12)
        }
    }

    var avatarTint: Color {
        switch self {
        case .neutral, .casual: return Color(red: 0.95, green: 0.65, blue: 0.78)
        case .formal:  return Color(red: 0.62, green: 0.55, blue: 0.95)
        case .veryCasual: return Color.gray
        case .excited: return Color(red: 0.95, green: 0.6,  blue: 0.35)
        }
    }

    /// The same cleaned dictation through each style, as the style pass leaves it.
    var example: (before: String, after: String) {
        let before = "Hey can u send maya a message saying we're running like really late."
        switch self {
        case .neutral, .casual:
            return (before, StyleTransform.apply(before, style: .casual))
        case .formal:
            return (before, StyleTransform.apply(before, style: .formal))
        case .veryCasual:
            return (before, StyleTransform.apply(before, style: .veryCasual))
        case .excited:
            return (before, StyleTransform.apply(before, style: .excited))
        }
    }

    static var current: PersonalityStyle {
        get {
            let raw = UserDefaults.standard.string(forKey: "personalityStyle") ?? "casual"
            // The old "neutral" default reads as Casual now.
            return PersonalityStyle(rawValue: raw).map { $0 == .neutral ? .casual : $0 } ?? .casual
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "personalityStyle") }
    }
}

// MARK: - My Style Level
//
// Four positions on the style-fidelity spectrum. Independent of personality
// presets — these control how tightly the model follows the user's Style Card.
// Only visible once a Style Card has been extracted.

enum MyStyleLevel: String, CaseIterable, Identifiable {
    case raw      = "raw"
    case light    = "light"
    case polished = "polished"
    case best     = "best"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw:      return "Raw You"
        case .light:    return "Light You"
        case .polished: return "Polished You"
        case .best:     return "Best You"
        }
    }

    var tagline: String {
        switch self {
        case .raw:      return "Audio cleanup only"
        case .light:    return "Grammar, your voice"
        case .polished: return "Full polish, still you"
        case .best:     return "Your best writing day"
        }
    }

    /// Injected into the cloud system prompt when My Style is active.
    /// Controls how tightly the model matches the Style Card vs. elevating prose.
    var fidelityInstruction: String {
        switch self {
        case .raw:
            return "STYLE FIDELITY: exact. Preserve every quirk, rhythm, and characteristic phrase from the Style Card. Fix only audio artifacts — nothing else."
        case .light:
            return "STYLE FIDELITY: close. Smooth grammar and run-ons only. Keep the speaker's exact cadence, slang, and characteristic phrases from the Style Card."
        case .polished:
            return "STYLE FIDELITY: primary. The Style Card is your main voice guide. Full editorial cleanup allowed. Mild elevation OK where it strengthens clarity."
        case .best:
            return "STYLE FIDELITY: card-informed. Quality and precision first. The Style Card defines character and voice — let the prose be its best possible form."
        }
    }

    var example: (before: String, after: String) {
        let before = "hey so um i was thinking we should probably push that deadline back a little"
        switch self {
        case .raw:
            return (before, "hey so i was thinking we should probably push that deadline back a little")
        case .light:
            return (before, "Hey, I was thinking we should probably push that deadline back a little.")
        case .polished:
            return (before, "Hey, I think we should push that deadline back a bit.")
        case .best:
            return (before, "I think we should push the deadline back — worth flagging now.")
        }
    }

    static var current: MyStyleLevel {
        get {
            let raw = UserDefaults.standard.string(forKey: "myStyleLevel") ?? "polished"
            return MyStyleLevel(rawValue: raw) ?? .polished
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "myStyleLevel") }
    }
}

// MARK: - Polish Preset

/// Polish-in-place presets. Independent of dictation cleanup and personality.
/// Used when the user selects existing text and triggers the polish hotkey (or
/// dot-tap). Always routes through Cerebras cloud — the 235B model does the
/// prose editing work.
enum PolishPreset: String, CaseIterable, Identifiable {
    case fix     = "fix"
    case smooth  = "smooth"
    case elevate = "elevate"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fix:     return "Fix"
        case .smooth:  return "Smooth"
        case .elevate: return "Elevate"
        }
    }

    var tagline: String {
        switch self {
        case .fix:     return "Grammar and punctuation only"
        case .smooth:  return "Improve flow, keep your voice"
        case .elevate: return "Tighten and professionalize"
        }
    }

    var example: (before: String, after: String) {
        let before = "hey so i was thinking we should maybe push that meeting to thursday it would be easier"
        switch self {
        case .fix:
            return (before,
                "Hey so I was thinking we should maybe push that meeting to Thursday, it would be easier.")
        case .smooth:
            return (before,
                "I was thinking we should push the meeting to Thursday. It'd be easier.")
        case .elevate:
            return (before,
                "I'd suggest moving the meeting to Thursday. It would work better.")
        }
    }

    static var current: PolishPreset {
        get {
            let raw = UserDefaults.standard.string(forKey: "polishPreset") ?? "smooth"
            return PolishPreset(rawValue: raw) ?? .smooth
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "polishPreset") }
    }
}

// Coalesce overlapping detector reports into one notice while any source is active.
struct MeetingDetectionNoticeGate {
    private(set) var sources: Set<String> = []
    mutating func begin(_ source: String) -> Bool {
        let shouldNotify = sources.isEmpty
        let inserted = sources.insert(source).inserted
        return inserted && shouldNotify
    }
    mutating func end(_ source: String) { sources.remove(source) }
    mutating func reset() { sources.removeAll() }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var flowIsYielding = false
    private var flowRecoveryTask: Task<Void, Never>?
    private var meetingNoticeGate = MeetingDetectionNoticeGate()
    private var meetingDetectorsRunning = false
    var statusItem: NSStatusItem?
    var overlayPanel: OverlayPanel?
    /// Set for the one lock that a pill click causes, so its lock cue is skipped.
    var lockStartedByClick = false
    let recordingState = RecordingState()
    lazy var coordinator: RecordingCoordinator = {
        let coordinator = RecordingCoordinator(state: recordingState)
        // Dictation never mutes output while a meeting is being recorded.
        coordinator.isMeetingCaptureActive = { [weak self] in
            self?.meetingCaptureService.isCapturing ?? false
        }
        return coordinator
    }()
    private lazy var meetingCaptureService: MeetingCaptureService = {
        MeetingCaptureService(transcriptionEngine: coordinator.transcription)
    }()
    // meetingSummarizer removed — meetings are stored as raw transcripts only.
    // Summarization / AI post-processing happens externally when needed.
    /// Local HTTP server on port 59423 that receives signals from the
    /// "Voice Meet Bridge" Chrome extension. Much more reliable than the
    /// AX-based window-title polling which breaks when Voice is frontmost.
    private let meetBridgeServer = MeetBridgeServer()
    /// Native-call-app detector (Discord, Zoom, Teams, Slack huddles, FaceTime,
    /// WhatsApp, Telegram). Polls SCShareableContent + CoreAudio mic-in-use
    /// every 2s and fires `onCallStateChange` with grace-debounced transitions.
    /// Complements the Chrome bridge for users who aren't on Meet/Zoom-web.
    private let callAppDetector = CallAppDetector()

    // MARK: - Meeting auto-detection master kill switch
    //
    // When `voice.disableMeetingDetection` is true in UserDefaults, ALL
    // automated meeting capture paths are torn down: CallAppDetector is never
    // started (no SCShareableContent calls at all), the Chrome bridge's
    // auto-start is short-circuited, and the .voiceAutoStartMeeting
    // notification is ignored. The user can still manually start a meeting
    // capture from the UI; this only disables the *automatic* triggers that
    // were causing the orange screen-recording indicator to light up
    // unexpectedly during plain dictation.
    //
    // Default: false (auto-detection enabled). UI toggle is wired separately
    // in BigMenuWindow.swift; this file only exposes the storage key and the
    // gate logic.
    static let kDisableMeetingDetectionKey = "voice.disableMeetingDetection"
    static var isMeetingDetectionDisabled: Bool {
        UserDefaults.standard.bool(forKey: kDisableMeetingDetectionKey)
    }
    /// Meeting resilience: orphan WAV recovery on launch, per-30s draft
    /// checkpoint during capture, and a re-transcribe-from-audio path that
    /// can rebuild a transcript from any meeting's saved WAV file.
    lazy var meetingRecovery: MeetingRecoveryService = MeetingRecoveryService(
        storage: coordinator.storage,
        transcription: coordinator.transcription
    )
    /// 30-second draft-checkpoint timer for the live meeting. Cancelled in stopMeetingCapture.
    private var meetingDraftCheckpointTask: Task<Void, Never>?
    private var meetingStartTask: Task<Void, Never>?
    private var meetingStopping = false
    /// True while a saved dictation is being transcribed again for Companion.
    fileprivate var flowRetryInProgress = false
    private var meetingAudioImportInProgress = false
    private var meetingStartupSucceeded = false
    /// 15-second grace timer that fires when MeetBridge reports the call is
    /// still active but no other participants remain. Cancelled if anyone
    /// re-joins, or in stopMeetingCapture().
    private var meetingParticipantsLeftTask: Task<Void, Never>?
    private let hotkeyService = HotkeyService()
    private let textFormatter = TextFormatter()
    private let cursorPaster = CursorPaster()

    private var cancelDismissTask: Task<Void, Never>?
    private var undoPasteDismissTask: Task<Void, Never>?
    // Each finishRecording() spawns its OWN independent Task. We do NOT cancel
    // prior in-flight finish tasks when a new recording starts — the user's
    // dictation must reach the cursor even if they re-pressed the hotkey
    // before the prior pipeline finished pasting. The only legitimate cancel
    // path is app shutdown (and we just let those drop on the floor).
    private let dictationWork = DictationWorkRegistry()
    // Serializes paste tail-segments so back-to-back completed transcripts
    // land at the cursor in chronological arrival order without trampling
    // each other's clipboard / synthesized-keystroke state. Each finish task
    // appends its paste step to this chain.
    private var pasteChain: Task<Void, Never>?
    // The in-flight Opt+1 polish-selection task. Stored so cancelInFlightProcessing
    // can cancel it — otherwise an ESC can't stop a polish that's about to mutate
    // the user's selected text after they cancelled.
    private var polishSelectionTask: Task<Void, Never>?
    /// Identifies the latest Opt+1 operation. A cancelled or finished polish only touches shared state
    /// while it is still the current one, so an old task can never clear a newer polish's flags
    /// (sol/01 finding 1).
    private var polishGate = OperationGate()
    private var quickPolishTimingHistory = QuickPolishTiming.History()
    /// The last applied Opt+1 polish, for Undo and Try again (one step only).
    private var lastPolish: LastPolish?
    private var lastPolishEvidenceID: UUID?
    /// The run records (FlowRunLog) of the last dictation and the last Opt+1, for their follow-up lines.
    private var lastDictationRunID: String?
    private var lastPolishRunID: String?
    private var bigMenuWindow: NSWindow?
    private var speechSettingsWindow: NSPanel?
    // Floor for "this is too short to bother transcribing". The hotkey state
    // machine has its own short-tap gate at 0.35s and only fires deactivate
    // for legitimate holds, so this is purely belt-and-suspenders against
    // tiny lock-exit recordings (lock entered, immediately third-tapped).
    // 0.15s comfortably distinguishes real speech from a button bounce while
    // never rejecting a borderline-threshold PTT release after dispatch jitter.
    private let minRecordingDuration: TimeInterval = 0.15
    private var recordingStartedAt: Date?

    /// Bundle identifier of whatever app was frontmost when the user
    /// triggered recording. Re-activated before paste so the transcript
    /// lands where the user expects — even if focus shifted in the interim
    /// (e.g., the user used System Settings to grant Accessibility, then
    /// pressed the hotkey without re-clicking their target app).
    @ObservationIgnored private var targetAppBundleID: String?
    @ObservationIgnored private var rollingContextTarget: CursorPaster.PasteTargetSnapshot?

    /// Saved personality style from before an auto-personality override.
    /// When `voice.autoPersonality` is on and a frontmost app maps to a
    /// specific personality, we stash the user's real preference here and
    /// restore it after the dictation is pasted so the user's setting is
    /// never permanently changed.
    @ObservationIgnored private var previousPersonality: String? = nil

    /// Text-field context (chars immediately before cursor) sampled at the
    /// moment recording starts. We read at start (not paste) because that's
    /// when the user's target field reliably owns AX focus — by paste time,
    /// toast popups or other UI may have stolen focus and given us a stale
    /// or empty read. The polisher uses this to make smart spacing /
    /// punctuation / number-formatting decisions relative to existing text.
    @ObservationIgnored private var capturedFieldContext: String?

    /// The field that `capturedFieldContext` was read from. At finish, the context is
    /// re-read only while focus is still on this same element, so text he typed during
    /// the dictation reaches the polisher. Otherwise the start-of-recording sample stands.
    @ObservationIgnored private var capturedFieldTarget: CursorPaster.PasteTargetSnapshot?

    /// Rich app context (window title, focused element role, placeholder text)
    /// sampled at recording-start alongside `capturedFieldContext`. This becomes
    /// the `appContextLabel` passed to the cloud polisher — it's far richer than
    /// the static bundle-ID→string map (`Qwen3Polisher.appContextLabel`) because
    /// it includes WHICH Slack channel, WHAT email subject, or WHICH file in
    /// Xcode. The cloud model uses this to pick register, length, and format.
    /// Built by `buildEnrichedAppContextLabel(...)` and consumed at polish time.
    @ObservationIgnored private var capturedRichAppContext: String?

    // Permission-prompt throttling. macOS shows the system "grant access"
    // dialog every time AXIsProcessTrustedWithOptions(prompt: true) is called
    // — pressing the hotkey 40 times yields 40 dialogs. Track per-session so
    // we ask exactly once, then route the user to System Settings.
    private var didShowAXPrompt = false
    private var didShowMicPrompt = false
    private var didShowSRPrompt = false
    private var permissionWatcherTimer: Timer?
    /// 0.5Hz safety tick — clears a stuck `pendingRecordingStart` if it sits
    /// true with no corresponding `isRecording` for more than 2 seconds (e.g.
    /// audio engine failed to spin up, or the user released during spin-up
    /// and the release handler somehow missed clearing it). Without this,
    /// the pill latches in .recording forever (see 5.1).
    private var pendingPillSafetyTimer: Timer?
    private var lastObservedAXTrusted: Bool = AXIsProcessTrusted()

    // Polished-app extras
    private var errorToastWindow: NSPanel?

    /// Throttles model-not-ready toasts so a held key doesn't spam.
    private var lastModelReadyToastAt: Date?
    private var errorDismissTask: Task<Void, Never>?
    private var onboardingWindow: NSPanel?
    private var errorObserver: NSObjectProtocol?
    /// Set true once `applicationDidFinishLaunching` has run far enough that any
    /// further `applicationShouldHandleReopen` is a genuine USER reopen (Dock
    /// click / re-launch of the running app) rather than the spurious reopen
    /// macOS delivers at launch — notably for launch-at-login. We use this to
    /// stop the app from opening its window + stealing focus on its own at
    /// startup. Flipped true at the very end of didFinishLaunching.
    private var didFinishLaunchingComplete = false
    /// Non-nil only in shadow mode (voice.shadowMode).
    /// Then nothing else in this delegate is started: no pill, hotkey, sounds or paste.
    private var shadowController: ShadowModeController?
    /// All block-based NotificationCenter observers we register. We hold the
    /// tokens so `applicationWillTerminate` can remove every one — previously
    /// only `errorObserver` got cleaned up, leaving the didBecomeActive +
    /// voiceOpenBigMenu observers as zombies if the
    /// process is ever re-spawned in the same address space (tests, hot reload).
    private var notificationTokens: [NSObjectProtocol] = []

    /// In-memory final text of the last successful dictation, for Control+Command+V.
    /// Written only in the dictation finish path, right where finalText is decided.
    private var lastTranscript = LastTranscriptStore()
    private var pasteRecoveryID = UUID()

    /// Observers registered on `NSWorkspace.shared.notificationCenter` (sleep /
    /// wake). These live on a DIFFERENT center than `notificationTokens`, so
    /// they must be removed from the workspace center in `applicationWillTerminate`
    /// — mixing them into `notificationTokens` would leak them (removeObserver on
    /// the default center is a silent no-op for workspace tokens).
    private var workspaceTokens: [NSObjectProtocol] = []

    /// Meeting ID handed off from a "Transcript ready" notification click. Picked
    /// up by BigMenuWindow on first appearance (and via .onReceive for the
    /// already-open case) so the row is pre-expanded + scrolled into view.
    static var pendingMeetingIDFromNotification: String? = nil

    // (Previously used to swallow a deactivate after lock-exit, but the new
    // state machine doesn't fire deactivate on lock exit, so the flag was a
    // footgun — once set on lock exit, it stayed true and silently killed
    // every subsequent PTT release. Removed.)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bound every Accessibility call to a short wait, so a slow app cannot stall dictation.
        AccessibilityBudget.installProcessDefault()
        // Whenever Companion is not running, the Mac's own screenshot shortcuts are back (Companion crash included).
        ScreenshotShortcutGuard.start()
        // Earcons are rendered and the sound engine is started now, so the first cue is not late.
        SoundEffects.prewarm()
        // Opt+1 must never meet a cold model: warm it shortly after launch and after every wake.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            await Qwen3Polisher.shared.prewarmQuickPolish()
            // The dictation model picked in Companion loads now too, so the first dictation does not fall to DOSE1.
            if Qwen3Polisher.isEnabled { await GeneralCleanupModel.shared.prepare() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                await Qwen3Polisher.shared.prewarmQuickPolish()
                if Qwen3Polisher.isEnabled { await GeneralCleanupModel.shared.prepare() }
            }
        }
        // Switched off in Companion: a login item or a stray launch must not show the pill,
        // unless shadow mode is on. Then Flow runs invisibly beside Wispr Flow and
        // nothing below (pill, hotkey, paste, meetings, Companion commands) is started.
        switch FlowLaunchGate.decide(defaults: .standard) {
        case .quit:
            Telemetry.log("app.disabled_exit", properties: [:])
            NSApp.terminate(nil)
            return
        case .shadow:
            Telemetry.log("app.shadow_mode_launch", properties: [:])
            let controller = ShadowModeController()
            shadowController = controller
            controller.start()
            return
        case .normal:
            break
        }
        FlowOwnership.shared.observeCompetitors { [weak self] in
            guard let self else { NSApp.terminate(nil); return }
            self.flowIsYielding = true
            if self.recordingState.flowNotice?.recoveryText != nil { self.recordingState.flowNotice = nil }
            self.hotkeyService.stopMonitoring()
            self.flowRecoveryTask?.cancel()
            self.meetingStartTask?.cancel()
            self.permissionWatcherTimer?.invalidate()
            self.pendingPillSafetyTimer?.invalidate()
            self.callAppDetector.stop()
            self.meetBridgeServer.stop()
            WakeWordService.shared.disable()
            self.recordingState.sessionCancelled = true
            self.recordingState.pendingRecordingStart = false
            // Keep captured files intact. No transcription or automatic paste on handoff.
            if let capture = self.coordinator.claimRecordingSync() {
                capture.startupTask?.cancel()
                self.coordinator.audioCapture.stopWritingToFile()
                FlowOwnership.shared.retainRecoveryReference(capture.audioURL)
            }
            self.dictationWork.cancelAll()
            self.recordingState.transcribingCount = self.dictationWork.activeCount
            self.coordinator.restoreOutputAudio()
            if self.recordingState.isCapturingMeeting || self.meetingStartTask != nil {
                if self.recordingState.isCapturingMeeting { self.checkpointMeetingDraft() }
                self.stopMeetingCapture(reason: "ownershipConflict")
            }
            Task { @MainActor in
                // Let the existing meeting finalizer drain accepted audio before exit.
                while self.meetingStopping { try? await Task.sleep(nanoseconds: 100_000_000) }
                await self.flowRecoveryTask?.value
                NSApp.terminate(nil)
            }
        }

        guard !flowIsYielding else { return }
        WisprPersonalizationProfile.load()?.applyInitialPreferences(to: .standard)
        WisprPersonalizationProfile.importPreparedDictionary(defaults: .standard)
        Task { await WisprImportService.refreshVocabulary() }
        print("[VOICE-ICON] startup: bundlePath=\(Bundle.main.bundlePath)")
        print("[VOICE-ICON] startup: bundleId=\(Bundle.main.bundleIdentifier ?? "<nil>")")

        // Learn-from-correction: when the user fixes a misheard word right
        // after a paste, surface a short "Added 'X'" pill. The learner already
        // persists the term to the boosted vocabulary (ASR + polish).
        CorrectionLearner.shared.onWordLearned = { [weak self] word in
            self?.showToast("Added \u{2018}\(word)\u{2019}")
        }

        // ONE-TIME MIGRATION (V2): force meeting auto-detection OFF for existing
        // installs. The default for `voice.enableMeetingDetection` is now false,
        // but a user who ran an earlier build may have it explicitly stored as
        // `true` in UserDefaults — they'd keep getting auto screen-audio capture
        // (and the orange screen-recording indicator) at idle. Run exactly once,
        // guarded by `voice.meetingDetectionMigratedV2`, to bring those installs
        // to the safe default. The user can still re-enable it from Settings
        // afterward (we only flip the stored value once; the toggle remains live).
        let migratedKey = "voice.meetingDetectionMigratedV2"
        if !UserDefaults.standard.bool(forKey: migratedKey) {
            UserDefaults.standard.set(false, forKey: "voice.enableMeetingDetection")
            UserDefaults.standard.set(true, forKey: migratedKey)
            print("[VOICE-MIGRATE] meetingDetectionMigratedV2: forced voice.enableMeetingDetection=false (one-time)")
        }

        // One-time: force wake word OFF. Always-on wake word runs a continuous
        // speech recognizer that nudges the system's now-playing media app
        // (the "music starts on its own" bug). It had also re-enabled itself
        // with the catastrophic default phrase "voice" (said constantly). Force
        // it off once; if a user truly wants it they re-enable from Settings.
        let wakeWordMigratedKey = "voice.wakeWordForcedOffV1"
        if !UserDefaults.standard.bool(forKey: wakeWordMigratedKey) {
            UserDefaults.standard.set(false, forKey: "voice.wakeWordEnabled")
            UserDefaults.standard.set("off", forKey: "voice.wakeWordMode")
            // Repair the insane "voice" default so any future enable is sane.
            if (UserDefaults.standard.string(forKey: "voice.wakeWordPhrase") ?? "").lowercased() == "voice" {
                UserDefaults.standard.set("hey voice", forKey: "voice.wakeWordPhrase")
            }
            UserDefaults.standard.set(true, forKey: wakeWordMigratedKey)
            print("[VOICE-MIGRATE] wakeWordForcedOffV1: forced wake word OFF (one-time)")
        }

        // Seed the user's own name (used to filter "Jordan" out of the
        // participant list so meeting titles don't include the local user).
        // No UI yet — power users can override via `defaults write`.
        let existingUserName = UserDefaults.standard.string(forKey: "voice.userName") ?? ""
        if existingUserName.trimmingCharacters(in: .whitespaces).isEmpty {
            UserDefaults.standard.set("Jordan", forKey: "voice.userName")
        }

        // Orphan-meeting recovery: any WAV files on disk whose path isn't
        // referenced from a DB row are crash survivors. Import them as
        // placeholder Meeting rows so the user can find + re-transcribe them
        // instead of silently leaking. Runs after a 1.5s delay so the storage
        // layer has time to finish its own initialize/migrate pass.
        flowRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, !self.flowIsYielding else { return }
            // Preserve all existing meetings and recordings on startup.
            let orphans = self.meetingRecovery.discoverOrphanedMeetingAudio()
            // Recover saved meeting audio without guessing its category from length.
            var importedCount = 0
            var recoveredRecordingID: UUID?
            let savedAudioPaths = Set(self.coordinator.fetchAllMeetings().compactMap(\.audioFilePath))
            // Keep interrupted dictations visible without running recognition at launch.
            for retained in FlowOwnership.shared.retainedRecordings() {
                guard !Task.isCancelled, !self.flowIsYielding else { return }
                if savedAudioPaths.contains(retained.audioURL.path) { continue }
                let recovered = Meeting(id: retained.id, title: "Recovered dictation", date: retained.date,
                    duration: 0, segments: [], audioFilePath: retained.audioURL.path,
                    kind: .dictation, sourceApp: "Flow")
                if self.saveMeetingToStorage(recovered) { importedCount += 1; recoveredRecordingID = recovered.id }
            }

            for orphan in orphans {
                guard !Task.isCancelled, !self.flowIsYielding else { return }
                let repairedPath = orphan.audioFileURL.deletingLastPathComponent()
                    .appendingPathComponent("repair-" + orphan.audioFileURL.lastPathComponent).path
                if savedAudioPaths.contains(repairedPath) { continue }
                if self.meetingRecovery.importOrphan(orphan) { importedCount += 1; recoveredRecordingID = orphan.id }
            }
            if importedCount > 0 {
                self.fetchMeetingsIntoState()
                self.recordingState.flowNotice = FlowPillNotice(kind: .recoveredAudio,
                    message: "Recovered \(importedCount) recording\(importedCount == 1 ? "" : "s"). Your audio is saved in History.",
                    recordingID: importedCount == 1 ? recoveredRecordingID : nil)
            }

            // Title cleanup: meetings whose row was checkpointed mid-recording
            // but never properly finalized end up titled "Live meeting (in
            // progress) — …" or "Recording — …" forever. Rewrite those to a
            // clean human-readable form derived from the date + duration.
            self.cleanUpStaleMeetingTitles()

            // Try to repair any WAV files whose header is broken (Voice was
            // killed mid-write — the RIFF chunk size is still 0, so the file
            // says "I have 0 bytes of audio" even though the data section is
            // many megabytes). We rewrite a valid header so the audio is
            // actually decodable before the auto-transcribe pass tries it.
            await self.repairBrokenWAVHeaders()
            guard !Task.isCancelled, !self.flowIsYielding else { return }

            // Empty-meeting auto-recovery: re-transcribe any meeting where
            // audio is on disk but the segments table is empty. This catches
            // meetings broken by the pre-build-35 worker-respawn bug where
            // chunks 2..N silently dropped. Wait for the transcription engine
            // to be ready before kicking off, so we don't race coordinator.prepare().
            while !self.coordinator.transcription.isReady {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
            }
            let allMeetings = self.coordinator.fetchAllMeetings()
            let toFix = allMeetings.filter { m in
                let exists = m.audioFilePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                return DictationRecoveryRules.needsAutoRetranscribe(m, audioFileExists: exists)
            }
            guard !toFix.isEmpty else { return }
            print("[VOICE-RECOVERY] auto-retranscribe: \(toFix.count) empty meetings have audio on disk")
            self.showToast("Re-transcribing \(toFix.count) meeting\(toFix.count == 1 ? "" : "s") with missing transcripts…")
            var successCount = 0
            for m in toFix {
                guard !Task.isCancelled, !self.flowIsYielding else { return }
                if await self.meetingRecovery.retranscribe(meeting: m) != nil {
                    successCount += 1
                }
            }
            self.fetchMeetingsIntoState()
            self.showToast("Recovered transcripts for \(successCount) of \(toFix.count) meetings.")
            // System notification for the case where Voice ran the recovery
            // silently in the background and the user hasn't opened BigMenu.
            if successCount > 0 {
                MeetingNotifier.notify(
                    title: "Meeting transcripts ready",
                    body: "\(successCount) meeting\(successCount == 1 ? "" : "s") finished transcribing.",
                    meetingId: nil
                )
            }
        }

        // Stay as a menu-bar-only agent by default — dock icon appears only
        // while BigMenu is open. This lets Voice launch at login silently
        // so meeting capture is always running without user intervention.
        // (LSUIElement=true in Info.plist already starts us as .accessory;
        // we keep it that way and only flip to .regular in openBigMenu.)

        // Surface cloud polish failures (timeout / rate-limit / network) so the
        // user knows when we silently fell back to the local model. Toast is
        // throttled inside Qwen3Polisher to avoid spamming on rate-limit bursts.
        let cloudFallbackToken = NotificationCenter.default.addObserver(
            forName: .voiceCloudFellBackToLocal,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?["reason"] as? String) ?? "network issue"
            self?.showToast("Cloud unreachable (\(reason)) — using local model.")
        }
        notificationTokens.append(cloudFallbackToken)

        // LIFECYCLE SIGNALS: system sleep/wake. Previously unobserved — a
        // recording in flight when the lid closed left the audio engine in an
        // undefined state on wake (the AVAudioEngine input node can come back
        // detached after a sleep cycle). On sleep we defensively finish any
        // active recording so its audio is flushed to disk rather than lost;
        // on wake we emit a snapshot so the JSONL log shows the engine's state
        // at the moment dictation might next be attempted.
        let ws = NSWorkspace.shared.notificationCenter
        let sleepToken = ws.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Telemetry.signal("lifecycle.sleep", recordingState.isRecording ? "recording_active" : "idle")
            // Flush an in-flight recording so sleep can't strand its audio file.
            if self.recordingState.isRecording {
                self.finishRecording()
            }
        }
        workspaceTokens.append(sleepToken)
        let wakeToken = ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Telemetry.signal("lifecycle.wake")
            self.emitDebugSnapshot(reason: "wake")
        }
        workspaceTokens.append(wakeToken)

        // Belt-and-suspenders: re-assert at 0.1 s (before Dock finishes its first
        // cache write) and again at 1.5 s (after any post-launch Dock refresh).
        // Wrap startup tasks individually so one failure doesn't tank launch.
        runStartupStep("menu_bar") { self.setupMenuBar() }
        runStartupStep("overlay_panel") { self.setupOverlayPanel() }
        runStartupStep("hotkey") { self.setupHotkey() }
        runStartupStep("wake_word") { self.setupWakeWord() }
        runStartupStep("error_observer") { self.setupErrorObserver() }
        // Companion's remote control and the status Flow sends back.
        runStartupStep("flow_commands") { FlowCommandListener.shared.start(host: self) }
        runStartupStep("launch_at_login_sync") { LaunchAtLoginService.syncFromStorage() }
        runStartupStep("notification_auth") { MeetingNotifier.requestAuthIfNeeded() }
        // Wire the UN delegate BEFORE any notification can land so taps on
        // "Transcript ready" banners are routed back into BigMenu instead of
        // being silently swallowed.
        runStartupStep("notification_delegate") {
            UNUserNotificationCenter.current().delegate = MeetingNotifier.delegate
        }

        // Run the same throttled permission check at launch so first-time
        // users get the prompt + System Settings deep-link immediately
        // (instead of having to press the hotkey first to discover the
        // gate). Once granted, the watcher rebinds monitors automatically.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micOk = micStatus == .authorized
        let axOk = AXIsProcessTrusted()
        Telemetry.log("permissions.startup", properties: ["microphone": micOk, "accessibility": axOk])
        // Screen Recording is needed for meeting capture. CGPreflightScreenCaptureAccess
        // is a non-prompting check — pairs with the same handleMissingPermissions
        // chain as mic/AX so the user gets a one-shot toast + privacy pane deep-link.
        let srOk = CGPreflightScreenCaptureAccess()
        if !micOk || !axOk || !srOk {
            handleMissingPermissions(micOk: micOk, axOk: axOk, srOk: srOk, micStatus: micStatus)
        }

        Task { await coordinator.prepare() }

        // Load persisted meetings into UI state at launch. Goes through the
        // single fetch funnel so `meetingsLoadState` flips loading → loaded
        // (or → .error) and the BigMenuWindow Meetings tab can show a
        // skeleton on first frame instead of momentarily flashing the empty
        // state.
        fetchMeetingsIntoState()

        // Crash recovery — if a meeting was in progress when the app or computer
        // died, its segments were checkpointed to UserDefaults every 5 minutes.
        // Recover them now as an unsummarized meeting so nothing is lost.
        recoverCrashedMeetingIfNeeded()

        // Start the Chrome extension bridge server. The "Voice Meet Bridge"
        // extension POSTs to localhost:59423 when entering/leaving a meeting.
        // This replaces the fragile AX window-title polling approach.
        meetBridgeServer.onMeetActive = { [weak self] active, names in
            guard let self else { return }
            if active {
                // Capture participant names every time we hear "active=true",
                // even if we're already capturing — later notifications often
                // arrive after the participant tiles have rendered, so the
                // second / third message is the one that actually has names.
                if !names.isEmpty {
                    // Merge instead of overwrite: keep any names already seen
                    // this session (e.g. someone who left the call before the
                    // panel refreshed). Filtering of the local user happens
                    // later in `generateMeetingTitle`.
                    let existing = Set(self.recordingState.meetingParticipantNames)
                    let merged = self.recordingState.meetingParticipantNames + names.filter { !existing.contains($0) }
                    self.recordingState.meetingParticipantNames = merged
                    print("[MeetBridge] Captured participant names: \(merged)")
                    // Someone is on the call — cancel any pending participants-left
                    // grace timer.
                    if self.meetingParticipantsLeftTask != nil {
                        print("[MeetBridge] Participants returned — cancelling participants-left grace timer")
                        self.meetingParticipantsLeftTask?.cancel()
                        self.meetingParticipantsLeftTask = nil
                    }
                } else if self.recordingState.isCapturingMeeting,
                          !self.recordingState.meetingParticipantNames.isEmpty,
                          self.meetingParticipantsLeftTask == nil {
                    // Active=true but no other participants visible. If we had
                    // names before, the call has emptied out — schedule a 15s
                    // grace timer to handle brief reconnect blips. If we still
                    // see no one after the grace, stop the capture.
                    print("[MeetBridge] Participants dropped to 0 — scheduling 15s grace stop")
                    self.meetingParticipantsLeftTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        guard let self, !Task.isCancelled else { return }
                        guard self.recordingState.isCapturingMeeting else { return }
                        print("[MeetBridge] 15s grace elapsed with no participants — auto-stopping capture")
                        self.meetingParticipantsLeftTask = nil
                        self.stopMeetingCapture(reason: "participantsLeft")
                    }
                }
                guard !self.recordingState.isCapturingMeeting else { return }
                self.recordingState.isMeetingAppActive = true
                // Smart trigger: only start recording when at least ONE other
                // participant is present. Solo waits in an empty Meet are
                // Participant-count gate REMOVED. The Chrome extension's
                // participant-tile scraping is unreliable across Meet UI
                // refreshes (the tile DOM changes frequently), and solo
                // recordings (rehearsals, lectures, 1-on-1s where the other
                // person hasn't joined yet) were being silently dropped.
                // If the MeetBridge extension says a Meet URL is active,
                // that's the signal — start recording.
                let otherCount = self.recordingState.meetingParticipantNames.count
                if AppDelegate.isMeetingDetectionDisabled {
                    print("[VOICE-MEET] MeetBridge auto-start blocked — voice.disableMeetingDetection is true")
                    return
                }
                // Record the browser bundle as the meeting source. This is
                // the "proof" that lets MeetingCaptureService accept a
                // browser as a legitimate capture target — the bridge POST
                // came from the Voice Meet Bridge extension running in that
                // browser, so a real Meet/Zoom-web/Teams-web tab is active.
                // Without this, the service's proof-required whitelist would
                // refuse any browser-based capture.
                if self.recordingState.meetingSourceBundleID == nil {
                    self.recordingState.meetingSourceBundleID =
                        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                }
                print("[MeetBridge] Meet detected with \(otherCount) other participant(s)")
                print("[VOICE-MEET-START] reason=meetbridge participants=\(otherCount) source=chrome-extension bundle=\(self.recordingState.meetingSourceBundleID ?? "nil")")
                self.handleDetectedMeeting(source: "meetbridge")
            } else {
                self.meetingNoticeGate.end("meetbridge")
                self.recordingState.isMeetingAppActive = false
                // The extension only sends active=false when the meeting URL
                // is actually gone (user left the call or closed the tab) —
                // NOT when they just switch windows. So this is safe to act on.
                guard self.recordingState.isCapturingMeeting else { return }
                print("[MeetBridge] Meet ended → auto-stopping capture")
                self.stopMeetingCapture(reason: "meetEnded")
            }
        }
        // Active-speaker events from the Chrome extension. The MeetingCapture
        // service appends each event to a bounded timeline and, in the next
        // 30-second chunk, replaces the generic "MEETING" label with the
        // speaker name whose tile was lit up at the segment's midpoint.
        meetBridgeServer.onSpeakerEvent = { [weak self] name, active, t in
            self?.meetingCaptureService.recordSpeakerEvent(name: name, active: active, t: t)
        }
        // Gate the Chrome bridge HTTP listener behind the meeting-detection
        // opt-out. When off, the server never binds port 59423 and no auto
        // meeting captures fire from browser-detected calls.
        if BackgroundActivityGate.meetingDetectionEnabled {
            meetBridgeServer.start()
        } else {
            print("[VOICE-GATE] meetBridgeServer.start() skipped — voice.enableMeetingDetection=false (or privacyMode)")
        }

        // Native call-app detector — fires when Discord/Zoom/Teams/Slack/
        // FaceTime/WhatsApp/Telegram are actually on a call (visible in
        // SCShareableContent.applications AND mic is in use). Mirrors the
        // Chrome bridge wiring: starts a meeting capture, with a guard so
        // we don't double-trigger if Chrome already grabbed it.
        callAppDetector.onCallStateChange = { [weak self] active, bundle in
            guard let self else { return }
            if active {
                guard !self.recordingState.isCapturingMeeting else {
                    print("[CallAppDetector] \(bundle ?? "?") active, but capture already running — skipping")
                    return
                }
                // CRITICAL: ignore the detector when a dictation is running.
                // CallAppDetector's heuristic — "known-call app is in the
                // audio producers list AND mic is in use" — false-positives
                // during normal dictation because:
                //   1. The user has Discord/Slack open in the background and
                //      it produces a notification sound while they're
                //      dictating.
                //   2. The mic is hot because of the dictation itself.
                // Result: every dictation kicks off a screen-recording meeting
                // capture. We block it here.
                if self.recordingState.isRecording || self.recordingState.isLocked {
                    print("[CallAppDetector] \(bundle ?? "?") active, but dictation is running — ignoring")
                    return
                }
                if AppDelegate.isMeetingDetectionDisabled {
                    print("[VOICE-MEET] CallAppDetector auto-start blocked — voice.disableMeetingDetection is true")
                    return
                }
                self.recordingState.isMeetingAppActive = true
                self.recordingState.meetingSourceBundleID = bundle
                let label = bundle.flatMap { CallAppDetector.knownCallApps[$0] } ?? "call"
                print("[CallAppDetector] Detected \(label) (\(bundle ?? "?"))")
                print("[VOICE-MEET-START] reason=callappdetector app=\(label) bundle=\(bundle ?? "?") frontmost=true mic-in-use=true streak=\(CallAppDetector.knownCallApps[bundle ?? ""] ?? "?")")
                self.handleDetectedMeeting(source: "callapp:\(bundle ?? "unknown")")
            } else {
                self.meetingNoticeGate.end("callapp:\(bundle ?? "unknown")")
                self.recordingState.isMeetingAppActive = false
                guard BackgroundActivityGate.meetingDetectionEnabled, self.recordingState.isCapturingMeeting else { return }
                // Only stop if this capture was driven by the native detector
                // (matching bundle). If Chrome bridge took over with a
                // different source, leave it alone.
                if self.recordingState.meetingSourceBundleID == bundle {
                    print("[CallAppDetector] \(bundle ?? "?") call ended — auto-stopping capture")
                    self.stopMeetingCapture(reason: "callAppEnded")
                }
            }
        }
        // Combined gate: must be allowed by both the legacy disable flag and
        // the new opt-in. Defaults result in OFF (opt-in is false by default).
        if BackgroundActivityGate.meetingDetectionEnabled {
            callAppDetector.start()
            meetingDetectorsRunning = true
        } else {
            print("[VOICE-MEET] CallAppDetector NOT started — voice.enableMeetingDetection=false / disable=true / privacyMode")
        }

        // POLISH REPLAY AUTO-RUN — kicks the in-app golden-case battery
        // headlessly when `POLISH_REPLAY_AUTORUN=1` is set in the env (or
        // `polishReplayAutorun` UserDefaults bool). Writes the markdown dump
        // to ~/Library/Application Support/Voice/polish_replay_last.md and
        // quits the app. Lets an external driver verify polish quality
        // without needing computer-use clicks.
        let autorunEnv = ProcessInfo.processInfo.environment["POLISH_REPLAY_AUTORUN"] == "1"
        let autorunDefaults = UserDefaults.standard.bool(forKey: "polishReplayAutorun")
        if autorunEnv || autorunDefaults {
            print("[POLISH-REPLAY] autorun: starting batch (env=\(autorunEnv) defaults=\(autorunDefaults))")
            Task { @MainActor in
                // Wait for the 1.7B prewarm to land before running. We
                // poll instead of awaiting the coordinator prewarm because
                // prewarm is fire-and-forget. The 4B may still be loading;
                // routing falls back to 1.7B automatically.
                for i in 0..<120 {
                    if Qwen3Polisher.availabilityStatus.isReady { break }
                    if i == 0 { print("[POLISH-REPLAY] autorun: waiting for 1.7B...") }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                // Also give the 4B a chance to load — bounded wait so the
                // batch reflects the realistic warm-state behavior, not a
                // cold first-call timeout.
                for _ in 0..<60 {
                    if Qwen3Polisher.shared.isLargeModelReady { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                print("[POLISH-REPLAY] autorun: 1.7B ready=\(Qwen3Polisher.availabilityStatus.isReady) 4B ready=\(Qwen3Polisher.shared.isLargeModelReady)")

                let cases = GoldenCaseLoader.loadAll()
                print("[POLISH-REPLAY] autorun: loaded \(cases.count) cases")
                var lines: [String] = []
                lines.append("| Case | Route | ms | Similarity | Status |")
                lines.append("|------|-------|-----|------------|--------|")
                var dump = "# polish-replay batch \(Date())\n"
                dump += "1.7B-ready=\(Qwen3Polisher.availabilityStatus.isReady) 4B-ready=\(Qwen3Polisher.shared.isLargeModelReady)\n\n"
                for c in cases {
                    let cleanup = c.cleanupLevel ?? "medium"
                    let pers = c.personality ?? "neutral"
                    let route = PolishRouter.predictedRoute(for: c.raw, cleanupLevel: cleanup, forceLarge: false)
                    let (out, ms) = await PolishReplayView.runOnePolish(
                        raw: c.raw,
                        cleanupLevel: cleanup,
                        personality: pers,
                        forceLarge: false
                    )
                    let sim = Similarity.score(out, c.reference)
                    let status: String
                    if sim >= 0.80 { status = "ok" }
                    else if sim >= 0.60 { status = "warn" }
                    else { status = "fail" }
                    lines.append("| \(c.id) | \(route) | \(ms) | \(String(format: "%.2f", sim)) | \(status) |")
                    dump += "## \(c.id)\nroute=\(route) cleanup=\(cleanup) personality=\(pers) ms=\(ms) sim=\(String(format: "%.3f", sim)) status=\(status)\n\n"
                    dump += "RAW:\n\(c.raw)\n\nPOLISHED:\n\(out)\n\nREFERENCE:\n\(c.reference)\n\n---\n\n"
                    print("[POLISH-REPLAY] autorun: \(c.id) route=\(route) ms=\(ms) sim=\(String(format: "%.2f", sim)) status=\(status)")
                }
                let table = lines.joined(separator: "\n")
                let final = dump + "\n\(table)\n"
                let dir = GoldenCaseLoader.userDirectory().deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let outURL = dir.appendingPathComponent("polish_replay_last.md")
                try? final.write(to: outURL, atomically: true, encoding: .utf8)
                print("[POLISH-REPLAY] autorun: dump written to \(outURL.path) — terminating")
                NSApp.terminate(nil)
            }
        }

        // Granite 4.0 + Moonshine subprocess transcribers were disabled —
        // their source files (GraniteTranscriber.swift / MoonshineTranscriber.swift)
        // are not part of the Xcode project target. Parakeet v2 (built-in) is the
        // sole transcriber for this build. Re-enable here once the files are
        // added back to project.pbxproj.

        // First-run onboarding — non-blocking. The pill works without it.
        if !isEmbeddedInCompanion && !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showOnboarding()
            }
        }

        // Update check fires once at launch, debounced internally to 24h.
        UpdateChecker.checkInBackground { [weak self] info in
            guard let self else { return }
            self.showToast("Flow \(info.version) is available.")
        }

        Telemetry.log("app.launched", properties: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        ])
        // At-a-glance state dump in events.jsonl on every launch.
        emitDebugSnapshot(reason: "launch")

        // Safety timer (0.5Hz / every 2s) — force-clears a stuck
        // `pendingRecordingStart` flag when it's sat true for more than 2s
        // with no actual recording. Belt-and-suspenders for any code path
        // that fails to clear it (audio engine startup failure, release
        // handler missed, etc.). See 5.1.
        pendingPillSafetyTimer?.invalidate()
        pendingPillSafetyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let state = self.recordingState
            guard state.pendingRecordingStart,
                  let pendingAt = state.pendingRecordingStartAt,
                  Date().timeIntervalSince(pendingAt) > 2.0,
                  !state.isRecording else {
                return
            }
            print("[VOICE-PILL] safety-clear: pendingRecordingStart stuck for >2s")
            state.pendingRecordingStart = false
            state.pendingRecordingStartAt = nil
        }
        // Keep the timer alive during modal panels / nested run loops.
        if let timer = pendingPillSafetyTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        print("[VOICE] Launched")

        // Launch has fully settled. From here on, an `applicationShouldHandle
        // Reopen` is a genuine user gesture and may open the window. Any reopen
        // delivered DURING launch (e.g. launch-at-login) was suppressed above,
        // so the app stays a focusless .accessory menu-bar agent at startup.
        didFinishLaunchingComplete = true
    }

    /// Wraps a startup step in do/catch + telemetry. Errors don't stop launch.
    private func runStartupStep(_ name: String, _ block: () throws -> Void) {
        do {
            try block()
        } catch {
            Telemetry.log("startup.failed", properties: ["step": name, "error": "\(error)"])
            print("[VOICE] startup step '\(name)' failed: \(error)")
        }
    }

    /// Emit a `debug.snapshot` to events.jsonl capturing current health/config
    /// at a glance. Fired at launch and at failure points so a reader can see
    /// the app's full state without reconstructing it from scattered lines.
    /// NEVER logs the full cloud key — `Telemetry.snapshot` masks it to a
    /// prefix. `failureReasons` lets callers attach recent error context.
    @MainActor
    private func emitDebugSnapshot(reason: String, failureReasons: [String] = []) {
        var extra: [String: Any] = [
            // Cloud / Cerebras-first routing state. Raw key is masked inside
            // Telemetry.snapshot via the "cloud_key_raw" convention.
            "cloud_enabled": CerebrasPolisher.isEnabled,
            "cloud_available": CerebrasPolisher.isAvailable,
            "cloud_key_raw": CerebrasPolisher.apiKey,
            "wake_word": UserDefaults.standard.string(forKey: "voice.wakeWordMode") ?? "off",
            "wake_word_enabled": UserDefaults.standard.bool(forKey: "voice.wakeWordEnabled"),
            "meeting_detect": UserDefaults.standard.bool(forKey: "voice.enableMeetingDetection"),
            "default_model": UserDefaults.standard.string(forKey: "audioSource") ?? "microphone",
            "accessibility": AXIsProcessTrusted(),
            "model_state": "\(coordinator.state.modelState)",
            "is_recording": recordingState.isRecording,
            "transcribing_count": recordingState.transcribingCount,
            "last_polish_engine": PolishStatus.shared.lastEngine ?? "none",
        ]
        if !failureReasons.isEmpty {
            extra["recent_failures"] = failureReasons
        }
        Telemetry.snapshot(reason: reason, extra: extra)
    }

    // MARK: - App Icon Assertion

    /// Load the bundle's app icon and set it on NSApp so the Dock, Cmd-Tab
    /// switcher, and About panel always show the rounded-rect icon instead of
    /// a scaled-up emoji placeholder.
    ///
    /// Strategy (in priority order):
    ///   1. NSImage(named: "AppIcon")              — Assets.car lookup
    ///   2. NSImage(named: NSImage.applicationIconName) — system alias
    ///   3. Bundle.main.path(forResource:ofType:)  — loose .icns in Resources
    ///   4. Bundle.main.urlForImageResource        — any image named AppIcon
    ///
    /// After loading, validates the image has >= 2 representations at varying
    /// pixel sizes. A single-rep image is a placeholder (the Dock scales it up
    /// to a square). If validation fails, falls back directly to the compiled
    /// AppIcon.icns inside the running bundle's Resources/ directory, bypassing
    /// Assets.car entirely.
    ///
    /// Safe to call multiple times — idempotent on a warm icon cache.
    private func assertAppIcon(context: String) {
        let candidates: [() -> NSImage?] = [
            { NSImage(named: "AppIcon") },
            { NSImage(named: NSImage.applicationIconName) },
            {
                guard let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns") else { return nil }
                return NSImage(contentsOfFile: path)
            },
            {
                guard let url = Bundle.main.urlForImageResource("AppIcon") else { return nil }
                return NSImage(contentsOf: url)
            }
        ]

        // Find the first candidate that is at least 64 pt and has representations.
        var loadedIcon: NSImage? = nil
        for loader in candidates {
            if let img = loader(),
               img.size.width >= 64,
               img.size.height >= 64,
               !img.representations.isEmpty {
                loadedIcon = img
                break
            }
        }

        guard let icon = loadedIcon else {
            print("[VOICE-ICON][\(context)] WARNING: could not load AppIcon from any path — leaving Dock default")
            return
        }

        // Validate multi-rep: a proper .icns has representations at 16, 32, 128,
        // 256, 512 px. A single-rep image is a placeholder the Dock scales to a
        // square. Check for >= 2 reps AND at least 2 distinct pixel widths.
        let repSizes = Set(icon.representations.map { Int($0.pixelsWide) })
        let isValid  = icon.representations.count >= 2 && repSizes.count >= 2

        if isValid {
            print("[VOICE-ICON][\(context)] asserting icon size=\(icon.size) reps=\(icon.representations.count) widths=\(repSizes.sorted())")
            NSApp.applicationIconImage = icon
            return
        }

        // Validation failed — single-rep or uniform-size image (placeholder).
        // Bypass Assets.car and load the compiled .icns directly from disk.
        print("[VOICE-ICON][\(context)] WARNING: loaded icon is single-rep or single-size — forcing .icns reload")
        if let resPath = Bundle.main.resourcePath {
            let icnsPath = resPath + "/AppIcon.icns"
            if FileManager.default.fileExists(atPath: icnsPath),
               let icnsImg = NSImage(contentsOfFile: icnsPath) {
                let icnsReps   = icnsImg.representations.count
                let icnsSizes  = Set(icnsImg.representations.map { Int($0.pixelsWide) })
                if icnsReps >= 2 && icnsSizes.count >= 2 {
                    print("[VOICE-ICON][\(context)] reloaded from .icns reps=\(icnsReps) widths=\(icnsSizes.sorted())")
                    NSApp.applicationIconImage = icnsImg
                } else {
                    // .icns itself is degenerate — set whatever we have so the
                    // Dock at least shows something recognisable.
                    print("[VOICE-ICON][\(context)] .icns is also single-rep (reps=\(icnsReps)) — setting anyway")
                    NSApp.applicationIconImage = icnsImg
                }
            } else {
                print("[VOICE-ICON][\(context)] BUNDLED .icns NOT FOUND at \(icnsPath) — setting single-rep icon as fallback")
                NSApp.applicationIconImage = icon
            }
        } else {
            print("[VOICE-ICON][\(context)] could not resolve resourcePath — setting single-rep icon as fallback")
            NSApp.applicationIconImage = icon
        }
    }

    /// Dock-icon click while app is already running. Open the BigMenu so
    /// settings / stats / hotkey config are one click away. Returning false
    /// tells AppKit not to try to spawn a new window for an untitled doc
    /// (we're an LSUIElement-ish app — there's nothing to spawn).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // FOCUS-STEAL FIX: macOS delivers a reopen event at launch in several
        // configurations — most importantly when the app is launched at login,
        // or relaunched while already registered. Acting on that reopen would
        // pop the BigMenu window and pull focus away from whatever the user is
        // typing into, which is exactly the unwanted "window opens on its own"
        // behavior. We are a background (.accessory) menu-bar app: opening the
        // window must be an EXPLICIT user gesture (clicking the menu-bar item /
        // Dock icon / a menu command). So only honor a reopen once launch has
        // fully settled — a Dock-icon click after startup still works.
        guard didFinishLaunchingComplete else {
            Telemetry.log("app.reopen_suppressed", properties: ["reason": "launch_in_progress"])
            return false
        }
        if !hasVisibleWindows {
            openBigMenu()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let shadowController {
            // Shadow mode never created the coordinator, pill or Companion listener.
            shadowController.stop()
            Telemetry.log("app.terminate", properties: ["mode": "shadow"])
            return
        }
        // Tell Companion that Flow is gone (state with phase "off") and stop listening.
        FlowCommandListener.shared.stop()
        flowRecoveryTask?.cancel()
        Telemetry.log("app.terminate")
        // Give back the output mute if a dictation was in progress.
        coordinator.restoreOutputAudio()
        // BUGFIX: invalidate ALL timers, not just the permission watcher.
        // pendingPillSafetyTimer was previously leaked across a restart-in-process.
        permissionWatcherTimer?.invalidate()
        permissionWatcherTimer = nil
        pendingPillSafetyTimer?.invalidate()
        pendingPillSafetyTimer = nil
        menuBarIconTimer?.invalidate()
        menuBarIconTimer = nil
        // BUGFIX: cancel in-flight Tasks so they don't try to mutate state
        // during the shutdown window (could race UserDefaults flushes below).
        cancelDismissTask?.cancel(); cancelDismissTask = nil
        errorDismissTask?.cancel(); errorDismissTask = nil
        undoPasteDismissTask?.cancel(); undoPasteDismissTask = nil
        dictationWork.cancelAll()
        recordingState.transcribingCount = dictationWork.activeCount
        pasteChain = nil
        if let observer = errorObserver {
            NotificationCenter.default.removeObserver(observer)
            errorObserver = nil
        }
        // BUGFIX: remove every block-based observer we registered.
        // Previously only `errorObserver` got cleaned up; the didBecomeActive
        // and voiceOpenBigMenu observers leaked.
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        // Workspace observers (sleep/wake) live on a separate center — remove
        // them there, or they leak (the loop above wouldn't reach them).
        let wsCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens {
            wsCenter.removeObserver(token)
        }
        workspaceTokens.removeAll()
        // Best-effort: if a recording is still in flight, stop it so the
        // file isn't left half-flushed. We don't await — terminate doesn't
        // give us time, but stopRecording's writer will close synchronously.
        if recordingState.isRecording || recordingState.isLocked {
            Task { @MainActor in _ = await coordinator.stopRecording() }
        }
        // STORAGE AUDIT FIX: force-flush UserDefaults before quit so the
        // most recent RecentDictation isn't lost on quick cmd-Q. AppKit
        // normally flushes on exit, but Task-spawned writes during the
        // tear-down window can race the shutdown. synchronize() is
        // deprecated but still works and is the only synchronous flush.
        UserDefaults.standard.synchronize()
        // (Granite / Moonshine subprocess shutdown removed — see launch comment.)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ALWAYS allow quit immediately. We deliberately do NOT pop a modal
        // confirm here: on a menu-bar (LSUIElement) app the alert can't always
        // come to the front, and a stuck/phantom recording state left it hanging
        // invisibly — making the app impossible to quit. Losing an in-flight
        // dictation on an explicit quit is acceptable; an un-quittable app is not.
        return .terminateNow
    }

    /// Bulletproof quit, wired to the menu "Quit Flow" item. `NSApp.terminate`
    /// can be blocked, deferred, or hang (a wedged main thread, a stray modal,
    /// a background task). We schedule a hard `exit(0)` fallback on a BACKGROUND
    /// queue — so it fires even if the main thread is completely wedged — and
    /// the app is guaranteed to die within ~0.8s no matter what.
    @objc func quitNow() {
        Telemetry.log("app.terminate", properties: ["via": "menu-quit"])
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) { exit(0) }
        NSApp.terminate(nil)
    }

    private static let pureBundleID = "local.jordan.pcmonitor.sender"
    /// The meeting the "mic dropped" notice was last shown for, so it is said once per meeting.
    private var lastMicDropNoticeMeeting: UUID?

    private var isEmbeddedInCompanion: Bool {
        let helpers = Bundle.main.bundleURL.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers" else { return false }
        let host = helpers.deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: host)?.bundleIdentifier == Self.pureBundleID
    }

    private func syncStatusItemWithPure() {
        let pureRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.pureBundleID).isEmpty
        statusItem?.isVisible = !pureRunning
    }

    private func setupMenuBar() {
        // No cube in the menu bar while Flow lives inside Companion (22 Nov 2026): Companion's item covers it.
        guard !isEmbeddedInCompanion else { return }
        // squareLength reserves a fixed slot — variableLength can collapse
        // to 0 width if the icon fails to load, hiding the menu bar entry.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            if let img = NSImage(systemSymbolName: "cube", accessibilityDescription: "Flow") {
                img.isTemplate = true
                button.image = img
                button.imagePosition = .imageOnly
            } else {
                // SF Symbols failed — visible "V" so the slot isn't blank.
                button.title = "V"
            }
            button.toolTip = "Flow · fn to dictate"
        } else {
            print("[VOICE] WARNING: statusItem.button is nil — menu bar icon will not appear")
        }

        // One menu bar item for all of Companion: while Companion runs, its menu covers Flow and this one hides. With Companion
        // closed it comes back, so Flow stays reachable on its own.
        syncStatusItemWithPure()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.pureBundleID else { return }
                let launched = note.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated { self?.statusItem?.isVisible = !launched }
            }
        }

        let menu = NSMenu()
        menu.delegate = self  // refresh dynamic items lazily on open

        // Status header — disabled item at the top of the menu that shows
        // what Voice is doing right now ("Idle", "Dictating…", "Recording
        // meeting · 03:42"). Refreshed lazily in menuWillOpen.
        let statusHeader = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusHeader.tag = MenuTag.statusHeader.rawValue
        statusHeader.isEnabled = false
        menu.addItem(statusHeader)
        let upcomingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        upcomingItem.tag = MenuTag.upcomingCall.rawValue
        upcomingItem.isHidden = true
        menu.addItem(upcomingItem)
        _ = MeetingCalendarService.shared
        menu.addItem(NSMenuItem.separator())

        // "Stop Meeting Recording" — hidden unless a meeting capture is active.
        // Sits at the TOP of the menu (above "History") so the user can
        // kill an unwanted screen recording with one click, never hunting.
        // Visibility toggled in menuWillOpen so we don't have to observe state.
        // A `stop.circle.fill` SF symbol tinted .systemRed makes the row
        // unmistakable when it appears.
        let stopMeetingItem = NSMenuItem(title: "Stop taking notes",
                                          action: #selector(stopMeetingFromMenu),
                                          keyEquivalent: "")
        stopMeetingItem.target = self
        stopMeetingItem.tag = MenuTag.stopMeeting.rawValue
        stopMeetingItem.isHidden = true
        if let stopImg = NSImage(systemSymbolName: "stop.circle.fill",
                                 accessibilityDescription: "Stop meeting recording") {
            // Draw the symbol into a new image, then re-tint with systemRed
            // via the .sourceIn composite. NSMenuItem.image doesn't honour
            // contentTintColor so we have to bake the tint into the image.
            let size = stopImg.size
            let tinted = NSImage(size: size, flipped: false) { rect in
                stopImg.draw(in: rect)
                NSColor.systemRed.set()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.isTemplate = false
            stopMeetingItem.image = tinted
        }
        menu.addItem(stopMeetingItem)

        // "Start Meeting Recording" — manual trigger for solo recordings,
        // testing, or when auto-detection doesn't fire (e.g., Discord call
        // that the bundle detector missed). Hidden when a capture is already
        // active. Sits right above Stop so it's the obvious lever to find.
        let startMeetingItem = NSMenuItem(title: "Take notes",
                                          action: #selector(startMeetingFromMenu),
                                          keyEquivalent: "")
        startMeetingItem.target = self
        startMeetingItem.tag = MenuTag.startMeeting.rawValue
        startMeetingItem.isHidden = false
        if let startImg = NSImage(systemSymbolName: "record.circle",
                                  accessibilityDescription: "Start meeting recording") {
            let size = startImg.size
            let tinted = NSImage(size: size, flipped: false) { rect in
                startImg.draw(in: rect)
                NSColor.systemRed.set()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.isTemplate = false
            startMeetingItem.image = tinted
        }
        menu.addItem(startMeetingItem)

        let openItem = NSMenuItem(title: "History", action: #selector(openDictationHistory), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openBigMenuSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Activate wake-word listener for the configured window (default 5
        // minutes). Posts a notification picked up by setupWakeWord(). Only
        // useful while `voice.wakeWordMode == "activatedWindow"`, but we
        // surface it unconditionally — pressing it in always-on mode is a
        // harmless no-op (the listener is already running), and in off
        // mode the user has chosen to disable wake-word entirely so it
        // also no-ops in WakeWordService.
        let armWakeItem = NSMenuItem(
            title: "Activate Wake Word for 5 minutes",
            action: #selector(activateWakeWordWindowFromMenu),
            keyEquivalent: ""
        )
        armWakeItem.target = self
        // Wake word remains available through Settings.

        // Recent Dictations submenu — populated lazily in menuWillOpen so the
        // list always reflects the latest entries from the RecentDictations store.
        let recentsItem = NSMenuItem(title: "Recent dictations", action: nil, keyEquivalent: "")
        recentsItem.tag = MenuTag.recentsSubmenu.rawValue
        let recentsSubmenu = NSMenu(title: "Recent dictations")
        recentsItem.submenu = recentsSubmenu
        menu.addItem(recentsItem)

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LaunchAtLoginService.isEnabled ? .on : .off
        launchItem.tag = MenuTag.launchAtLogin.rawValue
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About Flow", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        // About is available through Settings.

        let diagItem = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        diagItem.target = self
        // Diagnostics remain available through Settings.

        let quitItem = NSMenuItem(title: "Quit Flow", action: #selector(quitNow), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu

        // Adaptive-rate menu bar icon refresh:
        //   • 1Hz while actively recording or capturing a meeting — tooltip
        //     shows a running clock and the state symbol needs to snap quickly.
        //   • 0.2Hz (every 5s) while idle — icon and tooltip are static; no
        //     visual benefit to waking the CPU every second. Saves ~4 timer
        //     firings/sec × every second the user isn't dictating.
        // State-change sites (startMeetingCapture, stopMeetingCapture,
        // hotkeyDidActivate/Deactivate) call refreshMenuBarIcon() directly so
        // the icon always updates immediately on transition regardless of where
        // the adaptive timer currently sits.
        scheduleMenuBarIconTimer()
        refreshMenuBarIcon()
    }

    private var menuBarIconTimer: Timer?
    /// Cache for the menu bar icon so we only allocate a new NSImage when the
    /// displayed state actually changes. The key encodes all inputs that affect
    /// symbol name + tooltip (state combination + meeting duration for the
    /// seconds-ticking tooltip). Re-create only on a key change; skip otherwise.
    private var cachedMenuIcon: (stateKey: String, image: NSImage)?

    /// Schedule (or reschedule) the menu bar icon refresh timer at the
    /// appropriate rate for the current state:
    ///   • 1s  — recording or capturing a meeting (live state visible in icon/tooltip)
    ///   • 5s  — idle (icon is static; tooltip is "fn to dictate")
    /// Call this whenever the app transitions between active and idle so the
    /// interval is always appropriate without needing to poll at 1Hz for no reason.
    func scheduleMenuBarIconTimer() {
        let isActive = recordingState.isRecording
                    || recordingState.isLocked
                    || recordingState.isCapturingMeeting
                    || recordingState.isTranscribing
        let interval: TimeInterval = isActive ? 1.0 : 5.0

        // Avoid tearing down and rebuilding a timer that already has the right
        // interval — RunLoop timer teardown/setup has a small but nonzero cost.
        if let existing = menuBarIconTimer, existing.timeInterval == interval { return }

        menuBarIconTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMenuBarIcon() }
        }
        RunLoop.main.add(t, forMode: .common)
        menuBarIconTimer = t
    }

    /// Tags so we can find specific items in the menu when refreshing.
    /// Recents used to live here (`case recent = 1001`) but were consolidated
    /// into the BigMenu popup, so only the launch-at-login state needs a tag.
    private enum MenuTag: Int {
        case launchAtLogin = 1002
        case recentsSubmenu = 1003
        case stopMeeting = 1004
        case statusHeader = 1005
        case startMeeting = 1006
        case upcomingCall = 1007
    }

    /// Refresh the menu bar status icon to reflect current state.
    /// Idle = `waveform`, dictating = `waveform.circle.fill` (accented),
    /// meeting = `record.circle.fill` (red tint via template + accent).
    func refreshMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        let tooltip: String
        let meetingActive = recordingState.isCapturingMeeting
        if meetingActive {
            symbolName = "record.circle.fill"
            let mins = recordingState.meetingDurationSeconds / 60
            let secs = recordingState.meetingDurationSeconds % 60
            tooltip = String(format: "Flow · RECORDING MEETING %d:%02d (click to stop)", mins, secs)
        } else if recordingState.isRecording || recordingState.isLocked {
            symbolName = "cube.fill"
            tooltip = "Flow · dictating"
        } else {
            symbolName = "cube"
            tooltip = "Flow · fn to dictate"
        }
        // Cache key includes tint mode so we rebuild the NSImage when
        // toggling between template (idle/dictating) and tinted-red (meeting).
        // During meeting capture the icon is rendered as a non-template image
        // with `contentTintColor = .systemRed` so the user can see at a glance
        // that screen recording is active — half of the explicit-visibility
        // fix for the meeting-false-trigger trust bug.
        let stateKey = "\(symbolName)|\(meetingActive ? "red" : "template")"
        if cachedMenuIcon?.stateKey != stateKey {
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Flow") {
                if meetingActive {
                    // Non-template so the systemRed tint actually paints —
                    // template images get forced to monochrome by AppKit.
                    img.isTemplate = false
                    button.image = img
                    button.contentTintColor = NSColor.systemRed
                } else {
                    img.isTemplate = true
                    button.image = img
                    button.contentTintColor = nil
                }
                cachedMenuIcon = (stateKey: stateKey, image: img)
            }
        }
        button.toolTip = tooltip
    }

    /// Format an age in seconds as a compact relative string ("2m ago", "1h ago").
    private func relativeTimestamp(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(max(s, 0))s ago" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        let d = h / 24
        return "\(d)d ago"
    }

    /// Rebuild the Recent Dictations submenu with the latest 5 entries.
    /// Called from menuWillOpen so the list is always fresh.
    fileprivate func refreshRecentsSubmenu(_ submenu: NSMenu) {
        submenu.removeAllItems()
        let recents = Array(RecentDictations.all().prefix(5))
        guard !recents.isEmpty else {
            let empty = NSMenuItem(title: "No recent dictations", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }
        for r in recents {
            let oneLine = r.text.replacingOccurrences(of: "\n", with: " ")
                                .replacingOccurrences(of: "\r", with: " ")
            let preview = oneLine.count > 50 ? "\(oneLine.prefix(50))…" : oneLine
            let item = NSMenuItem(title: preview, action: #selector(copyRecentDictation(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = relativeTimestamp(r.timestamp)
            item.representedObject = r.text
            submenu.addItem(item)
        }
    }

    @objc private func copyRecentDictation(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        let next = !LaunchAtLoginService.isEnabled
        let ok = LaunchAtLoginService.setEnabled(next)
        if !ok {
            showToast("Failed to update Launch at Login")
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "A menu-bar dictation app. Hold fn anywhere to talk.\nBuilt with care, runs entirely on-device.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        // Build number is the app's identity (no marketing version). The build
        // script auto-increments CFBundleVersion on every build-install run, so
        // "Build N" is the single source of truth for which build is running.
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "Flow",
            .applicationVersion: "Build \(buildNumber)"
        ])
    }

    /// Gather a self-contained diagnostics blob and copy it to the clipboard.
    /// Pulls: app version, model state, current input device, recent dictation
    /// outcomes, and the tail of `events.jsonl` (Telemetry sink — captures the
    /// [VOICE-FUNNEL] equivalents via Telemetry.log calls). When the events
    /// file doesn't exist yet we still copy the metadata so the user has
    /// something useful to paste into a bug report.
    @objc private func copyDiagnostics() {
        var lines: [String] = []
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("VOICE diagnostics")
        lines.append("version: \(version) (build \(build))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("model state: \(coordinator.state.modelState)")
        lines.append("input device: \(currentInputDeviceName())")
        lines.append("accessibility trusted: \(AXIsProcessTrusted())")
        lines.append("lifetime dictations: \(recordingState.lifetimeDictations) / words: \(recordingState.lifetimeWords)")
        lines.append("session: dictations=\(recordingState.sessionDictationCount) words=\(recordingState.sessionTotalWords)")

        // Last 5 recent dictation outcomes (length + age).
        let recents = RecentDictations.all().prefix(5)
        lines.append("recent dictations (\(recents.count)):")
        for r in recents {
            let age = Int(Date().timeIntervalSince(r.timestamp))
            let preview = r.text.count > 40 ? "\(r.text.prefix(40))…" : r.text
            lines.append("  - \(r.text.count) chars, \(age)s ago: \(preview)")
        }

        // Tail the Telemetry log file — last 100 lines. This is our best
        // proxy for [VOICE-FUNNEL] capture without rewiring every `print`.
        if let url = Telemetry.logURL,
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            let all = raw.split(separator: "\n", omittingEmptySubsequences: true)
            let tail = all.suffix(100)
            lines.append("--- events.jsonl tail (\(tail.count) lines of \(all.count)) ---")
            for line in tail { lines.append(String(line)) }
        } else {
            lines.append("--- events.jsonl: not present yet ---")
        }

        let blob = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(blob, forType: .string)
        NotificationCenter.default.post(
            name: .voiceError,
            object: nil,
            userInfo: ["message": "Diagnostics copied (\(blob.count) chars)"]
        )
        Telemetry.log("diagnostics.copied", properties: ["chars": blob.count])
    }

    /// Best-effort name of the current default input device. Returns "unknown"
    /// when CoreAudio refuses the query (rare).
    private func currentInputDeviceName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return "unknown" }
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr,
              let cf = nameRef?.takeRetainedValue() else {
            return "unknown"
        }
        return cf as String
    }

    /// Show (or reuse) the Big Menu window.
    /// Real titled NSWindow now (no longer a floating borderless panel) — the
    /// system traffic lights handle close/min/zoom and an NSToolbar exposes
    /// the "…" overflow menu (Settings, About, Quit). Not floating; behaves
    /// like a standard app window so Cmd-Tab / Mission Control / minimize work.
    /// Menu bar action — arms the wake-word listener for the configured
    /// window. Posts a notification rather than calling the service
    /// directly so any other UI surface (hotkey, future widget) can use
    /// the same entry point.
    @objc func activateWakeWordWindowFromMenu() {
        NotificationCenter.default.post(name: .voiceActivateWakeWordWindow, object: nil)
    }

    /// Dictations and meetings are read in Companion. Flow is the background engine and keeps its own
    /// window only for Settings and for granting permissions. Returns true when Companion was opened.
    /// After launching, Companion is told which page to show: its Voice tab, on dictations or meetings.
    /// `completion` runs on the main actor with true only once Companion has launched. On a missing app or a
    /// launch error it runs with false, so the caller can show Flow's own history instead (sol/03 finding 4).
    private func openHistoryInCompanion(section: String = "dictations", completion: @escaping @MainActor (Bool) -> Void) {
        let pure = URL(fileURLWithPath: "/Applications/Companion.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: pure.path) else { completion(false); return }
        let wasRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == pure.standardizedFileURL.path
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: pure, configuration: configuration) { _, error in
            Task { @MainActor in
                guard error == nil else { completion(false); return }
                FlowBroadcast.openCompanion(section: section)
                // A Companion that was just started may not be listening yet; ask once more.
                if !wasRunning {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { FlowBroadcast.openCompanion(section: section) }
                }
                completion(true)
            }
        }
    }

    @objc func openBigMenu() { presentBigMenu(allowCompanion: true) }

    private func presentBigMenu(allowCompanion: Bool) {
        let wantsSettings = recordingState.flowWindowRequest?.destination == .settings
        let historySection = recordingState.flowWindowRequest?.destination == .recordings ? "meetings" : "dictations"
        if allowCompanion, !wantsSettings, isEmbeddedInCompanion || PermissionsService.shared.allGranted {
            // The request is consumed only once Companion has really opened; otherwise Flow's own window takes it.
            openHistoryInCompanion(section: historySection) { [weak self] launched in
                guard let self else { return }
                if launched {
                    self.recordingState.flowWindowRequest = nil
                } else {
                    self.showToast("Companion did not open, so history is in Flow.")
                    self.presentBigMenu(allowCompanion: false)
                }
            }
            return
        }
        // Reveal in the Dock + Cmd-Tab while the window is visible.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            assertAppIcon(context: "openBigMenu")
        }
        if let win = bigMenuWindow {
            // Re-verify the frame is on a visible screen each time we reopen —
            // the user may have disconnected the external display the window was
            // last dragged to, leaving its saved frame offscreen.
            ensureWindowOnScreen(win)
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = BigMenuWindow(recordingState: recordingState, onClose: { [weak self] in
            self?.bigMenuWindow?.performClose(nil)
        })
        let host = NSHostingController(rootView: view)
        // DO NOT set host.sizingOptions = .preferredContentSize — on macOS 26+ beta
        // it calls preferredContentSize inside a constraint layout pass, which fires
        // _postWindowNeedsUpdateConstraints and crashes. Fixed 440×620 initial frame
        // is used instead, restored across launches via setFrameAutosaveName.

        // Titled window with full-size content + transparent titlebar so the
        // vibrancy background flows under the traffic lights for the modern
        // macOS look. Toolbar item on the right gives us the "…" overflow.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.minSize = NSSize(width: 700, height: 500)
        win.title = "Flow"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = false
        win.isReleasedWhenClosed = false
        win.contentViewController = host
        win.delegate = self
        // Standard window behavior — DO NOT make this floating / all-spaces.
        // It should behave like any normal app window so Cmd-Tab + Mission
        // Control treat it correctly.
        win.collectionBehavior = [.fullScreenAuxiliary, .managed]
        win.hidesOnDeactivate = false

        // Toolbar with a single primary item ("…") on the right, which opens
        // a popup menu (Settings, About, Quit). Identifier matters for the
        // delegate callbacks below.
        let toolbar = NSToolbar(identifier: "VoiceBigMenuToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        toolbar.delegate = self
        win.toolbar = toolbar
        if #available(macOS 11.0, *) {
            win.toolbarStyle = .unifiedCompact
        }

        // Remember where the user dragged it. setFrameAutosaveName both registers
        // future saves AND immediately restores any previously-saved frame, so
        // calling this can move the window before we have a chance to validate
        // that the saved frame is still on a visible screen.
        win.setFrameAutosaveName("VoiceBigMenu")

        // First-launch position: anchored below the menu bar, right-aligned.
        // Subsequent launches restore the user's saved frame via autosave — but
        // only if that frame is still on-screen.
        ensureWindowOnScreen(win, defaultSize: NSSize(width: 760, height: 620))

        // Bump up an old too-small autosaved frame to the new ideal.
        if win.frame.height < 500 || win.frame.width < 700 {
            var f = win.frame
            f.size.width  = max(f.size.width,  760)
            let extraHeight = max(0, 620 - f.size.height)
            f.size.height += extraHeight
            f.origin.y    -= extraHeight
            win.setFrame(f, display: true)
        }

        bigMenuWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Build and show the "…" toolbar overflow menu. Wired to the toolbar item
    /// via target/action in `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`.
    @objc fileprivate func showBigMenuOverflow(_ sender: Any?) {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openBigMenuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About Flow", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Flow", action: #selector(quitNow), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // Anchor the popup under the toolbar item.
        if let button = sender as? NSButton {
            let loc = NSPoint(x: 0, y: button.bounds.height + 4)
            menu.popUp(positioning: nil, at: loc, in: button)
        } else if let win = bigMenuWindow, let contentView = win.contentView {
            // Fallback — anchor in the top-right of the content view.
            let loc = NSPoint(x: contentView.bounds.maxX - 40, y: contentView.bounds.maxY - 8)
            menu.popUp(positioning: nil, at: loc, in: contentView)
        }
    }

    /// Open the Settings sheet hosted inside the BigMenu. Posts a notification
    /// the SwiftUI view observes (it can't be called directly from AppKit).
    private func openSpeechSettings() {
        if let panel = speechSettingsWindow {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 385),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Voice models"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView:
            ScrollView {
                LocalModelsSettingsView(coordinator: coordinator)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
        let visible = overlayPanel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        if let visible {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        speechSettingsWindow = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc fileprivate func openBigMenuSettings() {
        if isEmbeddedInCompanion {
            openHistoryInCompanion(section: "settings") { [weak self] opened in
                guard let self, !opened else { return }
                self.recordingState.flowWindowRequest = FlowWindowRequest(destination: .settings)
                self.presentBigMenu(allowCompanion: false)
            }
        } else {
            recordingState.flowWindowRequest = FlowWindowRequest(destination: .settings)
            openBigMenu()
        }
    }

    @objc private func openDictationHistory() {
        recordingState.flowWindowRequest = FlowWindowRequest(destination: .dictations)
        openBigMenu()
    }

    /// Verify the window's current frame is on a visible screen. If not, reset
    /// to a default position anchored below the menu bar on the main screen and
    /// purge the bad autosaved frame so we don't restore it again next launch.
    private func ensureWindowOnScreen(_ win: NSWindow, defaultSize: NSSize? = nil) {
        let frame = win.frame
        // A frame is considered visible if it intersects any screen's visibleFrame
        // by at least 40 pts in both dimensions (so a sliver poking onto a screen
        // doesn't count — the user effectively can't see/grab it).
        let minOverlap: CGFloat = 40
        let onScreen = NSScreen.screens.contains { screen in
            let inter = screen.visibleFrame.intersection(frame)
            return inter.width >= minOverlap && inter.height >= minOverlap
        }
        if onScreen { return }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = defaultSize ?? frame.size
        let menuBarHeight = screen.frame.height - screen.visibleFrame.height - screen.visibleFrame.origin.y
        let margin: CGFloat = 12
        let x = screen.frame.maxX - size.width - margin
        let y = screen.frame.maxY - menuBarHeight - size.height - margin
        win.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        // Purge the bad autosave so we don't restore the offscreen frame next
        // launch. The autosave key is prefixed with "NSWindow Frame ".
        let name = win.frameAutosaveName
        if !name.isEmpty {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
        }
    }
}

// MARK: - FloatingMenuPanel (legacy — kept for source compatibility)
// Was used for the borderless BigMenu popup. The BigMenu now uses a real
// titled NSWindow, so this class isn't constructed anymore. Left in place so
// any stray reference (e.g. old build output, downstream tooling) still
// compiles. Safe to delete once we're sure nothing references it.
final class FloatingMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - NSToolbarDelegate (BigMenu "…" overflow)

extension AppDelegate: NSToolbarDelegate {
    private static let bigMenuOverflowID = NSToolbarItem.Identifier("VoiceBigMenuOverflow")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.bigMenuOverflowID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.bigMenuOverflowID]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.bigMenuOverflowID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "More"
        item.paletteLabel = "More"
        item.toolTip = "More options"
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.title = ""
        let img = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        button.image = img
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(showBigMenuOverflow(_:))
        item.view = button
        return item
    }
}

// MARK: - NSMenuDelegate (refresh dynamic items on open)

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let meetingActive = recordingState.isCapturingMeeting
        // Status header: human-readable summary of current state.
        let statusTitle: String
        if meetingActive {
            let s = recordingState.meetingDurationSeconds
            statusTitle = String(format: "Recording meeting · %d:%02d", s / 60, s % 60)
        } else if recordingState.isRecording || recordingState.isLocked {
            statusTitle = "Dictating…"
        } else if recordingState.isTranscribing {
            statusTitle = "Transcribing…"
        } else {
            statusTitle = "Idle — fn to dictate"
        }
        for item in menu.items {
            if item.tag == MenuTag.launchAtLogin.rawValue {
                item.state = LaunchAtLoginService.isEnabled ? .on : .off
            } else if item.tag == MenuTag.recentsSubmenu.rawValue, let sub = item.submenu {
                refreshRecentsSubmenu(sub)
            } else if item.tag == MenuTag.stopMeeting.rawValue {
                item.isHidden = !meetingActive
            } else if item.tag == MenuTag.startMeeting.rawValue {
                // Start is the inverse of Stop: only visible when no capture is active.
                item.isHidden = meetingActive
            } else if item.tag == MenuTag.upcomingCall.rawValue {
                if let call = MeetingCalendarService.shared.upcoming.first(where: { $0.start > Date() }) {
                    let seconds = max(0, Int(call.start.timeIntervalSinceNow))
                    item.title = "\(call.title) · in \(seconds / 60)m \(seconds % 60)s"
                    item.isHidden = false
                } else {
                    item.isHidden = true
                }
            } else if item.tag == MenuTag.statusHeader.rawValue {
                item.title = statusTitle
            }
        }
        // Also refresh the icon when the menu opens — cheap, no timer needed.
        refreshMenuBarIcon()
    }

    /// "Stop meeting recording" menu bar item handler. Posts the same
    /// notification the pill tap uses so the off-limits AppDelegate
    /// meeting-handling code remains the single source of truth.
    @objc fileprivate func stopMeetingFromMenu() {
        NotificationCenter.default.post(name: .voiceStopMeetingRequested, object: nil)
    }

    /// "Start meeting recording" menu bar item handler. Manual override
    /// for solo recordings, testing, and any case where auto-detection
    /// didn't fire. Bypasses the participant-count and frontmost-app
    /// gates because the user is explicitly asking for it.
    @objc fileprivate func startMeetingFromMenu() {
        if recordingState.isCapturingMeeting {
            print("[VOICE-MEET] startMeetingFromMenu — already capturing, ignoring")
            return
        }
        startMeetingCapture(manual: true)
    }
}

// MARK: - Remote control from Companion

extension AppDelegate: FlowCommandHost {

    /// Settings that are normally re-read only when this process changes its
    /// own defaults. Companion writes them from outside, where that notice never
    /// fires, so it asks for this instead.
    fileprivate func reconcileSettingsFromDefaults() {
        UserDefaults.standard.synchronize()
        reconcileMeetingDetectors()
        Task { await WisprImportService.refreshVocabulary() }
        // The other in-app listeners of a defaults change (wake word, pill
        // position) re-read through the notice they already observe.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }

    /// The command is only a request to show Flow's picker. The file URL
    /// comes from the user's local selection and never crosses the IPC wire.
    private func chooseMeetingAudioForImport() async -> FlowCommandReply {
        guard !meetingAudioImportInProgress else { return .failed("The audio picker is already open") }
        guard canImportMeetingAudio else { return .failed("Wait for Flow to finish recording or processing first") }
        meetingAudioImportInProgress = true
        defer { meetingAudioImportInProgress = false }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .mpeg4Audio, .aiff]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file to save and transcribe as a meeting."
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        let response = await withCheckedContinuation { continuation in
            panel.begin { result in continuation.resume(returning: result) }
        }
        guard response == .OK, let url = panel.url else { return .done("Import canceled") }
        guard canImportMeetingAudio else { return .failed("Flow started recording or processing. Try importing again when it is ready") }
        guard let meeting = await meetingRecovery.importAudioFile(url, kind: .meeting) else {
            return .failed(meetingRecovery.lastAudioFailure ?? "Couldn’t import this audio file")
        }
        reloadMeetingsFromDisk()
        NotificationCenter.default.post(name: .voiceTranscribeMeetingRequested,
                                        object: nil, userInfo: ["meetingId": meeting.id.uuidString])
        return .done("Meeting audio saved. Transcribing…")
    }

    private var canImportMeetingAudio: Bool {
        !flowIsYielding && !recordingState.isRecording && !recordingState.pendingRecordingStart
            && !recordingState.isTranscribing && !recordingState.isPolishingSelection && !flowRetryInProgress
            && !recordingState.isCapturingMeeting && meetingStartTask == nil && !meetingStopping
    }

    /// Every command goes through the path its button or key already uses.
    func flowPerform(_ command: FlowCommand, id: UUID?, value: String?) async -> FlowCommandReply {
        if flowIsYielding && command != .ping { return .failed("Flow is not active right now") }
        switch command {
        case .ping:
            return .done("pong")

        case .startMeeting:
            guard !meetingStopping else { return .failed("The previous meeting is saving") }
            guard !recordingState.isCapturingMeeting, meetingStartTask == nil else {
                return .failed("A meeting is already starting or recording")
            }
            startMeetingCapture(manual: true)
            return .done("Starting the meeting recording")

        case .stopMeeting:
            guard !meetingStopping else { return .failed("The meeting is already saving") }
            guard recordingState.isCapturingMeeting || meetingStartTask != nil else {
                return .failed("No meeting is recording")
            }
            stopMeetingCapture(reason: "pureMenu")
            return .done("Saving the meeting recording")

        case .importMeetingAudio:
            return await chooseMeetingAudioForImport()

        case .retranscribeMeeting, .deleteMeeting:
            guard let id else { return .failed("A valid id is required") }
            let row: Meeting?
            do { row = try coordinator.storage.fetchMeeting(id: id) }
            catch { return .failed("History is unavailable") }
            guard let row else { return .failed("That meeting no longer exists") }
            guard row.kind == .meeting else { return .failed("That recording is a dictation, not a meeting") }
            if command == .deleteMeeting {
                guard recordingState.activeMeetingId != id else { return .failed("That meeting is still recording") }
                NotificationCenter.default.post(name: Notification.Name("voice.deleteMeetingRequested"),
                                                object: nil, userInfo: ["meetingId": id.uuidString])
                return .done("Deleting the meeting")
            }
            NotificationCenter.default.post(name: .voiceTranscribeMeetingRequested,
                                            object: nil, userInfo: ["meetingId": id.uuidString])
            return .done("Transcribing the meeting again")

        case .retryDictation:
            guard let id else { return .failed("A valid id is required") }
            // Answer the cheap questions (gone, no audio) before anything else.
            if case .failure(let failure) = DictationRetryService.audioURL(for: id, storage: coordinator.storage) {
                return .failed(failure.message)
            }
            guard !recordingState.isRecording, !recordingState.isTranscribing, !flowRetryInProgress else {
                return .failed("Flow is busy with another dictation. Try again in a moment")
            }
            flowRetryInProgress = true
            defer { flowRetryInProgress = false }
            switch await DictationRetryService.retry(id: id, storage: coordinator.storage,
                                                     transcription: coordinator.transcription,
                                                     formatter: textFormatter) {
            case .success: return .done("Dictation transcribed again")
            case .failure(let failure): return .failed(failure.message)
            }

        case .deleteDictation:
            guard let id else { return .failed("A valid id is required") }
            let row: Meeting?
            do { row = try coordinator.storage.fetchMeeting(id: id) }
            catch { return .failed("History is unavailable") }
            guard let row else { return .failed("That dictation no longer exists") }
            guard row.kind == .dictation else { return .failed("That recording is a meeting, not a dictation") }
            // Locked to the app (14 Nov 2026): the IPC channel is unauthenticated, so any local
            // process could send this. Jordan must confirm in Flow's own window first.
            let confirm = NSAlert()
            confirm.messageText = "Delete this dictation?"
            confirm.informativeText = "Another app asked Flow to delete it. This cannot be undone."
            confirm.addButton(withTitle: "Delete")
            confirm.addButton(withTitle: "Keep")
            NSApp.activate(ignoringOtherApps: true)
            guard confirm.runModal() == .alertFirstButtonReturn else {
                return .failed("Not deleted: Jordan did not confirm in Flow")
            }
            do {
                try coordinator.storage.deleteMeeting(id: id)
                return .done("Dictation deleted")
            } catch {
                let failure = error as NSError
                // Code 3: the row is gone but the audio file could not be removed.
                if failure.domain == "Voice.Storage" && failure.code == 3 {
                    return .done("Dictation deleted, but its audio was kept")
                }
                return .failed("Could not delete the dictation")
            }

        case .cancel:
            NotificationCenter.default.post(name: .voiceEscapePressed, object: nil)
            return .done("Cancelled")

        case .toggleHandsfree:
            // Starting needs the speech model; stopping never does.
            if !recordingState.isRecording && !recordingState.isLocked {
                guard checkModelsReadyOrToast() else { return .failed("The speech model is not ready yet") }
            }
            hotkeyService.fnSpacePressed()
            return .done("Hands-free toggled")

        case .rebindHotkeys:
            NotificationCenter.default.post(name: .voiceHotkeyChanged, object: nil)
            return .done("Shortcuts reloaded")

        case .reconcileSettings:
            reconcileSettingsFromDefaults()
            return .done("Settings reloaded")

        case .selectSpeechModel:
            guard let value, let id = SpeechModelID(rawValue: value),
                  SpeechModelCatalog.models().contains(where: { $0.id == id }) else {
                return .failed("That speech model is unavailable.")
            }
            coordinator.refreshSpeechModelAvailability()
            guard coordinator.speechModels.availability[id] == .available else {
                return .failed("That speech model isn’t installed on this Mac.")
            }
            coordinator.requestSpeechModelSelection(value)
            return .done("Speech model switch requested")
        }
    }
}

// MARK: - Toast + Onboarding + Error surfacing

extension AppDelegate {

    fileprivate func setupErrorObserver() {
        errorObserver = NotificationCenter.default.addObserver(
            forName: .voiceError,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?["message"] as? String) ?? "Something went wrong."
            Telemetry.log("error.surface", properties: ["message": message])
            // A diagnostics copy is not a problem: Wispr shows nothing for it.
            if message.hasPrefix("Diagnostics copied") { return }
            // Wispr's TranscriptCurrentlyProcessing card, with Cancel.
            if message.hasPrefix("Finishing previous dictations") {
                Task { @MainActor in
                    SoundEffects.playNotice(.alert)
                    self?.recordingState.flowNotice = FlowNoticeRules.currentlyProcessing()
                }
                return
            }
            // Wispr's PolishTextNotEditable: a quiet mini line, not an error card.
            if message.hasPrefix("Transcript saved to clipboard") {
                Task { @MainActor in self?.showToast(message) }
                return
            }
            if let notice = FlowPillNotice.permissionNotice(for: message) ?? FlowPillNotice.appSwitchNotice(for: message) {
                Task { @MainActor in self?.showNotice(notice) }
                return
            }
            let kind = FlowPillNotice.Kind(rawValue: note.userInfo?["flowKind"] as? String ?? "")
                ?? FlowPillNotice.Kind.inferred(from: message)
            // Wispr picks the sound by the card's status and plays it at half volume.
            SoundEffects.playNotice(kind.status)
            Task { @MainActor in
                guard let self else { return }
                if kind.status == .error { self.recordingState.flashErrorPill() }
                self.showNotice(FlowPillNotice(kind: kind, message: message, quiet: true))
                // Dump full health/config alongside the error so the JSONL log
                // carries enough context to diagnose it in isolation.
                self.emitDebugSnapshot(reason: "error", failureReasons: [message])
            }
        }

        // Mic-capture failed at meeting start. Surface a clear warning so the
        // user knows the meeting is being recorded with system audio only —
        // their own voice will be missing from playback. Without this they
        // would discover it hours later.
        let micFailedToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("voice.meetingMicFailed"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?["reason"] as? String) ?? "unknown reason"
            Task { @MainActor in
                self?.showToast("Mic capture failed (\(reason)). Recording system audio only — your voice may not be captured.")
            }
        }
        notificationTokens.append(micFailedToken)

        // Mic dropped mid-meeting. The 10s health log detected zero mic
        // samples while system audio kept flowing. Could be another app
        // grabbing exclusive mic access, device disconnect, etc.
        let micDroppedToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("voice.meetingMicDropped"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Say it once per meeting, not every 10 s health tick (Jordan, 21 Nov 2026: "keeps spamming").
                guard let self, self.lastMicDropNoticeMeeting != self.recordingState.activeMeetingId else { return }
                self.lastMicDropNoticeMeeting = self.recordingState.activeMeetingId
                self.showToast("Mic appears to have dropped mid-meeting — your voice may be missing from the recording.")
            }
        }
        notificationTokens.append(micDroppedToken)

        // Idle-pill context menu → "Open VOICE…"
        // BUGFIX: capture the token so applicationWillTerminate can remove it.
        let openBigMenuToken = NotificationCenter.default.addObserver(
            forName: .voiceOpenBigMenu,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            NSApp.activate(ignoringOtherApps: true)
            MainActor.assumeIsolated { self?.openBigMenu() }
        }
        notificationTokens.append(openBigMenuToken)
        let historyToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("flow.openHistory"), object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let recordings = note.userInfo?["recordings"] as? Bool ?? false
                if recordings { self.fetchMeetingsIntoState() }
                let id = (note.userInfo?["recordingID"] as? String).flatMap(UUID.init(uuidString:))
                self.recordingState.flowWindowRequest = FlowWindowRequest(
                    destination: recordings ? .recordings : .dictations, recordingID: id)
                self.openBigMenu()
            }
        }
        notificationTokens.append(historyToken)
        let settingsToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("flow.openSettings"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openBigMenuSettings() }
        }
        notificationTokens.append(settingsToken)


        // System notification click ("Transcript ready") → open BigMenu pre-
        // scrolled + expanded to that meeting row. The MeetingNotificationDelegate
        // translates the UN tap into this NotificationCenter post; we stash the
        // ID in a static so BigMenuWindow picks it up on first appearance, and
        // BigMenuWindow also listens to this same notification for the
        // already-open case.
        let openMeetingFromNotifToken = NotificationCenter.default.addObserver(
            forName: .voiceOpenMeetingFromNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let idStr = (note.userInfo?["meetingId"] as? String) ?? ""
                AppDelegate.pendingMeetingIDFromNotification = idStr.isEmpty ? nil : idStr
                NSApp.activate(ignoringOtherApps: true)
                self.openBigMenu()
            }
        }
        notificationTokens.append(openMeetingFromNotifToken)

        // Global Escape → cancel any in-flight dictation work. HotkeyService
        // posts this on every Esc keyDown; cancelInFlightProcessing() gates on
        // the current pipeline phase so idle Esc remains a true no-op (we
        // never shadow system-wide Esc semantics in other apps).
        let escapeToken = NotificationCenter.default.addObserver(
            forName: .voiceEscapePressed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordingState.flowNotice = nil
                self?.cursorPaster.cancelPendingSubmission()
                self?.cancelInFlightProcessing()
            }
        }
        notificationTokens.append(escapeToken)

        let polishToken = NotificationCenter.default.addObserver(
            forName: .voicePolishSelectionPressed, object: nil, queue: .main
        ) { [weak self] note in
            let quick = note.userInfo?["quick"] as? Bool ?? false
            MainActor.assumeIsolated { self?.handlePolishSelection(quick: quick) }
        }
        notificationTokens.append(polishToken)

        let pasteLastToken = NotificationCenter.default.addObserver(
            forName: .voicePasteLastTranscriptPressed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePasteLastTranscript() }
        }
        notificationTokens.append(pasteLastToken)
        let micToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("flow.micSwitched"), object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let label = note.userInfo?["label"] as? String else { return }
                self.recordingState.micHint = label
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    if self?.recordingState.micHint == label { self?.recordingState.micHint = nil }
                }
            }
        }
        notificationTokens.append(micToken)


        // All defaults changes can include privacy mode. Reconcile only on a
        // real gate transition so unrelated settings never duplicate listeners.
        let detectionSettingsToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileMeetingDetectors() }
        }
        notificationTokens.append(detectionSettingsToken)

        // Settings posts this when a meeting-detection switch is flipped. It had
        // no observer; it now runs the same reconcile as a defaults change.
        let detectionChangedToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("voice.meetingDetectionSettingsChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileMeetingDetectors() }
        }
        notificationTokens.append(detectionChangedToken)

        // Auto-start meeting capture when poll timer detects a meeting app.
        let autoStartMeetingToken = NotificationCenter.default.addObserver(
            forName: .voiceAutoStartMeeting,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.recordingState.isCapturingMeeting else { return }
                if AppDelegate.isMeetingDetectionDisabled {
                    print("[VOICE-MEET] .voiceAutoStartMeeting blocked — voice.disableMeetingDetection is true")
                    return
                }
                print("[VOICE-MEET] Auto-starting meeting capture")
                print("[VOICE-MEET-START] reason=voiceAutoStartMeeting source=notification")
                self.handleDetectedMeeting(source: "notification")
            }
        }
        notificationTokens.append(autoStartMeetingToken)

        // Menu bar "Stop meeting recording" → call the existing stop flow.
        let stopMeetingToken = NotificationCenter.default.addObserver(
            forName: .voiceStopMeetingRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recordingState.isCapturingMeeting else { return }
                self.stopMeetingCapture(reason: "userStopRequested")
            }
        }
        notificationTokens.append(stopMeetingToken)

        // BigMenu meetings empty-state "Start meeting manually" button →
        // same flow as the menu bar's "Start Meeting Recording" item so
        // there's one canonical path for user-initiated meeting captures.
        let startMeetingManualToken = NotificationCenter.default.addObserver(
            forName: .voiceStartMeetingManual,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startMeetingFromMenu()
            }
        }
        notificationTokens.append(startMeetingManualToken)

        // Watchdog: MeetingCaptureService posts this when no fresh audio
        // samples have arrived for >5s while capture is supposedly active.
        // Surface a toast so the user knows the recording may be incomplete.
        let audioStalledToken = NotificationCenter.default.addObserver(
            forName: .voiceMeetingAudioStalled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showToast("Meeting audio stopped unexpectedly — recording may be incomplete.")
            }
        }
        notificationTokens.append(audioStalledToken)

        // BigMenu "Delete meeting" context-menu → resolve meeting by ID,
        // delete the DB row + audio file via StorageService.deleteMeeting,
        // and post a toast confirming. Same notification-driven pattern as
        // transcribe so the view layer never has to reach into AppDelegate.
        let deleteMeetingToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("voice.deleteMeetingRequested"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let idStr = note.userInfo?["meetingId"] as? String,
                      let uuid = UUID(uuidString: idStr) else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        // A partial delete can remove history even if audio removal fails.
                        NotificationCenter.default.post(
                            name: Notification.Name("voice.meetingsChanged"), object: nil
                        )
                    }
                    do {
                        try self.coordinator.storage.deleteMeeting(id: uuid)
                        self.showToast("Meeting deleted.")
                    } catch {
                        let failure = error as NSError
                        // The storage partial-delete description includes a filesystem
                        // error, which may expose a private path. Preserve its meaning.
                        if failure.domain == "Voice.Storage" && failure.code == 3 {
                            self.showToast("Meeting history was deleted, but its audio was kept.")
                        } else if failure.domain == "Voice.Storage" && failure.code == 2 {
                            self.showToast("Flow history is unavailable. Please try again.")
                        } else {
                            self.showToast("Couldn’t delete the meeting. Please try again.")
                        }
                    }
                }
            }
        }
        notificationTokens.append(deleteMeetingToken)

        // BigMenu "Transcribe now" → resolve meeting by ID, run retranscribe,
        // post result back via .voiceTranscribeMeetingFinished. Avoids the
        // fragile NSApp.delegate cast from a SwiftUI view layer.
        let transcribeRequestedToken = NotificationCenter.default.addObserver(
            forName: .voiceTranscribeMeetingRequested,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let idStr = note.userInfo?["meetingId"] as? String,
                      let uuid = UUID(uuidString: idStr) else { return }
                let meetings = self.coordinator.fetchAllMeetings()
                guard let meeting = meetings.first(where: { $0.id == uuid }) else {
                    NotificationCenter.default.post(
                        name: .voiceTranscribeMeetingFinished,
                        object: nil,
                        userInfo: [
                            "meetingId": idStr,
                            "success": false,
                            "error": "Meeting not found in DB."
                        ]
                    )
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Wait briefly for the engine to load — at most ~10s.
                    var waited: Int = 0
                    while !self.coordinator.transcription.isReady && waited < 20 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        waited += 1
                    }
                    guard self.coordinator.transcription.isReady else {
                        NotificationCenter.default.post(
                            name: .voiceTranscribeMeetingFinished,
                            object: nil,
                            userInfo: [
                                "meetingId": idStr,
                                "success": false,
                                "error": "Transcription model still loading — try again in a moment."
                            ]
                        )
                        return
                    }
                    let result = await self.meetingRecovery.retranscribe(meeting: meeting)
                    if result != nil {
                        self.reloadMeetingsFromDisk()
                    }
                    NotificationCenter.default.post(
                        name: .voiceTranscribeMeetingFinished,
                        object: nil,
                        userInfo: [
                            "meetingId": idStr,
                            "success": result != nil,
                            "error": result == nil ? "Couldn't transcribe. The audio file may be corrupted or empty." : nil as Any?
                        ].compactMapValues { $0 }
                    )
                    // System notification — fires regardless of BigMenu state
                    // so the user knows it's done even while another app is
                    // focused. The in-window toast (.voiceTranscribeMeetingFinished
                    // observer in the row) also fires; users see whichever
                    // surfaces first.
                    if let updated = result {
                        MeetingNotifier.notify(
                            title: "Transcript ready",
                            body: updated.title,
                            meetingId: idStr
                        )
                    } else {
                        MeetingNotifier.notify(
                            title: "Couldn't transcribe meeting",
                            body: "Audio file may be corrupted or empty.",
                            meetingId: idStr
                        )
                    }
                }
            }
        }
        notificationTokens.append(transcribeRequestedToken)

        // The Changes window's Undo and Try again (PolishDiffWindow) come back here.
        for name in [Notification.Name.flowUndoLastPolish, .flowRetryLastPolish] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.undoLastPolish(thenRetry: note.name == .flowRetryLastPolish, expectedDiffID: note.object as? UUID)
                }
            }
            notificationTokens.append(token)
        }

        // (The Meetings tab used to post cancel/commit notifications observed
        // here. That tab was removed in favor of a future browser-extension
        // sourced meetings view — observers gone too.)
    }

    @MainActor
    /// Polish-in-place. Called either from the hotkey monitor (passes nil so we
    /// read selection ourselves) or from handlePillTap (passes the already-read
    /// selection to avoid a second AX round-trip).
    /// Polish the selected text. `level` lets a caller (Option-1/2/3, the pill
    /// menu) pick the strength for this single call without touching any saved
    /// preference. Valid values: "light" / "medium" / "heavy" (see PolishLevel).
    /// When nil or unknown, the saved `polishPreset` is used.
    private func handlePolishSelection(retrying originalSelection: CursorPaster.SelectionSnapshot? = nil,
                                       level levelName: String? = nil, quick: Bool = false) {
        guard !Self.wisprFlowRunning else {
            showToast("Polish waits while Wispr Flow is open.")
            return
        }
        let level = levelName.flatMap { PolishLevel(rawValue: $0.lowercased()) }
        print("[VOICE-POLISH] handlePolishSelection ENTER level=\(level?.rawValue ?? "default")")
        guard AXIsProcessTrusted() else {
            print("[VOICE-POLISH] BLOCKED: AX not trusted")
            showNotice(.permission(.accessibility))
            return
        }
        let admission = OperationAdmission.forPolish(
            isRecording: recordingState.isRecording,
            pendingStart: recordingState.pendingRecordingStart,
            isTranscribing: recordingState.isTranscribing,
            isPolishing: recordingState.isPolishingSelection)
        if let notice = OperationAdmission.notice(for: admission) {
            print("[VOICE-POLISH] BLOCKED: \(admission)")
            showToast(notice)
            return
        }

        let selection: CursorPaster.SelectionSnapshot
        if let originalSelection {
            guard cursorPaster.canReviewPolishSelection(originalSelection) else {
                showToast("The original selection changed. Select it to polish again.")
                return
            }
            selection = originalSelection
        } else {
            guard let current = cursorPaster.captureSelectionForPolish(),
                  !current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showToast("Couldn’t read selected text. Select text to polish.")
                return
            }
            selection = current
        }
        let text = selection.text
        guard !PolishTransaction.isTooLong(text) else {
            showToast("That selection is too long to polish. Select up to 6,000 characters.")
            return
        }

        recordingState.polishWords = text.split(whereSeparator: \.isWhitespace).count
        recordingState.isPolishingSelection = true
        recordingState.polishDiff = nil
        let recoveryID = beginPasteRecoveryWindow()
        let quickStartedAt = ContinuousClock.now
        let deadline = quick ? quickStartedAt + .seconds(PolishTransaction.shortcutBudgetSeconds(for: text)) : nil
        let timing = quick ? QuickPolishTiming(words: text.split(whereSeparator: \.isWhitespace).count, at: quickStartedAt) : nil
        recordingState.polishWorkEstimate = timing?.estimate(using: quickPolishTimingHistory)
        let operationID = polishGate.begin()
        let evidenceAt = Date()
        let saveEvidence: Bool = if quick, Opt1EvidenceLog.isEnabled, !fnSecureInputOn(), !BackgroundActivityGate.privacyMode,
                                   let element = selection.target.focusedElement {
            (AccessibilityBudget.copyAttribute(element, kAXSubroleAttribute, app: selection.target.bundleId) as? String)
                != (kAXSecureTextFieldSubrole as String)
        } else {
            false
        }

        // One local training record for this run (FlowRunLog). Never for a password field.
        let secureField = fnSecureInputOn() || (selection.target.focusedElement.flatMap {
            AccessibilityBudget.copyAttribute($0, kAXSubroleAttribute, app: selection.target.bundleId) as? String
        } == (kAXSecureTextFieldSubrole as String))
        let run = FlowRunCollector(kind: "opt1", id: operationID.uuidString, app: selection.target.bundleId,
                                   input: text, startedAt: evidenceAt)
        run.update {
            $0.settings = ["quick": "\(quick)", "level": level?.rawValue ?? "default",
                           "preset": level?.preset ?? PolishPreset.current.rawValue,
                           "method": selection.method, "viaCopy": "\(selection.viaCopy)",
                           "budgetSeconds": String(format: "%.2f", PolishTransaction.shortcutBudgetSeconds(for: text))]
        }
        run.model("opt1", ReviewPolishModel.typoFixModelFile?.lastPathComponent)
        polishSelectionTask = Task { @MainActor in
            var evidenceOutcome: Opt1Evidence.Outcome = .cancelled
            var evidenceOutput: String?
            var appliedText: String?
            defer {
                if !secureField {
                    run.update { $0.settings["route"] = Qwen3Polisher.lastOpt1Route }
                    if let rejection = Qwen3Polisher.lastSelectedRejection {
                        run.decision("opt1-guard", "rejected", reason: "\(rejection)")
                    }
                    run.finish(outcome: evidenceOutcome.rawValue, output: appliedText ?? evidenceOutput)
                    self.lastPolishRunID = run.snapshot.id
                }
                if [.applied, .unchanged, .unconfirmed].contains(evidenceOutcome) {
                    PillWorkTiming.recordPolish(words: text.split(whereSeparator: \.isWhitespace).count,
                                                seconds: Double(run.elapsedMs) / 1000)
                }
                if saveEvidence, Opt1EvidenceLog.isEnabled, !BackgroundActivityGate.privacyMode {
                    Opt1EvidenceLog.enqueue(Opt1Evidence(operationID: operationID, recordedAt: evidenceAt,
                                                          outcome: evidenceOutcome, input: text,
                                                          proposedOutput: evidenceOutput))
                }
                if self.polishGate.end(operationID) {
                    self.recordingState.isPolishingSelection = false
                }
                print("[VOICE-POLISH] DONE")
            }

            // A level rides its matching preset (light=fix, medium=smooth,
            // heavy=elevate) and brings its own instruction. Nothing saved is
            // changed: the dictation `cleanupLevel` stays the user's own.
            let preset = level?.preset ?? PolishPreset.current.rawValue
            print("[VOICE-POLISH] preset=\(preset) level=\(level?.rawValue ?? "<default>")")

            var timing = timing
            @MainActor
            func advance(_ stage: FlowWorkPresentation.PolishStage) {
                guard self.polishGate.isCurrent(operationID) else { return }
                timing?.enter(stage, at: ContinuousClock.now)
                self.recordingState.polishWorkStage = stage
                self.recordingState.polishWorkEstimate = timing?.estimate(using: self.quickPolishTimingHistory)
            }

            let polishedRaw: String?
            if quick {
                let result = await FlowRunCollector.$current.withValue(run) {
                    await Qwen3Polisher.shared.polishShortcut(text, deadline: deadline, onLoading: { loading in
                        advance(loading ? .loadingModel : .editing)
                    }, onDraft: {
                        advance(.checkingDraft)
                    })
                }
                polishedRaw = result.text
                evidenceOutput = result.text
            } else {
                Task(priority: .utility) { await DraftDecisionGate.prewarmIfEnabled() }
                let proposed = await FlowRunCollector.$current.withValue(run) {
                    await Qwen3Polisher.shared.polishInPlace(text, preset: preset, level: level)
                }
                run.stage("polish", text: proposed, ms: run.elapsedMs)
                if let proposed, await DraftDecisionGate.shouldKeepOriginal(text, edited: proposed) {
                    run.decision("decision-gate", "kept-original", reason: "meaning changed")
                    polishedRaw = text
                } else {
                    polishedRaw = proposed
                }
            }
            // Same final word pass as dictation: hesitations never reach the field. Nothing left means no change.
            let polished: String? = polishedRaw.map { DictationFinalPass.apply($0) }.flatMap { $0.isEmpty ? nil : $0 }

            // ESC-cancel checkpoint: an Escape during the call means no replacement, ever.
            guard !Task.isCancelled, self.polishGate.isCurrent(operationID) else { return }

            if quick && !UserDefaults.standard.bool(forKey: HotkeyService.quickPolishEnabledKey) { return }
            let modelSamples = timing?.samples(endingAt: ContinuousClock.now) ?? []
            // Who edited this one, shown quietly on the card and the "no changes" line.
            let madeBy: String? = quick
                ? (TypoFixModel.isAvailable
                    ? ModelLabel.optOne(route: Qwen3Polisher.lastOpt1Route, modelFile: ReviewPolishModel.typoFixModelFile) : nil)
                : ModelLabel.short(PolishStatus.shared.lastEngine)
            if quick, polished == text {
                evidenceOutcome = .unchanged
                self.quickPolishTimingHistory.record(modelSamples)
                self.showToast(madeBy.map { "No changes needed · " + $0 } ?? "No changes needed.")
                return
            }
            let outcome = PolishTransaction.classify(original: text, candidate: polished,
                                                     rejection: polished == nil ? Qwen3Polisher.lastSelectedRejection : nil)
            guard outcome == .changed, let polished else {
                switch outcome {
                case .noChangesNeeded: evidenceOutcome = .unchanged
                case .couldNotImprove: evidenceOutcome = .rejected
                default: evidenceOutcome = .unavailable
                }
                self.showToast(outcome.message)
                return
            }

            guard let expectedFull = selection.expectedFullText(replacingWith: polished) else {
                if quick { self.quickPolishTimingHistory.record(modelSamples) }
                // Chrome, Electron and web editors: no range to verify, so paste over the
                // selection only after reading it again and finding the same text there.
                self.recordingState.polishWorkStage = .applying
                if selection.viaCopy, self.cursorPaster.replaceUnverifiedSelection(with: polished, expected: selection) {
                    evidenceOutcome = .unconfirmed
                    Telemetry.log("polish.applied_unverified", properties: ["method": selection.method,
                                                                             "app": selection.target.bundleId ?? "unknown"])
                    self.lastPolish = nil
                    self.lastPolishEvidenceID = saveEvidence ? operationID : nil
                    let diff = PolishDiff(original: text, polished: polished, undoAvailable: false, model: madeBy)
                    appliedText = polished
                    run.update { $0.settings["diffID"] = diff.id.uuidString }
                    self.recordingState.polishDiff = diff
                    return
                }
                evidenceOutcome = .notApplied
                self.showPasteRecovery(polished, id: recoveryID, copyOnly: selection.viaCopy)
                return
            }
            self.recordingState.polishWorkStage = .applying
            guard self.cursorPaster.replaceSelection(with: polished, expected: selection) else {
                evidenceOutcome = .notApplied
                self.showPasteRecovery(polished, id: recoveryID)
                return
            }
            evidenceOutcome = .unconfirmed
            let verified = await self.cursorPaster.waitForPolishText(expectedFull, in: selection.target)
            guard self.polishGate.isCurrent(operationID), !Task.isCancelled else { return }
            if !verified {
                let current = self.cursorPaster.currentText(of: selection.target)
                // 23 Nov 2026: "Paste not confirmed" fired whenever AX returned no text, because nil != expected.
                // Electron and web editors expose no readable value, so unreadable is unknown, not failed:
                // the paste was sent, so it stays applied with no toast. Only a readable field that still
                // holds the original text is a known failure ("Couldn't paste"). Other readable text (the user
                // typed, or the editor rewrote it) is also unknown: no toast.
                // A slow editor can update just after the readback deadline, so this check runs only on a read.
                if let current, current != expectedFull {
                    if current == selection.fullText {
                        evidenceOutcome = .notApplied
                        self.showPasteRecovery(polished, id: recoveryID)
                        return
                    }
                }
            }
            evidenceOutcome = .applied
            self.quickPolishTimingHistory.record(modelSamples)
            let diff = PolishDiff(original: text, polished: polished, undoAvailable: true, model: madeBy)
            appliedText = polished
            run.update { $0.settings["diffID"] = diff.id.uuidString }
            self.lastPolish = LastPolish(
                diffID: diff.id, target: selection.target, original: text, candidate: polished,
                candidateRange: CFRange(location: selection.range.location, length: polished.utf16.count),
                expectedFullText: expectedFull, quick: quick)
            self.lastPolishEvidenceID = saveEvidence ? operationID : nil
            self.recordingState.polishDiff = diff
            PillHaptics.polishFinished()
            // Auto-dictionary: a result he keeps (no Undo) is evidence for the fixes in it.
            if !BackgroundActivityGate.privacyMode {
                CorrectionLearner.shared.trackPolish(diffID: diff.id, original: text, polished: polished, target: selection.target)
            }
        }
    }

    /// Restore only the field and text that the verified edit originally replaced.
    @MainActor
    func undoLastPolish(thenRetry: Bool = false, expectedDiffID: UUID? = nil) {
        guard let last = lastPolish else {
            showToast("No edit to undo.")
            return
        }
        guard PolishTransaction.matchesUndo(requested: expectedDiffID, active: last.diffID) else {
            showToast("This review shows an older edit.")
            return
        }
        let admission = OperationAdmission.forPolish(
            isRecording: recordingState.isRecording,
            pendingStart: recordingState.pendingRecordingStart,
            isTranscribing: recordingState.isTranscribing,
            isPolishing: recordingState.isPolishingSelection)
        if let notice = OperationAdmission.notice(for: admission) {
            showToast(notice)
            return
        }
        guard let expectedOriginal = PolishTransaction.expectedFullText(
            before: last.expectedFullText,
            range: NSRange(location: last.candidateRange.location, length: last.candidateRange.length),
            replacement: last.original) else { return }

        recordingState.polishDiff = nil
        recordingState.isPolishingSelection = true
        recordingState.polishWorkStage = .restoring
        let operationID = polishGate.begin()
        polishSelectionTask = Task { @MainActor in
            var retrySelection: CursorPaster.SelectionSnapshot?
            defer {
                if self.polishGate.end(operationID) {
                    self.recordingState.isPolishingSelection = false
                    if let retrySelection { self.handlePolishSelection(retrying: retrySelection, quick: last.quick) }
                }
            }

            if expectedDiffID != nil, !(await self.returnFocusForReview(to: last.target)) {
                self.showToast("Open the original field to undo this edit.")
                return
            }
            guard self.polishGate.isCurrent(operationID), !Task.isCancelled else { return }
            guard self.cursorPaster.restorePolish(
                target: last.target, original: last.original, candidate: last.candidate,
                candidateRange: last.candidateRange, expectedFullText: last.expectedFullText) else {
                self.showToast("Couldn’t undo in the original field. Check whether the text changed.")
                return
            }
            guard await self.cursorPaster.waitForPolishText(expectedOriginal, in: last.target) else {
                if !Task.isCancelled { self.showToast("Couldn’t confirm Undo. Check your text.") }
                return
            }
            guard self.polishGate.isCurrent(operationID), !Task.isCancelled else { return }
            if let id = self.lastPolishEvidenceID, !BackgroundActivityGate.privacyMode {
                Opt1EvidenceLog.enqueue(Opt1Evidence(operationID: id, recordedAt: .now, outcome: .undone))
            }
            // Auto-dictionary: Undo takes out every learned fix this edit made.
            CorrectionLearner.shared.polishUndone(diffID: last.diffID, original: last.original, candidate: last.candidate)
            if let id = self.lastPolishRunID {
                FlowRunLog.followup(id: id, kind: "opt1", followup: thenRetry ? "undo-and-retry" : "undo",
                                    app: last.target.bundleId)
            }
            self.lastPolish = nil
            self.lastPolishEvidenceID = nil
            guard thenRetry else {
                self.showToast("Original text restored.")
                return
            }
            let originalRange = CFRange(location: last.candidateRange.location, length: last.original.utf16.count)
            if self.cursorPaster.selectRange(originalRange, in: last.target) {
                retrySelection = CursorPaster.SelectionSnapshot(target: last.target, text: last.original,
                                                               fullText: expectedOriginal, range: originalRange)
            } else {
                self.showToast("Select the original text to polish it again.")
            }
        }
    }

    /// Review temporarily focuses Flow. Return to the same editor process, then let the
    /// actual undo check verify field identity and the full contents before writing.
    @MainActor
    private func returnFocusForReview(to target: CursorPaster.PasteTargetSnapshot) async -> Bool {
        guard let element = target.focusedElement else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let editor = NSRunningApplication(processIdentifier: pid),
              editor.bundleIdentifier == target.bundleId else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }

        let helperPID = ProcessInfo.processInfo.processIdentifier
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == helperPID,
              editor.activate(options: []) else { return false }
        for _ in 0..<8 {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front == pid { return true }
            if front != helperPID { return false }
        }
        return false
    }

    // MARK: - Permission handling

    /// Single permission-miss handler. Throttles the system prompt to once
    /// per session, deep-links to the right Privacy pane, and starts a
    /// background watcher so that as soon as Accessibility flips to granted
    /// we rebind the hotkey monitors (NSEvent monitors registered before
    /// permission was granted don't deliver events retroactively).
    fileprivate func handleMissingPermissions(micOk: Bool, axOk: Bool, srOk: Bool = true, micStatus: AVAuthorizationStatus) {
        if !micOk {
            if micStatus == .notDetermined, !didShowMicPrompt {
                didShowMicPrompt = true
                Task { @MainActor in
                    await PermissionsService.shared.requestMicrophone()
                    FlowCommandListener.shared.emitState(force: false)
                    if PermissionsService.shared.microphone != .granted {
                        self.showNotice(.permission(.microphone))
                    }
                }
            } else {
                showNotice(.permission(.microphone))
            }
            return
        }

        if !axOk {
            startPermissionWatcher()
            showNotice(.permission(.accessibility))
            return
        }

        if !srOk { showNotice(.permission(.screenRecording)) }
    }

    /// Open the System Settings → Privacy → <pane> directly. The
    /// `x-apple.systempreferences:` URL scheme handles both legacy and
    /// modern (System Settings) variants — macOS picks the right one.
    fileprivate func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Detect transcripts that landed in a non-Latin script (Greek, Cyrillic,
    /// CJK, Arabic, Hebrew, Thai, Devanagari etc.). Returns true if >30% of
    /// the letter characters are outside the Basic Latin / Latin-1 /
    /// Latin-Extended ranges. English and Dutch both live entirely inside
    /// Latin script, so a high non-Latin ratio is a reliable sign that the
    /// multilingual ASR mis-identified the language.
    fileprivate func isPredominantlyNonLatin(_ text: String) -> Bool {
        DictationTextPreparation.predominantlyNonLatin(text)
    }

    /// Count the spoken punctuation / structural commands the TextFormatter
    /// will turn into characters. Conservative substring count over the raw
    /// Parakeet transcript — matches the same vocabulary the formatter checks
    /// (period, comma, new line, exclamation, etc.). Used by the BigMenu
    /// stats row to populate "fixes made by voice".
    fileprivate func countVoiceCommands(in raw: String) -> Int {
        let lowered = " " + raw.lowercased() + " "
        // Multi-word phrases first so "exclamation point" isn't counted twice
        // (once as the long phrase, once as "point" — but we don't track that
        // anyway). Order mirrors TextFormatter.voiceCommands intent.
        let phrases: [String] = [
            "new paragraph", "new line", "next line",
            "exclamation point", "exclamation mark", "explanation point", "explanation mark",
            "question mark", "full stop", "open quote", "close quote",
            "open paren", "close paren", "bullet point", "dash point", "numbered list",
            "dash dash", "double dash", "double hyphen", "equals sign",
            "period", "comma", "colon", "semicolon", "ellipsis",
            "tilde", "caret", "dash", "bullet", "tab"
        ]
        // Strip multi-word phrases by length first to avoid double-count.
        var scratch = lowered
        var total = 0
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            let needle = " " + phrase + " "
            var searchRange = scratch.startIndex..<scratch.endIndex
            while let r = scratch.range(of: needle, range: searchRange) {
                total += 1
                scratch.replaceSubrange(r, with: " ")
                searchRange = r.lowerBound..<scratch.endIndex
            }
        }
        return total
    }

    // MARK: - Per-app personality routing

    /// Map the frontmost app's bundle ID to a personality name.
    /// Returns nil when auto-personality is disabled, the app is unknown,
    /// or VOICE itself is frontmost. A nil return means "use the user's
    /// current setting unchanged".
    fileprivate func personalityForFrontmostApp() -> String? {
        Self.autoPersonality(forBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Auto-personality for an app (nil = keep the user's setting). Shared with shadow mode.
    static func autoPersonality(forBundleID bundleID: String?) -> String? {
        guard let bundle = bundleID, bundle != Bundle.main.bundleIdentifier else { return nil }
        return AppWritingCategory.style(for: bundle)

    }

    // MARK: - Rich app-context capture (for cloud polish)

    /// Read the focused AX element's role + the focused window title +
    /// the focused field's placeholder. All three are best-effort: any may
    /// be nil if AX isn't granted or the app doesn't expose them.
    ///
    /// Roles seen in practice: `AXTextField` (single-line), `AXTextArea`
    /// (multi-line), `AXComboBox` (search), `AXStaticText` (rich
    /// editors that don't expose proper roles). We map these to short
    /// human-readable hints — the cloud model uses them to pick length.
    fileprivate static func readFocusedAXMetadata() -> (role: String?, windowTitle: String?, placeholder: String?) {
        guard AXIsProcessTrusted() else { return (nil, nil, nil) }

        // Every read here is budgeted: a slow app times out and the field gets no hints.
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let sys = AccessibilityBudget.bind(AXUIElementCreateSystemWide())
        guard let focused = AccessibilityBudget.copyAttribute(sys, kAXFocusedUIElementAttribute, app: app) else {
            return (nil, nil, nil)
        }
        let element = AccessibilityBudget.bind(focused as! AXUIElement)

        // Role: kAXRoleAttribute → "AXTextField" etc.
        let role = AccessibilityBudget.copyAttribute(element, kAXRoleAttribute, app: app) as? String

        // Placeholder: many text fields expose this even when empty, e.g.
        // Slack shows "Message #design", Gmail shows "Subject" etc.
        let placeholder = AccessibilityBudget.copyAttribute(element, kAXPlaceholderValueAttribute, app: app) as? String

        // Window title: walk up to focused window. Title often carries
        // doc name / channel / subject / file — the strongest signal of
        // WHAT the user is writing about.
        var windowTitle: String? = nil
        if let win = AccessibilityBudget.copyAttribute(element, kAXWindowAttribute, app: app) {
            let winEl = AccessibilityBudget.bind(win as! AXUIElement)
            windowTitle = AccessibilityBudget.copyAttribute(winEl, kAXTitleAttribute, app: app) as? String
        }

        return (role, windowTitle, placeholder)
    }

    /// Map an AX role string to a short human-readable hint, or nil if
    /// the role isn't informative. Goal: ~2-3 words the cloud prompt can
    /// surface as "<app>: <field type>".
    fileprivate static func describeAXRole(_ role: String?) -> String? {
        guard let role else { return nil }
        switch role {
        case "AXTextField":           return "single-line field"
        case "AXTextArea":            return "multi-line field"
        case "AXSearchField":         return "search field"
        case "AXComboBox":            return "combo box"
        case "AXStaticText":          return nil  // not informative
        default:                       return nil
        }
    }

    /// Truncate a window title to keep prompt tokens bounded. Keeps the
    /// "interesting" half (right side after " - " / " — " / " | " when
    /// possible, since macOS apps put doc/channel/subject AFTER the app
    /// name, e.g. "Slack | design | Maya").
    fileprivate static func compactWindowTitle(_ raw: String?, maxLen: Int = 80) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // Many app titles look like "App Name — Document" or "Document - App Name".
        // Prefer the side that doesn't match the bundle's marketing name.
        let trimmed = raw.replacingOccurrences(of: "  ", with: " ")
        if trimmed.count <= maxLen { return trimmed }
        // Title is huge — keep the first chunk (doc/subject usually leads).
        return String(trimmed.prefix(maxLen)) + "…"
    }

    /// Build the rich `appContextLabel` passed to the cloud polisher.
    ///
    /// Combines four signals into one short line the cloud model can use
    /// to set register, length, format:
    ///   1. Static app→string map (Slack message, email, code editor, etc.)
    ///   2. Focused window title (channel/subject/file)
    ///   3. Focused element role (single-line vs multi-line)
    ///   4. Focused element placeholder ("Compose a message", "Search…")
    ///
    /// Examples this produces:
    ///   - "Slack message — Slack | design (multi-line field)"
    ///   - "email — Inbox – Re: Q3 roadmap (multi-line field, placeholder: Compose)"
    ///   - "code editor… — VoiceApp.swift — Voice (multi-line field)"
    ///   - "Slack message"  (when AX is denied — degrades cleanly)
    static func buildEnrichedAppContextLabel(
        bundleID: String?,
        front: NSRunningApplication?
    ) -> String? {
        // Base label from the static map (Slack message / email / etc.).
        let baseLabel = Qwen3Polisher.appContextLabel(forBundleID: bundleID)
        // Pull live AX metadata. All three may be nil — degrade gracefully.
        let ax = readFocusedAXMetadata()
        let compactedTitle = compactWindowTitle(ax.windowTitle)
        let roleHint = describeAXRole(ax.role)
        let placeholderTrimmed = ax.placeholder?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        // Build the suffix pieces in priority order.
        var pieces: [String] = []
        if let compactedTitle, !compactedTitle.isEmpty {
            pieces.append(compactedTitle)
        }
        // Combine role + placeholder into a single parenthesized hint when
        // either is present. Keeps the label visually clean.
        var hintParts: [String] = []
        if let roleHint { hintParts.append(roleHint) }
        if let p = placeholderTrimmed, !p.isEmpty, p.count <= 60 {
            hintParts.append("placeholder: \(p)")
        }
        if !hintParts.isEmpty {
            pieces.append("(\(hintParts.joined(separator: ", ")))")
        }

        let suffix = pieces.joined(separator: " ")

        // Combine base + suffix. If the static map didn't recognise the
        // bundle, fall back to localised app name from NSRunningApplication
        // so we still send SOMETHING richer than nil.
        let head: String? = baseLabel ?? front?.localizedName.map { $0 }
        switch (head, suffix.isEmpty) {
        case (nil, true):
            return nil
        case (let h?, true):
            return h
        case (nil, false):
            return suffix
        case (let h?, false):
            return "\(h) — \(suffix)"
        }
    }

    /// Capture the frontmost app at the moment dictation begins, so we can
    /// re-activate it before paste. Skips capturing if VOICE itself happens
    /// to be frontmost (the pill, BigMenu, or Settings) — in that case the
    /// target is whatever was previous; leaving `targetAppBundleID` nil
    /// just means paste goes wherever focus lands naturally.
    fileprivate func captureTargetApp() {
        let nextTarget = cursorPaster.captureTargetSnapshot()
        let sameField: Bool
        if let previous = rollingContextTarget,
           previous.bundleId == nextTarget.bundleId,
           let old = previous.focusedElement, let new = nextTarget.focusedElement {
            sameField = CFEqual(old, new)
        } else { sameField = false }
        if !sameField { Qwen3Polisher.shared.clearRollingContext() }
        rollingContextTarget = nextTarget
        let ownID = Bundle.main.bundleIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication else {
            targetAppBundleID = nil
            capturedFieldContext = nil
            capturedFieldTarget = nil
            return
        }
        if let id = front.bundleIdentifier, id != ownID {
            targetAppBundleID = id
        }
        // else: VOICE was frontmost — keep whatever `targetAppBundleID` we
        // captured previously (might still be valid from the last session)

        // Sample the text-field context NOW (recording start), not at paste.
        // At this moment the target field reliably owns AX focus. We read up
        // to 24 chars before the cursor — enough for the polisher to detect
        // "ends mid-sentence", "ends with period+space", "ends with bullet 2.",
        // etc. without burning prompt tokens.
        capturedFieldTarget = cursorPaster.captureTargetSnapshot()
        capturedFieldContext = cursorPaster.sampleFieldContextBeforeCursor(length: 24)
        print("[VOICE] field context available: \(capturedFieldContext != nil)")

        // Sample RICH app context too (window title, focused element role,
        // placeholder). This becomes the `appContextLabel` passed to the cloud
        // polisher and is much richer than the static bundle→string map.
        // Cheap — same AX session that just read field context, plus an
        // NSWorkspace lookup. Do not log captured context.
        capturedRichAppContext = Self.buildEnrichedAppContextLabel(
            bundleID: targetAppBundleID,
            front: front
        )
        print("[VOICE] app context available: \(capturedRichAppContext != nil)")


    }

    /// Bring the target app back to the foreground before pasting. No-op if
    /// it's already frontmost or if we never captured one.
    fileprivate func restoreTargetApp() {
        guard let id = targetAppBundleID else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front != id else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate()
        }
    }

    /// Poll AXIsProcessTrusted() every 1.5s. When it flips from false → true
    /// (user just granted access), restart the hotkey monitors so events
    /// start flowing without the user having to relaunch the app.
    fileprivate func startPermissionWatcher() {
        guard permissionWatcherTimer == nil else { return }
        lastObservedAXTrusted = AXIsProcessTrusted()
        permissionWatcherTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = AXIsProcessTrusted()
            MainActor.assumeIsolated {
                if now && !self.lastObservedAXTrusted {
                    print("[VOICE] Accessibility flipped: false → true. Rebinding monitors.")
                    self.hotkeyService.startMonitoring()
                    FlowCommandListener.shared.emitState(force: false)
                    self.showToast("Shortcut ready.")
                    self.permissionWatcherTimer?.invalidate()
                    self.permissionWatcherTimer = nil
                }
                self.lastObservedAXTrusted = now
            }
        }
    }

    /// Top-right NSPanel toast. Independent of the dictation pill so we
    /// never interfere with the user's primary UI.
    /// Every message now appears at the pill as Wispr's card for the same situation.
    fileprivate func showToast(_ message: String) {
        guard let overlayPanel, overlayPanel.isVisible else { showCornerToast(message); return }
        Telemetry.log("notice.toast", properties: ["message": message])
        guard let notice = FlowPillNotice.wispr(forToast: message) else { return }
        showNotice(notice)
    }

    private func showNotice(_ notice: FlowPillNotice) {
        // A duplicate paste error, for example a skipped automatic Return,
        // cannot replace the Copy action for the same failed delivery.
        if notice.kind == .paste, notice.recoveryText == nil,
           recordingState.flowNotice?.recoveryText != nil { return }
        if !notice.quiet { SoundEffects.playNotice(notice.effectiveStatus) }
        if notice.effectiveStatus != .info { PillHaptics.error() }
        recordingState.flowNotice = notice
    }

    /// A newer delivery owns the pill, even if an older editor replies late.
    private func beginPasteRecoveryWindow() -> UUID {
        pasteRecoveryID = UUID()
        if recordingState.flowNotice?.recoveryText != nil { recordingState.flowNotice = nil }
        return pasteRecoveryID
    }

    /// A paste the field did not confirm: the text is on the clipboard. A calm info notice and a
    /// light haptic, never an error card, so a silent failure is always said out loud.
    private func showCopiedNotice() {
        guard !flowIsYielding, !recordingState.isRecording, !recordingState.pendingRecordingStart else { return }
        PillHaptics.pasteNotConfirmed()
        var notice = FlowPillNotice(kind: .paste, message: "Copied — press ⌘V", quiet: true)
        notice.title = "Copied — press ⌘V"
        notice.status = .info
        notice.timeout = 6
        showNotice(notice)
    }

    private func showPasteRecovery(_ text: String, id: UUID, unconfirmed: Bool = false, secureField: Bool = false,
                                   copyOnly: Bool = false) {
        guard pasteRecoveryID == id, !flowIsYielding, !recordingState.isRecording, !recordingState.pendingRecordingStart,
              var notice = FlowPillNotice.pasteRecovery(text, unconfirmed: unconfirmed, secureField: secureField) else { return }
        if copyOnly {
            notice.title = "Polished text ready to copy"
            notice.status = .info
        }
        recordingState.polishDiff = nil
        showNotice(notice)
    }

    /// The old corner panel, kept only for when the pill is not on screen.
    fileprivate func showCornerToast(_ message: String) {
        errorDismissTask?.cancel()

        // Reuse if already on screen — just update the text.
        if let panel = errorToastWindow,
           let host = panel.contentViewController as? NSHostingController<ToastView> {
            host.rootView = ToastView(message: message)
        } else {
            let host = NSHostingController(rootView: ToastView(message: message))
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.contentViewController = host
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                let size = panel.frame.size
                let origin = NSPoint(
                    x: frame.maxX - size.width - 16,
                    y: frame.maxY - size.height - 16
                )
                panel.setFrameOrigin(origin)
            }
            errorToastWindow = panel
        }

        errorToastWindow?.orderFrontRegardless()

        errorDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.errorToastWindow?.orderOut(nil)
        }
    }

    fileprivate func showOnboarding() {
        guard onboardingWindow == nil else { return }
        let host = NSHostingController(rootView: OnboardingView { [weak self] in
            UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
            self?.onboardingWindow?.orderOut(nil)
            self?.onboardingWindow = nil
            Telemetry.log("onboarding.completed")
        })
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome to Flow"
        panel.contentViewController = host
        panel.center()
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        onboardingWindow = panel
        panel.makeKeyAndOrderFront(nil)
        Telemetry.log("onboarding.shown")
    }
}

// MARK: - Toast + Onboarding views

private struct ToastView: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
    }
}

private struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private let pages: [(title: String, body: String)] = [
        ("Welcome to Flow", "Hold Right Option (⌥) anywhere on your Mac and start talking. Release to paste the transcript at your cursor."),
        ("Two permissions, then you're set", "Flow needs Microphone (to hear you) and Accessibility (to paste text). macOS will ask the first time."),
        ("You're set", "The waveform icon lives in your menu bar. Click it any time for settings or recent dictations.")
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text(pages[page].title)
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(pages[page].body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Spacer()
                Text("\(page + 1) / \(pages.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                if page < pages.count - 1 {
                    Button("Next") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get started", action: onFinish)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 420, height: 320)
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as AnyObject?) === bigMenuWindow else { return }
        // Stay a normal Dock app after the window closes so VOICE is ALWAYS
        // findable + quittable (Dock, Cmd-Tab, Force Quit). We no longer drop
        // back to .accessory ("hidden agent") on close — the user wants it
        // visible, not hidden. (Scene is Settings{EmptyView()}, so no stray
        // window opens; the Dock icon just stays put.)
    }

    // MARK: - Overlay

    private func setupOverlayPanel() {
        overlayPanel = OverlayPanel(recordingState: recordingState)

        overlayPanel?.onTap = { [weak self] in
            self?.handlePillTap()
        }

        // Hover-bar Polish buttons. The hover bar exposes three levels —
        // "light" (spell+punct), "medium" (grammar+fillers), "heavy" (full
        // rewrite) — and we route the click straight through to
        // handlePolishSelection with that level for this one call.
        overlayPanel?.onPolish = { [weak self] level in
            self?.handlePolishSelection(level: level)
        }

        overlayPanel?.onCancel = { [weak self] in
            self?.hotkeyService.endSessionFromUI()
            self?.cancelRecording()
        }

        overlayPanel?.onConfirm = { [weak self] in
            self?.hotkeyService.endSessionFromUI()
            self?.commitRecording()
        }

        overlayPanel?.onUndoCancel = { [weak self] in
            self?.undoCancel()
        }
        // Card actions are explicit. Each one opens the setting that can resolve it.
        let cardTokens: [NSObjectProtocol] = [
            NotificationCenter.default.addObserver(forName: Notification.Name("flow.selectMicrophone"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { FlowMicrophoneMenu.show() }
            },
            NotificationCenter.default.addObserver(forName: Notification.Name("flow.openSoundSettings"), object: nil, queue: .main) { _ in
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input") {
                    NSWorkspace.shared.open(url)
                }
            },
            NotificationCenter.default.addObserver(forName: Notification.Name("flow.openMicrophonePrivacy"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.openPrivacyPane("Privacy_Microphone") }
            },
            NotificationCenter.default.addObserver(forName: Notification.Name("flow.openAccessibilityPrivacy"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.didShowAXPrompt {
                        self.didShowAXPrompt = true
                        PermissionsService.shared.requestAccessibility()
                    }
                    self.startPermissionWatcher()
                    self.openPrivacyPane("Privacy_Accessibility")
                }
            },
            NotificationCenter.default.addObserver(forName: Notification.Name("flow.openScreenRecordingPrivacy"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.didShowSRPrompt {
                        self.didShowSRPrompt = true
                        _ = CGRequestScreenCaptureAccess()
                    }
                    self.openPrivacyPane("Privacy_ScreenCapture")
                }
            },
            NotificationCenter.default.addObserver(forName: Notification.Name("flow.openSpeechModels"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.openSpeechSettings() }
            },
        ]
        notificationTokens.append(contentsOf: cardTokens)
        // "Don't show again" on the slow-processing card.
        let delayOffToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("flow.processingDelayOff"), object: nil, queue: .main
        ) { _ in UserDefaults.standard.set(true, forKey: FlowNoticeRules.processingDelayOffKey) }
        notificationTokens.append(delayOffToken)
        // The detailed cancel card's Undo.
        let undoCancelToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("flow.undoCancel"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.undoCancel() }
        }
        notificationTokens.append(undoCancelToken)

        overlayPanel?.onUndoPaste = { [weak self] in
            self?.undoLastPaste()
        }

        overlayPanel?.onStopMeeting = { [weak self] in
            self?.stopMeetingCapture(reason: "userPillTap")
        }

        overlayPanel?.showPersistent()
    }

    /// Clicking the ready mic starts hands-free dictation, matching the
    /// reference bar. The separate wand explicitly edits selected text.
    ///
    /// The pill is ALWAYS dedicated to dictation, even while a meeting capture
    /// is running. Meeting capture is started exclusively via the Chrome
    /// extension MeetBridgeServer signal, and stopped via the persistent meeting
    /// dot (right of the pill) or the menu bar's "Stop meeting recording" item.
    /// This lets the user dictate inside a Google Meet while the meeting is
    /// being recorded in the background.
    private func handlePillTap() {
        guard !flowIsYielding else { return }
        if recordingState.showingCancelledToast {
            dismissCancelledToast()
            return
        }
        if recordingState.showingUndoPasteToast {
            dismissUndoPasteToast()
            return
        }
        guard !recordingState.isLocked   else { return }
        guard !recordingState.isRecording else { return }

        // Use exactly the keyboard activation path, including permissions,
        // captured field/context, session identity and shortcut latch.
        guard checkModelsReadyOrToast() else { return }
        // Wispr's click sends StartClicked: the start cue plays, the hands-free lock cue does not.
        lockStartedByClick = true
        hotkeyService.fnSpacePressed()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.lockStartedByClick = false }
    }

    // MARK: - Meeting Capture

    /// Start a meeting capture session. Called when a known meeting app is
    /// frontmost and the user taps the idle pill.
    private func reconcileMeetingDetectors() {
        let shouldRun = !flowIsYielding && BackgroundActivityGate.meetingDetectionEnabled
        guard shouldRun != meetingDetectorsRunning else { return }
        meetingDetectorsRunning = shouldRun
        if shouldRun {
            meetBridgeServer.start()
            callAppDetector.start()
        } else {
            meetBridgeServer.stop()
            callAppDetector.stop()
            meetingNoticeGate.reset()
        }
    }

    private func handleDetectedMeeting(source: String) {
        guard BackgroundActivityGate.meetingDetectionEnabled, !recordingState.isCapturingMeeting else { return }
        let isFirstSource = meetingNoticeGate.begin(source)
        if UserDefaults.standard.bool(forKey: "voice.autoStartMeetings") {
            startMeetingCapture()
        } else if isFirstSource {
            showToast("Call detected. Use the menu to start recording.")
            MeetingNotifier.notify(title: "Call detected", body: "Use the Flow menu to start recording.")
        }
        // This legacy one-shot event has no matching end event.
        if source == "notification" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.meetingNoticeGate.end(source)
            }
        }
    }

    private func startMeetingCapture(manual: Bool = false) {
        guard !flowIsYielding else { return }
        guard !recordingState.isCapturingMeeting, meetingStartTask == nil, !meetingStopping else { return }

        // Detection alone never grants permission to start a recording.
        if !manual && !UserDefaults.standard.bool(forKey: "voice.autoStartMeetings") {
            return
        }

        // Master kill switch — backstop for any auto-detection path that
        // managed to reach this function. Manual user taps go through
        // enterLockMode → handlePillTap and never call this.
        if !manual && AppDelegate.isMeetingDetectionDisabled {
            print("[VOICE-MEET] startMeetingCapture refused — voice.disableMeetingDetection is true")
            return
        }

        // Secondary gate — the new opt-in flag. Together with the legacy
        // inverted kill switch above, both must allow auto-meeting capture
        // before SCStream is ever instantiated. The orange screen-recording
        // indicator lights up as soon as we touch ScreenCaptureKit, so we
        // refuse here at the central choke point rather than relying on every
        // caller to gate themselves consistently.
        if !manual && !BackgroundActivityGate.meetingDetectionEnabled {
            print("[VOICE-MEET] startMeetingCapture refused — BackgroundActivityGate.meetingDetectionEnabled is false (enableMeetingDetection opt-in not granted, or privacy mode)")
            return
        }

        print("[VOICE-MEET-START] startMeetingCapture invoked: sourceBundle=\(recordingState.meetingSourceBundleID ?? "nil") isRecording=\(recordingState.isRecording) isLocked=\(recordingState.isLocked)")

        // (Spotify warning removed — user found it annoying. SCK's
        // excludingApplications: denylist handles media app audio now.)

        let captureID = UUID()
        recordingState.activeMeetingId = captureID
        recordingState.meetingCaptureStatus = "starting"
        recordingState.meetingCaptureProblem = nil
        meetingStartupSucceeded = false
        meetingStartTask = Task { @MainActor in
            defer { self.meetingStartTask = nil }
            let granted = await MeetingCaptureService.requestPermission()
            guard self.recordingState.activeMeetingId == captureID,
                  !Task.isCancelled, !self.flowIsYielding else { return }
            guard granted else {
                self.recordingState.activeMeetingId = nil
                let message = "Allow Flow in System Settings → Privacy & Security → Screen Recording to capture meeting audio."
                self.recordingState.meetingCaptureStatus = "failed"
                self.recordingState.meetingCaptureProblem = message
                NotificationCenter.default.post(name: .voiceError, object: nil, userInfo: ["message": message])
                return
            }

            do {
                // Switch icon timer to 1Hz so the running-clock tooltip ticks.
                scheduleMenuBarIconTimer()
                refreshMenuBarIcon()
                // Pass the source app into the service so it persists on the saved Meeting.
                meetingCaptureService.sourceApp = recordingState.meetingSourceBundleID
                // Pass any participant names already scraped by the Chrome extension.
                // The bridge may also push more names mid-call; we re-sync at stop.
                meetingCaptureService.participantNames = recordingState.meetingParticipantNames
                try await meetingCaptureService.startCapture(manual: manual)
                if Task.isCancelled || self.flowIsYielding || self.recordingState.activeMeetingId != captureID {
                    FlowOwnership.shared.retainRecoveryReference(self.meetingCaptureService.audioFileURL)
                    _ = await self.meetingCaptureService.stopCapture()
                    return
                }
                self.meetingStartupSucceeded = true
                self.recordingState.isCapturingMeeting = true
                self.recordingState.meetingCaptureStatus = "recording"
                self.scheduleMenuBarIconTimer()
                self.refreshMenuBarIcon()
                if manual { self.showToast("Meeting recording started") }
                print("[VOICE-MEETING] Capture started: \(recordingState.activeMeetingId?.uuidString ?? "<no-id>")")

                // EXPLICIT VISIBILITY: post a system-wide banner notification
                // so the user can't miss that screen + audio capture has begun.
                // Carries an actionable "Stop" button (and tapping the body
                // also stops) — both routes post `.voiceStopMeetingRequested`,
                // which the existing observer below converts into the
                // off-limits `stopMeetingCapture()` call.
                self.postMeetingRecordingNotification()

                // LAZY-TRANSCRIBE: no 30s draft checkpoint needed — there's
                // no in-stream transcript to checkpoint. The audio file on disk
                // IS the durable artifact; if Voice crashes mid-meeting, the
                // orphan-WAV recovery on next launch will import the file and
                // transcribe it. Lightweight row-level checkpoint instead: save
                // an empty Meeting row pointing at the live audio path every
                // 30s so the row appears in the UI immediately.
                let meetingIdForCheckpoint = self.recordingState.activeMeetingId ?? UUID()
                let startedAt = Date()
                let sourceForCheckpoint = self.recordingState.meetingSourceBundleID
                self.meetingDraftCheckpointTask?.cancel()
                self.meetingDraftCheckpointTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        guard let self, !Task.isCancelled, self.recordingState.isCapturingMeeting else { break }
                        let snapshot = MeetingDraftSnapshot(
                            meetingId: meetingIdForCheckpoint,
                            title: "Recording — \(startedAt.formatted(date: .abbreviated, time: .shortened))",
                            date: startedAt,
                            durationSeconds: Double(self.meetingCaptureService.durationSeconds),
                            segments: [],
                            audioFilePath: self.meetingCaptureService.audioFileURL?.path,
                            sourceApp: sourceForCheckpoint,
                            participantNames: self.recordingState.meetingParticipantNames
                        )
                        self.meetingRecovery.checkpointDraft(snapshot)
                    }
                }

                // Mirror only this session; a later meeting must not be reset by
                // an older task waking after its sleep.
                Task { @MainActor in
                    while self.recordingState.isCapturingMeeting,
                          self.recordingState.activeMeetingId == meetingIdForCheckpoint {
                        self.recordingState.meetingDurationSeconds = self.meetingCaptureService.durationSeconds
                        self.recordingState.meetingLiveTranscript = self.meetingCaptureService.liveTranscript
                        self.recordingState.meetingLiveTranscriptStatus = self.meetingCaptureService.liveTranscriptStatus
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    if self.recordingState.activeMeetingId == nil ||
                       self.recordingState.activeMeetingId == meetingIdForCheckpoint {
                        self.recordingState.meetingDurationSeconds = 0
                        self.recordingState.meetingLiveTranscript = []
                        self.recordingState.meetingLiveTranscriptStatus = ""
                    }
                }

                // Duration warnings (30/60/120 min toasts, 4h hard stop)
                // + crash-safety checkpoint every 5 minutes.
                Task { @MainActor in
                    var warnedAt: Set<Int> = []
                    var lastCheckpointSeconds = 0
                    let warnMinutes = [30, 60, 120]
                    let hardStopSeconds = 4 * 60 * 60   // 4 hours
                    let checkpointInterval = 5 * 60      // checkpoint every 5 min
                    while self.recordingState.isCapturingMeeting,
                          self.recordingState.activeMeetingId == captureID {
                        let elapsed = self.meetingCaptureService.durationSeconds
                        // Duration warnings.
                        for minutes in warnMinutes {
                            let threshold = minutes * 60
                            if elapsed >= threshold && !warnedAt.contains(minutes) {
                                warnedAt.insert(minutes)
                                let label = minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
                                self.showToast("Meeting recording: \(label)")
                            }
                        }
                        // Hard stop at 4h.
                        if elapsed >= hardStopSeconds {
                            print("[VOICE-MEETING] Hard stop: 4h limit reached")
                            self.showToast("Meeting recording stopped — 4h limit reached.")
                            self.stopMeetingCapture(reason: "hardLimit4h")
                            break
                        }
                        // Crash-safety: checkpoint segments to UserDefaults every 5 min.
                        if elapsed - lastCheckpointSeconds >= checkpointInterval {
                            lastCheckpointSeconds = elapsed
                            self.checkpointMeetingDraft()
                            print("[VOICE-MEETING] Draft checkpoint: \(elapsed)s elapsed")
                        }
                        try? await Task.sleep(nanoseconds: 30_000_000_000)  // check every 30s
                    }
                }
            } catch {
                guard self.recordingState.activeMeetingId == captureID else { return }
                self.recordingState.isCapturingMeeting = false
                self.recordingState.activeMeetingId = nil
                let message = "Could not start recording. \(error.localizedDescription)"
                self.recordingState.meetingCaptureStatus = "failed"
                self.recordingState.meetingCaptureProblem = message
                self.scheduleMenuBarIconTimer()
                self.refreshMenuBarIcon()
                NotificationCenter.default.post(name: .voiceError, object: nil, userInfo: ["message": message])
            }
        }
    }

    // MARK: Meeting-active system notification
    //
    // Identifier + category strings used to post / dismiss the persistent
    // banner that shows while meeting capture is live. The category carries
    // a "Stop" action button so the user can kill the recording from the
    // Notification Center without going back to the menu bar.
    static let kMeetingActiveNotifID = "voice.meetingActive"
    static let kMeetingActiveCategory = "VOICE_MEETING_ACTIVE"
    static let kMeetingStopAction = "VOICE_STOP_MEETING"

    /// Register the actionable category once. Idempotent — UN merges by ID.
    /// Also installs a tiny delegate proxy that intercepts taps on the Stop
    /// action and forwards everything else to the existing `MeetingNotifier`
    /// delegate so the "transcript ready" tap routing still works.
    fileprivate func ensureMeetingNotificationCategoryRegistered() {
        let stop = UNNotificationAction(
            identifier: AppDelegate.kMeetingStopAction,
            title: "Stop Recording",
            options: [.destructive, .foreground]
        )
        let category = UNNotificationCategory(
            identifier: AppDelegate.kMeetingActiveCategory,
            actions: [stop],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        // Swap in our proxy delegate the first time we register the category.
        // The proxy forwards every call to MeetingNotifier.delegate by default
        // and only intercepts when it sees our specific Stop action.
        if !(center.delegate is MeetingActiveNotificationDelegate) {
            MeetingActiveNotificationDelegate.shared.fallback = MeetingNotifier.delegate
            center.delegate = MeetingActiveNotificationDelegate.shared
        }
    }

    /// Fire (or refresh) the "Voice is recording your meeting" banner.
    /// Idempotent on the same identifier — UN replaces an existing one with
    /// the same id, so calling this on every start is safe.
    func postMeetingRecordingNotification() {
        ensureMeetingNotificationCategoryRegistered()
        let center = UNUserNotificationCenter.current()

        // Defensive permission check. If the user never saw the auth prompt
        // OR denied it, our notification call would silently fail and they'd
        // wonder why no banner appeared. Re-request on .notDetermined and
        // surface a clear toast on .denied so the user knows to enable it
        // in System Settings.
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    print("[VOICE-NOTIF] re-requested auth at meeting start, granted=\(granted)")
                    if granted {
                        DispatchQueue.main.async { self?.actuallyPostMeetingNotification() }
                    }
                }
            case .denied:
                print("[VOICE-NOTIF] notifications DENIED — banner won't show. Toast guidance fired.")
                DispatchQueue.main.async {
                    self?.showToast("Recording started. Enable Notifications in System Settings → Voice to see banners.")
                }
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { self?.actuallyPostMeetingNotification() }
            @unknown default:
                DispatchQueue.main.async { self?.actuallyPostMeetingNotification() }
            }
        }
    }

    /// Actual UN post call. Split out so the auth-check path can defer it.
    private func actuallyPostMeetingNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Voice: Recording meeting"
        content.body = "Click to stop."
        content.sound = .default
        content.categoryIdentifier = AppDelegate.kMeetingActiveCategory
        content.userInfo = ["voiceMeetingActiveBanner": true]
        let request = UNNotificationRequest(
            identifier: AppDelegate.kMeetingActiveNotifID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[VOICE-NOTIF] meeting-active post failed: \(error.localizedDescription)")
            } else {
                print("[VOICE-NOTIF] meeting-active banner posted")
            }
        }
    }

    /// Dismiss the meeting-active banner once recording stops, so it doesn't
    /// linger in Notification Center claiming the meeting is still live.
    func dismissMeetingRecordingNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [AppDelegate.kMeetingActiveNotifID])
        center.removePendingNotificationRequests(withIdentifiers: [AppDelegate.kMeetingActiveNotifID])
    }

    /// Stop the active meeting capture session. Called when the user taps
    /// Stop the active meeting capture session. Saves raw transcript directly —
    /// no AI summarization. Post-processing happens externally when needed.
    private func stopMeetingCapture(reason: String = "userMenu") {
        guard !meetingStopping, recordingState.isCapturingMeeting || meetingStartTask != nil else { return }
        let pendingStart = meetingStartTask
        if !meetingStartupSucceeded { pendingStart?.cancel() }
        recordingState.isCapturingMeeting = false
        recordingState.meetingCaptureStatus = "saving"
        recordingState.meetingCaptureProblem = nil
        meetingStopping = true
        let meetingId = recordingState.activeMeetingId ?? UUID()
        recordingState.activeMeetingId = nil
        // Cancel any pending grace timer for participants-left auto-stop.
        meetingParticipantsLeftTask?.cancel()
        meetingParticipantsLeftTask = nil
        // Capture pre-stop snapshot for the structured end log.
        let stopReason = reason
        let stopElapsed = meetingCaptureService.durationSeconds
        let stopAudioFile = meetingCaptureService.audioFileURL?.lastPathComponent ?? "nil"

        // Tear down the "Recording meeting" system banner so it doesn't
        // hang around in Notification Center claiming we're still live.
        dismissMeetingRecordingNotification()

        // Drop icon timer back to 5s idle rate now that capture has stopped.
        scheduleMenuBarIconTimer()
        refreshMenuBarIcon()

        // Stop the crash-safety draft checkpoint timer.
        meetingDraftCheckpointTask?.cancel()
        meetingDraftCheckpointTask = nil

        Task { @MainActor in
            defer {
                self.meetingStopping = false
                self.meetingStartupSucceeded = false
                if self.recordingState.meetingCaptureStatus == "saving" {
                    self.recordingState.meetingCaptureStatus = "idle"
                }
            }
            await pendingStart?.value
            guard self.meetingStartupSucceeded else { return }
            // Sync any names the bridge has pushed since startCapture(): the
            // participant tiles often render after the call becomes active, so
            // names that arrived mid-call still need to be threaded in.
            if !recordingState.meetingParticipantNames.isEmpty {
                meetingCaptureService.participantNames = recordingState.meetingParticipantNames
            }
            let (segments, capturedSourceApp, capturedAudioURL, capturedParticipantNames, capturedSpeakerEventsJson) = await meetingCaptureService.stopCapture()

            // Reset the names cache now that this session is over.
            recordingState.meetingParticipantNames = []

            let audioExists = capturedAudioURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            if segments.isEmpty && !audioExists {
                recordingState.meetingCaptureStatus = "failed"
                recordingState.meetingCaptureProblem = "No meeting audio was captured."
                self.showToast("No meeting audio was captured.")
                return
            }

            // Save even with no transcript — audio file is still valuable.
            // (Transcription can fail on short/quiet audio without it being an error.)
            if segments.isEmpty {
                print("[VOICE-MEETING] No segments captured — saving audio-only record")
            }

            // Use actual elapsed time from service if available, fall back to
            // segment-estimated duration so even audio-only saves have sane duration.
            let elapsedFromService = Double(max(stopElapsed, meetingCaptureService.durationSeconds))
            let totalDuration: TimeInterval
            if elapsedFromService > 0 {
                totalDuration = elapsedFromService
            } else if let last = segments.last {
                totalDuration = last.startTime + Double(last.text.split(separator: " ").count) / 2.5
            } else {
                totalDuration = 0
            }

            // Anything shorter than 3 minutes isn't really a meeting — it's a
            // quick note / voice memo. Classify it as `.dictation` so it
            // doesn't pollute the Meetings tab with 30-second drive-by
            // recordings. (3-min threshold matches the user's explicit rule.)
            let meetingKind: MeetingKind = .meeting

            let meeting = Meeting(
                id: meetingId,
                title: generateMeetingTitle(
                    from: segments,
                    sourceApp: capturedSourceApp,
                    participantNames: capturedParticipantNames
                ),
                date: Date(),
                duration: totalDuration,
                segments: segments,
                audioFilePath: capturedAudioURL?.path,
                kind: meetingKind,
                sourceApp: capturedSourceApp,
                participantNames: capturedParticipantNames,
                speakerEventsJson: capturedSpeakerEventsJson
            )

            guard saveMeetingToStorage(meeting) else {
                FlowOwnership.shared.retainRecoveryReference(capturedAudioURL)
                recordingState.meetingCaptureStatus = "failed"
                recordingState.meetingCaptureProblem = "Couldn't save the meeting. Its audio was retained for recovery."
                showToast("Couldn’t save meeting. Check your recordings.")
                return
            }
            UserDefaults.standard.removeObject(forKey: crashDraftKey)
            recordingState.meetingCaptureStatus = "ready"
            fetchMeetingsIntoState()
            recordingState.recordMeeting(durationSeconds: Int(totalDuration))
            print("[VOICE-MEETING] Saved \(segments.count) segments, \(Int(totalDuration))s")
            let durationMinutes = Int(totalDuration) / 60
            print("[VOICE-MEET-END] duration=\(durationMinutes)m elapsedSeconds=\(stopElapsed) audioFile=\(stopAudioFile) segments=\(segments.count) stopReason=\(stopReason)")

            // LAZY-TRANSCRIBE: kick off post-hoc transcription against the
            // saved audio file. Runs in background — user gets a toast when
            // it lands. Only fires when segments are empty (i.e. always under
            // the new lazy path; legacy meetings that already had segments
            // skip this).
            if segments.isEmpty,
               let audioPath = capturedAudioURL?.path,
               FileManager.default.fileExists(atPath: audioPath),
               totalDuration >= 0.5 {
                self.showToast("Meeting saved — transcribing…")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Wait for the engine to be ready (it's almost certainly
                    // already ready, but the meeting could have ended during a
                    // model reload).
                    let deadline = ContinuousClock.now + .seconds(30)
                    while !self.coordinator.transcription.isReady && ContinuousClock.now < deadline {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if Task.isCancelled { return }
                    }
                    guard self.coordinator.transcription.isReady else {
                        self.showToast("Audio saved. Retry transcription from the meeting.")
                        return
                    }
                    if let updated = await self.meetingRecovery.retranscribe(meeting: meeting) {
                        self.fetchMeetingsIntoState()
                        self.showToast("Transcript ready — \(updated.segments.count) segments")
                    } else {
                        self.showToast("Couldn't transcribe — audio saved, try again from the meeting row.")
                    }
                }
            }
        }
    }

    // MARK: - Meeting Capture Helpers

    /// Build a human title like "Night May 20th, Meet with Alice and Bob".
    ///
    /// Title shape:
    ///   `<TimeOfDay> <Month> <DayOrdinal>[, Meet with <Names>]`
    ///
    /// Name priority:
    ///   1. `participantNames` from the Chrome extension (scraped DOM).
    ///   2. Fallback: `extractNamesFromSegments` regex pass over the transcript.
    /// The local user (from `voice.userName` UserDefaults) is filtered out
    /// case-insensitively before names are formatted.
    private func generateMeetingTitle(
        from segments: [TranscriptSegment],
        sourceApp: String? = nil,
        participantNames: [String] = []
    ) -> String {
        // Time-of-day bucket.
        let hour = Calendar.current.component(.hour, from: Date())
        let timeLabel: String
        switch hour {
        case 5..<11:   timeLabel = "Morning"
        case 11..<13:  timeLabel = "Midday"
        case 13..<17:  timeLabel = "Afternoon"
        case 17..<21:  timeLabel = "Evening"
        default:       timeLabel = "Night"
        }

        // "May 20th" — month name + ordinal day.
        let now = Date()
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "MMMM"
        let monthStr = monthFmt.string(from: now)
        let day = Calendar.current.component(.day, from: now)
        let dayStr = "\(day)\(Self.ordinalSuffix(for: day))"

        // Filter the local user out of the candidate name list.
        let userName = (UserDefaults.standard.string(forKey: "voice.userName") ?? "").trimmingCharacters(in: .whitespaces)
        func notUser(_ name: String) -> Bool {
            guard !userName.isEmpty else { return true }
            return name.caseInsensitiveCompare(userName) != .orderedSame
        }

        // Resolve names: extension wins if it gave us anything, otherwise
        // fall back to the legacy transcript regex.
        var rawNames: [String]
        if !participantNames.isEmpty {
            rawNames = participantNames
        } else {
            rawNames = extractNamesFromSegments(segments)
        }

        // Dedup (case-insensitive, preserving first-seen casing) + user filter.
        var seen = Set<String>()
        let names: [String] = rawNames.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            // Use just the first word ("Alice Smith" → "Alice") to keep titles tight.
            let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
            guard notUser(firstWord), notUser(trimmed) else { return nil }
            let key = firstWord.lowercased()
            if seen.contains(key) { return nil }
            seen.insert(key)
            return firstWord
        }

        let base = "\(timeLabel) \(monthStr) \(dayStr)"
        guard !names.isEmpty else {
            // Solo recording: nobody else was ever detected (Chrome extension
            // gave us no names and the transcript regex pulled nothing). The
            // old code dropped "Meet" entirely; explicitly label this as a
            // solo recording so the title reads coherently.
            return "\(base), Solo recording"
        }
        return "\(base), Meet with \(Self.formatNameList(names))"
    }

    /// "1st", "2nd", "3rd", "4th"… English ordinal suffix for the given day.
    private static func ordinalSuffix(for day: Int) -> String {
        let mod100 = day % 100
        if (11...13).contains(mod100) { return "th" }
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// Format participant names for inclusion in the meeting title.
    /// - 1 name:  "Alice"
    /// - 2 names: "Alice and Bob"
    /// - 3 names: "Alice, Bob, and Charlie"
    /// - 4+ names: "Alice, Bob, and 2 others"
    private static func formatNameList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]), and \(names[2])"
        default:
            let extra = names.count - 2
            return "\(names[0]), \(names[1]), and \(extra) others"
        }
    }

    /// Extract up to 3 likely proper names from the transcript text.
    /// Strategy: find capitalized words that are NOT at the start of a sentence
    /// and NOT common non-name words. Rank by frequency and take the top 3.
    private func extractNamesFromSegments(_ segments: [TranscriptSegment]) -> [String] {
        // Case-insensitive stoplist. Anything that looks like a name but is
        // really a common English word, weekday, month, calendar reference, or
        // tool name. Compared lowercase to dodge the regex's capitalization
        // requirement (e.g. "Today", "Tomorrow", "Yeah", "Cool" all start with
        // a capital letter at the start of a sentence and would otherwise be
        // accepted as candidates).
        let skipWordsLC: Set<String> = [
            // Pronouns / articles / determiners
            "i", "the", "a", "an", "this", "that", "these", "those",
            "it", "he", "she", "we", "they", "you", "me", "him", "her", "us", "them",
            // Aux verbs
            "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did",
            "will", "would", "could", "should", "may", "might", "must", "shall",
            "can", "cannot",
            // Conjunctions / prepositions
            "and", "but", "or", "so", "yet", "for", "nor",
            "in", "on", "at", "by", "to", "of", "up", "as", "if",
            "from", "with", "into", "onto", "out", "off", "over", "under",
            // Interjections / fillers / casual
            "ok", "okay", "yes", "no", "hi", "hey", "uh", "um", "oh",
            "yeah", "yep", "nope", "nah", "yo", "cool", "nice", "great",
            "right", "well", "sure", "wait", "stop", "go", "now", "then",
            "really", "actually", "basically", "literally", "honestly", "anyway",
            "alright", "fine", "sorry", "thanks", "thank", "please", "welcome",
            "maybe", "perhaps", "probably", "definitely", "absolutely",
            // Calendar references
            "today", "tomorrow", "yesterday", "tonight",
            "morning", "afternoon", "evening", "night", "noon", "midnight",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december",
            "minute", "minutes", "hour", "hours", "second", "seconds",
            "week", "weeks", "month", "months", "year", "years",
            // Software / tool names that frequently appear in meeting transcripts
            "google", "meet", "zoom", "teams", "discord", "slack", "facetime",
            "voice", "chrome", "safari", "firefox", "edge", "browser",
            "outlook", "gmail", "notion", "figma", "linear", "github",
            "claude", "chatgpt", "openai", "anthropic",
            "mac", "windows", "linux", "iphone", "android",
            // Generic
            "everyone", "everybody", "someone", "somebody", "anyone", "anybody",
            "nobody", "nothing", "something", "anything",
        ]

        let fullText = segments.map(\.text).joined(separator: " ")
        // Match capitalized words that are preceded by a space (not sentence-start).
        // "sentence start" words are those after . ! ? or at string start — we exclude those.
        let pattern = #"(?<=\s)([A-Z][a-z]{1,14})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(fullText.startIndex..., in: fullText)
        var freq: [String: Int] = [:]
        for match in regex.matches(in: fullText, range: range) {
            if let r = Range(match.range(at: 1), in: fullText) {
                let word = String(fullText[r])
                guard !skipWordsLC.contains(word.lowercased()) else { continue }
                freq[word, default: 0] += 1
            }
        }
        // Require at least 2 occurrences to be confident it's a name.
        // If nothing survives the stoplist + frequency filter, return [] so the
        // caller falls back to "Night May 20th, Meet" instead of e.g.
        // "Night May 20th, Meet with Today and Slack".
        let candidates = freq
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
        return Array(candidates)
    }

    // MARK: - Crash Recovery

    private var crashDraftKey: String { "voice.meetingCrashDraft" }

    /// Called every 5 minutes during a capture session. Encodes live segments
    /// to UserDefaults so a crash / power-loss doesn't lose the recording.
    private func checkpointMeetingDraft() {
        let segments = meetingCaptureService.liveTranscript
        guard !segments.isEmpty else { return }
        if let data = try? JSONEncoder().encode(segments) {
            UserDefaults.standard.set(data, forKey: crashDraftKey)
        }
    }

    /// Called on next launch. If a crash draft exists, recover it as a
    /// saved (unsummarized) meeting and clear the draft.
    private func recoverCrashedMeetingIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: crashDraftKey),
              let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data),
              !segments.isEmpty else { return }

        let title = generateMeetingTitle(from: segments) + " (recovered)"
        let totalDuration = segments.last.map {
            $0.startTime + Double($0.text.split(separator: " ").count) / 2.5
        } ?? 0

        let meeting = Meeting(
            id: UUID(),
            title: title,
            date: Date(),
            duration: totalDuration,
            segments: segments,
            kind: .meeting
        )
        guard saveMeetingToStorage(meeting) else {
            showToast("Couldn’t save recovered meeting. It will remain available for recovery.")
            return
        }
        UserDefaults.standard.removeObject(forKey: crashDraftKey)
        fetchMeetingsIntoState()
        showToast("Recovered \(segments.count) segments from last session.")
        print("[VOICE-MEETING] Crash recovery: saved \(segments.count) segments")
    }

    /// Persist a Meeting via the coordinator's storage layer.
    @discardableResult
    private func saveMeetingToStorage(_ meeting: Meeting) -> Bool {
        do {
            try coordinator.saveMeeting(meeting)
            return true
        } catch {
            print("[VOICE-MEETING] Storage error: \(error)")
            return false
        }
    }

    /// Single funnel for "(re)read meetings from disk and push into UI state".
    ///
    /// Calls the *throwing* `storage.fetchAllMeetings()` directly so it can
    /// distinguish between "read returned zero rows" (.loaded with empty array
    /// → empty-state UI) and "read threw" (.error with the underlying message
    /// → error-state UI with Retry). The error path is what the BigMenuWindow
    /// Meetings tab surfaces — without this, every storage failure would
    /// silently render as "no meetings yet" which is misleading and hides
    /// real DB problems.
    @MainActor
    func fetchMeetingsIntoState() {
        recordingState.meetingsLoadState = .loading
        do {
            let fresh = try coordinator.storage.fetchAllMeetings()
                .sorted { $0.date > $1.date }
            recordingState.meetings = fresh
            recordingState.meetingsLoadState = .loaded
        } catch {
            let reason = (error as NSError).localizedDescription
            print("[VOICE-MEETING] load failed: \(reason)")
            recordingState.meetingsLoadState = .error(reason)
            // Intentionally do NOT clobber `recordingState.meetings` on
            // failure — if a previous load succeeded, the user keeps seeing
            // their existing list while we surface the error banner.
        }
    }

    /// Public reload, callable from UI views that need to refresh after
    /// a manual re-transcribe (BigMenu meeting row "Transcribe now" button).
    @MainActor
    func reloadMeetingsFromDisk() {
        fetchMeetingsIntoState()
    }

    /// Return a friendly name ("Spotify", "Music") if a music app is currently
    /// running with audio likely playing. Heuristic: any of the known media
    /// bundle IDs is in NSWorkspace.runningApplications. We can't tell from
    /// here whether it's *actually* playing (would need AppleScript or
    /// per-app audio APIs), so we err on the side of the warning fires when
    /// the app is open — easy enough for the user to dismiss.
    private func currentlyPlayingMusicApp() -> String? {
        let musicApps: [(bundleID: String, friendly: String)] = [
            ("com.spotify.client", "Spotify"),
            ("com.apple.Music", "Music"),
            ("io.mpv", "mpv"),
            ("org.videolan.vlc", "VLC"),
            ("com.apple.podcasts", "Podcasts"),
            ("com.apple.TV", "TV"),
        ]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        for app in musicApps where running.contains(app.bundleID) {
            return app.friendly
        }
        return nil
    }

    /// Replace stuck checkpoint titles ("Live meeting (in progress) — …" /
    /// "Recording — …") with a clean derived title. Runs at launch so the
    /// meetings list never shows the in-flight placeholder once a session is
    /// over. Keeps the row's date + source app + duration intact.
    @MainActor
    private func cleanUpStaleMeetingTitles() {
        let stalePrefixes = [
            "Live meeting (in progress)",
            "Recording —",
            "Recording ",
            "Recovered meeting",      // From the orphan auto-importer
            "Untranscribed recording",
            "Afternoon recording",
            "Morning recording",
            "Evening recording",
            "Night recording",
            "Solo recording",
            "Afternoon May",          // Old date-bucket placeholders
            "Morning May",
            "Evening May",
            "Night May",
        ]
        let meetings = coordinator.fetchAllMeetings()
        for m in meetings {
            let hasStaleTitle = stalePrefixes.contains { m.title.hasPrefix($0) }
            guard hasStaleTitle else { continue }
            // Don't touch the row that's CURRENTLY being recorded.
            if recordingState.isCapturingMeeting,
               recordingState.activeMeetingId == m.id { continue }

            // If this meeting has real transcript content, derive a better
            // title from it (first substantive line / participant names).
            // Otherwise fall back to a clean date-based placeholder.
            let newTitle: String
            if !m.segments.isEmpty {
                newTitle = deriveTitleFromTranscript(meeting: m)
            } else {
                newTitle = humanReadableMeetingFallbackTitle(for: m)
            }
            guard newTitle != m.title else { continue }
            var updated = m
            updated.title = newTitle
            do {
                try coordinator.saveMeeting(updated)
                print("[VOICE-CLEANUP] retitled meeting \(m.id)")
            } catch {
                print("[VOICE-CLEANUP] retitle failed for \(m.id): \(error)")
            }
        }
        reloadMeetingsFromDisk()
    }

    /// Build a title from an existing transcript — mirrors the logic in
    /// MeetingRecoveryService.deriveMeetingTitle so retitling a recovered
    /// meeting at launch produces the same title shape as a freshly-
    /// retranscribed one.
    private func deriveTitleFromTranscript(meeting m: Meeting) -> String {
        let dateStr: String = {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: m.date)
        }()
        let me = (UserDefaults.standard.string(forKey: "voice.userName") ?? "").trimmingCharacters(in: .whitespaces)
        let others = m.participantNames
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(me) != .orderedSame }
        if !others.isEmpty {
            let joined: String
            if others.count == 1 { joined = others[0] }
            else if others.count == 2 { joined = "\(others[0]) and \(others[1])" }
            else { joined = "\(others.prefix(2).joined(separator: ", ")) and \(others.count - 2) others" }
            return "Meeting with \(joined) · \(dateStr)"
        }
        if let seg = m.segments.first(where: { $0.text.split(separator: " ").filter({ !$0.isEmpty }).count >= 5 }) {
            let cleaned = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
            let shortened: String
            if cleaned.count <= 60 { shortened = cleaned }
            else {
                let cutoff = cleaned.index(cleaned.startIndex, offsetBy: 60)
                shortened = String(cleaned[..<cutoff]) + "…"
            }
            return "\(shortened) · \(dateStr)"
        }
        return humanReadableMeetingFallbackTitle(for: m)
    }

    /// Build a clean fallback title for a meeting that doesn't have one yet.
    /// Examples: "Morning meeting · May 25", "Untranscribed recording · May 25".
    private func humanReadableMeetingFallbackTitle(for m: Meeting) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = fmt.string(from: m.date)
        let hour = Calendar.current.component(.hour, from: m.date)
        let timeBucket: String = {
            switch hour {
            case 5..<12:  return "Morning"
            case 12..<17: return "Afternoon"
            case 17..<22: return "Evening"
            default:      return "Night"
            }
        }()
        let appLabel: String = {
            switch m.sourceApp {
            case "com.google.meet": return "Meet"
            case "us.zoom.xos":     return "Zoom"
            case "com.microsoft.teams2": return "Teams"
            case "com.cisco.webex.meetings": return "Webex"
            default: return "recording"
            }
        }()
        return "\(timeBucket) \(appLabel) · \(dateStr)"
    }

    /// Walk every meeting's audioFilePath and rewrite a valid WAV header for
    /// any file whose RIFF chunk-size field still says "0 bytes" (the file
    /// was killed mid-write before MeetingCaptureService got to flush the
    /// final header). Without this, AVFoundation refuses to decode the file
    /// and "Couldn't transcribe — audio may be corrupted" fires forever.
    @MainActor
    private func repairBrokenWAVHeaders() async {
        for var meeting in coordinator.fetchAllMeetings() {
            guard !Task.isCancelled, !flowIsYielding else { return }
            guard let path = meeting.audioFilePath, path.hasSuffix(".wav"),
                  FileManager.default.fileExists(atPath: path) else { continue }
            let original = URL(fileURLWithPath: path)
            // Only copy files that appear undecodable or truncated. The meeting
            // writer uses mono float32 PCM; allow room for its padded WAV header.
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            if let readable = try? AVAudioFile(forReading: original), readable.length > 0,
               Int64(readable.length) * 4 + 8192 >= size { continue }
            let copy = original.deletingLastPathComponent().appendingPathComponent("repair-" + original.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: original, to: copy)
                try WAVHeaderRepair.repairIfNeeded(at: copy)
                guard let repaired = try? AVAudioFile(forReading: copy), repaired.length > 0 else { continue }
                meeting.audioFilePath = copy.path
                guard saveMeetingToStorage(meeting) else { continue }
            } catch {
                print("[VOICE-WAV-REPAIR] copy could not be repaired: \(error)")
            }
        }
    }

    private func enterLockMode() {
        guard !flowIsYielding else { return }
        recordingState.isLocked = true
        hotkeyService.isLocked = true
        // Hands-free latched — distinct "lock" earcon (self-gates on the
        // soundEffectsEnabled toggle).
        if lockStartedByClick { lockStartedByClick = false } else { SoundEffects.playLock() }
        // With the deferred-quickRelease state machine, double-tap entry
        // happens WHILE the first tap's recording is still running. Do not
        // restart it — that would race a fresh start against a pending stop
        // AND play a duplicate start sound. Just flip the lock flags.
        // If somehow no recording is active (e.g. UI-button-triggered lock),
        // start one as a safety net.
        if !recordingState.isRecording {
            recordingStartedAt = Date()
            recordingState.clearCancelledUndo()
            // BUGFIX: rotate the session ID for this safety-net fresh start so
            // any prior in-flight finishRecording Task can detect the new
            // session and bail (matches Path 2/3 in hotkeyDidActivate).
            recordingState.recordingSessionID = UUID()
            recordingState.sessionCancelled = false
            recordingState.cancelledSessionID = nil
            coordinator.startRecording()
            playStartCueWhenWarm()
        }
        // Start live preview — only meaningful for long recordings; short PTT
        // sessions never see a partial before stop, so this is a no-op for them.
        coordinator.startLivePartials()
    }

    private func exitLockMode() {
        recordingState.isLocked = false
        hotkeyService.isLocked = false
        coordinator.stopLivePartials()
    }

    /// X button — stop transcribing, but RETAIN the recording.
    ///
    /// Cancel no longer throws the user's words away. We stop active
    /// transcription/CPU work (claim the recording synchronously, which tears
    /// down the audio engine) but KEEP the audio file on disk and save a record
    /// to the dictation History marked as cancelled/unpolished — with whatever
    /// partial transcript we already have. The result still shows up in the
    /// BigMenu History (audio retained, recoverable); it just isn't pasted and
    /// isn't fully polished. The "Transcript cancelled / Undo" toast still works
    /// exactly as before for an immediate re-paste.
    private func cancelRecording() {
        // Escape must end the same key session
        // as the pill buttons. Keep a physically held key latched until key-up.
        hotkeyService.endSessionFromUI()
        // Restore auto-personality override if one was in effect — cancel
        // never pastes so we never enter finishRecording()'s defer.
        if let saved = previousPersonality {
            UserDefaults.standard.set(saved, forKey: "personalityStyle")
            previousPersonality = nil
            print("[VOICE-PERSONALITY] restored on cancel: \(saved)")
        }
        recordingState.sessionCancelled = true
        // Scope the cancel to the CURRENT session (see cancelInFlightProcessing).
        recordingState.cancelledSessionID = recordingState.recordingSessionID
        Telemetry.signal("recording.cancel", "user", [
            "session": recordingState.recordingSessionID,
            "was_recording": recordingState.isRecording
        ])
        print("[VOICE] Cancel → stop transcribing, retain recording")
        // Claim synchronously so we (a) atomically stop the audio engine — no
        // more CPU burned transcribing — and (b) capture the on-disk audio URL.
        // Unlike before, we do NOT delete this file; it's the user's retained
        // recording.
        let cancelledSession = recordingState.recordingSessionID
        let claimedForCancel = recordingState.isRecording ? coordinator.claimRecordingSync() : nil
        let retainedAudioURL = claimedForCancel?.audioURL
        // Snapshot the partial transcript we already have RIGHT NOW (sync, on the
        // main actor) as a fallback — showCancelledToast() consumes/clears
        // currentTranscript, and a superseding session could mutate it before our
        // async drain returns. The drain's return value is preferred; this is the
        // safety net.
        let partialSegments = recordingState.currentTranscript
        let partialFromSegments = partialSegments
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let partialLivePreview = recordingState.livePartialText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Capture paste-target + duration for the History row, same as the
        // commit path does.
        let capturedTargetForCancel = targetAppBundleID
        let startedAtForCancel = recordingStartedAt
        // BUGFIX: clear pendingRecordingStart so the pill doesn't get stuck in
        // the .recording phase if cancel arrived between Path 3 sync mutations.
        recordingState.pendingRecordingStart = false
        recordingStartedAt = nil
        exitLockMode()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Drain the engine on the claimed recording. This flushes the final
            // ASR tail AND (crucially) leaves the audio file on disk when there's
            // real speech — RecordingCoordinator only deletes sub-300ms clips.
            // We deliberately do NOT delete the file afterwards.
            // A cancelled pending start has no claim. Never stop whichever
            // recording happens to be active when this asynchronous task runs.
            let drained: [TranscriptSegment]
            if let claimedForCancel {
                drained = await self.coordinator.stopRecording(claiming: claimedForCancel)
            } else {
                drained = []
            }
            let drainedText = drained
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Best transcript we can salvage: prefer the freshly-drained final
            // text, then the segments we snapshotted, then the live preview.
            let bestTranscript = !drainedText.isEmpty
                ? drainedText
                : (!partialFromSegments.isEmpty ? partialFromSegments : partialLivePreview)

            // Does a retained audio file actually exist on disk? (If cancel hit
            // during spin-up there may be no URL, or the clip was too short and
            // the coordinator already reaped it — in that case there's nothing
            // meaningful to retain.)
            let audioExists: Bool = {
                guard let url = retainedAudioURL else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }()

            if audioExists || !bestTranscript.isEmpty {
                let duration = startedAtForCancel.map { Int(Date().timeIntervalSince($0)) }
                // Persist to History via the SAME RecentDictations.add API the
                // normal pipeline uses, so the cancelled item renders identically
                // in the BigMenu. Marked unpolished: polished == the partial text,
                // raw == nil, polishMs == nil (polish never ran), and tagged
                // cancelled (with the retained audio path) via the new fields.
                // When there's no transcript at all but we DID keep audio, store a
                // placeholder so the row still appears and the audio is reachable.
                let storedText = bestTranscript.isEmpty ? "(cancelled — audio retained)" : bestTranscript
                RecentDictations.add(
                    raw: nil,
                    polished: storedText,
                    pasteTargetBundleID: capturedTargetForCancel,
                    polishMs: nil,
                    parakeetRaw: bestTranscript.isEmpty ? nil : bestTranscript,
                    durationSeconds: duration,
                    cleanupLevelUsed: nil,
                    personalityStyleUsed: nil,
                    polishFixCount: nil,
                    cancelled: true,
                    audioFilePath: retainedAudioURL?.path
                )
                print("[VOICE-CANCEL] retained: audio=\(retainedAudioURL?.lastPathComponent ?? "none") transcriptChars=\(bestTranscript.count) duration=\(duration.map(String.init) ?? "?")s → saved to History (unpolished, not pasted)")
            } else {
                // Nothing to keep (cancelled during spin-up, no audio, no text).
                print("[VOICE-CANCEL] nothing to retain (no audio file, no partial transcript) — skipping History save")
            }

            // Keep the history row, but do not clear the next recording's preview.
            guard self.recordingState.recordingSessionID == cancelledSession else { return }
            self.showCancelledToast()
            // After the toast, so its bookkeeping cannot wipe what Undo needs.
            self.recordingState.cancelledText = bestTranscript
            self.recordingState.cancelledAudioURL = audioExists ? retainedAudioURL : nil
        }
    }

    /// ESC key handler — cancel any in-flight dictation work.
    ///
    /// Escape semantics by phase:
    ///   * Idle → NO-OP. We never shadow system-wide Esc when there's nothing
    ///     to cancel. (Otherwise an Esc in another app would do weird things.)
    ///   * Recording → routes to the existing `cancelRecording()` path so the
    ///     audio + partial transcript get retained exactly the same way the
    ///     pill's X button does.
    ///   * Transcribing / polishing / pasting (i.e. post-recording stages) →
    ///     hard-cancel everything mid-flight. The streaming task chain is
    ///     killed, `sessionCancelled` is set so any guard that hasn't fired
    ///     yet will bail, and whatever partial transcript exists is persisted
    ///     to History as a cancelled dictation so the user doesn't lose work.
    ///   * Polish-selection (Opt+1 in flight) → cancel that one too.
    ///
    /// Audio is already on disk by the time we get here (every code path
    /// flushes via claimRecordingSync / stopRecording before this point), so
    /// "save it but cancel it" reduces to: don't paste, don't keep spinning
    /// the CPU, but do write the History row.
    fileprivate func cancelInFlightProcessing() {
        // Phase 1: still recording → defer to the existing cancel path.
        // That code already retains audio + writes a cancelled-dictation row.
        if recordingState.isRecording || recordingState.pendingRecordingStart {
            print("[VOICE-CANCEL-INFLIGHT] ESC during recording → routing to cancelRecording()")
            cancelRecording()
            return
        }

        // Phase 2: post-recording pipeline (transcribe / polish / paste).
        // We may also be in polish-selection (Opt+1). Both are addressed below.
        let wasTranscribing = recordingState.transcribingCount > 0
        let wasPolishingSelection = recordingState.isPolishingSelection
        guard wasTranscribing || wasPolishingSelection else {
            // Phase 0: truly idle. Don't touch anything — Esc here belongs to
            // whatever app is frontmost (it should dismiss its menus, sheets, etc.).
            return
        }

        print("[VOICE-CANCEL-INFLIGHT] ESC mid-pipeline: transcribing=\(wasTranscribing) polishingSelection=\(wasPolishingSelection)")

        // 1. Signal "cancelled" to every guard inside the finish Task. Each
        //    `guard !recordingState.sessionCancelled else { return }` checkpoint
        //    along the polish → paste path will now bail.
        let cancelledWork = dictationWork.cancelLatest(preferred: recordingState.recordingSessionID)
        if let cancelledWork, cancelledWork.session == recordingState.recordingSessionID {
            recordingState.sessionCancelled = true
            recordingState.cancelledSessionID = cancelledWork.session
        }

        // 2. Salvage whatever partial transcript exists RIGHT NOW (before we
        //    cancel the Task, which may still be appending). Mirrors the
        //    cancelRecording() snapshot path so the rules match exactly.
        let partialSegments = recordingState.currentTranscript
        let partialFromSegments = partialSegments
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let partialLivePreview = recordingState.livePartialText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bestTranscript = !partialFromSegments.isEmpty ? partialFromSegments : partialLivePreview
        let capturedTargetForCancel = targetAppBundleID
        let startedAtForCancel = recordingStartedAt

        // 3. The target's token cancels its actual task and delayed callbacks.
        // Never cancel the FIFO barrier: it still owns the preceding paste order.
        // 4. Other in-flight dictations keep their own count.
        recordingState.transcribingCount = dictationWork.activeCount
        recordingState.isPolishingSelection = false
        // Kill the in-flight Opt+1 polish-selection task so it can't paste over
        // the user's selection after they pressed ESC.
        polishSelectionTask?.cancel()
        polishGate.cancel()
        recordingState.livePartialText = ""
        recordingState.currentTranscript = []
        coordinator.stopLivePartials()

        // 5. Persist a cancelled-dictation History row when there's something
        //    worth keeping. Mirrors cancelRecording()'s salvage path. We
        //    intentionally do NOT include an audioFilePath here — the audio
        //    was already finalized/disposed by the upstream stopRecording
        //    drain (the cancellation point is past the audio-claim stage).
        if cancelledWork?.session == recordingState.recordingSessionID, !bestTranscript.isEmpty {
            let duration = startedAtForCancel.map { Int(Date().timeIntervalSince($0)) }
            RecentDictations.add(
                raw: nil,
                polished: bestTranscript,
                pasteTargetBundleID: capturedTargetForCancel,
                polishMs: nil,
                parakeetRaw: bestTranscript,
                durationSeconds: duration,
                cleanupLevelUsed: nil,
                personalityStyleUsed: nil,
                polishFixCount: nil,
                cancelled: true,
                audioFilePath: nil
            )
            print("[VOICE-CANCEL-INFLIGHT] retained partial transcript: chars=\(bestTranscript.count) duration=\(duration.map(String.init) ?? "?")s → saved to History (cancelled, unpolished)")
        } else {
            print("[VOICE-CANCEL-INFLIGHT] no partial transcript to retain")
        }

        // 6. Surface confirmation to the user. We use the regular toast (not
        //    showCancelledToast) so it doesn't offer Undo — the pipeline was
        //    torn down past the point where Undo could meaningfully restore it.
        showToast("Cancelled. Audio saved.")

        // 7. Refresh the menu bar so its icon + status header reflect idle.
        scheduleMenuBarIconTimer()
        refreshMenuBarIcon()
    }

    /// ✓ button — finalize recording and paste at cursor.
    private func commitRecording() {
        print("[VOICE] Confirm → transcribe + paste")
        exitLockMode()
        finishRecording()
    }

    /// End recording, drain the streaming engine, then copy + paste at cursor.
    /// Each invocation runs to completion independently — if the user re-presses
    /// the hotkey while a prior finish is mid-flight, the prior task keeps going
    /// and its transcript still lands at the cursor (queued via pasteChain so it
    /// arrives in chronological order behind the older one).
    private func finishRecording() {
        hotkeyService.endSessionFromUI()
        // Key release. Every stage time in the dictation trace is counted from here.
        let keyUpAt = CFAbsoluteTimeGetCurrent()
        print("[VOICE-TIMING] finishRecording entered at \(Date())")
        let wasRecording = recordingState.isRecording
        let started = recordingStartedAt
        // Snapshot the session ID at entry. Task A below uses this to detect
        // whether a NEW recording has started in the meantime — if so, the
        // stale finish bails out before it can mutate state belonging to the
        // new session (see 5.2 "race between finishRecording and re-press").
        let mySession = recordingState.recordingSessionID
        print("[VOICE-HK] finishRecording: wasRecording=\(wasRecording)  started=\(started?.description ?? "nil")  session=\(mySession)")
        Telemetry.signal("recording.finish", wasRecording ? "commit" : "noop", [
            "session": mySession,
            "duration_s": started.map { Int(Date().timeIntervalSince($0)) } ?? 0
        ])

        // === ATOMIC CLAIM: synchronously stop audio capture and snapshot the
        // current recording's resources BEFORE we return from this function.
        //
        // The bug this fixes: finishRecording() creates a Task (Task A) and
        // returns. Between that return and Task A's body running, the main
        // actor's run-loop can process the next keyDown event. If the user
        // re-pressed the hotkey, hotkeyDidActivate Path 2 calls
        // coordinator.startRecording() — setting isRecording = true for the
        // NEW recording. Task A then calls coordinator.stopRecording(), sees
        // isRecording = true, and stops the NEW recording instead of recording 1.
        // The prior transcript is lost; recording 2 is also corrupted.
        //
        // By calling claimRecordingSync() here — on the main actor, synchronously,
        // before returning — we atomically flip isRecording = false and capture
        // the audio URL. startRecording() for the new recording can only start
        // AFTER this function returns, so it always gets a fresh URL. Task A
        // then calls stopRecording(claiming:) with the pre-captured context and
        // transcribes the right audio file regardless of what the new recording is doing.
        let claimed: RecordingCoordinator.ClaimedRecording? = wasRecording ? coordinator.claimRecordingSync() : nil
        print("[VOICE-TIMING] claimRecordingSync done at \(Date()) (claimed=\(claimed != nil))")

        // === ATOMIC STATE TRANSITION: recording → transcribing ===
        // Flip transcribing ON now that we've claimed the recording.
        recordingState.pendingRecordingStart = false
        if wasRecording {
            recordingState.lastRecordingSeconds = started.map { Date().timeIntervalSince($0) } ?? 0
            SoundEffects.playStop()
        }

        recordingStartedAt = nil
        guard wasRecording else {
            // Nothing to claim. An async stop here could stop the next recording.
            print("[VOICE-HK] finishRecording: wasRecording=false, bailing")
            coordinator.stopLivePartials()
            return
        }

        let duration = started.map { Date().timeIntervalSince($0) } ?? 0
        print("[VOICE-HK] finishRecording: duration=\(duration)s")
        if duration < minRecordingDuration {
            print("[VOICE] Too short (\(duration)s) → silent discard")
            // Pass the claim through so stopRecording() still does its drain+cleanup,
            // but the result is discarded since duration is too short.
            if let claimed {
                Task { @MainActor in _ = await coordinator.stopRecording(claiming: claimed) }
            }
            recordingState.currentTranscript = []
            return
        }

        // Snapshot the paste-destination state RIGHT NOW (synchronously on the
        // main actor) so a later Path 2 re-press that calls captureTargetApp()
        // can't repoint this task's paste at the wrong field. Each finish task
        // owns its own copy of where its transcript belongs.
        let work = dictationWork.begin(mySession)
        recordingState.transcribingCount = dictationWork.activeCount
        let recoveryID = beginPasteRecoveryWindow()
        let capturedTargetForTask = targetAppBundleID
        // He may have typed in the same field while dictating. Re-read the context
        // from that field now, so the polisher sees the current text before the cursor.
        let capturedFieldContextForTask: String? = {
            guard let startField = capturedFieldTarget?.focusedElement,
                  let liveField = cursorPaster.captureTargetSnapshot().focusedElement,
                  CFEqual(startField, liveField) else { return capturedFieldContext }
            return cursorPaster.sampleFieldContextBeforeCursor(length: 24) ?? capturedFieldContext
        }()
        let capturedRichAppContextForTask = capturedRichAppContext
        let personalityForTask = AppWritingCategory.style(for: capturedTargetForTask)
        let cleanupForTask = CleanupLevel.current.rawValue

        // Each finish gets its OWN Task. We intentionally do NOT cancel the
        // previous pendingFinishTask — if the user re-pressed the hotkey
        // before the prior pipeline finished, the prior transcript still
        // needs to reach the cursor. We just overwrite the reference so the
        // most recent task is reachable for diagnostics.
        // Snapshot the auto-personality override at Task creation time.
        // captureTargetApp() set previousPersonality on the main actor
        // synchronously before this Task is created, so the value is stable.
        let personalityToRestore = previousPersonality
        previousPersonality = nil  // consumed — prevent double-restore on re-press

        // Paste order is taken at release, before ASR or cleanup run (sol/01 finding 2). Each dictation
        // waits for the one released before it to finish delivering, and finishes its own slot on every path.
        let priorDelivery: Task<Void, Never>? = pasteChain
        let deliverySlot = DeliverySlot(after: priorDelivery)
        pasteChain = deliverySlot.task

        work.task = Task { @MainActor in
            var deliveryStarted = false
            // The token remains active until paste/readback finishes, not just cleanup.
            defer {
                if !deliveryStarted {
                    self.dictationWork.finish(work)
                    self.recordingState.transcribingCount = self.dictationWork.activeCount
                }
                // Ensure live partials are always cleaned up regardless of
                // which code path triggered finishRecording (silence timeout,
                // hotkey, or confirm button — all paths end here).
                if self.recordingState.recordingSessionID == mySession {
                    coordinator.stopLivePartials()
                }
                // Restore only the personality override owned by this session.
                if self.recordingState.recordingSessionID == mySession, let saved = personalityToRestore {
                    UserDefaults.standard.set(saved, forKey: "personalityStyle")
                    print("[VOICE-PERSONALITY] restored: \(saved)")
                }
                // Session ended — drop icon timer back to the 5s idle rate and
                // update the icon once so it reflects the new idle state.
                self.scheduleMenuBarIconTimer()
                self.refreshMenuBarIcon()
            }

            defer { if !deliveryStarted { deliverySlot.finish() } }
            // One local training record for this dictation (FlowRunLog): input, every stage, decisions, timings.
            let run = FlowRunCollector(kind: "dictation", id: claimed?.sessionId.uuidString ?? mySession.uuidString,
                                       app: capturedTargetForTask, input: nil, startedAt: started ?? Date())
            run.update {
                $0.audioPath = claimed?.audioURL?.path
                $0.audioSeconds = (duration * 100).rounded() / 100
                $0.settings = ["cleanupLevel": cleanupForTask, "style": personalityForTask,
                               "cleanupModel": Qwen3Polisher.effectiveAutomaticCleanupModel,
                               "polishEnabled": "\(UserDefaults.standard.object(forKey: "polishEnabled") as? Bool ?? true)"]
            }
            defer { if !deliveryStarted { run.finish(outcome: run.snapshot.outcome ?? "not-delivered", output: nil) } }

            // SESSION OWNERSHIP CHECK: if a fresh recording has started since
            // this Task was scheduled (the user re-pressed the hotkey), the
            // session ID will have rotated and the live/shared UI buffers
            // (currentTranscript, livePartialText, the per-clip polish flags,
            // the "last dictation" stats) now belong to the NEW session B.
            //
            // We do NOT abandon anymore. The earlier "lost first dictation"
            // bug came from returning here and silently discarding A's
            // transcript. A's audio was already claimed synchronously above
            // (via claimRecordingSync) and the coordinator now returns A's OWN
            // segments (see RecordingCoordinator's per-session return), so
            // there is no longer any reason to throw A away.
            //
            // Instead we compute `iOwnLiveState`: true only while THIS task
            // still owns the active session. Every write to shared/live-UI
            // `recordingState` below is gated on it — when false, B owns those
            // fields and we leave them untouched. But the transcribe → polish →
            // paste pipeline runs unconditionally for A's own claimed audio,
            // and A's paste still flows through the pasteChain / pasteOrderAnchor
            // ordering mechanism so A lands before B (chronological order).
            // Re-evaluate after every suspension: another capture can start at any await.
            func iOwnLiveState() -> Bool { self.recordingState.recordingSessionID == mySession }
            if !iOwnLiveState() {
                vlog("[VOICE-RACE] proceeding as background session (not live owner) session=\(mySession) current=\(self.recordingState.recordingSessionID)")
            }

            // ============================================================
            // LATENCY PROFILING — captures per-stage wall time so we can prove
            // where the pipeline is spending its budget. Single source of
            // truth: every stage logs from t0; the final TOTAL is t_now - t0.
            // Also forwarded to Telemetry so the JSONL log can be diffed by
            // build / model / app target.
            // ============================================================
            let tPipelineStart = CFAbsoluteTimeGetCurrent()
            // This is a cooperative warning threshold, not a hard deadline:
            // the task group still waits for a cancellation-unresponsive decoder.
            // A WARNING at 15 s, never a cut-off. A transcription that finishes late is still pasted
            // (sol/01 finding 5). The old race threw away a finished result when the timer won.
            let asrWarningNs: UInt64 = 15_000_000_000
            let slowWarning = Task { @MainActor in
                try? await Task.sleep(nanoseconds: asrWarningNs)
                guard !Task.isCancelled else { return }
                fputs("[LATENCY] ASR warning threshold reached; still waiting for the transcript\n", stderr)
            }
            let segments = await coordinator.stopRecording(claiming: claimed)
            slowWarning.cancel()
            let parakeetMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000
            let transcriptAtMs = Int((CFAbsoluteTimeGetCurrent() - keyUpAt) * 1000)
            fputs("[LATENCY] Parakeet (drain+ASR): \(Int(parakeetMs))ms\n", stderr)
            vlog("[VOICE-TIMING] Parakeet returned at \(Date())")
            // [VOICE-RACE] Prove each finish task received ITS OWN session's
            // transcript. Before the coordinator fix, a superseded session's
            // stopRecording returned the shared state.currentTranscript (a newer
            // recording's text), which is what caused the same message to paste
            // twice. This logs what THIS session actually got back to drain.
            // BUGFIX (Category 4): reserve our slot in pasteChain RIGHT NOW (right after
            // Parakeet returns) so paste order = finishRecording-call order, NOT
            // polish-completion order. Previously pasteChain was assigned AFTER polish
            // completed — if recording A's polish ran slower than recording B's, B's
            // paste could land first, scrambling chronological order at the cursor.
            // The reserved anchor task simply awaits the prior chain link; the real
            // paste task (assigned below after polish) awaits this anchor.
            let pasteOrderAnchor: Task<Void, Never> = priorDelivery ?? Task {}
            if Task.isCancelled { return }

            // Preserve segment timing so the formatter can insert paragraph
            // breaks on long pauses for natural-looking long-form output.
            let segmentsForFormat = segments.map {
                (text: $0.text, startTime: $0.startTime, endTime: $0.endTime)
            }
            let rawText = segmentsForFormat
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            run.update {
                $0.input = rawText
                let words = segments.flatMap { $0.wordConfidences ?? [] }
                $0.asrWords = words.isEmpty ? nil : words
                let confidences = segments.compactMap(\.confidence)
                $0.asrConfidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Float(confidences.count)
                let suspects = segments.compactMap(\.suspectWords).flatMap { $0 }
                $0.suspectWords = suspects.isEmpty ? nil : suspects
                $0.timingsMs["transcriptAtMs"] = transcriptAtMs
                $0.timingsMs["asrMs"] = Int(parakeetMs)
            }
            run.setBaseline(rawText)

            // Live-UI clears: only when we still own the active session. If B
            // has taken over, currentTranscript / livePartialText now mirror
            // B's in-flight recording — clearing them here would blank B's live
            // preview. A still pastes its own text via pasteChain below.
            if iOwnLiveState() {
                recordingState.currentTranscript = []
                // Final transcript has landed — clear live preview so partial text
                // doesn't linger after the real result is pasted.
                recordingState.livePartialText = ""
            }

            if rawText.isEmpty {
                run.update { $0.outcome = "empty-transcript" }
                vlog("[VOICE] Empty transcript")
                showToast(DictationRecoveryRules.emptyTranscriptMessage(mic: coordinator.audioCapture.activeMicrophoneName))
                // STALE-FLAG GUARD: the coordinator may have set
                // skipPolishForCurrent for THIS session before we discovered the
                // transcript was empty. We return before the normal consume site
                // below, so clear it here (only if we still own live state) —
                // otherwise the NEXT dictation inherits this session's stale
                // short-clip flag and wrongly skips its own LLM polish.
                if iOwnLiveState() {
                    recordingState.skipPolishForCurrent = false
                    recordingState.graniteTranscript = nil
                    recordingState.moonshineTranscript = nil
                }
                return
            }

            // Language gate: VOICE supports English + Dutch (both Latin-script).
            // Parakeet TDT v3 is multilingual and occasionally misidentifies
            // unfamiliar audio as Greek / Russian / Chinese etc. If the result
            // is dominantly non-Latin, treat it as a misrecognition rather
            // than pasting garbage at the cursor.
            if isPredominantlyNonLatin(rawText) {
                run.update { $0.outcome = "non-latin" }
                // Save the raw transcript to clipboard so the user doesn't lose it.
                let pb = NSPasteboard.general
                DictationPasteboard.write(rawText, to: pb)
                vlog("[VOICE] Non-Latin transcript saved to clipboard (\(rawText.count) chars)")
                // STORAGE AUDIT FIX: Also persist to RecentDictations so the user can
                // recover the rejected transcript from the History menu (BigMenu).
                // Without this, a rejected dictation is invisible after the toast dismisses.
                // We mark the polish stage as "skipped" (polishMs = nil, no fix count)
                // since the language gate ran before polish.
                RecentDictations.add(
                    raw: nil,
                    polished: rawText,
                    pasteTargetBundleID: capturedTargetForTask,
                    polishMs: nil,
                    granite: nil,
                    moonshine: nil,
                    parakeetRaw: rawText,
                    suspects: nil,
                    durationSeconds: Int(duration),
                    voiceCommandCount: nil,
                    cleanupLevelUsed: nil,
                    personalityStyleUsed: nil,
                    polishFixCount: nil
                )
                NotificationCenter.default.post(
                    name: .voiceError,
                    object: nil,
                    userInfo: ["message": "Transcript saved to clipboard — mixed script detected"]
                )
                // STALE-FLAG GUARD (same rationale as the empty-transcript path):
                // consume this session's per-clip polish flags before returning so
                // a stale skipPolishForCurrent can't leak into the next dictation.
                if iOwnLiveState() {
                    recordingState.skipPolishForCurrent = false
                    recordingState.graniteTranscript = nil
                    recordingState.moonshineTranscript = nil
                }
                return
            }

            // ============================================================
            // FUNNEL OBSERVABILITY — every stage logged with [VOICE-FUNNEL]
            // so the user can grep one prefix to see exactly what each layer
            // produced. Non-optional: this is how we diagnose "Chachi Pt"-
            // class bugs (something landed at paste that shouldn't have).
            // ============================================================

            // Run formatter — paragraph-aware, synchronous (no Ollama round-trip).
            let tFormatStart = CFAbsoluteTimeGetCurrent()
            // Strip a trailing stop-word command token ("finito") so the word
            // the user spoke to END the recording never lands in the pasted /
            // saved text. Trailing-only and gated on the feature flag, so a
            // genuine earlier mention is preserved and PTT is unaffected.
            let usesTunedCleanup = Qwen3Polisher.effectiveAutomaticCleanupModel == WhisperNowTunedPolisher.settingValue
            let recognizedT2 = usesTunedCleanup && WhisperNowTunedPolisher.usesT2Contracts
            let usesModelTranscript = recognizedT2 || (usesTunedCleanup && WhisperNowTunedPolisher.usesT4)
            let t2RawText = T2CleanupOptions.preparationTranscript(rawASR: rawText, recognizedT2: usesModelTranscript)
            let preparation = t2RawText.map { raw in
                // Explicit recording/submit commands keep their existing meaning outside model input.
                let text = coordinator.lastVoiceStopSession == mySession
                    ? RecordingCoordinator.strippingTrailingStopWord(from: raw) : raw
                let submitEnabled = UserDefaults.standard.bool(forKey: "voice.pressEnterCommandEnabled")
                    && (UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true)
                return DictationTextPreparation.Prepared(rawText: raw,
                    command: TrailingPressEnter.parse(text, enabled: submitEnabled), rejection: nil)
            } ?? DictationTextPreparation.prepare(segments: segments, formatter: textFormatter,
                pressEnterEnabled: UserDefaults.standard.bool(forKey: "voice.pressEnterCommandEnabled"),
                autoPaste: UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true,
                endedByVoiceStop: coordinator.lastVoiceStopSession == mySession)
            let pressEnterCommand = preparation.command
            let formatted = pressEnterCommand.text
            let formatterMs = (CFAbsoluteTimeGetCurrent() - tFormatStart) * 1000
            fputs("[LATENCY] TextFormatter: \(Int(formatterMs))ms\n", stderr)
            run.stage("rules", text: formatted, ms: Int(formatterMs),
                      detail: t2RawText != nil ? ["preparation": "model-transcript"] : nil)
            // ESC-cancel checkpoint: if cancelInFlightProcessing() fired while
            // the formatter ran, bail before we sink time into Ollama polish.
            // The `defer` above still runs (transcribingCount decrement, live
            // partial cleanup) so the pill flips back to idle cleanly.
            if Task.isCancelled || work.isCancelled {
                run.update { $0.outcome = "cancelled" }
                print("[VOICE-CANCEL-INFLIGHT] post-formatter cancellation detected — bailing before polish")
                return
            }
            // isTranscribing flips false in `defer` after this block returns —
            // pill exits the transcribing state right before paste happens.

            // Auto-copy is on by default — clipboard is the safety net for
            // when paste fails. Toggle in BigMenu → Output.
            let autoCopy: Bool = {
                if UserDefaults.standard.object(forKey: "autoCopy") == nil { return true }
                return UserDefaults.standard.bool(forKey: "autoCopy")
            }()

            // Auto-paste at cursor — default ON. Transcript also lands on
            // the clipboard. Toggle in BigMenu → Output if you want OFF.
            let autoPaste: Bool = {
                if UserDefaults.standard.object(forKey: "autoPaste") == nil { return true }
                return UserDefaults.standard.bool(forKey: "autoPaste")
            }()
            vlog("[VOICE] autoPaste setting: \(autoPaste)")

            // ============================================================
            // POLISH ENABLE TOGGLE — UI-facing kill switch.
            // Storage key `polishEnabled` (defaults to true). When false we
            // skip Qwen3 entirely and paste TextFormatter output directly.
            // This is the single biggest perceived-latency win on a hot mic
            // (sub-second paste vs. multi-second wait for the LLM).
            //
            // Distinct from `llmPolishEnabled` (the old internal flag the
            // polisher itself reads) — that one stays for backward compat,
            // this one is the new user-visible setting wired into the UI.
            // ============================================================
            let polishEnabledByUser: Bool = {
                if UserDefaults.standard.object(forKey: "polishEnabled") == nil { return true }
                return UserDefaults.standard.bool(forKey: "polishEnabled")
            }()
            // ============================================================
            // OPTIMISTIC PASTE — "type now, refine after".
            // Storage key `optimisticPaste` (defaults to false). When true
            // AND polish is enabled AND polish hasn't been short-circuited
            // for any reason, paste the TextFormatter output IMMEDIATELY,
            // then run Qwen3 in background and try to swap. Swap only
            // happens when the pasteboard fingerprint hasn't changed since
            // our optimistic write (a rough "user hasn't typed over us" gate)
            // — otherwise the polished text is dropped and the unpolished
            // text remains. Opt-in because the swap involves Cmd+Z which
            // can feel disruptive if the user is fast-typing.
            // ============================================================
            let optimisticPasteEnabled: Bool = {
                if UserDefaults.standard.object(forKey: "optimisticPaste") == nil { return false }
                return UserDefaults.standard.bool(forKey: "optimisticPaste")
            }()
            // LLM polish runs only if enabled+available; otherwise returns
            // `formatted` unchanged after a near-zero check. 800ms hard
            // timeout inside the polisher guards paste latency (warm
            // Qwen3-0.6B-4bit on M2 typically completes in ~80–150ms).
            // Insertion-context hint lets the model bias for chat / email and
            // skip entirely in code editors.
            vlog("[VOICE] Starting polish... (formatted=\(formatted.count) chars) polishEnabledByUser=\(polishEnabledByUser)")
            // The app the words were spoken into, captured at recording start, not whatever is frontmost at polish time.
            let polishContext = CursorPaster.polishContext(forBundleID: capturedTargetForTask)
            // Aggregate suspect words across segments — the polisher gets one
            // flat list. Combined dictionary (starter + user) is also surfaced
            // so the model knows e.g. "GitHub" not "get hub".
            let parakeetSuspectsAgg = segments.compactMap { $0.suspectWords }.flatMap { $0 }
            let formatterSuspects = TextFormatter.suspectsForPolish(formatted)
            let suspectWords = Array(Set(parakeetSuspectsAgg + formatterSuspects))
            // Merge built-in dictionary terms with the user's auto-learned
            // proper nouns (brand names, frequent contacts). Auto-learned
            // first so they take priority in any de-duplication.
            let preferredWords = ProperNounVocabulary.preferredSpellingTerms()
            var seenWords = Set<String>()
            let userVocab = (preferredWords + ProperNounVocabulary.current() + CombinedDictionary.terms())
                .filter { seenWords.insert($0.lowercased()).inserted }
            let polishStart = Date()
            // Short-utterance bypass: when RecordingCoordinator flagged the
            // current clip as 16-36KB ("ok"/"yeah"/"no" territory), skip the
            // LLM polish pass and keep the rule-based formatted text. Polish
            // on a single word costs ~100ms and sometimes mangles it.
            // Per-clip polish flags belong to the ACTIVE session. The
            // coordinator only mirrors skipPolishForCurrent / granite /
            // moonshine into shared state for the still-active session (gated
            // by isStillActive() in RecordingCoordinator), so when B has taken
            // over these fields hold B's values — reading them would apply B's
            // polish decision to A, and consuming (clearing) them would rob B's
            // own finish task of its flags. When we don't own live state, fall
            // back to safe defaults: no short-clip skip, no triple-model merge,
            // i.e. run the standard polish() on A's own formatted text. Lossless
            // for A, and B's flags stay intact for B to consume.
            let skipPolish: Bool
            let graniteTranscript: String?
            let moonshineTranscript: String?
            if iOwnLiveState() {
                skipPolish = recordingState.skipPolishForCurrent
                recordingState.skipPolishForCurrent = false  // consume the flag
                graniteTranscript = recordingState.graniteTranscript
                recordingState.graniteTranscript = nil        // consume the flag
                moonshineTranscript = recordingState.moonshineTranscript
                recordingState.moonshineTranscript = nil      // consume the flag
            } else {
                skipPolish = false
                graniteTranscript = nil
                moonshineTranscript = nil
            }
            // Decide up-front whether this dictation will actually hit the LLM.
            // Used to gate optimistic paste: there's no point doing the
            // "paste-now, replace-after" dance if polish was going to be a
            // no-op anyway (short clip, polish disabled, non-English, etc.).
            let polishWillRun = CleanupLevel.current != .none && polishEnabledByUser && !skipPolish

            // Optimistic paste: paste TextFormatter output immediately, BEFORE
            // the LLM round trip. The post-polish replace is best-effort.
            //
            // We push the optimistic paste onto pasteChain so it serializes
            // with any in-flight prior dictation's paste — we don't want two
            // pastes racing the clipboard. The swap task is fired LATER after
            // polish completes.
            //
            // `optimisticPasteSnapshot` is the SHA-like fingerprint we use to
            // verify the field hasn't changed before we attempt Cmd+Z + repaste.
            // (Plain string equality on the pasteboard contents is good enough
            // — if anything else clobbered our paste, we abort the swap.)
            let optimisticActive = false // Avoid undoing edits made while cleanup runs.
            var optimisticPasteboardSig: String? = nil
            // BUGFIX: hold our own optimistic-paste task locally. The Qwen3
            // polish below has an `await` and during that await another
            // finishRecording can overwrite `pasteChain`. If we read
            // `pasteChain` after the await, we may pick up a NEWER session's
            // chain link and lose serialization with our own optimistic write.
            // Capturing it here keeps the swap correctly ordered behind our
            // own pre-polish paste.
            var ourOptimisticTask: Task<Void, Never>? = nil
            if optimisticActive {
                // BUGFIX (Category 4): chain off the anchor reserved at Parakeet-return,
                // not pasteChain-now. Otherwise a faster recording B could overwrite
                // pasteChain between Parakeet and here, and our optimistic paste would
                // skip past it. The anchor preserves enqueue (chronological) order.
                let priorChain = pasteOrderAnchor
                let snapshotTarget = capturedTargetForTask
                let optimisticText = formatted
                let optimisticPolishOwnedFormatting = false  // pre-polish — paster runs its rule-based adjuster
                let optimisticTask: Task<Void, Never> = Task { @MainActor in
                    _ = await priorChain.value
                    guard !work.isCancelled else { return }
                    var didReactivate = false
                    if let id = snapshotTarget,
                       let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                       !app.isActive {
                        app.activate()
                        didReactivate = true
                    }
                    // LATENCY: only pay the 80ms activation settle when we
                    // actually switched apps (see final-paste path for rationale).
                    if didReactivate { try? await Task.sleep(nanoseconds: 80_000_000) }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(optimisticText, forType: .string)
                    self.cursorPaster.pasteAtCursor(
                        optimisticText,
                        restoreClipboard: false,
                        preFormatted: optimisticPolishOwnedFormatting
                    )
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    vlog("[VOICE] OPTIMISTIC paste DONE")
                }
                pasteChain = optimisticTask
                ourOptimisticTask = optimisticTask
                // Snapshot the pasteboard once the optimistic write has landed,
                // so the post-polish swap can detect "user typed over our paste".
                optimisticPasteboardSig = optimisticText
            }
            // var (not let) — see the empty-polish guard below that may
            // fall back to `formatted` if Qwen3 returns whitespace/empty.
            // Dictation trace (numbers and labels only): which engine was asked, and why a fallback was used.
            var traceEngine: String = {
                if CleanupLevel.current == .none || !polishEnabledByUser { return "off" }
                switch Qwen3Polisher.effectiveAutomaticCleanupModel {
                case WhisperNowTunedPolisher.settingValue:
                    if WhisperNowTunedPolisher.usesT4 { return WhisperNowTunedPolisher.dictationAdapter(for: formatted).traceName }
                    return WhisperNowTunedPolisher.usesT2Contracts ? "dose1-t2" : "dose1-t1"
                case "s1-mini": return "s1-mini"
                default: return "qwen3"
                }
            }()
            // dose1-t1 is ready when its files are installed. The others count as ready when selected.
            var traceEngineReady = (traceEngine.hasPrefix("dose1-") || traceEngine == WhisperNowTunedPolisher.DictationAdapter.t4.traceName
                || traceEngine == WhisperNowTunedPolisher.DictationAdapter.v3c.traceName) ? WhisperNowTunedPolisher.isInstalled : traceEngine != "off"
            var traceModelWillRun = CleanupLevel.current != .none && polishEnabledByUser && !skipPolish
            var traceFallback: String? = (CleanupLevel.current == .none || !polishEnabledByUser) ? "level-off"
                : (skipPolish ? "short-clip" : nil)
            let t2OutcomeObserver = recognizedT2 ? ShadowCleanupObserver() : nil
            let longProse = formatted.count > 1_200
            let draftWords = formatted.split(whereSeparator: { $0.isWhitespace }).count
            var editedBySection = false
            var finalText: String
            var cleanupRoute = "skipped-level-off"
            if (recognizedT2 ? cleanupForTask == "none" : CleanupLevel.current == .none) || !polishEnabledByUser {
                vlog("[VOICE] Polish skipped (cleanupLevel=none or polishEnabled=false) — rule-based only")
                finalText = formatted
            } else if skipPolish {
                vlog("[VOICE] Short clip — skipping LLM polish (rule-based only)")
                cleanupRoute = "skipped-short-clip"
                finalText = formatted
            } else if !recognizedT2 && (graniteTranscript != nil || moonshineTranscript != nil) {
                // Triple-model path: Qwen3 merges Parakeet v2 + Granite 4.0 + Moonshine Tiny outputs.
                cleanupRoute = "triple-merge"
                run.update {
                    if let graniteTranscript { $0.settings["graniteTranscript"] = graniteTranscript }
                    if let moonshineTranscript { $0.settings["moonshineTranscript"] = moonshineTranscript }
                }
                let graniteLabel = graniteTranscript.map { "'\($0.prefix(40))'" } ?? "nil"
                let moonshineLabel = moonshineTranscript.map { "'\($0.prefix(40))'" } ?? "nil"
                finalText = await Qwen3Polisher.shared.merge(
                    parakeet: formatted,
                    granite: graniteTranscript,
                    moonshine: moonshineTranscript,
                    context: polishContext,
                    suspectWords: suspectWords.isEmpty ? nil : suspectWords,
                    userVocabulary: userVocab.isEmpty ? nil : userVocab,
                    fieldContext: capturedFieldContextForTask,
                    appContextLabel: capturedRichAppContextForTask ?? Qwen3Polisher.appContextLabel(forBundleID: capturedTargetForTask),
                    cleanupLevel: cleanupForTask,
                    personalityStyle: personalityForTask
                )
                // Triple-ASR capture for the Polish Replay debug panel. Pure
                // observer — runs AFTER the merge has produced `finalText`,
                // never blocks the paste path, persists best-effort. We
                // intentionally take the post-formatter Parakeet text here
                // (matches what the merge actually saw); raw segments-joined
                // text is logged elsewhere via [VOICE-FUNNEL] STAGE 1.
                let parakeetConfs = segments.compactMap { $0.confidence }
                let parakeetAvgConf: Float? = parakeetConfs.isEmpty
                    ? nil
                    : parakeetConfs.reduce(0, +) / Float(parakeetConfs.count)
                // Surface average confidence to the pill so it can tint its
                // stroke (white >= 0.55, amber 0.40..<0.55, red < 0.40).
                // Already on MainActor (enclosing Task), so set directly.
                if iOwnLiveState(), let conf = parakeetAvgConf {
                    self.recordingState.transcriptionConfidence = Double(conf)
                }
                let capture = TripleASRCapture(
                    parakeet: formatted,
                    granite: graniteTranscript,
                    moonshine: moonshineTranscript,
                    merged: finalText,
                    polished: finalText,
                    parakeetConfidence: parakeetAvgConf,
                    graniteConfidence: nil,
                    moonshineConfidence: nil,
                    source: "live dictation"
                )
                Task.detached(priority: .utility) {
                    TripleASRStore.save(capture)
                    await MainActor.run {
                        NotificationCenter.default.post(name: .tripleASRCaptured, object: nil)
                    }
                }
            } else {
                guard !work.isCancelled else { return }
                let polishDraft: @Sendable (String, Bool) async -> String = { [polishContext, suspectWords, userVocab,
                    capturedFieldContextForTask, capturedRichAppContextForTask, capturedTargetForTask, cleanupForTask, personalityForTask]
                    text, isSection in
                    await FlowRunCollector.$current.withValue(run) { await ShadowCleanupTrace.$observer.withValue(t2OutcomeObserver) {
                        await Qwen3Polisher.shared.polish(
                            text,
                            context: polishContext,
                            suspectWords: isSection || suspectWords.isEmpty ? nil : suspectWords,
                            userVocabulary: userVocab.isEmpty ? nil : userVocab,
                            fieldContext: isSection ? nil : capturedFieldContextForTask,
                            appContextLabel: capturedRichAppContextForTask ?? Qwen3Polisher.appContextLabel(forBundleID: capturedTargetForTask),
                            cleanupLevel: cleanupForTask,
                            personalityStyle: personalityForTask
                        )
                    } }
                }
                // The short path retains the key-up deadline. A long draft can
                // already have spent that much on recognition. Give its editor a
                // separate bounded window and preserve each unedited section.
                // Longer drafts earn more time (1.5 s + 12 ms a word, at most 6 s): mid-length dictations
                // used to miss the flat 1.5 s about two times in three and paste rules-only text (21 Nov 2026).
                let shortBudget = DictationDeadline.remainingSeconds(sinceKeyRelease: CFAbsoluteTimeGetCurrent() - keyUpAt,
                                                                     words: draftWords)
                // Long dictations try the PC first (RemoteCleanup); its time counts inside the same budgets below.
                let remoteStarted = ContinuousClock.now
                if !recognizedT2, polishContext != .code, Qwen3Polisher.isEnabled,
                   let pcText = await RemoteCleanup.cleanedText(formatted, cleanupLevel: cleanupForTask,
                        userVocabulary: userVocab.isEmpty ? nil : userVocab, personalityStyle: personalityForTask,
                        appContextLabel: capturedRichAppContextForTask ?? Qwen3Polisher.appContextLabel(forBundleID: capturedTargetForTask),
                        longProse: longProse, timeout: longProse ? 2.4 : max(0.3, shortBudget * 0.6)) {
                    cleanupRoute = "remote-pc"
                    finalText = pcText
                } else if !recognizedT2, polishContext != .code, Qwen3Polisher.isEnabled,
                   longProse || formatted.contains(where: \.isNewline) {
                    editedBySection = true
                    cleanupRoute = "sections"
                    let ranges = DictationTextPreparation.cleanupSections(in: formatted)
                    let budget = longProse ? DictationDeadline.sectionBudgetSeconds(count: ranges.count) : shortBudget
                    let deadline = remoteStarted + .seconds(budget)
                    let result = await DictationTextPreparation.cleanSections(in: formatted, ranges: ranges, deadline: deadline,
                        review: { section, edited in
                            let vetoed = await DraftDecisionGate.shouldKeepOriginal(section, edited: edited, deadline: deadline)
                            if vetoed { run.decision("decision-gate", "kept-section", reason: "meaning check vetoed a section edit") }
                            return vetoed
                        }) { section in
                            await polishDraft(section, true)
                        }
                    finalText = result.text
                    if result.timedOut { traceFallback = finalText == formatted ? "deadline" : "partial-deadline" }
                } else {
                    cleanupRoute = "local"
                    run.update { $0.settings["budgetSeconds"] = String(format: "%.2f", shortBudget) }
                    let localLeft = max(0.05, shortBudget - RemoteCleanup.seconds(since: remoteStarted))
                    let answer = await DictationDeadline.run(seconds: localLeft) { await polishDraft(formatted, false) }
                    finalText = answer ?? formatted
                    if answer == nil {
                        traceFallback = "deadline"
                        vlog("[VOICE] Cleanup missed its deadline — pasting rules-only text")
                    }
                }
            }
            if recognizedT2 {
                if traceFallback == "level-off" {
                    traceEngine = "off"
                    traceEngineReady = true
                    traceModelWillRun = false
                } else if traceFallback != nil && t2OutcomeObserver?.result == nil {
                    traceEngine = "rules"
                    traceEngineReady = false
                    traceModelWillRun = false
                } else if t2OutcomeObserver?.result != nil {
                    let actual = T2ResponseSafety.trace(engine: t2OutcomeObserver?.engine, result: t2OutcomeObserver?.result,
                        deadlineExpired: traceFallback == "deadline")
                    traceEngine = actual.engine
                    traceEngineReady = actual.ready
                    traceModelWillRun = actual.ready
                    traceFallback = actual.fallback
                }
            }
            run.stage("cleanup", text: finalText, ms: Int(Date().timeIntervalSince(polishStart) * 1000),
                      detail: ["route": cleanupRoute, "engine": traceEngine, "fallback": traceFallback ?? "none"])
            run.model("cleanup", traceEngine)
            run.model("cleanupEngine", PolishStatus.shared.lastEngine)
            if PolishStatus.shared.lastSanitizerRejected {
                run.decision("cleanup-guard", "rejected", reason: PolishStatus.shared.lastReason)
            } else if let reason = PolishStatus.shared.lastReason, !reason.isEmpty {
                run.decision("cleanup-guard", "note", reason: reason)
            }
            if let fallback = traceFallback { run.decision("cleanup", "fallback", reason: fallback) }
            // Check the proposed cleanup only within the existing key-up budget.
            // A cold or busy reviewer leaves the ordinary cleanup result in place.
            if (traceModelWillRun || cleanupRoute == "remote-pc"), !editedBySection,
               !work.isCancelled {
                let remaining = DictationDeadline.remainingSeconds(sinceKeyRelease: CFAbsoluteTimeGetCurrent() - keyUpAt,
                                                                   words: draftWords)
                if await DraftDecisionGate.shouldKeepOriginal(formatted, edited: finalText,
                    deadline: ContinuousClock.now + .seconds(remaining)) {
                    let partial = finalText.utf8.count <= 600 &&
                        DictationDeadline.remainingSeconds(sinceKeyRelease: CFAbsoluteTimeGetCurrent() - keyUpAt,
                                                           words: draftWords) > 0.05
                        ? Qwen3Polisher.recoverAnchoredSpelling(original: formatted, proposed: finalText) : nil
                    finalText = partial ?? formatted
                    traceFallback = "decision-meaning"
                    run.decision("decision-gate", "kept-original",
                                 reason: partial != nil ? "meaning changed; anchored spelling fixes kept" : "meaning changed")
                    run.stage("decision-gate", text: finalText)
                }
            }
            let polishMs = Int(Date().timeIntervalSince(polishStart) * 1000)
            fputs("[LATENCY] Qwen3 polish: \(polishMs)ms (enabled=\(polishEnabledByUser), skipShort=\(skipPolish))\n", stderr)
            // BUGFIX: guard against polish returning empty/whitespace. If
            // Qwen3 ever returns "" we'd paste nothing at the cursor while
            // the user thinks their dictation succeeded. Fall back to the
            // pre-polish formatted text — same data the optimistic-paste
            // path would have written.
            if WhisperNowCleanupDecision.isConfirmedNoSpeech(polished: finalText, formatted: formatted) {
                // WhisperNow tuned answered EMPTY for hesitation sounds only: treat it like no speech.
                vlog("[VOICE] WhisperNow tuned: no speech — nothing to paste")
                run.update { $0.outcome = "no-speech" }
                Telemetry.log("polish.no_speech", properties: ["input_chars": formatted.count])
                return
            }
            if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               && !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vlog("[VOICE] WARNING: polish returned empty — falling back to formatted text")
                traceFallback = "empty-answer"
                run.decision("cleanup", "empty-answer", reason: "model returned nothing; rules text used")
                Telemetry.log("polish.empty_output", properties: [
                    "input_chars": formatted.count
                ])
                finalText = formatted
            }
            let modelOutputForTraining = finalText
            finalText = T2CleanupOptions.finalizedTranscript(candidate: finalText, preparedASR: formatted,
                level: cleanupForTask, recognizedT2: usesModelTranscript)
                ?? DictationTextPreparation.finalize(polished: finalText, formatted: formatted)
            run.stage("finalize", text: finalText)
            // Fail-proof word pass after every engine: hesitations, stutters, list markup.
            finalText = DictationFinalPass.apply(finalText)
            run.stage("final-pass", text: finalText)
            if finalText.isEmpty {
                // Only hesitations were said ("um"): nothing to paste. Same outcome as no speech.
                run.update { $0.outcome = "no-speech" }
                showToast(DictationRecoveryRules.emptyTranscriptMessage(mic: coordinator.audioCapture.activeMicrophoneName))
                if iOwnLiveState() {
                    recordingState.skipPolishForCurrent = false
                    recordingState.graniteTranscript = nil
                    recordingState.moonshineTranscript = nil
                }
                return
            }
            // Real-word pass (tinyfix): their/there, its/it's, then/than in English sentences. Off with cleanup.
            if polishEnabledByUser && cleanupForTask != "none" {
                let started = CFAbsoluteTimeGetCurrent()
                let input = finalText
                let isCode = polishContext == .code
                finalText = await DictationReferee.background {
                    DictationReferee.dictationPass(input, isCode: isCode)
                }
                guard !Task.isCancelled, !work.isCancelled else { return }
                run.stage("tinyfix", text: finalText, ms: Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
            }
            // tinynext recheck of Parakeet's low-confidence words: a word changes only when a near word reads
            // clearly better in context (LowConfidenceRecheck). Off with cleanup and in code. Falls back to text.
            if polishEnabledByUser && cleanupForTask != "none" && polishContext != .code {
                let started = CFAbsoluteTimeGetCurrent()
                let input = finalText
                let recheck = await DictationReferee.background {
                    LowConfidenceRecheck.recheck(input, suspects: suspectWords, protectedTerms: userVocab)
                }
                guard !Task.isCancelled, !work.isCancelled else { return }
                finalText = recheck.text
                for change in recheck.changes {
                    run.decision("tinynext", "\(change.original) -> \(change.replacement)",
                                 reason: String(format: "score margin %.3f", change.delta))
                }
                run.stage("tinynext", text: finalText, ms: Int((CFAbsoluteTimeGetCurrent() - started) * 1000),
                          detail: ["suspects": "\(suspectWords.count)", "changed": "\(recheck.changes.count)"])
            }
            if polishContext != .code {
                finalText = ProperNounVocabulary.applyPreferredSpelling(finalText, terms: preferredWords)
                run.stage("vocabulary", text: finalText)
            }
            if polishEnabledByUser && cleanupForTask != "none" {
                finalText = polishContext == .code
                    ? DictationParagraphs.format(finalText)
                    : DictationParagraphs.formatDictation(finalText, isEmail: polishContext == .email)
                run.stage("layout", text: finalText, detail: ["context": polishContext.rawValue,
                    "paragraphs": "\(finalText.components(separatedBy: "\n\n").count)"])
            }
            // ESC-cancel checkpoint: if cancelInFlightProcessing() fired
            // during the polish round-trip, don't enqueue the paste step.
            // The cancelled-dictation History row was already written by
            // cancelInFlightProcessing(), so we just exit cleanly here.
            if Task.isCancelled || work.isCancelled {
                run.update { $0.outcome = "cancelled" }
                print("[VOICE-CANCEL-INFLIGHT] post-polish cancellation detected — skipping paste enqueue")
                return
            }
            // The single place a dictation's final text is decided. Remembered
            // before the paste is attempted, so Control+Command+V still works
            // when the automatic paste landed in the wrong place or failed.
            lastTranscript.remember(finalText)
            let polishChanged = finalText != formatted
            // Classify the polish outcome from the call-site's perspective.
            // The Polisher itself logs the granular reason ("rejected: word
            // drift", "TIMEOUT", "skipped: disabled", etc.); we tag the
            // observable outcome here so telemetry has a single source of truth.
            let polishOutcome: String
            if !Qwen3Polisher.isEnabled {
                polishOutcome = "disabled"
            } else if !polishChanged {
                // Either no-op (input clean) or rejected/timed-out — both
                // surface as "input unchanged". The Polisher log line above
                // disambiguates for humans; for telemetry "unchanged" is fine.
                polishOutcome = "unchanged"
            } else {
                polishOutcome = "succeeded"
            }
            Telemetry.log("polish.\(polishOutcome)", properties: [
                "elapsed_ms": polishMs,
                "input_chars": formatted.count,
                "output_chars": finalText.count,
                "context": polishContext.rawValue,
                "suspect_count": suspectWords.count,
                "vocab_count": userVocab.count
            ])

            // Calculate statistics
            let wordCount = finalText.split(separator: " ").count
            let durationSeconds = Int(duration)
            let wpm = durationSeconds > 0 ? (wordCount * 60) / durationSeconds : 0
            // "Last dictation" snapshot stats drive the live pill / stats UI and
            // represent the MOST RECENT dictation. If B owns the session, B is
            // the most recent — an older background session A must not overwrite
            // these with its stale numbers. Gate on ownership.
            if iOwnLiveState() {
                recordingState.lastDictationWordCount = wordCount
                recordingState.lastDictationDurationSeconds = durationSeconds
                recordingState.lastDictationWPM = wpm
            }
            // Cumulative session + lifetime totals: A's dictation genuinely
            // happened, so it must be counted regardless of ownership. These are
            // additive (order-independent) and not live-preview state.
            recordingState.recordDictation(words: wordCount, durationSeconds: durationSeconds)

            print("[VOICE] About to handle copy/paste... autoCopy=\(autoCopy), autoPaste=\(autoPaste)")

            // Hand the clipboard + paste step off to the serial pasteChain.
            // Doing it inline would let two completed pipelines race the
            // clipboard and synthesized-keystroke state — instead each finish
            // task awaits the prior chain link, then takes its turn. No
            // staleness gate: older transcripts MUST reach the cursor even
            // if the user already started a new recording. Order = arrival
            // order (older finishes first → pastes first).
            let deliveryIntent = DictationTextPreparation.delivery(autoCopy: autoCopy, autoPaste: autoPaste,
                skipPolish: skipPolish, formatted: formatted, final: finalText,
                fieldContextProvided: capturedFieldContextForTask != nil, command: pressEnterCommand)
            let polishOwnedFormatting = deliveryIntent.preFormatted
            // BUGFIX (Category 4): if we ran optimistic paste, chain off THAT task
            // (most-recent pasteChain) so our final paste serializes after our own
            // optimistic write. Otherwise chain off the parakeet-return anchor so
            // paste order = finish-call order, not polish-completion order.
            // BUGFIX: reading `pasteChain` here was racy — during the polish
            // await another session can mutate it. Use the local snapshot of
            // our own optimistic task instead so we always serialize behind
            // our own pre-polish write.
            let prior: Task<Void, Never>? = optimisticActive
                ? (ourOptimisticTask ?? pasteOrderAnchor)
                : pasteOrderAnchor
            print("[VOICE-TIMING] polish returned at \(Date()) chars=\(finalText.count)")
            // OPTIMISTIC SWAP PATH: optimistic paste already wrote `formatted`
            // to the field above. If polish completed and produced something
            // genuinely different, attempt a Cmd+Z then paste the polished
            // version. Bail out and leave the unpolished text in place when:
            //   - polish didn't change anything (no swap needed)
            //   - polish was disabled / short / non-English (finalText==formatted)
            //   - the system pasteboard contents differ from what we wrote
            //     (something else clobbered it — could be the user typing
            //     manually, another paste source, etc.)
            //
            // The Cmd+Z + repaste is best-effort: if Cmd+Z can't undo (the
            // app doesn't support it) the user ends up with both versions
            // visible, which is a less bad outcome than losing their text.
            let optimisticSwapNeeded = optimisticActive && polishChanged
            let optimisticSig = optimisticPasteboardSig
            // The pill's glow learns how long processing took for this much speech.
            PillWorkTiming.recordDictation(words: wordCount, audioSeconds: duration,
                                           seconds: CFAbsoluteTimeGetCurrent() - keyUpAt)
            run.update {
                $0.fallbackReason = traceFallback
                $0.timingsMs["rulesMs"] = Int(formatterMs)
                $0.timingsMs["cleanupMs"] = polishMs
                $0.timingsMs["handoffAtMs"] = Int((CFAbsoluteTimeGetCurrent() - keyUpAt) * 1000)
                $0.settings["context"] = polishContext.rawValue
                $0.settings["autoPaste"] = "\(autoPaste)"
            }
            deliveryStarted = true
            work.task = Task { @MainActor in
                defer {
                    deliverySlot.finish()
                    self.dictationWork.finish(work)
                    self.recordingState.transcribingCount = self.dictationWork.activeCount
                    self.scheduleMenuBarIconTimer()
                    self.refreshMenuBarIcon()
                }
                _ = await prior?.value
                // ESC-cancel checkpoint: unlike the optimistic first paste, the
                // swap (Cmd+Z undo + repaste) had no early guard — so an ESC
                // could still trigger an undo/repaste after cancellation. Bail.
                guard !Task.isCancelled, work.mayDeliver else {
                    run.finish(outcome: "cancelled", output: nil)
                    return
                }
                let tPasteStart = CFAbsoluteTimeGetCurrent()
                if optimisticSwapNeeded, let sig = optimisticSig {
                    // SWAP PATH — optimistic paste already ran, try to replace.
                    let pb = NSPasteboard.general
                    let currentClipboard = pb.string(forType: .string) ?? ""
                    if currentClipboard != sig {
                        print("[VOICE] OPTIMISTIC swap SKIPPED — clipboard changed since paste (current!=sig)")
                        if autoCopy {
                            DictationPasteboard.write(finalText, to: pb)
                        }
                    } else {
                        if let id = capturedTargetForTask,
                           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                           !app.isActive {
                            app.activate()
                        }
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        self.cursorPaster.undoLastPaste()
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        // TRANSCRIPT-LOSS SAFETY NET (mirrors the final-paste
                        // path): keep the polished text on the clipboard as the
                        // recovery net whether or not auto-copy is on, and never
                        // restore the prior clipboard over it. If the synthetic
                        // repaste fails, CursorPaster's toast tells the user to
                        // press Cmd+V — that must actually paste their transcript.
                        DictationPasteboard.write(finalText, to: pb)
                        self.cursorPaster.pasteAtCursor(
                            finalText,
                            restoreClipboard: false,
                            preFormatted: polishOwnedFormatting
                        )
                        try? await Task.sleep(nanoseconds: 60_000_000)
                    }
                    Qwen3Polisher.shared.updateRollingContext(finalText)
                    let pasteMs = (CFAbsoluteTimeGetCurrent() - tPasteStart) * 1000
                    let totalMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000
                    fputs("[LATENCY] Paste (optimistic-swap branch): \(Int(pasteMs))ms\n", stderr)
                    run.finish(outcome: "optimistic-swap", output: finalText, fallback: traceFallback)
                    fputs("[LATENCY] TOTAL pipeline (optimistic): \(Int(totalMs))ms (parakeet=\(Int(parakeetMs)) formatter=\(Int(formatterMs)) polish=\(polishMs) paste=\(Int(pasteMs)))\n", stderr)
                    Telemetry.log("latency.pipeline", properties: [
                        "total_ms": Int(totalMs),
                        "parakeet_ms": Int(parakeetMs),
                        "formatter_ms": Int(formatterMs),
                        "polish_ms": polishMs,
                        "paste_ms": Int(pasteMs),
                        "polish_enabled": polishEnabledByUser,
                        "polish_skipped_short": skipPolish,
                        "input_chars": formatted.count,
                        "output_chars": finalText.count,
                        "optimistic_paste": true
                    ])
                    return
                }
                if optimisticActive && !optimisticSwapNeeded {
                    // Optimistic paste already landed the right text — nothing to do.
                    print("[VOICE] OPTIMISTIC paste was sufficient — polish unchanged")
                    if autoCopy {
                        let pb = NSPasteboard.general
                        DictationPasteboard.write(finalText, to: pb)
                    }
                    Qwen3Polisher.shared.updateRollingContext(finalText)
                    let pasteMs = (CFAbsoluteTimeGetCurrent() - tPasteStart) * 1000
                    let totalMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000
                    fputs("[LATENCY] Paste (optimistic-noop branch): \(Int(pasteMs))ms\n", stderr)
                    run.finish(outcome: "optimistic", output: finalText, fallback: traceFallback)
                    fputs("[LATENCY] TOTAL pipeline (optimistic-noop): \(Int(totalMs))ms (parakeet=\(Int(parakeetMs)) formatter=\(Int(formatterMs)) polish=\(polishMs) paste=\(Int(pasteMs)))\n", stderr)
                    Telemetry.log("latency.pipeline", properties: [
                        "total_ms": Int(totalMs),
                        "parakeet_ms": Int(parakeetMs),
                        "formatter_ms": Int(formatterMs),
                        "polish_ms": polishMs,
                        "paste_ms": Int(pasteMs),
                        "polish_enabled": polishEnabledByUser,
                        "polish_skipped_short": skipPolish,
                        "input_chars": formatted.count,
                        "output_chars": finalText.count,
                        "optimistic_paste": true,
                        "optimistic_noop": true
                    ])
                    return
                }
                if autoCopy {
                    print("[VOICE] Copying to clipboard...")
                    let pb = NSPasteboard.general
                    DictationPasteboard.write(finalText, to: pb)
                    print("[VOICE] Copied to clipboard successfully")
                }
                // Record one outcome after delivery or readback. Keep transcripts
                // and clipboard details out of the trace.
                var traceStages: [String: Int] = [
                    "transcriptAtMs": transcriptAtMs,
                    "rulesMs": Int(formatterMs)
                ]
                if started != nil { traceStages["holdMs"] = Int(duration * 1000) }
                if traceModelWillRun { traceStages["modelMs"] = polishMs }
                var trace = DictationTrace(
                    engine: traceEngine, engineReady: traceEngineReady, fallbackReason: traceFallback,
                    level: cleanupForTask, style: personalityForTask,
                    stagesMs: traceStages, pasteVerdict: nil, recordedAt: Date())
                let traceGate = OneShotGate()
                // Set when the paste was refused for a secure (password) field. Text from such a dictation is never logged.
                var pasteTargetSecure = false
                func recordPaste(_ verdict: String) {
                    guard traceGate.claim() else { return }
                    let secure = pasteTargetSecure || verdict == "secure-field"
                    trace.pasteVerdict = verdict
                    DictationTraceLog.append(trace)
                    run.timing("pasteAtMs", Int((CFAbsoluteTimeGetCurrent() - keyUpAt) * 1000))
                    run.finish(outcome: verdict, output: finalText, fallback: trace.fallbackReason, secureField: secure)
                    let runID = run.snapshot.id
                    Task { @MainActor in self.lastDictationRunID = runID }
                    // Training copy with text: every dictation, whatever happened to the paste.
                    DictationTrainingLog.append(DictationTrainingRecord(
                        id: claimed?.sessionId.uuidString, recordedAt: Date(), app: capturedTargetForTask,
                        audioPath: claimed?.audioURL?.path, durationSeconds: Int(duration),
                        asrRaw: secure ? nil : rawText,
                        rulesText: secure ? nil : formatted, modelOutput: secure ? nil : modelOutputForTraining,
                        finalText: secure ? nil : finalText,
                        engine: trace.engine, fallbackReason: trace.fallbackReason, level: trace.level,
                        style: trace.style, pasteVerdict: verdict))
                }
                if autoPaste {
                    print("[VOICE] capturedTargetForTask=\(capturedTargetForTask ?? "nil")")
                    // Re-activate the SNAPSHOT target app (not the live
                    // instance var) so a newer recording that re-pointed
                    // targetAppBundleID elsewhere can't steal this older
                    // transcript's destination.
                    // Cancel-flag guard: if the user cancelled this session between
                    // the audio claim and now (race between finishRecording's async
                    // task and cancelRecording), skip the paste entirely. Audio drain
                    // and cleanup above already ran — only the cursor write is skipped.
                    guard !work.isCancelled else {
                        print("[VOICE-HK] finishRecording: session was cancelled — skipping paste")
                        Telemetry.signal("paste.skipped", "cancelled", ["session": mySession])
                        recordPaste("cancelled")
                        return
                    }
                    print("[VOICE] Calling pasteAtCursor...")
                    print("[VOICE-TIMING] paste scheduled at \(Date()) chars=\(finalText.count)")
                    // CursorPaster performs delayed target validation and owns clipboard
                    // restoration. A scheduled paste is not confirmation of delivery.
                    await withCheckedContinuation { (landed: CheckedContinuation<Void, Never>) in
                    let landedGate = OneShotGate()
                    var skippedInSecureField = false
                    cursorPaster.pasteAtCursor(
                        finalText,
                        restoreClipboard: deliveryIntent.restoreClipboard,
                        preFormatted: polishOwnedFormatting,
                        expectedTarget: claimed?.pasteTarget,
                        requireCapturedTarget: deliveryIntent.requireCapturedTarget,
                        submitAfterVerifiedPaste: deliveryIntent.shouldSubmit,
                        maySubmit: { [weak self] in
                            guard let self else { return false }
                            return self.recordingState.recordingSessionID == mySession &&
                                work.mayDeliver &&
                                UserDefaults.standard.bool(forKey: "voice.pressEnterCommandEnabled")
                        },
                        mayDeliver: { [weak self] in
                            guard self != nil else { return false }
                            return work.mayDeliver
                        },
                        completion: { [weak self] result in
                            // A sent event is not a completed delivery: keep the FIFO
                            // slot until readback has either verified or attempted fallback.
                            defer {
                                if result != .eventSent, landedGate.claim() { landed.resume() }
                            }
                            switch result {
                            case .eventSent:
                                trace.stagesMs["pasteSentAtMs"] = Int((CFAbsoluteTimeGetCurrent() - keyUpAt) * 1000)
                                // Wispr plays its paste cue once a dictation is pasted.
                                SoundEffects.playDone()
                                // Wispr's auto-cleanup nudge: "Cleaned up! See what's changed".
                                if let self, self.recordingState.recordingSessionID == mySession,
                                   !work.isCancelled, let diff = PolishDiff.autoCleanupNudge(raw: rawText, final: finalText,
                                                                                     level: cleanupForTask) {
                                    self.recordingState.polishDiff = diff
                                }
                            case .skipped:
                                recordPaste(skippedInSecureField ? "secure-field" : "skipped")
                            case .failed:
                                recordPaste("dispatch-failed")
                            }
                        },
                        onReadback: { verdict in
                            // A failed dispatch may report unknown synchronously before
                            // completion. Let the completion record the actual failure.
                            if trace.stagesMs["pasteSentAtMs"] != nil {
                                defer { if landedGate.claim() { landed.resume() } }
                                switch verdict {
                                case .verified: recordPaste("landed"); PillHaptics.pasteConfirmed()
                                case .notLanded: recordPaste("not-landed")
                                case .unknown: recordPaste("unverified")
                                }
                            }
                            // Learning starts only after the paste is verified in the field.
                            // A sent event is not enough, and unknown or not-landed starts nothing.
                            guard work.mayDeliver, verdict == .verified, let target = claimed?.pasteTarget else { return }
                            CorrectionLearner.shared.track(pastedText: finalText, snapshot: target,
                                                           dictationID: claimed?.sessionId.uuidString)
                        },
                        onFailure: { [weak self] reason in
                            skippedInSecureField = reason == .secureField
                            if reason == .secureField { pasteTargetSecure = true }
                            guard let self,
                                  self.recordingState.recordingSessionID == mySession,
                                  !work.isCancelled else { return }
                            if reason == .notConfirmed {
                                self.showCopiedNotice()
                                return
                            }
                            self.showPasteRecovery(finalText, id: recoveryID, secureField: reason == .secureField)
                        }
                    )
                    // Backstop: a paste that never reports back must not hold up the next dictation.
                    Task {
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        // If readback already ended, this timer must not mutate its token.
                        guard landedGate.claim() else { return }
                        work.expireDelivery()
                        recordPaste(trace.stagesMs["pasteSentAtMs"] == nil ? "no-dispatch-result" : "unverified")
                        landed.resume()
                    }
                    }
                    // Reduced settle — Wispr Flow ships Cmd-V without these.
                    // (Inter-paste 60ms removed entirely.)
                } else {
                    print("[VOICE] Auto-paste disabled")
                    recordPaste("auto-paste-off")
                }
                let pasteMs = (CFAbsoluteTimeGetCurrent() - tPasteStart) * 1000
                let totalMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000
                fputs("[LATENCY] Paste (incl. queue + settle): \(Int(pasteMs))ms\n", stderr)
                fputs("[LATENCY] TOTAL pipeline: \(Int(totalMs))ms (parakeet=\(Int(parakeetMs)) formatter=\(Int(formatterMs)) polish=\(polishMs) paste=\(Int(pasteMs)))\n", stderr)
                Telemetry.log("latency.pipeline", properties: [
                    "total_ms": Int(totalMs),
                    "parakeet_ms": Int(parakeetMs),
                    "formatter_ms": Int(formatterMs),
                    "polish_ms": polishMs,
                    "paste_ms": Int(pasteMs),
                    "polish_enabled": polishEnabledByUser,
                    "polish_skipped_short": skipPolish,
                    "input_chars": formatted.count,
                    "output_chars": finalText.count
                ])
            }

            // Record for the Recent Dictations submenu. We persist BOTH the
            // pre-polish formatted text and the final polished text so the
            // BigMenu's History view can show a before/after compare. When
            // polish was a no-op (disabled / unavailable / didn't change
            // anything) the storage helper drops `raw` to avoid duplication.
            // Count how many spoken voice-commands the formatter turned into
            // actual punctuation/formatting. Heuristic: count standalone-word
            // matches in the raw Parakeet text. Conservative — keeps it cheap
            // and predictable. Drives the "fixes made by voice" stats card.
            let commandCount = countVoiceCommands(in: rawText)
            // Diff the pre-polish formatted text against the polished output to
            // count real fix-events (spelling, capitalization, grammar, filler
            // removal). Zero when polish was a no-op / disabled / skipped.
            // Drives the BigMenu "fixes by voice" stat card.
            let fixCount: Int? = {
                let trimmedPol = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedRaw = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPol.isEmpty, !trimmedRaw.isEmpty,
                      trimmedPol.lowercased() != trimmedRaw.lowercased() else { return 0 }
                return RecentDictations.countFixes(raw: trimmedRaw, polished: trimmedPol)
            }()
            RecentDictations.add(raw: formatted, polished: finalText,
                                  pasteTargetBundleID: capturedTargetForTask,
                                  polishMs: polishChanged ? polishMs : nil,
                                  granite: graniteTranscript,
                                  moonshine: moonshineTranscript,
                                  parakeetRaw: rawText,
                                  suspects: suspectWords.isEmpty ? nil : suspectWords,
                                  durationSeconds: durationSeconds,
                                  voiceCommandCount: commandCount,
                                  cleanupLevelUsed: cleanupForTask,
                                  personalityStyleUsed: personalityForTask,
                                  polishFixCount: fixCount,
                                  polishEngine: PolishStatus.shared.lastEngine)
            // The database row (saved under this session's id when recording
            // stopped) keeps what was heard; add what was pasted beside it.
            if let rowID = claimed?.sessionId {
                do { try coordinator.storage.setFinalText(meetingId: rowID, text: finalText) }
                catch { vlog("[VOICE] finalText not stored: \(error.localizedDescription)") }
            }

            // Auto-learn proper nouns from the polished text. Looks at the
            // user's last 50 dictations and promotes capitalized terms that
            // appear ≥2 times into the proper-noun vocabulary — so the next
            // polish pass treats them as fixed brand/contact names instead
            // of "correcting" their spelling.
            let priorDictations = RecentDictations.all().prefix(50).map(\.text)
            ProperNounVocabulary.learnFrom(finalText, previousDictations: Array(priorDictations))
            Telemetry.log("dictation.completed", properties: [
                "chars": formatted.count,
                "duration_s": durationSeconds,
                "words": wordCount,
                "wpm": wpm
            ])
        }
    }

    private func showCancelledToast() {
        recordingState.cancelledTranscript = recordingState.currentTranscript
        recordingState.currentTranscript = []
        // Wispr's first three cancels get the full card (TranscriptCancelledDetailed, alert, 8 s)
        // with Undo and Open History; after that the condensed "Transcript cancelled".
        if let notice = FlowNoticeRules.cancelledDetailed() {
            cancelDismissTask?.cancel()
            SoundEffects.playNotice(.alert)
            recordingState.flowNotice = notice
            return
        }
        recordingState.showingCancelledToast = true
        recordingState.cancelToastShownAt = Date()

        cancelDismissTask?.cancel()
        cancelDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                // Only dismiss the UI, don't clear the transcript yet.
                // User may click Undo after timeout and it should still work.
                recordingState.showingCancelledToast = false
            }
        }
    }

    private func dismissCancelledToast() {
        cancelDismissTask?.cancel()
        recordingState.showingCancelledToast = false
        // Clear the transcript only when explicitly dismissed (Undo clicked or app action).
        recordingState.clearCancelledUndo()
    }

    // MARK: - Undo-paste toast

    private func showUndoPasteToast(finalText: String) {
        // User-controllable. The toast was firing after every single paste and
        // got annoying fast. Default OFF — power users can flip it on from
        // settings if they want the undo affordance. Cmd-Z works regardless.
        let showToast = UserDefaults.standard.object(forKey: "voice.showUndoPasteToast") as? Bool ?? false
        guard showToast else { return }
        guard !recordingState.isRecording, !recordingState.pendingRecordingStart else {
            print("[VOICE-PILL] suppressing undo toast — new recording in flight")
            return
        }
        recordingState.lastPastedText = finalText
        recordingState.showingUndoPasteToast = true
        recordingState.undoPasteToastShownAt = Date()
        undoPasteDismissTask?.cancel()
        undoPasteDismissTask = Task { @MainActor [weak self] in
            // Shorter — 3.5s instead of 7s. Long enough to register, not long
            // enough to feel like the app is begging for attention.
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissUndoPasteToast()
        }
    }

    func dismissUndoPasteToast() {
        undoPasteDismissTask?.cancel()
        undoPasteDismissTask = nil
        recordingState.showingUndoPasteToast = false
        recordingState.undoPasteToastShownAt = nil
        recordingState.lastPastedText = ""
    }

    func undoLastPaste() {
        guard !recordingState.lastPastedText.isEmpty else { return }
        if let id = lastDictationRunID { FlowRunLog.followup(id: id, kind: "dictation", followup: "undo-paste") }
        dismissUndoPasteToast()
        showToast("Use Undo in the original app")
    }

    /// Undo button on the cancelled toast — paste the discarded transcript.
    /// This works even if the UI toast has auto-dismissed, as long as the user
    /// hasn't recorded a new session.
    private func undoCancel() {
        let segmentText = recordingState.cancelledTranscript.map { $0.text }.joined(separator: " ")
        let heard = recordingState.cancelledText.isEmpty ? segmentText : recordingState.cancelledText
        let plan = CancelUndoPlan.make(text: heard, audioURL: recordingState.cancelledAudioURL)
        dismissCancelledToast()
        recordingState.flowNotice = nil

        switch plan {
        case .nothing:
            print("[VOICE] Undo → nothing kept from the cancelled dictation")
            showToast("Nothing to restore")
        case .pasteText(let text):
            pasteRestored(text)
        case .transcribeAudio(let url, let fallback):
            Task { @MainActor [weak self] in
                guard let self else { return }
                var waited = 0
                while !self.coordinator.transcription.isReady && waited < 20 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    waited += 1
                }
                var text = ""
                if self.coordinator.transcription.isReady,
                   let segments = try? await self.coordinator.transcription.transcribeFile(url: url) {
                    let prepared = DictationTextPreparation.prepare(segments: segments, formatter: self.textFormatter,
                                                                    pressEnterEnabled: false, autoPaste: false)
                    if prepared.rejection == nil {
                        let formatted = prepared.command.text
                        var finalText = formatted
                        let polishEnabled = UserDefaults.standard.object(forKey: "polishEnabled") as? Bool ?? true
                        if CleanupLevel.current != .none && polishEnabled {
                            finalText = await Qwen3Polisher.shared.polish(
                                formatted, suspectWords: nil,
                                userVocabulary: Array(Set(ProperNounVocabulary.current() + CombinedDictionary.terms())),
                                cleanupLevel: CleanupLevel.current.rawValue,
                                personalityStyle: PersonalityStyle.current.rawValue)
                        }
                        text = DictationTextPreparation.finalize(polished: finalText, formatted: formatted)
                    }
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = fallback }
                guard !text.isEmpty else { self.showToast("Nothing to restore"); return }
                self.pasteRestored(text)
            }
        }
    }

    private func pasteRestored(_ text: String) {
        cursorPaster.pasteFormatted(DictationFinalPass.apply(text), formatter: textFormatter)
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyService.delegate = self
        // Read by the event tap on the main run loop; gate is pure state, no side effects.
        hotkeyService.pasteLastTranscriptAvailable = { [weak self] in
            MainActor.assumeIsolated { self?.canPasteLastTranscript() ?? false }
        }
        hotkeyService.startMonitoring()
    }

    /// Control+Command+V gate: a remembered transcript exists and nothing is recording.
    private func canPasteLastTranscript() -> Bool {
        lastTranscript.shouldHandlePasteLast(isRecording: recordingState.isRecording)
    }

    /// The start cue plays once the microphone has delivered its first buffer, or after 250 ms at most, so it marks
    /// the moment audio is really recording (a cold engine start took about 100 ms on 22 Nov 2026).
    private func playStartCueWhenWarm() {
        Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .milliseconds(250)
            while let self, !self.coordinator.audioCapture.hasCapturedBuffer, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            SoundEffects.playStart()
        }
    }

    /// Control+Command+V: paste the last finished dictation again through the
    /// same CursorPaster path as normal dictation. The text is already final, so
    /// it is pasted verbatim (preFormatted) rather than re-adjusted for spacing.
    private func handlePasteLastTranscript() {
        guard canPasteLastTranscript(), let text = lastTranscript.text else { return }
        let recoveryID = beginPasteRecoveryWindow()
        let autoCopy = UserDefaults.standard.object(forKey: "autoCopy") as? Bool ?? true
        cursorPaster.pasteAtCursor(text, restoreClipboard: !autoCopy, preFormatted: true,
                                  onFailure: { [weak self] reason in
            self?.showPasteRecovery(text, id: recoveryID, secureField: reason == .secureField)
        })
    }

    // MARK: - Wake word

    /// Wire the "Hey Voice" listener. Off by default — user toggles it on
    /// from Settings, which sets `voice.wakeWordEnabled = true`. We observe
    /// that flag and start/stop the service accordingly.
    private func setupWakeWord() {
        guard !flowIsYielding else { return }
        // Stop word ("finito" by default): the hands-free counterpart to the
        // wake word. Fired from the live-partials stream when the user speaks
        // it at the trailing edge of a locked recording. Drives the exact
        // same commit path as a third-tap lock exit, so it inherits all the
        // session-claim / paste race safety for free.
        coordinator.onStopWordDetected = { [weak self] in
            guard let self else { return }
            guard self.recordingState.isLocked, self.recordingState.isRecording else { return }
            print("[VOICE-STOPWORD] committing locked recording via stop word")
            self.exitLockMode()
            self.finishRecording()
        }
        WakeWordService.shared.onWakeWordDetected = { [weak self] in
            guard let self else { return }
            // Same entry point a hotkey press uses, except we also want to
            // LOCK the recording so the user can keep talking without holding
            // anything — hands-free is the whole point of the wake phrase.
            print("[VOICE-WAKE] phrase detected → starting locked dictation")
            if !self.recordingState.isRecording && !self.recordingState.isLocked {
                self.hotkeyDidActivate()
                // Latch into locked mode after a tick so the recorder is fully up.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self else { return }
                    if self.recordingState.isRecording && !self.recordingState.isLocked {
                        self.enterLockMode()
                    }
                }
            }
        }
        // Mode-aware startup:
        //   • "off"             — never start; service inert.
        //   • "alwaysOn"        — legacy behavior. Mic indicator stays
        //                         on permanently while the listener runs.
        //   • "activatedWindow" — do not auto-start. Wait for a UI
        //                         surface to post
        //                         `.voiceActivateWakeWordWindow`. Then
        //                         the mic is hot only for the window.
        let mode = BackgroundActivityGate.wakeWordMode
        switch mode {
        case "alwaysOn":
            if BackgroundActivityGate.wakeWordEnabled {
                WakeWordService.shared.enable()
            } else {
                print("[VOICE-GATE] WakeWordService NOT enabled — gated OFF by privacyMode / enableWakeWord / wakeWordEnabled")
            }
        case "activatedWindow":
            print("[VOICE-WAKE] mode=activatedWindow — listener dormant until armed")
        default:
            print("[VOICE-WAKE] mode=off — wake word disabled")
        }

        // Wire the activation notification once, regardless of mode — if
        // the user flips into activatedWindow at runtime, the listener is
        // already attached to the notification stream.
        let activateToken = NotificationCenter.default.addObserver(
            forName: .voiceActivateWakeWordWindow,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                WakeWordService.shared.activateForWindow()
            }
        }
        notificationTokens.append(activateToken)

        // React to live toggles from Settings without requiring a restart.
        // Same gate applies — privacy mode forces disable regardless.
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let mode = BackgroundActivityGate.wakeWordMode
                switch mode {
                case "alwaysOn":
                    if BackgroundActivityGate.wakeWordEnabled {
                        WakeWordService.shared.enable()
                    } else {
                        WakeWordService.shared.disable()
                    }
                case "activatedWindow":
                    // Don't auto-start. Don't auto-disable either — that
                    // would cancel an active window the user just armed.
                    break
                default:
                    WakeWordService.shared.disable()
                }
            }
        }
        notificationTokens.append(token)
    }

    private static var wisprFlowRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.electron.wispr-flow")
            .contains { !$0.isTerminated }
    }

    // MARK: - Model readiness gate

    /// Speech recognition is required. Optional cleanup must never block a
    /// recording, including after its local model has been evicted while idle.
    private func checkModelsReadyOrToast() -> Bool {
        guard !Self.wisprFlowRunning else {
            showToast("Dictation waits while Wispr Flow is open.")
            return false
        }
        if Qwen3Polisher.isEnabled { Qwen3Polisher.shared.prewarm() }
        if coordinator.transcription.isReady { return true }
        let now = Date()
        if let last = lastModelReadyToastAt, now.timeIntervalSince(last) < 2 { return false }
        lastModelReadyToastAt = now
        recordingState.flowNotice = FlowPillNotice.speechNotReady(coordinator.transcription.modelState)
        return false
    }

}

// MARK: - HotkeyServiceDelegate
//
// HotkeyService dispatches delegate callbacks SYNCHRONOUSLY on the main
// actor. By the time the state machine's transition() returns, all
// side-effects we make here (flipping recordingState.isRecording,
// kicking off startRecording, etc.) are committed. Any next event the
// monitor processes sees the new world. This is the critical fix from
// prior attempts where async dispatch let keyUp run before keyDown's
// recording had actually started — `wasRecording` then read false and
// the press silently transcribed nothing.
//
// We use `hotkeyService.pressDownAt` (captured on the NSEvent thread at
// the exact keyDown instant) instead of recording our own Date() inside
// activate(). Dispatch latency never makes a real hold look short.

extension AppDelegate: HotkeyServiceDelegate {

    /// Called on a fresh keyDown OR a third-tap (lock-exit) keyDown. Must
    /// complete start-side work synchronously: when this returns, if a new
    /// recording is intended, recordingState.isRecording must already be true.
    func hotkeyDidActivate() {
        guard !flowIsYielding else { return }
        print("[VOICE-HK] >>> hotkeyDidActivate ENTER  thread=\(Thread.isMainThread ? "main" : "BG")  isRecording=\(recordingState.isRecording)  isLocked=\(recordingState.isLocked)  isTranscribing=\(recordingState.isTranscribing)")
        defer { print("[VOICE-HK] <<< hotkeyDidActivate EXIT  isRecording=\(recordingState.isRecording)  isLocked=\(recordingState.isLocked)") }
        // === Permission gates ===
        // Permissions are checked here AND throttled: we never show the
        // system prompt more than once per app launch (it pops a fresh
        // dialog every call), and we deep-link to the right Privacy pane on
        // the first miss so the user can resolve it without hunting.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micOk = micStatus == .authorized
        let axOk = AXIsProcessTrusted()
        // Dictation doesn't need Screen Recording — pass srOk=true so the gate
        // doesn't block hotkey use just because Screen Recording isn't granted.
        if !micOk || !axOk {
            print("[VOICE-HK] hotkeyDidActivate: permission gate FAILED micOk=\(micOk) axOk=\(axOk)")
            handleMissingPermissions(micOk: micOk, axOk: axOk, srOk: true, micStatus: micStatus)
            return
        }

        // === Polish gate ===
        // A polish owns the field until it finishes: dictation waits rather than sharing its state.
        if let notice = OperationAdmission.notice(for: OperationAdmission.forDictation(isPolishing: recordingState.isPolishingSelection)) {
            print("[VOICE-HK] refused: \(notice)")
            showToast(notice)
            return
        }

        // === Model readiness gate ===
        // Require speech recognition; cleanup can use its safe fallback while warming.
        guard checkModelsReadyOrToast() else { return }
        WakeWordService.shared.pauseWhileRecording()

        // === Path 1: third tap exits lock + transcribes ===
        // === Path 1: third tap exits lock + transcribes ===
        if recordingState.isLocked {
            print("[VOICE-HK] Path 1: Hotkey in lock → commit")
            exitLockMode()
            finishRecording()
            return
        }

        // [VOICE-TIMING] hotkey press received at the gate-passed boundary
        print("[VOICE-TIMING] hotkey press received at \(Date())")
        // Auxiliary model warmups are owned by RecordingCoordinator for every capture route.
        // === Path 2: re-press while transcribing — start fresh alongside ===
        // The prior finishRecording() task keeps running to completion: its
        // transcript will still polish and paste at the cursor via pasteChain.
        // We just need to start a NEW recording immediately so PTT stays
        // responsive. The prior pipeline already snapshotted its own target
        // app + field context inside its Task, so re-pointing those instance
        // vars below is safe. The prior task also locally captured its audio
        // URL (see RecordingCoordinator.stopRecording ~line 167) before any
        // await, so a new startRecording() can safely overwrite
        // currentAudioFileURL without corrupting the prior pipeline.
        if recordingState.isTranscribing {
            // BUGFIX: set pendingRecordingStart=true FIRST as a single mutation so SwiftUI
            // commits a render BEFORE any other work runs. Previously this was set true
            // and then immediately cleared after startRecording() returned, which meant
            // observers never saw the .recording phase originate from the pending flag.
            recordingState.pendingRecordingStart = true
            recordingState.pendingRecordingStartAt = Date()
            print("[VOICE-TIMING] pendingRecordingStart=true (Path 2) at \(Date())")
            print("[VOICE-HK] Path 2: Hotkey during transcribing → start NEW alongside in-flight prior (prior will still paste)")
            // Do NOT cancel pendingFinishTask. Do NOT clear isTranscribing or
            // currentTranscript — that prior task owns those until it returns.
            // isTranscribing will flip false in its `defer` block, and our
            // own finishRecording() will set it true again when the user
            // releases this new press. Brief overlap is fine — the pill UI
            // prioritizes isRecording over isTranscribing during overlap.
            if recordingState.showingCancelledToast { dismissCancelledToast() }
            recordingState.clearCancelledUndo()
            recordingStartedAt = hotkeyService.pressDownAt ?? Date()
            // Rotate the session ID — a fresh UUID identifies this brand-new
            // recording. Any prior finishRecording Task still in flight (from
            // the press that produced the current transcribing state) captured
            // the OLD sessionID at entry and will bail out the moment it
            // notices the mismatch, preventing it from clobbering this one.
            recordingState.recordingSessionID = UUID()
            // Clear the cancel flag for the fresh session.
            recordingState.sessionCancelled = false
            recordingState.cancelledSessionID = nil
            dismissUndoPasteToast()
            // Start recording — synchronously flips isRecording=true. pendingRecordingStart
            // will be cleared by finishRecording() when the user releases (not here);
            // the OR in pillPhase keeps the pill in .recording across that handover.
            coordinator.startRecording()
            print("[VOICE-TIMING] startRecording() returned (Path 2) at \(Date())")
            playStartCueWhenWarm()
            captureTargetApp()
            print("[VOICE-HK] Path 2: post-startRecording isRecording=\(recordingState.isRecording)")
            return
        }

        // === Path 3: normal fresh press ===
        // BUGFIX: set pendingRecordingStart=true FIRST (single mutation, before any other
        // work) so SwiftUI renders the .recording pill on the very next frame. Previously
        // this was set true and immediately cleared on the same sync block; observers
        // had no chance to render the pending state. Cleared by finishRecording() at
        // release time, with pillPhase's OR covering the handover via isRecording.
        recordingState.pendingRecordingStart = true
        recordingState.pendingRecordingStartAt = Date()
        print("[VOICE-TIMING] pendingRecordingStart=true (Path 3) at \(Date())")
        if recordingState.showingCancelledToast { dismissCancelledToast() }
        print("[VOICE-HK] Path 3: Hotkey down → start recording (fresh)")
        recordingStartedAt = hotkeyService.pressDownAt ?? Date()
        recordingState.clearCancelledUndo()
        // Rotate the session ID for the fresh recording (see Path 2 for rationale).
        recordingState.recordingSessionID = UUID()
        // Clear the cancel flag for the fresh session.
        recordingState.sessionCancelled = false
        recordingState.cancelledSessionID = nil
        dismissUndoPasteToast()
        // coordinator.startRecording() synchronously flips state.isRecording=true.
        coordinator.startRecording()
        print("[VOICE-TIMING] startRecording() returned (Path 3) at \(Date())")
        // Switch icon timer to 1Hz for the active-recording state, then update
        // the icon immediately so the waveform symbol appears without lag.
        scheduleMenuBarIconTimer()
        refreshMenuBarIcon()
        playStartCueWhenWarm()
        captureTargetApp()
        // Safety timer: if the audio engine never flips isRecording=true within 2s,
        // clear pendingRecordingStart so the pill doesn't latch in .recording forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.recordingState.pendingRecordingStart,
                  !self.recordingState.isRecording else { return }
            print("[VOICE-PILL] safety-clear: pendingRecordingStart stuck >2s without isRecording — force clearing")
            self.recordingState.pendingRecordingStart = false
            self.recordingState.pendingRecordingStartAt = nil
        }
        // coordinator.startRecording() synchronously flips state.isRecording = true.
        print("[VOICE-HK] Path 3: post-startRecording isRecording=\(recordingState.isRecording) (MUST be true)")
        if !recordingState.isRecording {
            print("[VOICE-HK] !!! CRITICAL: startRecording did NOT set isRecording=true. Next keyUp will fail.")
        }
    }

    /// Called ONLY when held duration was ≥ short-tap threshold (state
    /// machine gates this). No need for an additional duration check.
    /// Always commit.
    func hotkeyDidDeactivate() {
        // Unconditional clear FIRST — covers the case where the user releases
        // during audio-engine spin-up. If we wait for any other state check
        // and bail out, the pending flag stays true forever and the pill
        // latches in .recording (see 5.1 "stays on after release").
        recordingState.pendingRecordingStart = false
        recordingState.pendingRecordingStartAt = nil
        print("[VOICE-HK] >>> hotkeyDidDeactivate ENTER  thread=\(Thread.isMainThread ? "main" : "BG")  isRecording=\(recordingState.isRecording)  isLocked=\(recordingState.isLocked)  isTranscribing=\(recordingState.isTranscribing)")
        defer { print("[VOICE-HK] <<< hotkeyDidDeactivate EXIT") }
        // Resume wake-word listening 2 seconds after release so the user can
        // do back-to-back hotkey presses without the wake-word service
        // fighting for the mic. If they re-press inside 2s, pauseWhileRecording
        // pre-empts it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            if !self.recordingState.isRecording && !self.recordingState.isLocked {
                WakeWordService.shared.resume()
            }
        }
        // Defensive: state machine never fires this from .locked, but a
        // future change could regress and start firing it; finishing here
        // would commit a still-running locked recording. Keep the guard.
        if recordingState.isLocked {
            print("[VOICE-HK] hotkeyDidDeactivate: locked, bailing")
            return
        }
        print("[VOICE-HK] Hotkey released (hold >= threshold) → PTT commit, calling finishRecording")
        // Wispr's SuggestPOPO: a push-to-talk hold of a minute or more earns a hands-free tip
        // 3 s later, unless another dictation has started by then.
        if let started = recordingStartedAt, Date().timeIntervalSince(started) >= 60 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !self.recordingState.isRecording, !self.recordingState.isLocked,
                      !self.recordingState.pendingRecordingStart,
                      let tip = FlowNoticeRules.suggestHandsFree(shortcut: FlowShortcutName.dictation) else { return }
                SoundEffects.playNotice(.info)
                self.recordingState.flowNotice = tip
            }
        }
        print("[VOICE-TIMING] hotkey release received at \(Date())")
        finishRecording()
    }

    /// Double-tap window expired without a second tap. The recording that
    /// started on the first keyDown has been running this whole time —
    /// discard it silently.
    func hotkeyDidQuickRelease() {
        // Unconditional clear FIRST — same rationale as hotkeyDidDeactivate.
        // Any early-return path below would otherwise leave the pending flag
        // stuck true and the pill latched in .recording.
        recordingState.pendingRecordingStart = false
        recordingState.pendingRecordingStartAt = nil
        print("[VOICE-HK] >>> hotkeyDidQuickRelease ENTER  thread=\(Thread.isMainThread ? "main" : "BG")  isRecording=\(recordingState.isRecording)  isLocked=\(recordingState.isLocked)")
        defer { print("[VOICE-HK] <<< hotkeyDidQuickRelease EXIT") }
        if recordingState.isLocked {
            print("[VOICE-HK] hotkeyDidQuickRelease: locked, bailing")
            return
        }
        guard recordingState.isRecording else {
            print("[VOICE-HK] hotkeyDidQuickRelease: NOT recording, bailing (state desync?)")
            return
        }
        print("[VOICE-HK] Quick tap → discard, Wispr's Debounce card when eligible")
        if let notice = FlowNoticeRules.debounce(shortcut: FlowShortcutName.dictation) {
            SoundEffects.playNotice(.alert)
            recordingState.flowNotice = notice
        }
        recordingStartedAt = nil
        // (pendingRecordingStart was already cleared unconditionally at the
        // top of this handler — see the 5.1 fix.)
        // BUGFIX (Category 8): claim + explicitly delete the tiny audio file so
        // quick taps don't accumulate orphan .caf files on disk.
        let claimedForQuick = coordinator.claimRecordingSync()
        let urlToDeleteQuick = claimedForQuick?.audioURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.coordinator.stopRecording(claiming: claimedForQuick)
            if let url = urlToDeleteQuick {
                try? FileManager.default.removeItem(at: url)
            }
            self.recordingState.currentTranscript = []
        }
    }

    /// Second keyDown landed within the double-tap window — enter lock.
    /// The recording from the first tap is still running; lock mode picks it
    /// up seamlessly (no restart, no duplicate start sound).
    func hotkeyDidDoubleTap() {
        print("[VOICE-HK] >>> hotkeyDidDoubleTap ENTER  thread=\(Thread.isMainThread ? "main" : "BG")  isRecording=\(recordingState.isRecording)  isLocked=\(recordingState.isLocked)")
        defer { print("[VOICE-HK] <<< hotkeyDidDoubleTap EXIT  isLocked=\(recordingState.isLocked)") }
        if recordingState.isLocked {
            print("[VOICE-HK] hotkeyDidDoubleTap: already locked, bailing")
            return
        }
        guard recordingState.isRecording,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              AXIsProcessTrusted(), checkModelsReadyOrToast() else { return }
        if recordingState.showingCancelledToast { dismissCancelledToast() }
        print("[VOICE-HK] Double-tap → enter lock mode")
        enterLockMode()
    }
}

// MARK: - RecordingState

@Observable
class RecordingState {
    var flowNotice: FlowPillNotice?
    /// Microphone name shown above the pill for a moment when the input changed.
    var micHint: String?
    var flowWindowRequest: FlowWindowRequest?
    var isRecording = false
    var isPaused = false
    var isLocked = false                  // lock mode (X/✓ buttons or double-tap hotkey)
    /// Number of finish tasks currently in the transcribe/polish phase.
    /// isTranscribing is true when this is > 0.
    var transcribingCount: Int = 0 {
        didSet {
            if oldValue <= 0 && transcribingCount > 0 {
                dictationWorkStartedAt = Date()
            } else if transcribingCount <= 0 {
                dictationWorkStartedAt = nil
            }
        }
    }
    private(set) var dictationWorkStartedAt: Date?
    var isTranscribing: Bool { transcribingCount > 0 }
    /// Seconds of speech in the dictation now being processed: the pill's glow estimates from it.
    var lastRecordingSeconds: Double = 0
    /// Words in the selection an Opt+1 is polishing: the glow's time estimate when tokens are not reported.
    var polishWords: Int = 0
    var showingCancelledToast = false     // "Transcript cancelled" with Undo
    var cancelToastShownAt: Date?
    var cancelledTranscript: [TranscriptSegment] = []
    /// Best text heard before the cancel, and the kept audio: what Undo restores.
    var cancelledText = ""
    var cancelledAudioURL: URL?
    func clearCancelledUndo() { cancelledTranscript = []; cancelledText = ""; cancelledAudioURL = nil }
    /// Set true the moment cancel fires. Checked by finishRecording() before
    /// pasting — if true, the paste is skipped. Cleared when a new recording starts.
    var sessionCancelled = false
    /// The session ID that the in-flight cancel was meant for. Set alongside
    /// `sessionCancelled` so the cancel is SESSION-SCOPED: an ESC aimed at the
    /// current recording must not silently drop an UNRELATED background finish
    /// task that's still legitimately in flight. `nil` means "cancel applies to
    /// whatever session is current" (legacy/global semantics). Cleared when a
    /// new recording starts.
    var cancelledSessionID: UUID? = nil
    /// Session-scoped cancel check. True only when a cancel is active AND it
    /// targets `session` (or was a global cancel with no specific session).
    func isCancelled(for session: UUID) -> Bool {
        sessionCancelled && (cancelledSessionID == nil || cancelledSessionID == session)
    }
    var showingUndoPasteToast = false
    /// Set for five seconds after a polish changed the selection: the pill reads
    /// "Done. See changes" and a click shows what changed.
    var polishDiff: PolishDiff? = nil
    /// Wispr's `error` bar state: a red-edged bar for 500 ms after a dictation error.
    var showingErrorPill = false
    @ObservationIgnored private var errorPillTask: Task<Void, Never>?
    func flashErrorPill() {
        errorPillTask?.cancel()
        showingErrorPill = true
        errorPillTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.showingErrorPill = false
        }
    }
    var undoPasteToastShownAt: Date? = nil
    var lastPastedText: String = ""
    /// Average per-segment ASR confidence (0...1) from the most recent
    /// recording / live partial. Drives the pill's stroke color so the user
    /// gets a passive signal that the model is uncertain about what it heard.
    var transcriptionConfidence: Double = 1.0
    /// Set true by hotkeyDidActivate BEFORE startRecording() is called — lets the
    /// pill react on the very next frame (zero-latency visual feedback).
    /// Always paired with `pendingRecordingStartAt` so a safety timer in
    /// AppDelegate can detect a stuck flag (audio engine failed to start or
    /// user released during spin-up) and force-clear after >2s.
    var pendingRecordingStart: Bool = false {
        didSet {
            if pendingRecordingStart && !oldValue {
                pendingRecordingStartAt = Date()
            } else if !pendingRecordingStart {
                pendingRecordingStartAt = nil
            }
        }
    }
    /// Timestamp paired with `pendingRecordingStart`. Set automatically when
    /// `pendingRecordingStart` flips true; cleared when it flips false. The
    /// AppDelegate safety timer reads this to detect a stuck pending flag.
    var pendingRecordingStartAt: Date? = nil
    /// Identifies the currently-active recording session. Rotated to a fresh
    /// UUID every time a new recording begins (in hotkeyDidActivate just
    /// before `coordinator.startRecording()`). The `finishRecording` Task
    /// captures this at entry and bails if it changes mid-flight — preventing
    /// a stale finish from a previous session from clobbering a new recording
    /// (e.g., re-pressing the hotkey while the prior pipeline is still draining).
    var recordingSessionID: UUID = UUID()
    /// True while an Opt+1 "polish selected text" operation is in flight.
    var isPolishingSelection: Bool = false {
        didSet {
            guard oldValue != isPolishingSelection else { return }
            polishWorkStartedAt = isPolishingSelection ? Date() : nil
            polishWorkStage = .editing
            polishWorkEstimate = nil
        }
    }
    private(set) var polishWorkStartedAt: Date?
    var polishWorkStage: FlowWorkPresentation.PolishStage = .editing
    var polishWorkEstimate: FlowWorkPresentation.PolishEstimate?
    /// True while a meeting capture session is active (Google Meet / Zoom / Teams).
    var isCapturingMeeting: Bool = false
    var meetingCaptureStatus = "idle"
    var meetingCaptureProblem: String?
    /// The UUID of the current meeting capture session. Set when isCapturingMeeting
    /// flips true; cleared when it flips false.
    var activeMeetingId: UUID? = nil
    /// True when a known meeting app (Google Meet standalone, Zoom, Teams) is frontmost.
    /// Used to tint the idle pill and route a tap to startMeetingCapture() instead
    /// of starting a regular dictation.
    var isMeetingAppActive: Bool = false
    /// Live elapsed seconds of the active meeting capture session, mirrored from
    /// MeetingCaptureService.durationSeconds every 0.5s. Reset to 0 when capture stops.
    var meetingDurationSeconds: Int = 0
    /// Live transcript segments accumulated during the active meeting capture session.
    /// Mirrored from MeetingCaptureService.liveTranscript every 2s. Cleared when capture stops.
    var meetingLiveTranscript: [TranscriptSegment] = []
    var meetingLiveTranscriptStatus: String = ""
    var elapsedSeconds: Int = 0
    var currentTranscript: [TranscriptSegment] = []
    var audioLevels: [Float] = Array(repeating: 0, count: 32)
    /// Wispr-style 0..1 level for the pill bars (AudioCaptureService.barLevel).
    var barLevel: Float = 0
    /// Perceptual 0..1 input level. Drives the pill's always-on "I hear you"
    /// breathing so the user gets feedback even when speaking quietly.
    var inputLevel: Float = 0
    /// True after >2s of effectively-zero input during a recording. Surfaces
    /// a one-shot "no input detected" hint on the pill.
    var noInputDetected: Bool = false
    var modelState: ModelState = .notDownloaded

    // Statistics — last dictation
    var lastDictationWordCount: Int = 0
    var lastDictationDurationSeconds: Int = 0
    var lastDictationWPM: Int = 0  // words per minute

    // Statistics — today's session totals (in-memory, date-bucketed)
    // Resets to zero when the calendar day changes (checked on each record).
    var sessionDate: Date = Calendar.current.startOfDay(for: Date())
    var sessionDictationCount: Int = 0
    var sessionTotalWords: Int = 0
    var sessionTotalDurationSeconds: Int = 0
    var sessionAvgWPM: Int {
        guard sessionTotalDurationSeconds > 0 else { return 0 }
        return (sessionTotalWords * 60) / sessionTotalDurationSeconds
    }

    // Statistics — lifetime totals (persisted in UserDefaults)
    // Loaded once at init; incremented on every finishRecording.
    var lifetimeDictations: Int = UserDefaults.standard.integer(forKey: "voice.totalDictations")
    var lifetimeWords: Int = UserDefaults.standard.integer(forKey: "voice.totalWords")
    var lifetimeDurationSeconds: Int = UserDefaults.standard.integer(forKey: "voice.totalDurationSeconds")
    var lifetimeAvgWPM: Int {
        guard lifetimeDurationSeconds > 0 else { return 0 }
        return (lifetimeWords * 60) / lifetimeDurationSeconds
    }

    // Statistics — long-form "meeting" recordings (>= 30s).
    // Subset of the dictation counters above; tracked separately so the
    // Meetings tab can surface a clean view of long-form work.
    static let meetingMinDurationSeconds: Int = 30
    var sessionMeetingCount: Int = 0
    var sessionMeetingTotalDurationSeconds: Int = 0
    var lifetimeMeetingCount: Int = UserDefaults.standard.integer(forKey: "voice.totalMeetings")
    var lifetimeMeetingDurationSeconds: Int = UserDefaults.standard.integer(forKey: "voice.totalMeetingDurationSeconds")
    var lifetimeAvgMeetingDurationSeconds: Int {
        guard lifetimeMeetingCount > 0 else { return 0 }
        return lifetimeMeetingDurationSeconds / lifetimeMeetingCount
    }

    // Live partial transcript for lock-mode preview.
    // Populated by RecordingCoordinator.startLivePartials() during lock mode.
    // Cleared when the final transcript lands or recording is cancelled.
    // The UI shows confirmed text at full opacity; volatile text at 55% opacity.
    var livePartialText: String = ""
    var livePartialIsVolatile: Bool = true

    /// Set by RecordingCoordinator when the captured audio is short (16-36KB
    /// range). Consumed by finishRecording's polish stage to skip the LLM
    /// pass for one-word utterances like "ok"/"yeah"/"no" that polish tends
    /// to mangle. Auto-clears after consumption.
    var skipPolishForCurrent: Bool = false

    /// Raw transcript from IBM Granite 4.0 1B (second ASR model, runs in parallel
    /// with Parakeet v2). When non-nil, the polish stage calls Qwen3.merge()
    /// instead of Qwen3.polish() — giving the LLM both transcripts to pick the
    /// best reading from each. Nil when Granite is unavailable or timed out.
    /// Auto-clears after consumption.
    var graniteTranscript: String? = nil

    /// Raw transcript from Moonshine Tiny (third ASR model, runs in parallel
    /// with Parakeet v2 and Granite). Passed to Qwen3.merge() alongside the
    /// other transcripts when non-nil. Nil when Moonshine is unavailable or
    /// timed out. Auto-clears after consumption.
    var moonshineTranscript: String? = nil

    // Tick to nudge SwiftUI redraws when persisted recent-dictations list changes.
    var recentDictationsTick: Int = 0

    /// Completed meetings — populated by the meeting capture pipeline.
    var meetings: [Meeting] = []

    /// Tracks the lifecycle of the persisted-meetings fetch so the
    /// Meetings list can show a skeleton during the initial DB read and an
    /// error state with a Retry button if the read throws. Set by
    /// `AppDelegate.fetchMeetingsIntoState()` — the single funnel that all
    /// load/reload call sites now go through.
    var meetingsLoadState: MeetingsLoadState = .initial

    /// Bundle ID of the meeting app that triggered the current capture session.
    /// Set by OverlayPanel's poll when a meeting app is detected frontmost,
    /// then copied into MeetingCaptureService before startCapture() so it can
    /// be persisted on the saved Meeting record. Nil when no meeting is active.
    var meetingSourceBundleID: String? = nil

    /// Participant names scraped from the call platform's DOM by the Chrome
    /// extension (Google Meet, Discord, Teams, Slack huddles). Populated by
    /// `MeetBridgeServer.onMeetActive` and consumed by `generateMeetingTitle`
    /// when stopMeetingCapture() saves the Meeting. Empty when the extension
    /// isn't installed or couldn't scrape names — in that case the title
    /// generator falls back to the transcript-regex name extractor.
    var meetingParticipantNames: [String] = []

    /// The pill's phase for these flags (`PillPhaseResolver`, Views/Pill/PillStateMachine.swift).
    var pillPhase: PillPhase {
        PillPhaseResolver.phase(isRecording: isRecording, isLocked: isLocked, pendingStart: pendingRecordingStart,
                                isTranscribing: isTranscribing, isPolishingSelection: isPolishingSelection,
                                showingCancelled: showingCancelledToast, showingUndoPaste: showingUndoPasteToast,
                                showingPolishDone: polishDiff != nil)
    }

    /// Record one dictation: bump session counters (with day-rollover reset)
    /// AND lifetime UserDefaults counters. Called from finishRecording().
    func recordDictation(words: Int, durationSeconds: Int) {
        // Day rollover — if it's a new day, reset session totals first.
        let today = Calendar.current.startOfDay(for: Date())
        if today != sessionDate {
            sessionDate = today
            sessionDictationCount = 0
            sessionTotalWords = 0
            sessionTotalDurationSeconds = 0
        }
        sessionDictationCount += 1
        sessionTotalWords += words
        sessionTotalDurationSeconds += durationSeconds

        // Lifetime — persist and mirror in-memory.
        lifetimeDictations += 1
        lifetimeWords += words
        lifetimeDurationSeconds += durationSeconds
        UserDefaults.standard.set(lifetimeDictations, forKey: "voice.totalDictations")
        UserDefaults.standard.set(lifetimeWords, forKey: "voice.totalWords")
        UserDefaults.standard.set(lifetimeDurationSeconds, forKey: "voice.totalDurationSeconds")

        // Meeting counters are NOT bumped here. A long dictation is not a
        // meeting. Real meetings (captured via MeetingCaptureService through
        // the Chrome extension / meeting-app detection) flow through
        // recordMeeting(durationSeconds:) below, called from stopMeetingCapture.
        recentDictationsTick &+= 1
    }

    /// Record one ACTUAL meeting capture (system audio + mic from a Meet /
    /// Zoom / Discord / etc. session). Called from AppDelegate.stopMeetingCapture
    /// after the segments are saved. Bumps both session and lifetime counters.
    func recordMeeting(durationSeconds: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        if today != sessionDate {
            sessionDate = today
            sessionMeetingCount = 0
            sessionMeetingTotalDurationSeconds = 0
        }
        sessionMeetingCount += 1
        sessionMeetingTotalDurationSeconds += durationSeconds
        lifetimeMeetingCount += 1
        lifetimeMeetingDurationSeconds += durationSeconds
        UserDefaults.standard.set(lifetimeMeetingCount, forKey: "voice.totalMeetings")
        UserDefaults.standard.set(lifetimeMeetingDurationSeconds, forKey: "voice.totalMeetingDurationSeconds")
    }
}

// MARK: - MeetingActiveNotificationDelegate
//
// UN delegate proxy that owns the "Voice is recording your meeting" banner.
// Installed by AppDelegate the first time meeting capture starts. Everything
// it doesn't handle (transcript-ready taps, etc.) is forwarded to the
// existing `MeetingNotifier.delegate` so legacy routing keeps working.
//
// Intercepts:
//   • Tap on the "Stop Recording" action button (categoryIdentifier ==
//     kMeetingActiveCategory, actionIdentifier == kMeetingStopAction)
//   • Tap on the banner body when userInfo carries `voiceMeetingActiveBanner`
// Both paths post `.voiceStopMeetingRequested`, which the AppDelegate
// observer (see setupErrorObserver below) converts into stopMeetingCapture().
final class MeetingActiveNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MeetingActiveNotificationDelegate()
    /// Existing delegate to fall back to for unrelated notifications. Set by
    /// AppDelegate before installing this proxy.
    var fallback: UNUserNotificationCenterDelegate?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Always show banner + sound for our category. Delegate the rest.
        if notification.request.content.categoryIdentifier == AppDelegate.kMeetingActiveCategory {
            completionHandler([.banner, .sound])
            return
        }
        if let fallback = fallback {
            fallback.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
        } else {
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let isOurBanner = category == AppDelegate.kMeetingActiveCategory
            || (userInfo["voiceMeetingActiveBanner"] as? Bool) == true
        if isOurBanner {
            // Action button OR body tap → both stop the recording. The
            // default-action identifier is UNNotificationDefaultActionIdentifier.
            if action == AppDelegate.kMeetingStopAction
                || action == UNNotificationDefaultActionIdentifier {
                print("[VOICE-NOTIF] meeting-active banner action=\(action) — stopping capture")
                NotificationCenter.default.post(name: .voiceStopMeetingRequested, object: nil)
            }
            completionHandler()
            return
        }
        if let fallback = fallback {
            fallback.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }
}
