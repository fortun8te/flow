import AppKit
import SwiftUI

struct PermissionsView: View {
    var onDone: () -> Void

    @State private var service = PermissionsService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Voice permissions")
                        .font(.system(size: 22, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(service.allGranted
                         ? "Your microphone and text controls are ready."
                         : "Allow your microphone for dictation and Accessibility to insert or edit text.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    permissionRow(.microphone)
                    Divider().padding(.leading, 46)
                    permissionRow(.accessibility)
                    Divider().padding(.leading, 46)
                    permissionRow(.inputMonitoring)
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))

                if service.accessibility != .granted || service.inputMonitoring != .granted {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Can’t find Voice in System Settings?")
                            .font(.subheadline.weight(.medium))
                        Text("Drag the app into the permission list to add it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Show app to drag") {
                            let kind: PermissionsService.Kind =
                                service.accessibility == .granted ? .inputMonitoring : .accessibility
                            PermissionDragHelper.show(for: kind)
                            service.openSettings(for: kind)
                        }
                        .buttonStyle(PermissionButtonStyle())
                    }
                }

                HStack {
                    Button("Keyboard settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                    .help("If the Globe key opens an Apple shortcut, set “Press Globe key to” to “Do Nothing”.")
                    Spacer()
                    Button("Check again") { service.refresh() }
                }
                .buttonStyle(PermissionButtonStyle())
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { service.startMonitoring() }
        .onDisappear {
            service.stopMonitoring()
            PermissionDragHelper.dismiss()
        }
        .onChange(of: service.allGranted) { _, granted in
            if granted { onDone() }
        }
    }

    private func permissionRow(_ kind: PermissionsService.Kind) -> some View {
        let status = service.status(for: kind)
        return HStack(spacing: 12) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(kind.displayName).font(.system(size: 13, weight: .medium))
                Text(kind.requirementCopy)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)

            if status == .granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Button(kind == .microphone && status == .notDetermined ? "Allow" : "Open Settings") {
                    if kind == .microphone, status == .notDetermined {
                        Task { await service.requestMicrophone() }
                    } else {
                        if kind == .accessibility, status == .notDetermined {
                            service.requestAccessibility()
                        }
                        service.openSettings(for: kind)
                    }
                }
                .buttonStyle(PermissionButtonStyle(prominent: kind.isRequired))
                .accessibilityLabel("\(kind.displayName) settings")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
    }
}

private struct PermissionButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.18 : (prominent ? 0.11 : 0.055)),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
    }
}

@MainActor
private enum PermissionDragHelper {
    private static var panel: NSPanel?

    static func show(for permission: PermissionsService.Kind) {
        dismiss()
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 82),
                             styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        window.title = "Add Voice to \(permission.displayName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PermissionDragHelperContent(permission: permission))
        window.center()
        panel = window
        window.orderFrontRegardless()
    }

    static func dismiss() {
        panel?.close()
        panel = nil
    }
}

private struct PermissionDragHelperContent: View {
    let permission: PermissionsService.Kind

    var body: some View {
        let appURL = Bundle.main.bundleURL
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .frame(width: 30, height: 30)
            Text("Drag into the \(permission.displayName) list")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .draggable(appURL)
    }
}
