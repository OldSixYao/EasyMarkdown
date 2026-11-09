import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EasyMarkdownCore

@main
struct EasyMarkdownMain {
    @MainActor static func main() {
        EditorPreferences.registerDefaults()
        AppLanguage.configureAtLaunch()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var welcome: NSWindowController?
    private var settings: NSWindowController?
    private var opening: Set<URL> = []
    private let store = FileStore()
    private var recentMenu: NSMenu!
    let updates = UpdateController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        buildMenu()
        DocumentTabCoordinator.shared.start()
        NSDocumentController.shared.autosavingDelay = 0
        if let path = ProcessInfo.processInfo.environment["EASYMARKDOWN_MEMORY_CHECK"] {
            Task {
                if ProcessInfo.processInfo.environment["EASYMARKDOWN_MEMORY_PROFILE"] == "deep" {
                    await DeepPerformanceCheck.run(directory: URL(fileURLWithPath: path))
                } else {
                    await MemoryCheck.run(directory: URL(fileURLWithPath: path))
                }
            }
            return
        }
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--editor-workspace-test"),
           CommandLine.arguments.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await EditorWorkspaceCheck.run(output: output) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--lightweight-test"),
           CommandLine.arguments.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                do {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try await LightweightCheck.run(directory: output)
                    try Data("passed".utf8).write(to: output.appendingPathComponent("result.txt"))
                    print("PASS: lightweight checks")
                    NSApp.terminate(nil)
                } catch { print("FAIL: \(error)"); exit(1) }
            }
            return
        }
        if Bundle.main.object(forInfoDictionaryKey: "EasyMarkdownUpdateFixture") as? Bool == true,
           let path = Bundle.main.object(forInfoDictionaryKey: "EasyMarkdownUpdateReportPath") as? String {
            Task { await UpdateCheck.run(output: URL(fileURLWithPath: path)) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--update-test"),
           CommandLine.arguments.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await UpdateCheck.run(output: output) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--configuration-test"),
           CommandLine.arguments.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await ConfigurationCheck.run(output: output) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--language-test"),
           CommandLine.arguments.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await LanguageCheck.run(output: output) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--screenshots"),
           CommandLine.arguments.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await ScreenshotCapture.run(output: output) }
            return
        }
        if CommandLine.arguments.contains("--smoke-test") {
            Task { await SmokeCheck.run() }
            return
        }
        #endif
        updates.start()
        if NSDocumentController.shared.documents.isEmpty && opening.isEmpty { showWelcome(nil) }
        for argument in CommandLine.arguments.dropFirst() where !argument.hasPrefix("-") {
            open(URL(fileURLWithPath: argument))
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard NSDocumentController.shared.documents.contains(where: { $0.isDocumentEdited }) else { return .terminateNow }
        NSDocumentController.shared.closeAllDocuments(withDelegate: self,
            didCloseAllSelector: #selector(documentsClosed(_:didCloseAll:contextInfo:)), contextInfo: nil)
        return .terminateLater
    }

    @objc private func documentsClosed(_ controller: NSDocumentController, didCloseAll: Bool,
                                      contextInfo: UnsafeMutableRawPointer?) {
        NSApp.reply(toApplicationShouldTerminate: didCloseAll)
    }

    func open(_ input: URL) {
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL else { return }
        if let document = NSDocumentController.shared.documents.first(where: { $0.fileURL == url }) {
            document.showWindows(); return
        }
        guard opening.insert(url).inserted else { return }
        Task {
            defer { opening.remove(url) }
            do {
                let snapshot = try await store.read(url)
                let document = MarkdownDocument(snapshot: snapshot, url: url)
                NSDocumentController.shared.addDocument(document)
                document.makeWindowControllers()
                document.showWindows()
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                welcome?.close()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc func openPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.text, .sourceCode] + DefaultEditorFormat.allCases.map(\.contentType)
        panel.showsHiddenFiles = true
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }

    @objc func showWelcome(_ sender: Any?) {
        if let welcome { welcome.showWindow(nil); return }
        let size = NSSize(width: 720, height: 560)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "EasyMarkdown"
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingController(rootView: WelcomeView())
        // Let the window own its size; SwiftUI's compressed fitting size is too narrow.
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: 640, height: 520)
        window.setContentSize(size)
        window.center()
        welcome = NSWindowController(window: window)
        welcome?.showWindow(nil)
    }

    @objc private func showSettings(_ sender: Any?) {
        if let settings { settings.showWindow(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("设置")
        window.tabbingMode = .disallowed
        let hosting = NSHostingController(rootView: SettingsView(updates: updates))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 560, height: 650))
        window.center()
        settings = NSWindowController(window: window)
        settings?.showWindow(nil)
    }

    @objc func showAbout(_ sender: Any?) { AboutPanel.show() }

    private var currentSession: DocumentSession? {
        (NSDocumentController.shared.currentDocument as? MarkdownDocument)?.session
    }

    @objc private func find(_ sender: Any?) {
        currentSession?.showSearch()
    }

    @objc private func findNext(_ sender: Any?) { currentSession?.navigateSearch() }
    @objc private func findPrevious(_ sender: Any?) { currentSession?.navigateSearch(backwards: true) }
    @objc private func findAndReplace(_ sender: Any?) { currentSession?.showReplace() }
    @objc private func toggleEditing(_ sender: Any?) {
        guard let session = currentSession else { return }
        if session.mode == .read { session.mode = .edit }
        else { session.save(finishing: true) }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs.prefix(12) {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = url; item.toolTip = url.path
        }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: L10n.text("清除菜单"), action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = NSDocumentController.shared
    }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item); return menu
        }
        @discardableResult
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                  _ target: AnyObject? = nil, shift: Bool = false) -> NSMenuItem {
            let value = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            value.target = target
            if shift { value.keyEquivalentModifierMask = [.command, .shift] }
            return value
        }
        let app = submenu("EasyMarkdown")
        item(app, L10n.text("关于 EasyMarkdown"), #selector(showAbout(_:)), "", self)
        item(app, L10n.text("检查更新…"), #selector(UpdateController.checkForUpdates(_:)), "", updates)
        app.addItem(.separator())
        item(app, L10n.text("设置…"), #selector(showSettings(_:)), ",", self)
        app.addItem(.separator())
        item(app, L10n.text("隐藏 EasyMarkdown"), #selector(NSApplication.hide(_:)), "h", NSApp)
        app.addItem(.separator())
        item(app, L10n.text("退出 EasyMarkdown"), #selector(NSApplication.terminate(_:)), "q", NSApp)

        let file = submenu(L10n.text("文件"))
        item(file, L10n.text("打开…"), #selector(openPanel(_:)), "o", self)
        item(file, L10n.text("新建标签…"), #selector(DocumentTabCoordinator.newTab(_:)), "", DocumentTabCoordinator.shared)
        let recent = NSMenuItem(title: L10n.text("最近使用"), action: nil, keyEquivalent: "")
        recentMenu = NSMenu(title: L10n.text("最近使用")); recentMenu.delegate = self; recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        item(file, L10n.text("保存"), #selector(NSDocument.save(_:)), "s")
        item(file, L10n.text("另存为…"), #selector(NSDocument.saveAs(_:)), "s", shift: true)
        item(file, L10n.text("关闭"), #selector(NSWindow.performClose(_:)), "w")
        file.addItem(.separator())
        item(file, L10n.text("打开起始窗口"), #selector(showWelcome(_:)), "n", self)

        let edit = submenu(L10n.text("编辑"))
        item(edit, L10n.text("撤销"), NSSelectorFromString("undo:"), "z")
        item(edit, L10n.text("重做"), NSSelectorFromString("redo:"), "z", shift: true)
        edit.addItem(.separator())
        item(edit, L10n.text("剪切"), #selector(NSText.cut(_:)), "x")
        item(edit, L10n.text("复制"), #selector(NSText.copy(_:)), "c")
        item(edit, L10n.text("粘贴"), #selector(NSText.paste(_:)), "v")
        item(edit, L10n.text("全选"), #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, L10n.text("查找…"), #selector(find(_:)), "f", self)
        item(edit, L10n.text("查找下一个"), #selector(findNext(_:)), "g", self)
        item(edit, L10n.text("查找上一个"), #selector(findPrevious(_:)), "g", self, shift: true)
        let replace = item(edit, L10n.text("查找并替换…"), #selector(findAndReplace(_:)), "f", self)
        replace.keyEquivalentModifierMask = [.command, .option]
        item(edit, L10n.text("编辑 / 完成"), #selector(toggleEditing(_:)), "e", self)

        let window = submenu(L10n.text("窗口"))
        item(window, L10n.text("最小化"), #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, L10n.text("缩放"), #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        let previous = item(window, L10n.text("上一标签"), #selector(DocumentTabCoordinator.previousTab(_:)), "\t", DocumentTabCoordinator.shared)
        previous.keyEquivalentModifierMask = [.control, .shift]
        let next = item(window, L10n.text("下一标签"), #selector(DocumentTabCoordinator.nextTab(_:)), "\t", DocumentTabCoordinator.shared)
        next.keyEquivalentModifierMask = [.control]
        item(window, L10n.text("将标签移到独立窗口"), #selector(DocumentTabCoordinator.moveTabToNewWindow(_:)), "", DocumentTabCoordinator.shared)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}

private struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.secondary)
            Text("EasyMarkdown").font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(L10n.text("安静阅读，随手修改。")).foregroundStyle(.secondary)
            Button(L10n.text("打开文档…")) { (NSApp.delegate as? AppDelegate)?.openPanel(nil) }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 8)
            Text(L10n.text("也可以拖入 Markdown、文本或 YAML、TOML 等配置文件"))
                .font(.caption).foregroundStyle(.tertiary)
            if !NSDocumentController.shared.recentDocumentURLs.isEmpty {
                Divider().padding(.horizontal, 70).padding(.top, 8)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(NSDocumentController.shared.recentDocumentURLs.prefix(4)), id: \.self) { url in
                        Button { (NSApp.delegate as? AppDelegate)?.open(url) } label: {
                            Label(url.lastPathComponent, systemImage: "doc").lineLimit(1)
                        }.buttonStyle(.link)
                    }
                }.frame(maxWidth: 320, alignment: .leading)
            }
        }.padding(32)
            .frame(minWidth: 640, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in (NSApp.delegate as? AppDelegate)?.open(url) }
                    }
                }
                return !providers.isEmpty
            }
    }
}

private typealias SettingsState<Value> = State<Value>

private struct SettingsView: View {
    @ObservedObject var updates: UpdateController
    @SettingsState private var defaultEditor = DefaultEditorSettings()
    @AppStorage(AppLanguage.preferenceKey) private var language = "system"
    @AppStorage("readerFontSize") var fontSize = 16.0
    @AppStorage("editorFontSize") var editorSize = 14.0
    @AppStorage("readerWidth") var width = 780.0
    @AppStorage("remoteImages") var remoteImages = false
    @AppStorage("appearance") var appearance = "system"
    @AppStorage(EditorPreferences.showLineNumbers, store: EditorPreferences.store) private var showLineNumbers = true
    @AppStorage(EditorPreferences.documentTabsEnabled, store: EditorPreferences.store) private var documentTabsEnabled = true

    var body: some View {
        Form {
            SoftwareUpdateSection(updates: updates)
            Picker(L10n.text("应用语言"), selection: Binding(
                get: { AppLanguage(rawValue: language)?.rawValue ?? "system" },
                set: { value in AppLanguage.select(AppLanguage(rawValue: value) ?? .system) }
            )) {
                ForEach(AppLanguage.allCases, id: \.rawValue) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .accessibilityIdentifier("app-language")
            Text(L10n.text("语言更改将在下次启动时生效。请先保存文档，再退出并重新打开应用。"))
                .font(.caption).foregroundStyle(.secondary)
            if language != AppLanguage.launchChoice.rawValue {
                Text(L10n.text("语言已更改，重新启动应用后生效。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("language-restart-notice")
            }
            Picker(L10n.text("外观"), selection: $appearance) {
                Text(L10n.text("跟随系统")).tag("system"); Text(L10n.text("浅色")).tag("light"); Text(L10n.text("深色")).tag("dark")
            }
            Stepper(L10n.format("阅读字号：%d", Int(fontSize)), value: $fontSize, in: 12...26)
            Stepper(L10n.format("编辑字号：%d", Int(editorSize)), value: $editorSize, in: 11...24)
            Toggle(L10n.text("显示行号"), isOn: $showLineNumbers)
                .accessibilityIdentifier("show-line-numbers")
            Toggle(L10n.text("启用文档标签管理"), isOn: $documentTabsEnabled)
                .accessibilityIdentifier("document-tabs-enabled")
                .onChange(of: documentTabsEnabled) { _, _ in DocumentTabCoordinator.shared.applyPreference() }
            Picker(L10n.text("阅读宽度"), selection: $width) {
                Text(L10n.text("紧凑")).tag(660.0); Text(L10n.text("适中")).tag(780.0); Text(L10n.text("宽松")).tag(980.0)
            }
            Toggle(L10n.text("加载文档中的远程图片"), isOn: $remoteImages)
            Text(L10n.text("默认仅加载本地图片。开启后，会向图片所在的网站发送请求。"))
                .font(.caption).foregroundStyle(.secondary)
            DefaultEditorSection(settings: defaultEditor)
        }.formStyle(.grouped).frame(width: 560, height: 650)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                defaultEditor.refresh()
            }
            .onAppear { defaultEditor.refresh() }
    }
}
