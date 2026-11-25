import Foundation

/// The name of the user's dictation shortcut, for tooltips such as "Dictate fn".
enum FlowShortcutName {
    static var dictation: String {
        let names = HotkeyRole.pushToTalk.loadBindings().filter { !$0.isEmpty }.map(\.displayName)
        return names.first ?? "fn"
    }
}
