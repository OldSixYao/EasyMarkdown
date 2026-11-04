import Foundation
import EasyMarkdownCore

enum AppLanguage: String, CaseIterable {
    case system, simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant", english = "en"

    static let preferenceKey = "appLanguage"
    static let launchChoice = AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system

    var title: String {
        switch self {
        case .system: return L10n.text("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }

    /// Run before AppKit or any localized bundles initialize. Use a process-only
    /// override so the choice never changes macOS's global language preferences.
    static func configureAtLaunch() {
        let languages = launchChoice == .system
            ? UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? ["en"]
            : [launchChoice.rawValue]
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = languages
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    static func select(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: preferenceKey)
        // Keep this app's native AppKit language in sync on the next launch.
        // Removing the override restores the user's system/app language choice.
        if language == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([language.rawValue], forKey: "AppleLanguages") }
    }
}
