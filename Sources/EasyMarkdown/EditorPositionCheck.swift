#if DEBUG
import AppKit
import WebKit
import EasyMarkdownCore

/// 使用真实标签和保存流程检查视口，光标故意留在屏幕之外。
@MainActor enum EditorPositionCheck {
    static func check(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferences = EditorPreferences.store
        let originalTabs = preferences.bool(forKey: EditorPreferences.documentTabsEnabled)
        preferences.set(true, forKey: EditorPreferences.documentTabsEnabled)
        DocumentTabCoordinator.shared.applyPreference()
        var documents: [MarkdownDocument] = []
        defer {
            for document in documents { document.close() }
            preferences.set(originalTabs, forKey: EditorPreferences.documentTabsEnabled)
            DocumentTabCoordinator.shared.applyPreference()
        }
        let items = (0..<1_200).map { "{\"value\":\"定位\($0)中文📝\"}" }
        let source = "[\n" + items.joined(separator: ",\n") + "\n]\n"
        for index in 0..<2 {
            let url = directory.appendingPathComponent("position-\(index).json")
            try Data(source.utf8).write(to: url)
            try await DraftStore.shared.remove(url)
            let document = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)), url: url)
            documents.append(document)
            document.session.mode = .edit
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        }
        let document = documents[0]
        guard let window = document.windowControllers.first?.window, let root = window.contentView else {
            throw failure("位置检查未创建窗口")
        }
        NSApp.activate(ignoringOtherApps: true)
        document.showWindows()
        try await settle()
        var results: [[String: Any]] = []
        var failures: [String] = []
        for mode in [ViewMode.read, .edit, .split] {
            document.session.mode = mode
            try await settle()
            guard let text = editors(root).first(where: { ($0.delegate as? SourceEditor.Coordinator)?.isSecondary == false }),
                  let scroll = text.enclosingScrollView else { throw failure("位置检查未找到编辑器") }
            text.setSelectedRange(NSRange(location: 5, length: 12))
            try position(text, at: "定位600")
            try await settle()
            let before = scroll.contentView.bounds.minY
            documents[1].showWindows()
            try await settle()
            document.showWindows()
            try await settle()
            let after = scroll.contentView.bounds.minY
            results.append(["operation": "\(mode)-标签切换", "before": before, "after": after])
            if abs(after - before) > 1 { failures.append("\(mode)标签切换移动了\(after - before)点") }
            guard mode != .read else { continue }
            text.insertText(" ", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
            text.breakUndoCoalescing()
            text.setSelectedRange(NSRange(location: 0, length: 0))
            try position(text, at: "定位600")
            try await settle()
            let beforeSave = scroll.contentView.bounds.minY
            try await document.session.performSave(to: document.fileURL!, operation: .saveOperation)
            try await settle()
            let afterSave = scroll.contentView.bounds.minY
            results.append(["operation": "\(mode)-保存", "before": beforeSave, "after": afterSave])
            if abs(afterSave - beforeSave) > 1 { failures.append("\(mode)保存移动了\(afterSave - beforeSave)点") }
        }
        document.session.mode = .edit
        try await settle()
        guard let text = editors(root).first(where: \.isEditable), let scroll = text.enclosingScrollView else {
            throw failure("格式化位置检查未找到编辑器")
        }
        let selected = (text.string as NSString).range(of: "定位610中文📝")
        text.setSelectedRange(selected)
        try position(text, at: "定位600")
        try await settle()
        await document.session.format()?.value
        try await settle()
        let selection = (text.string as NSString).substring(with: text.selectedRange())
        let visible = visibleText(text)
        results.append(["operation": "格式化", "selection": selection, "visible": visible, "y": scroll.contentView.bounds.minY])
        if selection != "定位610中文📝" { failures.append("格式化没有保留原选区") }
        if !visible.contains("定位600") { failures.append("格式化丢失了当前可见内容") }
        let formatted = text.string
        document.undoManager?.undo()
        try await settle()
        if text.string == formatted || !text.string.contains(items[600]) { failures.append("格式化撤销未恢复原文") }
        document.undoManager?.redo()
        try await settle()
        if text.string != formatted { failures.append("格式化重做未恢复格式化结果") }
        for suffix in ["json", "xml"] {
            let input = suffix == "json" ? source : "<root>\n" + (0..<1_200).map { "<item>定位\($0)中文📝</item>" }.joined(separator: "\n") + "\n</root>\n"
            let url = directory.appendingPathComponent("split-format.\(suffix)")
            try Data(input.utf8).write(to: url)
            let split = MarkdownDocument(snapshot: try FileSnapshot(data: Data(input.utf8)), url: url)
            documents.append(split)
            split.session.mode = .split
            split.session.synchronizeSplitScroll = false
            NSDocumentController.shared.addDocument(split)
            split.makeWindowControllers()
            split.showWindows()
            try await settle()
            guard let splitRoot = split.windowControllers.first?.window?.contentView,
                  let editor = editors(splitRoot).first(where: \.isEditable),
                  let preview = editors(splitRoot).first(where: { ($0.delegate as? SourceEditor.Coordinator)?.isSecondary == true }) else {
                throw failure("分栏格式化缺少窗格")
            }
            editor.setSelectedRange((input as NSString).range(of: "定位610中文📝"))
            try position(editor, at: "定位600")
            try position(preview, at: "定位900")
            try await settle()
            await split.session.format()?.value
            try await settle()
            let keptEditor = visibleText(editor).contains("定位600")
            let keptPreview = visibleText(preview).contains("定位900")
            let keptSelection = (editor.string as NSString).substring(with: editor.selectedRange()) == "定位610中文📝"
            results.append(["operation": "\(suffix)分栏格式化", "editor": keptEditor, "preview": keptPreview, "selection": keptSelection])
            if !keptEditor || !keptPreview || !keptSelection { failures.append("\(suffix)分栏格式化丢失位置或选区") }
            split.session.synchronizeSplitScroll = true
            try position(editor, at: "定位100")
            try await settle()
            if !visibleText(preview).contains("定位100") { failures.append("\(suffix)格式化后分栏不再同步") }
        }
        // 一致 CRLF 文件保存会把刚输入的 LF 统一回磁盘约定，触发全文刷新。
        let crlfSource = source.replacingOccurrences(of: "\n", with: "\r\n")
        let crlfURL = directory.appendingPathComponent("position-crlf.json")
        try Data(crlfSource.utf8).write(to: crlfURL)
        let crlf = MarkdownDocument(snapshot: try FileSnapshot(data: Data(crlfSource.utf8)), url: crlfURL)
        documents.append(crlf)
        crlf.session.mode = .split
        NSDocumentController.shared.addDocument(crlf)
        crlf.makeWindowControllers()
        crlf.showWindows()
        try await settle()
        guard let crlfRoot = crlf.windowControllers.first?.window?.contentView,
              let crlfText = editors(crlfRoot).first(where: \.isEditable),
              let crlfScroll = crlfText.enclosingScrollView else { throw failure("换行保存检查缺少编辑器") }
        crlfText.insertText("\n", replacementRange: NSRange(location: 0, length: 0))
        crlfText.breakUndoCoalescing()
        crlfText.setSelectedRange((crlfText.string as NSString).range(of: "定位610中文📝"))
        try position(crlfText, at: "定位600")
        try await settle()
        let crlfBefore = crlfScroll.contentView.bounds.minY
        try await crlf.session.performSave(to: crlfURL, operation: .saveOperation)
        try await settle()
        let crlfAfter = crlfScroll.contentView.bounds.minY
        results.append(["operation": "换行转换保存", "before": crlfBefore, "after": crlfAfter,
                        "selection": (crlfText.string as NSString).substring(with: crlfText.selectedRange()),
                        "matchesSession": crlfText.string == crlf.session.state.text])
        if abs(crlfAfter - crlfBefore) > 1 { failures.append("换行转换保存移动了\(crlfAfter - crlfBefore)点") }
        if (crlfText.string as NSString).substring(with: crlfText.selectedRange()) != "定位610中文📝" {
            failures.append("换行转换保存改变了原选区")
        }
        if crlf.undoManager?.canUndo != true { failures.append("换行转换保存清空了撤销记录") }
        crlf.undoManager?.undo()
        try await settle()
        if crlfText.string == "\n" + crlfSource {
            crlf.undoManager?.undo()
            try await settle()
        }
        if crlfText.string != crlfSource { failures.append("保存前的编辑无法继续撤销") }
        let markdownSource = (0..<400).map { "## 段落\($0)\n\n" + String(repeating: "这是第\($0)段的内容，保留阅读位置。", count: 8) + "\n\n" }.joined()
        let markdownURL = directory.appendingPathComponent("position.md")
        try Data(markdownSource.utf8).write(to: markdownURL)
        let markdown = MarkdownDocument(snapshot: try FileSnapshot(data: Data(markdownSource.utf8)), url: markdownURL)
        documents.append(markdown)
        NSDocumentController.shared.addDocument(markdown)
        markdown.makeWindowControllers()
        markdown.showWindows()
        guard let markdownRoot = markdown.windowControllers.first?.window?.contentView else { throw failure("排版位置检查缺少窗口") }
        for mode in [ViewMode.read, .split] {
            markdown.session.mode = mode
            let web = try await reader(in: markdownRoot, context: "\(mode)初次打开")
            try await settle()
            _ = try await web.evaluateJavaScript("window.scrollTo(0,4500);true")
            try await settle()
            let before = try await web.evaluateJavaScript("scrollY") as? Double ?? -1
            guard abs(before - 4500) < 1 else { throw failure("后台标签检查未停在文档中部") }
            let native = editors(markdownRoot).first(where: \.isEditable)
            let sourceBefore = native?.enclosingScrollView?.contentView.bounds.minY ?? 0
            markdown.session.previewActivity.idleDelay = .milliseconds(100)
            markdown.session.setWindowActive(true)
            documents[1].showWindows()
            markdown.session.setWindowActive(false)
            for _ in 0..<100 {
                if !markdown.session.previewActivity.isAwake { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard !markdown.session.previewActivity.isAwake else { throw failure("后台标签未进入休眠") }
            markdown.session.previewActivity.idleDelay = .seconds(30)
            markdown.showWindows()
            markdown.session.setWindowActive(true)
            let restored = try await reader(in: markdownRoot, context: "\(mode)标签恢复")
            try await settle()
            let after = try await restored.evaluateJavaScript("scrollY") as? Double ?? -1
            let sourceAfter = native?.enclosingScrollView?.contentView.bounds.minY ?? 0
            results.append(["operation": "\(mode)-后台标签恢复", "before": before, "after": after,
                            "sourceBefore": sourceBefore, "sourceAfter": sourceAfter])
            if abs(after - before) > 5 || abs(sourceAfter - sourceBefore) > 5 {
                failures.append("\(mode)后台标签恢复改变了位置")
            }
        }
        markdown.session.mode = .edit
        try await settle()
        guard let markdownText = editors(markdownRoot).first(where: \.isEditable) else { throw failure("保存完成检查缺少编辑器") }
        markdownText.insertText("\n", replacementRange: NSRange(location: (markdownText.string as NSString).length, length: 0))
        markdownText.breakUndoCoalescing()
        try position(markdownText, at: "## 段落200")
        try await settle()
        markdown.session.save(finishing: true)
        for _ in 0..<100 {
            if markdown.session.mode == .read { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let finishedReader = try await reader(in: markdownRoot, context: "保存完成，模式\(markdown.session.mode)，活动\(markdown.session.isWindowActive)，休眠\(!markdown.session.previewActivity.isAwake)")
        try await settle()
        let heading = try await finishedReader.evaluateJavaScript("headingElements.filter(e=>e.getBoundingClientRect().top>=0)[0]?.textContent || ''") as? String ?? ""
        results.append(["operation": "保存并完成", "heading": heading])
        if heading != "段落200" { failures.append("保存并完成没有保持源码当前阅读位置：\(heading)") }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        guard failures.isEmpty else { throw failure(failures.joined(separator: "；")) }
    }

    private static func editors(_ root: NSView) -> [NSTextView] {
        ([root] + root.subviews.flatMap(allViews)).compactMap { $0 as? NSTextView }
            .filter { $0.delegate is SourceEditor.Coordinator }
    }

    private static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    private static func position(_ text: NSTextView, at marker: String) throws {
        guard let scroll = text.enclosingScrollView, let layout = text.layoutManager, let container = text.textContainer else {
            throw failure("位置检查缺少排版组件")
        }
        let offset = (text.string as NSString).range(of: marker).location
        guard offset != NSNotFound else { throw failure("位置检查缺少定位文本") }
        // 测试准备排版全文，保证目标坐标确定；不约束生产代码排版范围。
        layout.ensureLayout(for: container)
        text.sizeToFit()
        let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: text.textContainerInset.height + rect.minY - 3))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func visibleText(_ text: NSTextView) -> String {
        guard let layout = text.layoutManager, let container = text.textContainer else { return "" }
        let rect = text.visibleRect.offsetBy(dx: -text.textContainerInset.width, dy: -text.textContainerInset.height)
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        return (text.string as NSString).substring(with: layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
    }

    private static func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }
    private static func reader(in root: NSView, context: String) async throws -> WKWebView {
        for _ in 0..<150 {
            if let web = allViews(root).compactMap({ $0 as? WKWebView }).first,
               (try? await web.evaluateJavaScript("content.childElementCount>100 && !restoring")) as? Bool == true { return web }
            try await Task.sleep(for: .milliseconds(30))
        }
        let web = allViews(root).compactMap { $0 as? WKWebView }.first
        let state = try? await web?.evaluateJavaScript("JSON.stringify({count:content.childElementCount, restoring, y:scrollY})")
        throw failure("排版位置检查未完成渲染：\(context)，存在页面\(web != nil)，状态\(String(describing: state))")
    }
    private static func failure(_ message: String) -> Error { SmokeCheck.Failure(message: message) }
}
#endif
