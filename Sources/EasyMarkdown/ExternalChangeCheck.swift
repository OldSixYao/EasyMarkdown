#if DEBUG
import AppKit
import WebKit
import EasyMarkdownCore

@MainActor enum ExternalChangeCheck {
    static func wait(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        for document in NSDocumentController.shared.documents.compactMap({ $0 as? MarkdownDocument }) {
            let window = document.windowControllers.first?.window
            print("等待诊断：\(document.displayName ?? "未命名")，应用活跃=\(NSApp.isActive)，焦点=\(window?.isKeyWindow == true)，可见=\(window?.isVisible == true)，附属窗口=\(String(describing: window?.attachedSheet?.identifier))，待确认=\(document.session.state.needsExternalConfirmation)，外部版本=\(document.session.state.external != nil)，读取=\(document.session.isLoadingExternal)，状态=\(document.session.status)，错误=\(String(describing: document.session.errorMessage))")
        }
        throw SmokeCheck.Failure(message: "等待失败：" + description)
    }

    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    static func prompt(for document: MarkdownDocument) -> NSWindow? {
        guard let sheet = document.windowControllers.first?.window?.attachedSheet,
              sheet.identifier?.rawValue == "externalChangeConfirmation" else { return nil }
        return sheet
    }

    static func respond(_ document: MarkdownDocument, accept: Bool) async throws {
        try await waitForPrompt(document)
        guard let sheet = prompt(for: document), let root = sheet.contentView,
              let button = views(root).compactMap({ $0 as? NSButton }).first(where: {
                  $0.title == L10n.text(accept ? "确定" : "否")
              }) else { throw SmokeCheck.Failure(message: "确认框按钮缺失") }
        button.performClick(nil)
        try await wait("确认框结束") { document.windowControllers.first?.window?.attachedSheet !== sheet }
    }

    static func waitForPrompt(_ document: MarkdownDocument) async throws {
        try await wait("前台文档的外部修改确认框") {
            if prompt(for: document) != nil { return true }
            if !NSApp.isActive || document.windowControllers.first?.window?.isKeyWindow != true {
                document.showWindows()
                NSApp.activate(ignoringOtherApps: true)
            }
            return false
        }
    }

    /// 旧回归也必须实际经过窗口确认，先验证等待期间正文和保存基线不变。
    static func confirm(_ document: MarkdownDocument) async throws {
        let text = document.session.state.text, baseline = document.session.state.baseline.data
        document.showWindows()
        NSApp.activate(ignoringOtherApps: true)
        try await wait("检测外部版本") { document.session.state.external != nil }
        try require(document.session.state.text == text && document.session.state.baseline.data == baseline,
                    "确认前正文或保存基线发生变化")
        try await respond(document, accept: true)
        try await wait("载入最新内容") { !document.session.isLoadingExternal && document.session.state.external == nil }
    }

