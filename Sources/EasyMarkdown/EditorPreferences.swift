import Foundation

@MainActor enum EditorPreferences {
    static let showLineNumbers = "showLineNumbers"
    static let documentTabsEnabled = "documentTabsEnabled"

    // Real-window checks use a disposable domain for these preferences.
    private static let checkSuite: String? = {
        #if DEBUG
        let checks = ["--smoke-test", "--language-test", "--configuration-test", "--lightweight-test", "--editor-workspace-test", "--external-change-test"]
        if CommandLine.arguments.contains(where: checks.contains) {
            return "app.easymarkdown.editor-check.\(UUID().uuidString)"
        }
        #endif
        return nil
    }()
    static let store = checkSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard

    static func registerDefaults() {
        store.register(defaults: [showLineNumbers: true, documentTabsEnabled: true])
        #if DEBUG
        // Existing checks intentionally exercise several independent windows.
        if checkSuite != nil && !CommandLine.arguments.contains("--editor-workspace-test") {
            store.set(false, forKey: documentTabsEnabled)
        }
        #endif
    }

    static func finishChecks() {
        if let checkSuite { store.removePersistentDomain(forName: checkSuite) }
    }
}
