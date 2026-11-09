#if DEBUG
import AppKit
import WebKit
import EasyMarkdownCore

/// Each invocation starts a new application process so AppKit loads the language
/// naturally. Language selection persistence is exercised in a disposable suite.
@MainActor enum LanguageCheck {
    private final class CloseDecision: NSObject {
        var result: Bool?
        @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
            result = shouldClose
        }
    }

    static func run(output: URL) async {
        var document: MarkdownDocument?
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let expected = ProcessInfo.processInfo.environment["EASYMARKDOWN_EXPECTED_LANGUAGE"] ?? AppLanguage.launchChoice.rawValue
            guard Bundle.main.preferredLocalizations.first == expected else {
                throw SmokeCheck.Failure(message: "Expected \(expected), bundle selected \(Bundle.main.preferredLocalizations)")
            }
            let sample = expected == "en" ? "Settings" : expected == "zh-Hant" ? "設定" : "设置"
            guard L10n.text("设置") == sample else { throw SmokeCheck.Failure(message: "Application strings do not match native language") }
            let lineNumbers = expected == "en" ? "Show line numbers" : expected == "zh-Hant" ? "顯示行號" : "显示行号"
            let documentTabs = expected == "en" ? "Enable document tabs" : expected == "zh-Hant" ? "啟用文件標籤管理" : "启用文档标签管理"
            guard L10n.text("显示行号") == lineNumbers, L10n.text("启用文档标签管理") == documentTabs,
                  NSApp.mainMenu?.items.contains(where: { item in
                      item.submenu?.items.contains(where: { $0.title == L10n.text("下一标签") }) == true
                  }) == true else { throw SmokeCheck.Failure(message: "行号设置或标签菜单未本地化") }
            let updateTitle = expected == "en" ? "Check for Updates…" : expected == "zh-Hant" ? "檢查更新…" : "检查更新…"
            guard let application = NSApp.delegate as? AppDelegate,
                  let updateItem = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title == updateTitle }),
                  updateItem.target === application.updates,
                  L10n.text("软件更新") == (expected == "en" ? "Software Update" : expected == "zh-Hant" ? "軟體更新" : "软件更新") else {
                throw SmokeCheck.Failure(message: "Update menu localization or shared updater target failed")
            }
            guard AppLanguage.allCases.map(\.rawValue) == ["system", "zh-Hans", "zh-Hant", "en"] else {
                throw SmokeCheck.Failure(message: "Wrong language choices")
            }
            let suiteName = "app.easymarkdown.language-check.\(UUID().uuidString)"
            guard let suite = UserDefaults(suiteName: suiteName) else { throw CocoaError(.fileReadUnknown) }
            defer { suite.removePersistentDomain(forName: suiteName) }
            suite.set(19, forKey: "readerFontSize")
            for language in AppLanguage.allCases {
                AppLanguage.select(language, defaults: suite)
                guard suite.persistentDomain(forName: suiteName)?[AppLanguage.preferenceKey] as? String == language.rawValue,
                      suite.integer(forKey: "readerFontSize") == 19 else { throw SmokeCheck.Failure(message: "Language preference persistence failed") }
                if language == .system {
                    guard suite.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil else { throw SmokeCheck.Failure(message: "Follow System kept a language override") }
                } else {
                    guard suite.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String] == [language.rawValue] else { throw SmokeCheck.Failure(message: "Native language override not stored") }
                }
            }
            AppLanguage.select(.system, defaults: suite)
            guard suite.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil else { throw SmokeCheck.Failure(message: "Reset to Follow System failed") }

            guard let settingsItem = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title == L10n.text("设置…") }),
                  let action = settingsItem.action, NSApp.sendAction(action, to: settingsItem.target, from: settingsItem) else {
                throw SmokeCheck.Failure(message: "Localized settings menu missing")
            }
            try await wait("settings window") { NSApp.windows.contains { $0.title == sample } }
            guard let settings = NSApp.windows.first(where: { $0.title == sample }) else { throw SmokeCheck.Failure(message: "Settings window missing") }
            try await ScreenshotCapture.capture(settings, to: output.appendingPathComponent("settings.png"))
            settings.close()

            let file = output.appendingPathComponent("Language Sample.md")
            let source = "# Language Sample\n\nOriginal document 文档 文件\n\n`let value = 42`\n\n```swift\nprint(value)\n```\n"
            try await DraftStore.shared.remove(file)
            try Data(source.utf8).write(to: file)
            let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)), url: file)
            document = doc
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers(); doc.showWindows()
            guard let window = doc.windowControllers.first?.window, let root = window.contentView else { throw SmokeCheck.Failure(message: "No language sample window") }
            var web: WKWebView?
            try await wait("localized preview") {
                web = descendants(root).compactMap { $0 as? WKWebView }.first
                guard let web else { return false }
                return (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "Language Sample"
            }
            guard let web else { throw SmokeCheck.Failure(message: "No preview") }
            let copyTitle = try await web.evaluateJavaScript("document.querySelector('.code-copy-button')?.title") as? String
            guard copyTitle == L10n.text("复制代码"), doc.session.state.text == source else { throw SmokeCheck.Failure(message: "Preview UI localization changed content or missed copy labels") }
            doc.session.showSearch(); doc.session.search = "value"
            try await wait("localized search count") { doc.session.searchResultCount == 2 }
            try await ScreenshotCapture.capture(window, to: output.appendingPathComponent("reader-search.png"))
            if AppLanguage.launchChoice != .system {
                window.setContentSize(NSSize(width: 620, height: 520))
                try await ScreenshotCapture.capture(window, to: output.appendingPathComponent("reader-search-narrow.png"))
            }
            doc.session.showReplace()
            var editor: NSTextView?
            try await wait("localized native replace") {
                editor = descendants(root).compactMap { $0 as? NSTextView }.first { $0.delegate is SourceEditor.Coordinator }
                return editor?.enclosingScrollView?.isFindBarVisible == true
            }
            guard let editor, let bar = editor.enclosingScrollView?.findBarView else { throw SmokeCheck.Failure(message: "Replace bar missing") }
            let nativeTitles = descendants(bar).compactMap { $0 as? NSButton }.map(\.title)
            let replaceTitle = expected == "en" ? "Replace" : expected == "zh-Hant" ? "取代" : "替换"
            guard nativeTitles.contains(replaceTitle), nativeTitles.contains(expected == "en" ? "Done" : "完成") else {
                throw SmokeCheck.Failure(message: "Native replace is not \(expected): \(nativeTitles)")
            }
            let fields = descendants(bar).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            guard fields.contains(where: { $0.stringValue == "value" }) else { throw SmokeCheck.Failure(message: "Query lost entering localized replace") }
            try await ScreenshotCapture.capture(window, to: output.appendingPathComponent("native-replace.png"))
            if AppLanguage.launchChoice != .system {
                doc.session.requestEditorFind(.hideFindInterface)
                try await ScreenshotCapture.capture(window, to: output.appendingPathComponent("editor-narrow.png"))
                doc.session.mode = .split
                try await ScreenshotCapture.capture(window, to: output.appendingPathComponent("split-narrow.png"))
                doc.session.edit(source + "\nUnsaved modification\n")
                doc.session.saveFailure = "Layout check"
                try await ScreenshotCapture.capture(window, to: output.appendingPathComponent("save-failure-narrow.png"))
                doc.session.saveFailure = nil
                doc.session.isSaving = true
                try await ScreenshotCapture.capture(window, to: output.appendingPathComponent("saving-narrow.png"))
                doc.session.isSaving = false
                doc.session.mode = .read
                doc.session.edit(source + "\nUnsaved modification\n")
                try Data("# Changed elsewhere\n".utf8).write(to: file, options: .atomic)
                try await wait("external conflict banner") { doc.session.state.external != nil }
                try await ScreenshotCapture.capture(window, to: output.appendingPathComponent("conflict-narrow.png"))
                try Data(source.utf8).write(to: file, options: .atomic)
                await doc.session.reload(force: true)?.value
                doc.session.state = DocumentState(snapshot: try FileSnapshot(data: Data(source.utf8)))
                doc.session.recovery = RecoveryDraft(baseline: Data(source.utf8), text: source + "draft", savedAt: Date())
                try await ScreenshotCapture.capture(window, to: output.appendingPathComponent("recovery-narrow.png"))
                doc.session.recovery = nil
            }
            doc.session.edit(source + "\nUnsaved modification\n")
            let decision = CloseDecision()
            doc.canClose(withDelegate: decision, shouldClose: #selector(CloseDecision.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            try await wait("localized unsaved changes prompt") { window.attachedSheet != nil }
            guard let sheet = window.attachedSheet?.contentView else { throw SmokeCheck.Failure(message: "No save prompt") }
            let buttons = descendants(sheet).compactMap { $0 as? NSButton }
            let cancel = expected == "en" ? "Cancel" : "取消"
            let saves = expected == "en" ? ["Save"] : expected == "zh-Hant" ? ["儲存"] : ["保存", "存储"]
            guard buttons.contains(where: { saves.contains($0.title) }), let cancelButton = buttons.first(where: { $0.title == cancel }) else {
                throw SmokeCheck.Failure(message: "Unsaved changes prompt is not \(expected): \(buttons.map(\.title))")
            }
            try await ScreenshotCapture.capture(window, to: output.appendingPathComponent("save-confirmation.png"))
            cancelButton.performClick(nil)
            try await wait("cancel preserves edited document") { decision.result == false && window.attachedSheet == nil }
            guard doc.isDocumentEdited, try String(contentsOf: file, encoding: .utf8) == source else {
                throw SmokeCheck.Failure(message: "Language change/save cancel lost edits")
            }
            doc.updateChangeCount(.changeCleared); doc.close(); document = nil
            let report: [String: Any] = ["status":"passed", "choice":AppLanguage.launchChoice.rawValue,
                "resolved":expected, "nativeReplace":nativeTitles, "saveButtons":buttons.map(\.title),
                "checks":["settings", "preference persistence/reset", "menu and app strings", "preview copy labels", "search count", "native replace", "native save cancel preserves edits"]]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
            print("PASS: application and native UI in \(expected) (choice: \(AppLanguage.launchChoice.rawValue))")
            NSApp.terminate(nil)
        } catch {
            document?.updateChangeCount(.changeCleared); document?.close()
            print("FAIL: language check: \(error)")
            exit(1)
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func wait(_ description: String, condition: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SmokeCheck.Failure(message: "Timed out waiting for \(description)")
    }
}
#endif
