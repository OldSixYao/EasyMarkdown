import Foundation

/// App strings live in the main .app bundle. The Chinese key is also the
/// fallback for command-line/core-only builds without application resources.
public enum L10n {
    // Keep the current process in one language even after the user chooses the
    // next launch's language in Settings. AppKit also resolves its language once.
    private static let bundle: Bundle = {
        guard let language = Bundle.main.preferredLocalizations.first,
              let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }()

    public static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }
}
