import Foundation

/// Category choices are resolved for the captured target, never by changing the global style mid-recording.
enum AppWritingCategory: String, CaseIterable, Identifiable {
    case personal, work, email, other
    var id: String { rawValue }
    // Email remains hidden until its cleanup behaviour is validated with T2.
    static let offered: [Self] = [.personal, .work, .other]
    var displayName: String { rawValue.capitalized }
    var defaultStyle: PersonalityStyle { self == .personal ? .veryCasual : .excited }
    var selectedStyle: String {
        let raw = UserDefaults.standard.string(forKey: "voice.categoryStyle.\(rawValue)")
        return raw.flatMap(PersonalityStyle.init(rawValue:))?.rawValue ?? defaultStyle.rawValue
    }
    func setStyle(_ style: PersonalityStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: "voice.categoryStyle.\(rawValue)")
    }
    static func category(for bundle: String?) -> Self {
        switch bundle?.lowercased() {
        case "com.apple.mobilesms", "com.facebook.messenger", "ru.keepcoder.telegram", "com.discord", "com.hnc.discord", "net.whatsapp.whatsapp": return .personal
        case "com.tinyspeck.slackmacos", "com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.microsoft.teams2": return .work
        case "com.apple.mail", "com.microsoft.outlook": return .email
        default: return .other
        }
    }
    static func style(for bundle: String?) -> String {
        let codeApps = ["com.apple.dt.xcode", "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable"]
        if codeApps.contains(bundle?.lowercased() ?? "") { return "" }
        let category = category(for: bundle)
        // Email uses Other until Email is offered.
        return (category == .email ? Self.other : category).selectedStyle
    }
    static func s1Styling(for style: String) -> S1MiniPolisher.Styling {
        switch style.lowercased() {
        case "formal": return .formal
        case "casual", "neutral": return .semiCasual
        case "verycasual": return .casual
        default: return .semiFormal
        }
    }
}
