import AppKit
import Darwin
import Security

/// The legacy host cannot participate in flock. Refuse it at launch and yield
/// if it appears later. This reduces overlap; it cannot make legacy startup atomic.
@MainActor
final class FlowOwnership {
    static let shared = FlowOwnership()
    private var descriptor: Int32 = -1
    private var observer: NSObjectProtocol?
    private var yielding = false
    private let directory: URL
    private let applications: () -> [NSRunningApplication]
    /// Flow's real lock folder. The cloud polish eval (`--polish-eval`) may claim its own folder
    /// through FLOW_EVAL_SUPPORT_DIR, so it runs beside the app. Nothing else can change this.
    @MainActor static var defaultDirectory: URL {
        if CommandLine.arguments.contains("--polish-eval"),
           let path = ProcessInfo.processInfo.environment["FLOW_EVAL_SUPPORT_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Flow", isDirectory: true)
    }

    init(directory: URL? = nil,
         applications: @escaping () -> [NSRunningApplication] = { NSWorkspace.shared.runningApplications }) {
        self.directory = directory ?? Self.defaultDirectory
        self.applications = applications
    }
    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    static func verifiedClient(role: String?, staticValid: Bool, staticHash: Data?, liveHash: Data?) -> Bool {
        guard role == "client", staticValid, let staticHash, !staticHash.isEmpty,
              let liveHash, !liveHash.isEmpty else { return false }
        return staticHash == liveHash
    }

    private static func isVerifiedPureClient(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        var staticInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &staticInfo) == errSecSuccess,
              let info = staticInfo as? [String: Any],
              let plist = info[kSecCodeInfoPList as String] as? [String: Any],
              let staticHash = info[kSecCodeInfoUnique as String] as? Data else { return false }
        var liveCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: app.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &liveCode) == errSecSuccess,
              let liveCode else { return false }
        var liveInfo: CFDictionary?
        // Security's Swift declaration takes SecStaticCode, but the C API also
        // accepts its SecCode subtype to return information about the live guest.
        let liveAsStatic = unsafeBitCast(liveCode, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(liveAsStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &liveInfo) == errSecSuccess,
              let dynamic = liveInfo as? [String: Any] else { return false }
        return verifiedClient(role: plist["FlowBackendRole"] as? String, staticValid: true,
                              staticHash: staticHash, liveHash: dynamic[kSecCodeInfoUnique as String] as? Data)
    }

    static func conflicts(bundleID: String?, executable: String?, pid: pid_t, ownPID: pid_t, verifiedPureClient: Bool = false) -> Bool {
        guard pid != ownPID else { return false }
        let identity = (bundleID ?? "").lowercased()
        let name = (executable ?? "").lowercased()
        // Offscreen preview copies of Companion (scripts/preview-shots.sh, ui-shot.sh) never dictate: ignore them,
        // or every UI render quit the live Flow mid-meeting (21 Nov 2026).
        if identity.hasSuffix(".uipreview") || identity.contains("preview") { return false }
        if identity == "local.jordan.pcmonitor.sender", verifiedPureClient { return false }
        return identity == "local.jordan.pcmonitor.sender" || identity == "com.example.flow.voice" || identity.contains("pc-xdr")
            || identity == "com.example.flow.pc" || identity == "com.example.flow.pure"
            || ["pc", "pure", "voice", "voice preview"].contains(name)
    }

    private func competitor() -> NSRunningApplication? {
        applications().first {
            Self.conflicts(bundleID: $0.bundleIdentifier,
                executable: $0.executableURL?.lastPathComponent ?? $0.localizedName,
                pid: $0.processIdentifier, ownPID: getpid(),
                verifiedPureClient: $0.bundleIdentifier?.lowercased() == "local.jordan.pcmonitor.sender" && Self.isVerifiedPureClient($0))
        }
    }

    func acquire() -> String? {
        if descriptor >= 0 { return nil }
        if let app = competitor() { return "Close \(app.localizedName ?? "the other voice app") to use Flow." }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
                  (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o077) == 0 else {
                return "Flow's private folder needs checking."
            }
            let path = directory.appendingPathComponent("backend.lock").path
            let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return "Flow could not claim the microphone service." }
            guard fstat(fd, &info) == 0, info.st_uid == getuid(),
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                  (info.st_mode & 0o077) == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd); return "Another Flow session is already open."
            }
            descriptor = fd
            if let app = competitor() {
                close(fd); descriptor = -1
                return "Close \(app.localizedName ?? "the other voice app") to use Flow."
            }
            return nil
        } catch { return "Flow could not open its private folder." }
    }

    func observeCompetitors(onConflict: @escaping @MainActor () -> Void) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.yielding, self.competitor() != nil else { return }
                // An app that is still starting, or one being replaced by an update, can fail the
                // identity check for a moment. Look again before giving up the microphone: Flow
                // quitting because Companion was relaunched is worse than a three-second wait.
                try? await Task.sleep(for: .seconds(3))
                guard !self.yielding, let rival = self.competitor() else { return }
                Telemetry.log("ownership.yield", properties: [
                    "bundle": rival.bundleIdentifier ?? "",
                    "name": rival.executableURL?.lastPathComponent ?? rival.localizedName ?? ""
                ])
                self.yielding = true
                onConflict()
            }
        }
        // Close the gap between acquire and observer registration.
        if competitor() != nil, !yielding { yielding = true; onConflict() }
    }

    struct RetainedRecording {
        let id: UUID
        let audioURL: URL
        let date: Date
    }
    func retainedRecordings() -> [RetainedRecording] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])) ?? []
        return files.compactMap { file in
            guard file.lastPathComponent.hasPrefix("interrupted-"), file.pathExtension == "json",
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) < 8192,
                  let data = try? Data(contentsOf: file),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let path = record["audioPath"], path.hasPrefix("/"),
                  let id = UUID(uuidString: String(file.deletingPathExtension().lastPathComponent.dropFirst("interrupted-".count))),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return RetainedRecording(id: id, audioURL: URL(fileURLWithPath: path), date: values.contentModificationDate ?? Date())
        }
    }

    func retainRecoveryReference(_ url: URL?) {
        guard let url else { return }
        let file = directory.appendingPathComponent("interrupted-\(UUID().uuidString).json")
        let record = ["audioPath": url.path, "reason": "another voice app opened"]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}

@MainActor
private final class FlowBlockedDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let reason: String
    init(reason: String) { self.reason = reason }
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "cube", accessibilityDescription: "Flow")
        icon?.isTemplate = true
        statusItem?.button?.image = icon
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: reason, action: nil, keyEquivalent: ""))
        let retry = NSMenuItem(title: "Try again", action: #selector(retry), keyEquivalent: "")
        retry.target = self; menu.addItem(retry)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    @objc private func retry() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        do { try task.run(); NSApp.terminate(nil) } catch { NSSound.beep() }
    }
}

@MainActor
enum FlowBlockedApplication {
    static func run(reason: String) {
        let application = NSApplication.shared
        let delegate = FlowBlockedDelegate(reason: reason)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
