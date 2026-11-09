#if DEBUG
import AppKit
import EasyMarkdownCore
import SwiftUI
import WebKit

@MainActor enum EditorStatisticsCheck {
    static func check(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let accessibility = setAccessibilityTestingEnabled(true)
        defer { setAccessibilityTestingEnabled(accessibility) }
        let source = "# 统计测试\n\n甲乙 🧑🏽‍💻 e\u{301}\n \t\n尾\n"
        let url = directory.appendingPathComponent("statistics.md")
        try Data(source.utf8).write(to: url)
        let document = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)), url: url)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        defer { document.close() }
        guard let window = document.windowControllers.first?.window, let root = window.contentView else {
            throw failure("统计窗口未创建")
        }
        try await wait("阅读模式显示全文统计") {
            statusBar(in: root) != nil && document.session.editorStatistics.total == expected(source)
        }
        let reader = try await webReader(in: root)
        try await selectReaderText(reader, length: 1)
        try await wait("排版阅读选区统计") {
            document.session.editorStatistics.selection == TextStatistics(lineCount: 1, characterCount: 1)
        }
        try await selectReaderText(reader, length: 2)
        try await wait("排版阅读连续扩选统计") {
            document.session.editorStatistics.selection == TextStatistics(lineCount: 1, characterCount: 2)
        }
        try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("statistics-reader.png"))
        _ = try await reader.evaluateJavaScript("getSelection().removeAllRanges();true")
        try await wait("排版阅读取消选区") { document.session.editorStatistics.selection == nil }
        guard !document.isDocumentEdited else { throw failure("阅读选择修改了文档") }
        document.session.mode = .edit
        do {
            try await wait("进入编辑显示全文统计") {
                editor(in: root) != nil && document.session.editorStatistics.total == expected(source) && statusBar(in: root) != nil
            }
        } catch {
            try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("statistics-failure.png"))
            print("统计诊断：editor=\(editor(in: root) != nil) total=\(document.session.editorStatistics.total) expected=\(expected(source)) accessibility=\(String(describing: root.accessibilityChildren()))")
            throw error
        }
        guard let text = editor(in: root), let coordinator = text.delegate as? SourceEditor.Coordinator else {
            throw failure("统计编辑器缺失")
        }
        let revision = document.session.state.revision
        try checkTrackingSelection(text, session: document.session)
        let row = (source as NSString).range(of: "甲乙 🧑🏽‍💻 e\u{301}\n")
        text.setSelectedRange(row)
        try await wait("选区结束于下一行开头") {
            document.session.editorStatistics.selection == TextStatistics(lineCount: 1, characterCount: 4)
        }
        let whitespace = (source as NSString).range(of: " \t\n")
        text.setSelectedRange(whitespace)
        try await wait("只选空白仍显示选区") {
            document.session.editorStatistics.selection == TextStatistics(lineCount: 1, characterCount: 0)
        }
        text.setSelectedRanges([(source as NSString).range(of: "甲乙"), (source as NSString).range(of: "尾")].map { NSValue(range: $0) },
                               affinity: .downstream, stillSelecting: false)
        try await wait("原生多个选区合并统计") {
            document.session.editorStatistics.selection == TextStatistics(lineCount: 2, characterCount: 3)
        }
        text.setSelectedRange(NSRange(location: 0, length: 0))
        try await wait("取消选择隐藏选区统计") { document.session.editorStatistics.selection == nil }
        guard document.session.state.revision == revision, coordinator.statisticsIndex?.rebuildCount == 1,
              !document.isDocumentEdited else { throw failure("统计改变了正文或重复全量统计") }

        text.insertText("新📝\n", replacementRange: NSRange(location: 0, length: 0))
        text.breakUndoCoalescing()
        try await wait("输入后统计刷新") { document.session.editorStatistics.total == expected(text.string) }
        let edited = text.string
        text.undoManager?.undo()
        try await wait("撤销刷新统计") { text.string == source && document.session.editorStatistics.total == expected(source) }
        text.undoManager?.redo()
        try await wait("重做刷新统计") { text.string == edited && document.session.editorStatistics.total == expected(edited) }
        text.setMarkedText("组合", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let marked = text.markedRange()
        try await wait("组合输入期间更新统计") { document.session.editorStatistics.total == expected(text.string) }
        guard text.hasMarkedText(), text.markedRange() == marked else { throw failure("统计中断了输入法组合") }
        text.unmarkText()
        text.setSelectedRange(NSRange(location: 0, length: 2))
        try await wait("组合输入后选区") { document.session.editorStatistics.selection?.characterCount == 2 }
        let beforeToggle = document.session.editorStatistics
        let preferences = EditorPreferences.store
        let originalLines = preferences.bool(forKey: EditorPreferences.showLineNumbers)
        defer { preferences.set(originalLines, forKey: EditorPreferences.showLineNumbers) }
        preferences.set(false, forKey: EditorPreferences.showLineNumbers)
        try await wait("关闭行号保留统计") { text.enclosingScrollView?.verticalRulerView == nil }
        guard document.session.editorStatistics == beforeToggle else { throw failure("统计依赖行号开关") }
        preferences.set(originalLines, forKey: EditorPreferences.showLineNumbers)
        document.session.mode = .split
        try await wait("分栏保留主编辑器与状态栏") {
            editor(in: root) === text && statusBar(in: root) != nil && document.session.editorStatistics.selection?.characterCount == 2
        }
        let splitReader = try await webReader(in: root)
        try await selectReaderText(splitReader, length: 1)
        try await wait("排版分栏切换选区来源") { document.session.editorStatistics.selection?.characterCount == 1 }
        text.setSelectedRange(NSRange(location: 0, length: 2))
        try await wait("返回源码选区实时统计") { document.session.editorStatistics.selection?.characterCount == 2 }
        let stable = document.session.editorStatistics
        // An external-version editor must never publish into the main session.
        let overrideView = NSHostingView(rootView: SourceEditor(session: document.session, isReadOnly: true, overrideText: "外部\n内容\n"))
        overrideView.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        overrideView.layoutSubtreeIfNeeded()
        if let external = editor(in: overrideView) {
            external.setSelectedRange(NSRange(location: 0, length: 5))
            (external.delegate as? SourceEditor.Coordinator)?.scheduleStatistics()
        } else { throw failure("外部版本编辑器未创建") }
        try await Task.sleep(for: .milliseconds(80))
        guard document.session.editorStatistics == stable else { throw failure("外部版本污染主编辑器统计") }
        window.setContentSize(NSSize(width: 620, height: 520))
        try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("statistics-split-narrow.png"))
        document.session.mode = .edit
        let appearance = UserDefaults.standard.object(forKey: "appearance")
        defer {
            if let appearance { UserDefaults.standard.set(appearance, forKey: "appearance") }
            else { UserDefaults.standard.removeObject(forKey: "appearance") }
        }
        for value in ["light", "dark"] {
            UserDefaults.standard.set(value, forKey: "appearance")
            try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("statistics-\(value).png"))
        }
        try await document.session.performSave(to: url, operation: .saveOperation)
        let external = "磁盘加载\n甲\n乙\n"
        try Data(external.utf8).write(to: url, options: .atomic)
        await document.session.reload(force: true)?.value
        try await wait("外部加载同步正文和统计") {
            text.string == external && document.session.editorStatistics.total == expected(external)
        }
        document.session.mode = .read
        try await wait("返回阅读保留全文并清除旧选区") {
            statusBar(in: root) != nil && document.session.editorStatistics.total == expected(external) &&
                document.session.editorStatistics.selection == nil
        }
        let refreshed = external + "刷新后的行\n"
        try Data(refreshed.utf8).write(to: url, options: .atomic)
        await document.session.reload(force: true)?.value
        try await wait("排版阅读外部刷新更新全文统计") { document.session.editorStatistics.total == expected(refreshed) }

        for suffix in ["txt", "json", "xml", "yaml", "toml", "ini", "conf", "env", "properties", "jsonc"] {
            let value = suffix == "json" ? "{\"a\":1,\"b\":[2,3]}" : suffix == "xml" ? "<root><a>甲</a><b>乙</b></root>" : "甲\n乙\n"
            let file = directory.appendingPathComponent("sample.\(suffix)")
            try Data(value.utf8).write(to: file)
            let other = MarkdownDocument(snapshot: try FileSnapshot(data: Data(value.utf8)), url: file)
            NSDocumentController.shared.addDocument(other)
            other.makeWindowControllers(); other.showWindows()
            defer { other.close() }
            guard let otherWindow = other.windowControllers.first?.window, let otherRoot = otherWindow.contentView else {
                throw failure("\(suffix) 窗口缺失")
            }
            try await wait("\(suffix) 阅读显示全文统计") {
                statusBar(in: otherRoot) != nil && other.session.editorStatistics.total == expected(value)
            }
            guard let nativeReader = editor(in: otherRoot) else { throw failure("原文阅读视图缺失") }
            try checkTrackingSelection(nativeReader, session: other.session)
            nativeReader.setSelectedRange(NSRange(location: 0, length: 0))
            try await wait("\(suffix) 阅读取消选区") { other.session.editorStatistics.selection == nil }
            other.session.mode = .split
            try await wait("\(suffix) 分栏统计") {
                views(otherRoot).compactMap { $0 as? NSTextView }.count == 2 &&
                    other.session.editorStatistics.total == expected(value) && statusBar(in: otherRoot) != nil
            }
            guard let primary = views(otherRoot).compactMap({ $0 as? NSTextView }).first(where: \.isEditable),
                  let secondary = views(otherRoot).compactMap({ $0 as? NSTextView }).first(where: { !$0.isEditable }) else {
                throw failure("\(suffix) 分栏视图缺失")
            }
            primary.setSelectedRange(NSRange(location: 0, length: 1))
            try await wait("主选区统计") { other.session.editorStatistics.selection?.characterCount == 1 }
            secondary.setSelectedRange(NSRange(location: 0, length: (value as NSString).length))
            try await wait("原文分栏按当前选区更新") {
                other.session.editorStatistics.selection?.characterCount == expected(value).characterCount
            }
            guard document.session.editorStatistics.total == expected(refreshed) else { throw failure("文档标签之间共享了统计") }
            primary.setSelectedRange(NSRange(location: 0, length: 1))
            try await wait("原文分栏切回源码选区") { other.session.editorStatistics.selection?.characterCount == 1 }
            if suffix == "json" || suffix == "xml" {
                other.session.format()
                try await wait("\(suffix) 格式化刷新统计") {
                    primary.string != value && !other.session.isFormatting && other.session.editorStatistics.total == expected(primary.string)
                }
                primary.undoManager?.undo()
                try await wait("\(suffix) 撤销格式化刷新统计") { primary.string == value && other.session.editorStatistics.total == expected(value) }
            }
        }
    }

    private static func checkTrackingSelection(_ text: NSTextView, session: DocumentSession) throws {
        let value = text.string as NSString
        for length in [1, 2, min(12, value.length)] {
            let range = NSRange(location: 0, length: length)
            var index = DocumentStatisticsIndex(value)
            let expected = index.statistics(in: value, selectedRanges: [range]).selection
            let selectedLabel = EditorStatusBar.selectionLabel(DocumentStatistics(total: index.total, selection: expected))!
            let root = text.window?.contentView
            text.setSelectedRanges([NSValue(range: range)], affinity: .downstream, stillSelecting: true)
            let deadline = Date().addingTimeInterval(0.3)
            func hasUpdated() -> Bool {
                session.editorStatistics.selection == expected &&
                    root.map { statusBarLabel(in: $0)?.contains(selectedLabel) == true } != false
            }
            while !hasUpdated() && Date() < deadline {
                RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
            }
            guard hasUpdated() else { throw failure("鼠标尚未松开时选区统计或状态栏文字未刷新") }
        }
        text.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 0))], affinity: .downstream, stillSelecting: false)
    }

    private static func webReader(in root: NSView) async throws -> WKWebView {
        for _ in 0..<150 {
            if let web = views(root).compactMap({ $0 as? WKWebView }).first,
               (try? await web.evaluateJavaScript("!!document.querySelector('#content p')")) as? Bool == true { return web }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw failure("排版阅读视图未就绪")
    }

    private static func selectReaderText(_ web: WKWebView, length: Int) async throws {
        _ = try await web.callAsyncJavaScript("""
            const node = document.querySelector('#content p').firstChild;
            getSelection().setBaseAndExtent(node, 0, node, length);
            return true;
            """, arguments: ["length": length], in: nil, contentWorld: .page)
    }

    // SwiftUI creates its accessibility tree on demand. This affects only the
    // current test process, without changing VoiceOver or system preferences.
    @discardableResult static func setAccessibilityTestingEnabled(_ enabled: Bool) -> Bool {
        let attribute = "AXEnhancedUserInterface"
        let previous = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?
            .takeUnretainedValue() as? NSNumber
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                          with: NSNumber(value: enabled), with: attribute)
        return previous?.boolValue ?? false
    }

    static func statusBar(in root: Any, depth: Int = 0) -> NSObject? {
        guard depth < 30, let element = root as? NSObject else { return nil }
        if accessibilityProperty("accessibilityIdentifier", of: element) as? String == "editorStatistics" { return element }
        for child in accessibilityProperty("accessibilityChildren", of: element) as? [Any] ?? [] {
            if let found = statusBar(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    static func statusBarLabel(in root: Any) -> String? {
        guard let element = statusBar(in: root) else { return nil }
        return accessibilityProperty("accessibilityLabel", of: element) as? String
    }

    private static func accessibilityProperty(_ name: String, of element: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        // SwiftUI's nodes implement these selectors without declaring the full
        // NSAccessibilityProtocol; direct protocol casts omit those nodes.
        return element.perform(selector)?.takeUnretainedValue()
    }

    private static func expected(_ source: String) -> TextStatistics { DocumentStatisticsIndex(source as NSString).total }
    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private static func editor(in root: NSView) -> NSTextView? {
        views(root).compactMap { $0 as? NSTextView }.first { $0.delegate is SourceEditor.Coordinator }
    }
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
