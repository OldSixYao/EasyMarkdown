#if DEBUG
import AppKit
import WebKit
import EasyMarkdownCore

@MainActor enum ReadOnlyEditCheck {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for ext in ["txt", "md", "json", "yaml"] { try await document(extension: ext, directory: directory) }
        try await closeDuringPrompt(directory: directory)
        try Data("passed\n".utf8).write(to: directory.appendingPathComponent("result.txt"))
    }

    private static func document(extension ext: String, directory: URL) async throws {
        print("只读检查：\(ext)，开始")
        let source = ext == "json" ? "{\"message\": \"只读内容\"}\n" : "# 只读内容\n\n保留正文、位置和保存状态。\n"
        let url = directory.appendingPathComponent("read-only." + ext)
        try Data(source.utf8).write(to: url)
        let document = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)), url: url)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        NSApp.activate(ignoringOtherApps: true)
        defer { document.updateChangeCount(.changeCleared); document.close() }
        guard let window = document.windowControllers.first?.window, let root = window.contentView else {
            throw failure("缺少文档窗口")
        }
        let session = document.session
        var reader: NSView?
        try await wait("阅读内容挂载") {
            reader = ext == "md" ? views(root).first(where: { $0 is WKWebView }) :
                views(root).first(where: { ($0 as? NSTextView)?.delegate is SourceEditor.Coordinator })
            return reader != nil && window.isKeyWindow && NSApp.isActive
        }
        guard let reader else { throw failure("缺少阅读视图") }
        if let web = reader as? WKWebView {
            try await waitAsync("排版阅读就绪") {
                (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "只读内容"
            }
        }
        window.makeFirstResponder(reader)
        let revision = session.state.revision

        // 定位及阅读快捷键不能产生编辑确认。
        for (characters, keyCode, modifiers) in [
            ("\u{F701}", UInt16(125), NSEvent.ModifierFlags()),
            ("\u{F72D}", UInt16(121), NSEvent.ModifierFlags()),
            (" ", UInt16(49), NSEvent.ModifierFlags()),
            ("\t", UInt16(48), NSEvent.ModifierFlags()),
            ("\r", UInt16(36), NSEvent.ModifierFlags()),
            ("c", UInt16(8), NSEvent.ModifierFlags.command)
        ] {
            window.makeFirstResponder(reader)
            send(characters, code: keyCode, modifiers: modifiers, window: window)
            try require(prompt(document) == nil && session.mode == .read, "阅读按键误触发编辑确认：" + characters)
        }
        // 网页阅读在另一个进程处理按键，等导航及其未处理按键回传完成再发起确认。
        if reader is WKWebView { try await Task.sleep(for: .milliseconds(250)) }
        try require(prompt(document) == nil && session.mode == .read, "网页阅读按键延后触发了编辑确认")

        let selected = (source as NSString).range(of: "只读内容")
        (reader as? NSTextView)?.setSelectedRange(selected)

        window.makeFirstResponder(reader)
        send("a", code: 0, window: window)
        try await wait("文字输入弹出只读确认") { prompt(document) != nil }
        let firstPrompt = prompt(document)
        send("b", code: 11, window: window)
        send("a", code: 0, repeatKey: true, window: window)
        try require(prompt(document) === firstPrompt && session.state.text == source && session.state.revision == revision &&
            !session.state.isDirty && session.mode == .read, "等待确认时重复弹窗或修改文档")
        try require(prompt(document)?.contentView.map { root in
            views(root).compactMap { ($0 as? NSTextField)?.stringValue }.contains(L10n.text("当前是只读模式，是否开始编辑？"))
        } == true, "只读确认文案没有正确本地化")
        if ext == "txt" || ext == "md" {
            try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("confirmation-" + ext + ".png"))
        }
        try await respond(document, accept: false)
        try require(session.mode == .read && session.state.text == source && !session.state.isDirty,
                    "取消后未保留阅读模式及正文")
        if let text = reader as? NSTextView {
            try require(text.string == source && text.selectedRange() == selected, "取消后原生正文或选区改变")
        }

        window.makeFirstResponder(reader)
        send("a", code: 0, repeatKey: true, window: window)
        try require(prompt(document) == nil, "取消后长按导致再次弹出确认")
        send("\u{7f}", code: 51, window: window)
        try await wait("删除键触发确认") { prompt(document) != nil }
        guard let sheet = prompt(document) else { throw failure("删除键没有确认框") }
        send("\u{1b}", code: 53, window: sheet)
        try await wait("退出键取消只读确认") { prompt(document) == nil }
        try require(session.mode == .read && session.state.text == source, "退出键改变了文档模式或内容")

        for (characters, code) in [("v", UInt16(9)), ("x", UInt16(7))] {
            window.makeFirstResponder(reader)
            send(characters, code: code, modifiers: .command, window: window)
            try await wait("剪切或粘贴触发确认：" + characters) { prompt(document) != nil }
            try await respond(document, accept: false)
        }

        session.showSearch()
        var search: NSTextView?
        try await wait("查找输入焦点") {
            search = window.firstResponder as? NSTextView
            return search?.isEditable == true && !(search?.delegate is SourceEditor.Coordinator)
        }
        guard let search else { throw failure("缺少查找框字段编辑器") }
        send("q", code: 12, window: window)
        try await wait("查找输入继续正常工作") { search.string.contains("q") }
        try require(prompt(document) == nil && session.mode == .read, "查找框输入触发了只读编辑确认")
        session.closeSearch()
        try await Task.sleep(for: .milliseconds(100))

        // 已有系统面板和外部版本预览不应触发正文编辑确认。
        let blocker = NSAlert()
        blocker.messageText = "测试面板"
        blocker.addButton(withTitle: L10n.text("取消"))
        blocker.beginSheetModal(for: window) { _ in }
        send("a", code: 0, window: window)
        try require(window.attachedSheet === blocker.window && prompt(document) == nil, "编辑提示覆盖其他系统面板")
        window.endSheet(blocker.window, returnCode: .abort)
        try await wait("测试面板关闭并恢复文档焦点") { window.attachedSheet == nil && window.isKeyWindow }

        window.makeFirstResponder(reader)
        send("a", code: 0, window: window)
        try await respond(document, accept: true)
        var editor: NSTextView?
        try await wait("确认后聚焦可编辑源码") {
            editor = views(root).compactMap { $0 as? NSTextView }.first { $0.isEditable && $0.delegate is SourceEditor.Coordinator }
            return session.mode == .edit && editor != nil && window.firstResponder === editor
        }
        try require(session.state.text == source && !session.state.isDirty && session.state.revision == revision &&
            (try Data(contentsOf: url)) == Data(source.utf8), "确认进入编辑时修改了正文或磁盘")
        guard let editor else { throw failure("确认后缺少源码编辑器") }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        send("z", code: 6, window: window)
        try await wait("确认后文字可以正常输入") { session.state.text == source + "z" }
        try require(prompt(document) == nil && session.state.isDirty && editor.undoManager?.canUndo == true,
                    "编辑模式仍有确认或未保留原生撤销")

        session.mode = .split
        try await wait("分栏只读预览挂载") {
            ext == "md" ? views(root).contains(where: { $0 is WKWebView }) :
                views(root).compactMap { $0 as? NSTextView }.contains { !$0.isEditable && $0.delegate is SourceEditor.Coordinator }
        }
        let preview = ext == "md" ? views(root).first(where: { $0 is WKWebView }) :
            views(root).first(where: { ($0 as? NSTextView)?.isEditable == false && ($0 as? NSTextView)?.delegate is SourceEditor.Coordinator })
        if let preview { window.makeFirstResponder(preview) }
        send("a", code: 0, window: window)
        try require(session.mode == .split && prompt(document) == nil, "分栏预览错误触发进入编辑提示")
    }

    private static func closeDuringPrompt(directory: URL) async throws {
        let url = directory.appendingPathComponent("close-prompt.txt")
        try Data("保留内容".utf8).write(to: url)
        let document = MarkdownDocument(snapshot: try FileSnapshot(data: Data("保留内容".utf8)), url: url)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        NSApp.activate(ignoringOtherApps: true)
        guard let window = document.windowControllers.first?.window, let root = window.contentView else { throw failure("缺少关闭测试窗口") }
        try await wait("关闭测试窗口的阅读器") { views(root).contains { ($0 as? NSTextView)?.delegate is SourceEditor.Coordinator } && window.isKeyWindow }
        window.makeFirstResponder(views(root).first { ($0 as? NSTextView)?.delegate is SourceEditor.Coordinator })
        send("a", code: 0, window: window)
        try await wait("关闭前确认出现") { prompt(document) != nil }
        document.close()
        try await wait("关闭文档时移除确认框") { window.attachedSheet == nil }
        try require(document.session.mode == .read && document.session.closed, "关闭后仍开始编辑")
    }

    private static func respond(_ document: MarkdownDocument, accept: Bool) async throws {
        try await wait("只读编辑确认框，操作：" + (accept ? "确定" : "取消")) { prompt(document) != nil }
        guard let sheet = prompt(document), let root = sheet.contentView,
              let button = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == L10n.text(accept ? "确定" : "取消") }) else {
            throw failure("只读确认缺少操作按钮")
        }
        button.performClick(nil)
        try await wait("只读确认结束并恢复文档焦点") {
            prompt(document) == nil && document.windowControllers.first?.window?.isKeyWindow == true
        }
    }

    private static func prompt(_ document: MarkdownDocument) -> NSWindow? {
        let sheet = document.windowControllers.first?.window?.attachedSheet
        return sheet?.identifier?.rawValue == "readOnlyEditConfirmation" ? sheet : nil
    }

    private static func send(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                             repeatKey: Bool = false, window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code) else { return }
        NSApp.sendEvent(event)
    }

    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> SmokeCheck.Failure { .init(message: message) }
    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<160 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw failure("等待失败：" + message)
    }
    private static func waitAsync(_ message: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<160 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw failure("等待失败：" + message)
    }
}
#endif
