#if DEBUG
import AppKit
import EasyMarkdownCore

@MainActor enum EditorWorkspaceCheck {
    @MainActor private final class OpenPanelProbe: NSObject {
        var opened = false
        private var attempts = 0
        @objc func tick(_ timer: Timer) {
            attempts += 1
            if let panel = NSApp.modalWindow as? NSOpenPanel {
                opened = panel.allowsMultipleSelection
                timer.invalidate()
                panel.cancel(nil)
            } else if attempts > 100 {
                timer.invalidate()
                NSApp.abortModal()
            }
        }
    }
    static func run(output: URL) async {
        do {
            try await check(directory: output)
            try? FileManager.default.removeItem(at: output.appendingPathComponent("failure.txt"))
            try Data("passed".utf8).write(to: output.appendingPathComponent("result.txt"))
            print("PASS: 编辑行号、底部统计与原生文档标签检查")
            NSApp.terminate(nil)
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("failure.txt"))
            EditorPreferences.finishChecks()
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func check(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await EditorPositionCheck.check(directory: directory.appendingPathComponent("positions"))
        try await EditorStatisticsCheck.check(directory: directory.appendingPathComponent("statistics"))
        let preferences = EditorPreferences.store
        let originalLines = preferences.bool(forKey: EditorPreferences.showLineNumbers)
        let originalTabs = preferences.bool(forKey: EditorPreferences.documentTabsEnabled)
        let appearance = UserDefaults.standard.object(forKey: "appearance")
        let tabs = DocumentTabCoordinator.shared
        preferences.set(true, forKey: EditorPreferences.showLineNumbers)
        preferences.set(true, forKey: EditorPreferences.documentTabsEnabled)
        tabs.applyPreference()
        var documents: [MarkdownDocument] = []
        defer {
            for document in documents { document.close() }
            preferences.set(originalLines, forKey: EditorPreferences.showLineNumbers)
            preferences.set(originalTabs, forKey: EditorPreferences.documentTabsEnabled)
            tabs.applyPreference()
            if let appearance { UserDefaults.standard.set(appearance, forKey: "appearance") }
            else { UserDefaults.standard.removeObject(forKey: "appearance") }
        }
        let paragraph = String(repeating: "自动折行保留同一个逻辑行编号，中文与表情 📝。", count: 50)
        let sources = ["# 行号与标签\n\n\(paragraph)\n\n最后一行\n", "name: 文档\nvalue: 42\n", "# 第三份文档\n\n独立的编辑状态。\n"]
        for number in 0..<3 {
            let folder = directory.appendingPathComponent("document-\(number)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(number == 1 ? "example.yaml" : "example.md")
            try await DraftStore.shared.remove(url)
            try Data(sources[number].utf8).write(to: url)
            let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(sources[number].utf8)), url: url)
            documents.append(doc)
            if number != 1 { doc.session.mode = .edit }
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
        }
        let first = documents[0], second = documents[1], third = documents[2]
        NSApp.activate(ignoringOtherApps: true)
        third.showWindows()
        guard let window = first.windowControllers.first?.window, let root = window.contentView,
              let secondWindow = second.windowControllers.first?.window,
              let thirdWindow = third.windowControllers.first?.window else { throw failure("文档窗口未创建") }
        do {
            try await wait("原生文档标签合并") {
                window.tabGroup?.windows.count == 3 && window.tabGroup?.isTabBarVisible == true &&
                    NSDocumentController.shared.currentDocument === third
            }
        } catch {
            print("标签诊断：\([window, secondWindow, thirdWindow].map { "count=\($0.tabGroup?.windows.count ?? 0) visible=\($0.tabGroup?.isTabBarVisible ?? false) key=\($0.isKeyWindow)" }) currentThird=\(NSDocumentController.shared.currentDocument === third)")
            throw error
        }
        tabs.previousTab(nil)
        try await wait("上一标签") { NSDocumentController.shared.currentDocument === second }
        tabs.nextTab(nil)
        try await wait("下一标签") { NSDocumentController.shared.currentDocument === third }
        first.showWindows()
        try await wait("标签切换时的当前文档与预览活动状态") {
            NSDocumentController.shared.currentDocument === first && first.session.isWindowActive && !third.session.isWindowActive
        }
        let count = NSDocumentController.shared.documents.count
        (NSApp.delegate as? AppDelegate)?.open(second.fileURL!)
        try await wait("重复打开选中已有标签") {
            NSDocumentController.shared.currentDocument === second && NSDocumentController.shared.documents.count == count
        }
        first.showWindows()
        try await wait("源码行号") { editor(in: root)?.enclosingScrollView?.verticalRulerView is LineNumberRulerView }
        guard let text = editor(in: root), let scroll = text.enclosingScrollView,
              let ruler = scroll.verticalRulerView as? LineNumberRulerView,
              let coordinator = text.delegate as? SourceEditor.Coordinator else { throw failure("源码行号控件缺失") }
        window.setContentSize(NSSize(width: 720, height: 620))
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        do {
            try await wait("首行行号可见") { ruler.visibleLabels().first?.number == 1 }
        } catch {
            print("行号诊断：text=\(text.frame) visible=\(text.visibleRect) clip=\(scroll.contentView.bounds) ruler=\(ruler.frame) labels=\(ruler.visibleLabels().map(\.number)) length=\(text.string.utf16.count)")
            try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("line-number-failure.png"))
            throw error
        }
        let labels = ruler.visibleLabels()
        guard Set(labels.map(\.number)).count == labels.count,
              ruler.index.lineCount == 6,
              window.tab.toolTip == first.fileURL?.path else { throw failure("行号、折行或标签路径提示错误") }
        text.insertText("未保存的修改\n", replacementRange: NSRange(location: 0, length: 0))
        text.breakUndoCoalescing()
        try await wait("编辑内容进入文档会话") { first.isDocumentEdited }
        guard window.isDocumentEdited else {
            throw failure("原生未保存标记未更新：document=\(first.isDocumentEdited) window=\(window.isDocumentEdited) controller=\(window.windowController?.document === first)")
        }
        let changed = text.string
        first.undoManager?.undo()
        try await wait("撤销恢复正文与行号") { text.string == sources[0] && ruler.index.lineCount == 6 && !window.isDocumentEdited }
        first.undoManager?.redo()
        try await wait("重做更新行号") { text.string == changed && ruler.index.lineCount == 7 && window.isDocumentEdited }
        let selection = NSRange(location: 4, length: 2)
        text.setSelectedRange(selection)
        let revision = first.session.state.revision
        preferences.set(false, forKey: EditorPreferences.showLineNumbers)
        try await wait("即时关闭行号") { scroll.verticalRulerView == nil }
        guard editor(in: root) === text, text.string == changed, text.selectedRange() == selection,
              first.session.state.revision == revision, first.undoManager?.canUndo == true,
              ruler.clientView == nil else { throw failure("切换行号改变了编辑状态或未清理标尺") }
        preferences.set(true, forKey: EditorPreferences.showLineNumbers)
        try await wait("即时开启行号") { scroll.verticalRulerView is LineNumberRulerView }
        guard text.string == changed, text.selectedRange() == selection else { throw failure("开启行号丢失正文或选区") }
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: 80))
        scroll.reflectScrolledClipView(scroll.contentView)
        let anchor = coordinator.scrollPosition()
        preferences.set(false, forKey: EditorPreferences.showLineNumbers)
        try await wait("滚动后关闭行号") { scroll.verticalRulerView == nil }
        preferences.set(true, forKey: EditorPreferences.showLineNumbers)
        try await wait("滚动后开启行号") { scroll.verticalRulerView is LineNumberRulerView }
        if let anchor, let restored = coordinator.scrollPosition() {
            guard abs(anchor.offset - restored.offset) < 80 else { throw failure("行号开关丢失可见内容位置") }
        } else { throw failure("无法读取行号切换时的滚动锚点") }
        text.setMarkedText("组合", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let marked = text.markedRange()
        preferences.set(false, forKey: EditorPreferences.showLineNumbers)
        try await wait("输入法组合期间关闭行号") { scroll.verticalRulerView == nil }
        preferences.set(true, forKey: EditorPreferences.showLineNumbers)
        try await wait("输入法组合期间开启行号") { scroll.verticalRulerView is LineNumberRulerView }
        guard text.hasMarkedText(), text.markedRange() == marked else { throw failure("行号开关打断输入法组合") }
        text.unmarkText()
        first.session.mode = .split
        try await wait("分栏左侧行号") {
            views(root).compactMap { $0 as? LineNumberRulerView }.count == 1
        }
        first.session.mode = .edit
        second.showWindows()
        guard let secondRoot = secondWindow.contentView else { throw failure("原文阅读窗口缺失") }
        try await wait("原文阅读不显示行号") {
            editor(in: secondRoot)?.isEditable == false && views(secondRoot).allSatisfy { !($0 is LineNumberRulerView) }
        }
        second.session.mode = .split
        try await wait("原生分栏仅编辑侧显示行号") {
            views(secondRoot).compactMap { $0 as? LineNumberRulerView }.count == 1 &&
                views(secondRoot).compactMap { $0 as? NSTextView }.count == 2
        }
        first.showWindows()
        let sample = """
        # 文档编辑与标签管理

        多份文档放在标签栏中，点击即可切换。

        ## 编辑时显示行号

        - 按实际换行编号，自动折行不重复编号。
        - 支持查找、替换、撤销与保存。
        - 在设置中随时开启或关闭行号。

        ## 整理打开的文档

        拖动标签可以调整顺序，也可以移到独立窗口。
        关闭标签管理后，所有文档立即拆成独立窗口。

        ```swift
        let title = "EasyMarkdown"
        print(title)
        ```

        修改尚未保存时，关闭标签会先询问是否保存。

        """
        text.insertText(sample, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        text.breakUndoCoalescing()
        window.setContentSize(NSSize(width: 940, height: 760))
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        UserDefaults.standard.set("light", forKey: "appearance")
        try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("editor-tabs-light.png"))
        guard text.convert(text.textContainerOrigin, to: scroll).x > (scroll.verticalRulerView?.frame.maxX ?? 0) else {
            throw failure("行号栏遮挡了正文开头")
        }
        UserDefaults.standard.set("dark", forKey: "appearance")
        try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("editor-tabs-dark.png"))

        // A real close sheet must finish before the latest preference is applied.
        window.performClose(nil)
        try await wait("未保存文档的关闭确认") { window.attachedSheet != nil }
        preferences.set(false, forKey: EditorPreferences.documentTabsEnabled)
        tabs.applyPreference()
        guard tabs.isEnabled, window.tabGroup?.windows.count == 3 else { throw failure("保存对话框期间重组了窗口") }
        guard let sheet = window.attachedSheet, let sheetRoot = sheet.contentView,
              let cancel = views(sheetRoot).compactMap({ $0 as? NSButton }).first(where: { ["取消", "Cancel"].contains($0.title) }) else {
            throw failure("找不到关闭确认的取消按钮")
        }
        cancel.performClick(nil)
        try await wait("取消关闭后立即拆分文档") {
            !tabs.isEnabled && window.attachedSheet == nil && [window, secondWindow, thirdWindow].allSatisfy {
                ($0.tabGroup?.windows.count ?? 1) == 1 && $0.tabGroup?.isTabBarVisible != true && $0.tabbingMode == .disallowed
            }
        }
        guard first.isDocumentEdited, text.string == first.session.state.text, first.undoManager?.canUndo == true else {
            throw failure("拆分窗口丢失未保存修改或撤销记录")
        }
        let settingsItem = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title == L10n.text("设置…") }
        if let settingsItem, let action = settingsItem.action {
            NSApp.sendAction(action, to: settingsItem.target, from: settingsItem)
        }
        try await wait("设置窗口") { NSApp.keyWindow?.title == L10n.text("设置") }
        let settings = NSApp.keyWindow
        preferences.set(true, forKey: EditorPreferences.documentTabsEnabled)
        tabs.applyPreference()
        try await wait("设置窗口中即时合并文档") { window.tabGroup?.windows.count == 3 }
        guard window.tabGroup?.selectedWindow === window else { throw failure("合并时未保留原活动文档") }
        guard NSApp.keyWindow === settings, settings?.tabbingMode == .disallowed,
              first.isDocumentEdited, first.undoManager?.canUndo == true else { throw failure("合并窗口改变焦点或文档状态") }
        if let settings { try await ScreenshotCapture.capture(settings, to: directory.appendingPathComponent("settings.png")); settings.close() }
        first.showWindows()
        let beforeSave = text.string
        let destination = directory.appendingPathComponent("renamed.md")
        try await first.session.performSave(to: destination, operation: .saveAsOperation)
        try await wait("另存为更新标签") { window.tab.toolTip == destination.path && window.title.contains("renamed") }
        guard try String(contentsOf: destination, encoding: .utf8) == beforeSave, !first.isDocumentEdited else {
            throw failure("标签中的保存写入了错误文档")
        }
        tabs.moveTabToNewWindow(nil)
        try await wait("标签移到独立窗口") { (window.tabGroup?.windows.count ?? 1) == 1 && secondWindow.tabGroup?.windows.count == 2 }
        first.showWindows()
        guard (window.tabGroup?.windows.count ?? 1) == 1 else { throw failure("激活独立窗口时被重新合并") }
        let panelProbe = OpenPanelProbe()
        let panelTimer = Timer(timeInterval: 0.1, target: panelProbe, selector: #selector(OpenPanelProbe.tick(_:)),
            userInfo: nil, repeats: true)
        RunLoop.main.add(panelTimer, forMode: .modalPanel)
        window.newWindowForTab(nil)
        panelTimer.invalidate()
        guard panelProbe.opened, NSDocumentController.shared.documents.count == count else {
            throw failure("原生新标签入口未打开文件面板，或取消后改变了文档列表")
        }
        // Reordering is provided by the same native group API used by dragging.
        if let group = secondWindow.tabGroup {
            group.insertWindow(thirdWindow, at: 0)
            guard group.windows.first === thirdWindow else { throw failure("原生标签排序失败") }
        }
        // The active window remains first, preserving the other group's order.
        preferences.set(false, forKey: EditorPreferences.documentTabsEnabled)
        tabs.applyPreference()
        preferences.set(true, forKey: EditorPreferences.documentTabsEnabled)
        tabs.applyPreference()
        try await wait("重开标签管理合并独立窗口") { window.tabGroup?.windows.count == 3 }
        guard window.tabGroup?.windows == [window, thirdWindow, secondWindow] else { throw failure("标签合并未保留排序") }
        second.close()
        try await wait("关闭一个标签保留其余文档") { window.tabGroup?.windows.count == 2 }
        third.close()
        try await wait("最后一个标签自动隐藏标签栏") { window.tabGroup?.isTabBarVisible != true }
        try await localLayoutAndRelease(directory: directory)
        // Ensure the font/visibility updates kept the original coordinator alive.
        guard text.delegate === coordinator else { throw failure("行号更新重建了编辑器") }
    }

    private static func localLayoutAndRelease(directory: URL) async throws {
        let source = String(repeating: "局部排版与行号验证。\n", count: 80_000)
        let document = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)), url: directory.appendingPathComponent("large.txt"))
        defer { document.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.isVerticallyResizable = true
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        text.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        text.string = source
        scroll.documentView = text
        let coordinator = SourceEditor.Coordinator(session: document.session)
        coordinator.textView = text
        document.session.mode = .edit
        text.delegate = coordinator
        coordinator.observeStatistics()
        defer { coordinator.stopStatistics() }
        coordinator.updateLineNumbers(scroll, visible: true)
        weak var reference = scroll.verticalRulerView as? LineNumberRulerView
        guard reference?.visibleLabels().first?.number == 1,
              text.layoutManager!.firstUnlaidCharacterIndex() < text.textStorage!.length / 2 else {
            throw failure("行号首次显示强制排版了整份大文件")
        }
        text.textContainer?.containerSize.width = 460
        _ = reference?.visibleLabels()
        guard text.layoutManager!.firstUnlaidCharacterIndex() < text.textStorage!.length / 2 else {
            throw failure("缩放行号强制排版了整份大文件")
        }
        try await wait("大文件统计首次建立") { coordinator.statisticsIndex != nil }
        let unlaid = text.layoutManager!.firstUnlaidCharacterIndex()
        for _ in 0..<20 {
            // Exercise storage edits without NSTextView's insertText frame-size
            // adjustment, so this probe isolates layout requested by statistics.
            text.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "字")
        }
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
        // Keep the native caret in the viewport: moving it to the end itself
        // asks TextKit to lay out through that position, independently of stats.
        text.setSelectedRange(NSRange(location: 40, length: 20))
        try await wait("大文件连续编辑和选区统计") {
            document.session.editorStatistics.total.characterCount == 800_020 && document.session.editorStatistics.selection != nil
        }
        guard coordinator.statisticsIndex?.rebuildCount == 1,
              (coordinator.statisticsIndex?.lastScannedUTF16Count ?? .max) < 20_000,
              (coordinator.statisticsIndex?.lastSelectionScannedUTF16Count ?? .max) < 12_288,
              text.layoutManager!.firstUnlaidCharacterIndex() <= max(unlaid, 20_000) else {
            throw failure("大文件统计重复扫描全文或触发全文排版：rebuild=\(coordinator.statisticsIndex?.rebuildCount ?? -1) scan=\(coordinator.statisticsIndex?.lastScannedUTF16Count ?? -1) selection=\(coordinator.statisticsIndex?.lastSelectionScannedUTF16Count ?? -1) unlaid=\(unlaid)→\(text.layoutManager!.firstUnlaidCharacterIndex())")
        }
        text.string = ""
        guard reference?.visibleLabels().map(\.number) == [1] else { throw failure("空文档未显示第 1 行") }
        text.string = "正文\n"
        guard reference?.visibleLabels().map(\.number) == [1, 2] else { throw failure("末尾空行未显示行号") }
        text.string = String(repeating: "行\n", count: 98)
        reference?.refreshMetrics()
        let narrow = reference?.ruleThickness ?? 0
        text.string = String(repeating: "行\n", count: 1_000)
        reference?.refreshMetrics()
        guard (reference?.ruleThickness ?? 0) > narrow else { throw failure("行数增加后行号栏未扩宽") }
        let smallFontWidth = reference?.ruleThickness ?? 0
        text.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        reference?.refreshMetrics()
        guard (reference?.ruleThickness ?? 0) > smallFontWidth else { throw failure("行号字号未跟随编辑字号") }
        coordinator.updateLineNumbers(scroll, visible: false)
        try await wait("关闭行号后标尺释放") { reference == nil }
        reference = nil
    }

    private static func editor(in view: NSView) -> NSTextView? {
        views(view).compactMap { $0 as? NSTextView }.first { $0.delegate is SourceEditor.Coordinator }
    }

    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private static func failure(_ message: String) -> SmokeCheck.Failure { .init(message: message) }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw failure("等待超时：\(message)")
    }
}
#endif
