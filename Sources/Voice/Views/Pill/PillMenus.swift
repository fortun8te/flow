import SwiftUI
import AppKit

// MARK: - Menus the pill opens (native menus at the pointer)

/// The wand's polish levels, in menu order.
enum IdleWandMenu {
    struct Item: Equatable {
        let level: String
        let label: String
    }

    static let items: [Item] = [
        Item(level: "light", label: "Spell"),
        Item(level: "medium", label: "Grammar"),
        Item(level: "heavy", label: "Rewrite")
    ]
}


/// "Select microphone": the inputs as a native menu at the pointer.
@MainActor
enum FlowMicrophoneMenu {
    private final class Target: NSObject {
        @objc func choose(_ sender: NSMenuItem) {
            let uid = sender.representedObject as? String ?? ""
            if uid.isEmpty { UserDefaults.standard.removeObject(forKey: MicrophonePreference.key) }
            else { UserDefaults.standard.set(uid, forKey: MicrophonePreference.key) }
        }
    }
    private static let target = Target()
    static func show() {
        let menu = NSMenu()
        let chosen = UserDefaults.standard.string(forKey: MicrophonePreference.key) ?? ""
        let auto = NSMenuItem(title: "Automatic", action: #selector(Target.choose(_:)), keyEquivalent: "")
        auto.target = target; auto.representedObject = ""; auto.state = chosen.isEmpty ? .on : .off
        menu.addItem(auto)
        for input in MicrophonePreference.inputs() {
            let item = NSMenuItem(title: input.name, action: #selector(Target.choose(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = input.uid; item.state = input.uid == chosen ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// The notes button's tab: upcoming calendar calls. Choosing one starts notes; without a
/// calendar it offers Settings.
@MainActor
enum FlowUpcomingMeetingsMenu {
    private final class Target: NSObject {
        @objc func start(_ sender: NSMenuItem) {
            NotificationCenter.default.post(name: .voiceStartMeetingManual, object: nil)
        }
        @objc func settings(_ sender: NSMenuItem) {
            NotificationCenter.default.post(name: Notification.Name("flow.openSettings"), object: nil)
        }
    }
    private static let target = Target()

    static func show() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Upcoming meetings", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let calendar = MeetingCalendarService.shared
        calendar.refresh()
        if !calendar.enabled {
            let connect = NSMenuItem(title: "Connect calendar…", action: #selector(Target.settings(_:)), keyEquivalent: "")
            connect.target = target
            menu.addItem(connect)
        } else if calendar.upcoming.isEmpty {
            let none = NSMenuItem(title: "No upcoming meetings", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let time = DateFormatter()
            time.doesRelativeDateFormatting = true
            time.dateStyle = .short
            time.timeStyle = .short
            for call in calendar.upcoming.prefix(6) {
                let item = NSMenuItem(title: "\(call.title)  ·  \(time.string(from: call.start))",
                                      action: #selector(Target.start(_:)), keyEquivalent: "")
                item.target = target
                menu.addItem(item)
            }
        }
        PillMenuState.whileOpen { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }
}

/// The wand's levels as a native menu at the pointer.
@MainActor
enum FlowPolishMenu {
    private final class Target: NSObject {
        let pick: (String) -> Void
        init(pick: @escaping (String) -> Void) { self.pick = pick }
        @objc func choose(_ sender: NSMenuItem) {
            if let level = sender.representedObject as? String { pick(level) }
        }
    }
    private static var live: Target?

    static func show(current: String, pick: @escaping (String) -> Void) {
        let target = Target(pick: pick)
        live = target
        let menu = NSMenu()
        for item in IdleWandMenu.items {
            let entry = NSMenuItem(title: item.label, action: #selector(Target.choose(_:)), keyEquivalent: "")
            entry.target = target
            entry.representedObject = item.level
            entry.state = item.level == current ? .on : .off
            menu.addItem(entry)
        }
        PillMenuState.whileOpen { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }
}

/// While a menu from the bar is open, the bar stays open and its tooltips stay hidden.
@MainActor
enum PillMenuState {
    static func whileOpen(_ run: () -> Void) {
        NotificationCenter.default.post(name: Notification.Name("flow.pillMenu"), object: nil, userInfo: ["open": true])
        run()
        NotificationCenter.default.post(name: Notification.Name("flow.pillMenu"), object: nil, userInfo: ["open": false])
    }
}
