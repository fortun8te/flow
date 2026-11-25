import AppKit

// Passive until an ownership protocol and safe shutdown are implemented.
final class FlowShell: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "cube", accessibilityDescription: "Flow")
        icon?.isTemplate = true
        status.button?.image = icon
        let menu = NSMenu()
        let state = NSMenuItem(title: "Flow is inactive", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let detail = NSMenuItem(title: "Backend ownership not yet available", action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu
        item = status
    }
}
let app = NSApplication.shared
let delegate = FlowShell()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