    static func run(directory: URL) async throws {
        let output = directory.appendingPathComponent("external-confirmation", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for mode in [ViewMode.read, .edit, .split] { try await preservation(mode: mode, directory: output) }
        try await markdownPreservation(directory: output)
        try await deferredWindows(directory: output)
        try await readFailures(directory: output)
        try await staleLoads(directory: output)
        try await recoveryWithExternalVersion(directory: output)
    }

    private static func open(_ url: URL, text: String) throws -> MarkdownDocument {
        try Data(text.utf8).write(to: url, options: .atomic)
        let document = MarkdownDocument(snapshot: try FileSnapshot(data: Data(text.utf8)), url: url)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        NSApp.activate(ignoringOtherApps: true)
        return document
    }

    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw SmokeCheck.Failure(message: message) }
    }

    private static func preservation(mode: ViewMode, directory: URL) async throws {
        let source = (1...180).map { "第\($0)行，保留文字与位置 📝\n" }.joined()
        let url = directory.appendingPathComponent("preserve-\(mode.rawValue).txt")
        let document = try open(url, text: source)
        defer { document.close() }
        document.session.mode = mode
        document.session.synchronizeSplitScroll = false
        let window = document.windowControllers.first!.window!, root = window.contentView!
        var editor: NSTextView?
        try await wait("原生文本视图") {
            editor = views(root).compactMap { $0 as? NSTextView }.first { $0.delegate is SourceEditor.Coordinator }
            return editor != nil && (mode == .read || document.session.replaceText != nil)
        }
        guard let editor else { throw SmokeCheck.Failure(message: "没有编辑器") }
        if mode != .read { document.session.replaceText?(source + "本地未保存内容\n") }
        let local = document.session.state.text
        let selected = (local as NSString).range(of: "第90行")
        editor.setSelectedRange(selected); editor.scrollRangeToVisible(selected)
        try await Task.sleep(for: .milliseconds(150))
        let position = editor.enclosingScrollView!.contentView.bounds.origin
        let revision = document.session.state.revision
        let canUndo = editor.undoManager?.canUndo == true
        let external = source + "外部第一次修改\n"
        try Data(external.utf8).write(to: url, options: .atomic)
        try await waitForPrompt(document)
        try require(document.session.state.text == local && editor.string == local &&
            document.session.state.revision == revision && editor.selectedRange() == selected,
                    "等待确认时正文、选区或修订变化")
        try require(abs(editor.enclosingScrollView!.contentView.bounds.minY - position.y) < 2,
                    "等待确认时阅读位置变化")
        let labels = views(prompt(for: document)!.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
        try require(labels.contains(L10n.text("更新将放弃当前尚未保存的修改。")) == (mode != .read),
                    "未保存修改警告与文档状态不符")
        try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("confirmation-\(mode.rawValue).png"))
        try await respond(document, accept: false)
        try require(document.session.state.text == local && document.session.state.baseline.text == source &&
            document.session.state.isDirty == (mode != .read) && document.session.mode == mode &&
            editor.selectedRange() == selected && (editor.undoManager?.canUndo == true) == canUndo,
                    "拒绝更新没有保留内容、编辑状态、选区或撤销")
        try require(abs(editor.enclosingScrollView!.contentView.bounds.minY - position.y) < 2,
                    "拒绝更新后阅读位置变化")
        try require(try String(contentsOf: url, encoding: .utf8) == external, "拒绝更新回写了磁盘")
        if canUndo {
            editor.undoManager?.undo()
            try require(document.session.state.text == source, "拒绝更新破坏了撤销内容")
            editor.undoManager?.redo()
            try require(document.session.state.text == local, "拒绝更新破坏了重做内容")
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: url.path)
        await document.session.reload(force: true)?.value
        await document.session.reload(force: true)?.value
        try await Task.sleep(for: .milliseconds(200))
        try require(prompt(for: document) == nil && !document.session.state.needsExternalConfirmation,
                    "同一内容或元数据变动重复询问")

        // 手动加载复用同一框；退出键与“否”采用相同的原生按钮动作。
        document.session.acceptExternal()
        try await waitForPrompt(document)
        let sheet = prompt(for: document)!
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        sheet.sendEvent(escape)
        try await wait("退出键保留内容") { prompt(for: document) == nil }
        try require(document.session.state.text == local, "退出键丢失内容")

        try Data((source + "外部第二次修改\n").utf8).write(to: url, options: .atomic)
        try await waitForPrompt(document)
        // 故意不等待监听器读取第三版；确认必须重新读盘。
        let latest = source + "点击确定时的最新内容\n"
        try Data(latest.utf8).write(to: url, options: .atomic)
        try await respond(document, accept: true)
        try await wait("最新内容与统计") {
            document.session.state.text == latest && editor.string == latest &&
                document.session.editorStatistics.total == DocumentStatisticsIndex(latest as NSString).total
        }
        try require(!document.session.state.isDirty && !document.session.state.hasConflict &&
            document.session.state.baseline.text == latest && editor.undoManager?.canUndo != true,
                    "接受外部版本后基线、撤销或保存状态错误")
        try await wait("过期草稿已移除") { !document.session.isLoadingExternal }
        try await Task.sleep(for: .milliseconds(100))
        let draft = try await DraftStore.shared.load(url)
        try require(draft == nil, "接受外部内容后仍保留过期草稿")
        if mode != .read {
            let identical = latest + "与磁盘相同的本地输入\n"
            document.session.replaceText?(identical)
            try require(editor.undoManager?.canUndo == true, "相同内容检查没有原生撤销历史")
            let revision = document.session.state.revision
            try Data(identical.utf8).write(to: url, options: .atomic)
            try await waitForPrompt(document)
            try require(document.session.state.isDirty && document.session.state.baseline.text == latest,
                        "外部内容相同时未经确认清除了本地未保存状态")
            try await respond(document, accept: true)
            try await wait("相同内容经确认后更新基线") { !document.session.state.isDirty }
            try require(editor.undoManager?.canUndo != true && document.session.state.revision == revision &&
                document.session.state.baseline.text == identical, "相同内容确认后未清理撤销或基线错误")
        }
    }

    private final class CloseDecision: NSObject {
        var result: Bool?
        @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
            result = shouldClose
        }
    }

    private static func deferredWindows(directory: URL) async throws {
        let preferences = EditorPreferences.store
        let oldTabs = preferences.bool(forKey: EditorPreferences.documentTabsEnabled)
        preferences.set(true, forKey: EditorPreferences.documentTabsEnabled)
        DocumentTabCoordinator.shared.applyPreference()
        defer {
            preferences.set(oldTabs, forKey: EditorPreferences.documentTabsEnabled)
            DocumentTabCoordinator.shared.applyPreference()
        }
        let first = try open(directory.appendingPathComponent("background.txt"), text: "第一份")
        let second = try open(directory.appendingPathComponent("foreground.txt"), text: "第二份")
        defer { first.close(); second.close() }
        try await wait("两份文档使用原生标签") { second.windowControllers.first?.window?.tabGroup?.windows.count == 2 }
        try Data("后台外部修改".utf8).write(to: first.fileURL!, options: .atomic)
        await first.session.reload(force: true)?.value
        try await Task.sleep(for: .milliseconds(150))
        try require(prompt(for: first) == nil && first.session.state.text == "第一份", "后台文档抢占确认")
        try Data("前台外部修改".utf8).write(to: second.fileURL!, options: .atomic)
        try await respond(second, accept: false)
        first.showWindows()
        try await respond(first, accept: false)

        let window = first.windowControllers.first!.window!
        window.miniaturize(nil)
        try Data("最小化期间修改".utf8).write(to: first.fileURL!, options: .atomic)
        await first.session.reload(force: true)?.value
        try await Task.sleep(for: .milliseconds(150))
        try require(prompt(for: first) == nil, "最小化文档弹出了确认")
        first.showWindows()
        try await respond(first, accept: false)

        NSApp.hide(nil)
        try await wait("应用进入后台") { !NSApp.isActive }
        try Data("应用后台期间修改".utf8).write(to: first.fileURL!, options: .atomic)
        await first.session.reload(force: true)?.value
        try await Task.sleep(for: .milliseconds(150))
        try require(prompt(for: first) == nil, "后台应用弹出了确认")
        NSApp.unhide(nil); first.showWindows(); NSApp.activate(ignoringOtherApps: true)
        try await respond(first, accept: false)

        first.session.showExternal = true
        try await wait("查看外部版本窗口") { window.attachedSheet != nil }
        try Data("查看期间的更新".utf8).write(to: first.fileURL!, options: .atomic)
        await first.session.reload(force: true)?.value
        try require(prompt(for: first) == nil, "确认框覆盖了外部预览")
        first.session.showExternal = false
        try await respond(first, accept: false)

        let panel = NSSavePanel()
        panel.beginSheetModal(for: window) { _ in }
        try await wait("保存面板") { window.attachedSheet != nil }
        try Data("保存面板期间更新".utf8).write(to: first.fileURL!, options: .atomic)
        await first.session.reload(force: true)?.value
        try require(prompt(for: first) == nil, "确认框覆盖了保存面板")
        panel.cancel(nil)
        try await respond(first, accept: false)

        first.session.edit("关闭前未保存内容")
        let close = CloseDecision()
        first.canClose(withDelegate: close, shouldClose: #selector(CloseDecision.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        try await wait("原生关闭确认") { window.attachedSheet != nil }
        try Data("关闭确认期间更新".utf8).write(to: first.fileURL!, options: .atomic)
        await first.session.reload(force: true)?.value
        try require(prompt(for: first) == nil, "确认框覆盖了关闭对话框")
        guard let closeRoot = window.attachedSheet?.contentView,
              let cancel = views(closeRoot).compactMap({ $0 as? NSButton }).first(where: { $0.title == L10n.text("取消") }) else {
            throw SmokeCheck.Failure(message: "关闭确认缺少取消按钮")
        }
        cancel.performClick(nil)
        try await wait("取消关闭完成") { close.result == false }
        try await respond(first, accept: false)
        try require(first.session.state.text == "关闭前未保存内容", "关闭与更新确认丢失了本地内容")

        try Data("旧提示".utf8).write(to: first.fileURL!, options: .atomic)
        try await waitForPrompt(first)
        try Data("新提示".utf8).write(to: first.fileURL!, options: .atomic)
        await first.session.reload(force: true)?.value
        try await respond(first, accept: false)
        try await respond(first, accept: false)
        try require(first.session.state.external?.text == "新提示", "旧提示的拒绝丢弃了新版本")
        try Data("第一份".utf8).write(to: first.fileURL!, options: .atomic)
        await first.session.reload(force: true)?.value
        try require(!first.session.state.hasConflict, "恢复基线后仍残留提示")
    }

    private static func markdownPreservation(directory: URL) async throws {
        let source = "# 保留排版内容\n\n" + (1...80).map { "## 段落\($0)\n\n这是原来的第\($0)段正文。\n\n" }.joined()
        let url = directory.appendingPathComponent("reader-preservation.md")
        let document = try open(url, text: source)
        defer { document.close() }
        let root = document.windowControllers.first!.window!.contentView!
        var web: WKWebView?
        try await wait("排版阅读视图") {
            web = views(root).compactMap { $0 as? WKWebView }.first
            return web != nil
        }
        guard let web else { throw SmokeCheck.Failure(message: "缺少排版阅读视图") }
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "保留排版内容" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.evaluateJavaScript("""
            window.scrollTo(0, 1400);
            window.__retainedParagraph = document.querySelectorAll('#content p')[12];
            const retainedRange = document.createRange();
            retainedRange.selectNodeContents(window.__retainedParagraph);
            getSelection().removeAllRanges(); getSelection().addRange(retainedRange);
            true
            """)
        try await Task.sleep(for: .milliseconds(150))
        let position = try await web.evaluateJavaScript("scrollY") as? Double ?? -1
        let selection = try await web.evaluateJavaScript("getSelection().toString()") as? String ?? ""
        let external = source.replacingOccurrences(of: "原来的", with: "磁盘上的")
        try Data(external.utf8).write(to: url, options: .atomic)
        try await waitForPrompt(document)
        try require((try await web.evaluateJavaScript("document.querySelectorAll('#content p')[12] === window.__retainedParagraph")) as? Bool == true,
                    "等待期间重建了排版节点")
        try await respond(document, accept: false)
        let after = try await web.evaluateJavaScript("scrollY") as? Double ?? -100
        let afterSelection = try await web.evaluateJavaScript("getSelection().toString()") as? String ?? ""
        try require(abs(after - position) < 2 && !selection.isEmpty && afterSelection == selection &&
            document.session.state.text == source, "拒绝更新改变了排版阅读位置、选区或正文")
        document.session.acceptExternal()
        try await confirm(document)
        try require(document.session.state.text == external, "手动确认未加载排版文档")
        try await Task.sleep(for: .milliseconds(200))
        try require(prompt(for: document) == nil, "手动加载连续弹出两个确认框")
    }

    private static func readFailures(directory: URL) async throws {
        for missing in [false, true] {
            let url = directory.appendingPathComponent("read-failure-\(missing).txt")
            let document = try open(url, text: "当前内容")
            defer { document.close() }
            try Data("准备更新".utf8).write(to: url, options: .atomic)
            try await waitForPrompt(document)
            // 同一主线程回合内改磁盘并点击，确保覆盖确认后的读取失败。
            let root = prompt(for: document)!.contentView!
            let button = views(root).compactMap { $0 as? NSButton }.first { $0.title == L10n.text("确定") }!
            if missing { try FileManager.default.removeItem(at: url) }
            else { try Data([0, 0, 0]).write(to: url, options: .atomic) }
            button.performClick(nil)
            try await wait("读取错误提示") { document.session.errorMessage != nil }
            try require(document.session.state.text == "当前内容" && document.session.state.baseline.text == "当前内容",
                        "读取失败丢失了当前内容")
            try require(document.session.state.isMissing == missing, "删除状态不符")
        }
    }

    private static func recoveryWithExternalVersion(directory: URL) async throws {
        let url = directory.appendingPathComponent("pending-recovery.txt")
        let document = try open(url, text: "打开时的内容")
        defer { document.close() }
        try Data("已检测到的外部版本".utf8).write(to: url, options: .atomic)
        try await respond(document, accept: false)
        document.session.recovery = RecoveryDraft(baseline: Data("旧草稿基线".utf8), text: "要恢复的本地草稿", savedAt: Date())
        document.session.restoreDraft()
        try require(document.session.state.text == "要恢复的本地草稿" &&
            document.session.state.external?.text == "已检测到的外部版本",
                    "恢复草稿丢弃了已检测到的外部版本")
        try await respond(document, accept: false)
    }

    private static func staleLoads(directory: URL) async throws {
        for action in ["edit", "saveAs", "close"] {
            let url = directory.appendingPathComponent("stale-\(action).txt")
            let document = try open(url, text: "原内容")
            defer { document.close() }
            try Data("外部内容".utf8).write(to: url, options: .atomic)
            try await waitForPrompt(document)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let store = document.session.store
            let blocker = Task.detached { await store.blockExternalCheck(entered: entered, release: release) }
            defer { release.signal() }
            try await wait("文件服务已暂停") { entered.wait(timeout: .now()) == .success }
            try await respond(document, accept: true)
            try require(document.session.isLoadingExternal, "确认未启动读取")
            if action == "edit" {
                document.session.edit("读取期间继续输入")
                release.signal(); await blocker.value
                try await waitForPrompt(document)
                try require(document.session.state.text == "读取期间继续输入", "过期读取覆盖了新输入")
                try await respond(document, accept: false)
            } else if action == "saveAs" {
                let target = directory.appendingPathComponent("saved-as.txt")
                let save = Task { try await document.session.performSave(to: target, operation: .saveAsOperation) }
                try await wait("另存为开始") { document.session.isSaving }
                release.signal(); await blocker.value
                try await save.value
                try require(document.fileURL == target && document.session.state.text == "原内容" &&
                    document.session.state.baseline.text == "原内容" && !document.session.state.hasConflict,
                            "旧地址的载入覆盖了另存为文档")
            } else {
                document.close()
                release.signal(); await blocker.value
                try await Task.sleep(for: .milliseconds(100))
                try require(document.session.state.text == "原内容" && !document.session.isLoadingExternal,
                            "已关闭文档收到过期载入")
            }
        }
    }
}

private extension FileStore {
    func blockExternalCheck(entered: DispatchSemaphore, release: DispatchSemaphore) {
        entered.signal()
        release.wait()
    }
}
#endif
