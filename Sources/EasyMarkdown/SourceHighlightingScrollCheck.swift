#if DEBUG
import AppKit
import EasyMarkdownCore

/// 滚动后立即检查实际窗口的显示属性，不等待输入防抖或直接调用高亮。
@MainActor enum SourceHighlightingScrollCheck {
    private struct Token {
        let range: NSRange
        let color: NSColor
    }

    private struct Fixture {
        let name: String
        var source = ""
        var tokens: [Token] = []
        var anchors: [Int] = []

        mutating func append(_ value: String, color: NSColor? = nil) {
            let range = NSRange(location: source.utf16.count, length: value.utf16.count)
            source += value
            if let color { tokens.append(Token(range: range, color: color)) }
        }
    }

    static func run(directory: URL) async throws -> Int {
        var json = Fixture(name: "快速滚动.json")
        json.append("[\n")
        for index in 0..<2_600 {
            json.anchors.append(json.source.utf16.count)
            json.append("  { ")
            json.append("\"field\(index)\"", color: .systemGreen)
            json.append(": ")
            json.append("\"中文📝 value\(index)\"", color: .systemBlue)
            json.append(", \"count\": ", color: nil)
            json.append("\(10_000 + index)", color: .systemPurple)
            json.append(index == 2_599 ? " }\n" : " },\n")
        }
        json.append("]\n")

        var yaml = Fixture(name: "快速滚动.yaml")
        for index in 0..<1_200 {
            yaml.anchors.append(yaml.source.utf16.count)
            yaml.append("field\(index)", color: .systemGreen)
            yaml.append(": |\n")
            yaml.append("  # 这里是多行正文\n  true 42 key: value\n  中文📝 第\(index)项\n", color: .systemBlue)
            yaml.append("count\(index)", color: .systemGreen)
            yaml.append(": ")
            yaml.append("\(10_000 + index)", color: .systemPurple)
            yaml.append("\n")
        }

        var jsonc = Fixture(name: "快速滚动.jsonc")
        jsonc.append("[\n")
        for index in 0..<600 {
            jsonc.append("/* 第\(index)项\n", color: .secondaryLabelColor)
            jsonc.anchors.append(jsonc.source.utf16.count)
            jsonc.append("  true 42 \"comment\"\n*/", color: .secondaryLabelColor)
            jsonc.append("\n")
            jsonc.append("{")
            jsonc.append("\"field\(index)\"", color: .systemGreen)
            jsonc.append(": ")
            jsonc.append("\"value\(index)\"", color: .systemBlue)
            jsonc.append(index == 599 ? "}\n" : "},\n")
        }
        jsonc.append("]\n")

        var xml = Fixture(name: "快速滚动.xml")
        xml.append("<root>\n")
        for index in 0..<600 {
            xml.append("<item", color: .systemGreen)
            xml.append(" ")
            xml.append("value", color: .systemGreen)
            xml.append("=")
            xml.append("\"first line\n", color: .systemBlue)
            xml.anchors.append(xml.source.utf16.count)
            xml.append("中文📝 value\(index)\nlast\"", color: .systemBlue)
            xml.append(">", color: .systemGreen)
            xml.append("正文\(index)", color: .systemBlue)
            xml.append("</item>", color: .systemGreen)
            xml.append("\n")
        }
        xml.append("</root>", color: .systemGreen)

        var checks = 0
        var scrollDurations: [Double] = []
        for fixture in [json, yaml, jsonc, xml] {
            guard fixture.source.utf8.count < 200_000 else {
                throw SmokeCheck.Failure(message: "滚动样例超出语法高亮大小限制")
            }
            let document = MarkdownDocument(snapshot: try FileSnapshot(data: Data(fixture.source.utf8)),
                url: directory.appendingPathComponent(fixture.name))
            document.session.mode = .read
            document.session.synchronizeSplitScroll = false
            document.makeWindowControllers()
            document.showWindows()
            defer { document.updateChangeCount(.changeCleared); document.close() }
            guard let window = document.windowControllers.first?.window, let root = window.contentView else {
                throw SmokeCheck.Failure(message: "滚动高亮检查缺少文档窗口")
            }
            window.setContentSize(NSSize(width: 980, height: 660))
            for mode in [ViewMode.read, .edit, .split] {
                document.session.mode = mode
                var editors: [NSTextView] = []
                for _ in 0..<100 {
                    editors = textViews(in: root).filter { $0.delegate is SourceEditor.Coordinator }
                    if editors.count == (mode == .split ? 2 : 1),
                       editors.allSatisfy({ $0.string == fixture.source && $0.visibleRect.height > 100 }) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard editors.count == (mode == .split ? 2 : 1) else {
                    throw SmokeCheck.Failure(message: "滚动高亮检查未挂载所需文本视图：\(fixture.name)，\(mode)")
                }
                for text in editors {
                    guard let scroll = text.enclosingScrollView, let layout = text.layoutManager,
                          let container = text.textContainer, let storage = text.textStorage else {
                        throw SmokeCheck.Failure(message: "滚动高亮检查缺少排版组件")
                    }
                    let originalSize = window.contentView?.frame.size ?? NSSize(width: 980, height: 660)
                    defer { window.setContentSize(originalSize) }
                    // 仅测试准备阶段排版全文，以获得确定的跳转位置；生产高亮仍使用局部排版。
                    layout.ensureLayout(for: container)
                    text.sizeToFit()
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(for: .milliseconds(150))
                    let original = NSAttributedString(attributedString: storage)
                    let last = fixture.anchors.count - 1
                    let stops = [last / 4, last * 3 / 4, last * 3 / 4 + 1, last, last / 8, last / 2, 0]
                    for stop in stops {
                        let glyph = layout.glyphIndexForCharacter(at: fixture.anchors[stop])
                        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                        let maximum = max(0, text.bounds.height - scroll.contentView.bounds.height)
                        let y = min(maximum, line.minY + text.textContainerInset.height)
                        let start = ProcessInfo.processInfo.systemUptime
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        window.displayIfNeeded()
                        scrollDurations.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                        try checkVisibleColors(fixture, text: text, context: "\(mode)，第\(stop)项")
                        checks += 1
                    }
                    guard text.string == fixture.source, !document.session.state.isDirty,
                          storage.isEqual(to: original) else {
                        throw SmokeCheck.Failure(message: "滚动着色修改了正文、保存状态或持久文字属性")
                    }
                    // 宽度改变会重新折行，不能复用原来的物理坐标覆盖范围。
                    window.setContentSize(NSSize(width: 720, height: 780))
                    root.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    let stop = fixture.anchors[last / 2]
                    layout.ensureLayout(forCharacterRange: NSRange(location: stop, length: 1))
                    let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: stop), effectiveRange: nil)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: line.minY + text.textContainerInset.height))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    window.displayIfNeeded()
                    try checkVisibleColors(fixture, text: text, context: "窗口变窄后")
                    checks += 1
                }
            }

            if fixture.name.hasSuffix(".json") {
                guard let editor = textViews(in: root).first(where: { $0.isEditable }),
                      let scroll = editor.enclosingScrollView else {
                    throw SmokeCheck.Failure(message: "编辑后高亮检查缺少源码编辑器")
                }
                let defaults = UserDefaults.standard
                let savedFont = defaults.object(forKey: "editorFontSize")
                defer {
                    if let savedFont { defaults.set(savedFont, forKey: "editorFontSize") }
                    else { defaults.removeObject(forKey: "editorFontSize") }
                }
                let fontSize = (editor.font?.pointSize ?? 14) + 3
                defaults.set(Double(fontSize), forKey: "editorFontSize")
                for _ in 0..<100 {
                    if editor.font?.pointSize == fontSize { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard editor.font?.pointSize == fontSize else {
                    throw SmokeCheck.Failure(message: "字号设置没有更新实际源码视图")
                }
                window.displayIfNeeded()
                try checkVisibleColors(fixture, text: editor, context: "字号变大后")
                checks += 1
                let range = (editor.string as NSString).range(of: "\"中文📝 value0\"")
                // 连续替换改变了正文长度，旧快照即使随后完成也不得回写。
                editor.insertText("false", replacementRange: range)
                editor.insertText("\"临时值\"", replacementRange: NSRange(location: range.location, length: 5))
                editor.insertText("true", replacementRange: NSRange(location: range.location, length: 5))
                try await Task.sleep(for: .milliseconds(150))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 20))
                scroll.reflectScrolledClipView(scroll.contentView)
                window.displayIfNeeded()
                for index in range.location..<(range.location + 4) {
                    guard editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                        effectiveRange: nil) as? NSColor == .systemPurple else {
                        throw SmokeCheck.Failure(message: "编辑后滚动复用了过期的字符串颜色")
                    }
                }
                guard document.session.state.isDirty, editor.undoManager?.canUndo == true else {
                    throw SmokeCheck.Failure(message: "滚动高亮破坏了编辑的未保存状态或撤销记录")
                }
                checks += 1
                // 只改变文件类型，正文修订号不变，也必须清掉旧语法颜色。
                document.fileURL = directory.appendingPathComponent("快速滚动.txt")
                try await Task.sleep(for: .milliseconds(150))
                for text in textViews(in: root) where text.delegate is SourceEditor.Coordinator {
                    guard text.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location,
                        effectiveRange: nil) == nil else {
                        throw SmokeCheck.Failure(message: "文件类型变为纯文本后仍保留旧快照颜色")
                    }
                    checks += 1
                }
            }
        }
        checks += try await cancelledSnapshotAndClose()
        let durations = scrollDurations.sorted()
        if !durations.isEmpty {
            print(String(format: "滚动到首帧显示检查：%d次，中位数%.2f毫秒，百分之九十五分位%.2f毫秒，最长%.2f毫秒",
                durations.count, durations[durations.count / 2], durations[min(durations.count - 1, durations.count * 95 / 100)], durations.last!))
        }
        return checks
    }

    private static func cancelledSnapshotAndClose() async throws -> Int {
        let cancelled = Task { @MainActor in
            SourceHighlighting.snapshot(in: "{\"field\": true}", kind: .json)
        }
        cancelled.cancel()
        guard await cancelled.value == nil else {
            throw SmokeCheck.Failure(message: "已取消的语法解析仍返回了快照")
        }

        weak var releasedSession: DocumentSession?
        weak var releasedCoordinator: SourceEditor.Coordinator?
        weak var releasedText: NSTextView?
        do {
            let source = String(repeating: "field: |\n  true 42 value\n", count: 6_000)
            let document = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)),
                url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("关闭解析.yaml"))
            let coordinator = SourceEditor.Coordinator(session: document.session)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
            let text = StatisticsTextView(frame: scroll.bounds)
            text.string = source
            scroll.documentView = text
            coordinator.textView = text
            coordinator.highlight()
            releasedSession = document.session
            releasedCoordinator = coordinator
            releasedText = text
            SourceEditor.dismantleNSView(scroll, coordinator: coordinator)
            document.close()
        }
        for _ in 0..<50 {
            if releasedSession == nil && releasedCoordinator == nil && releasedText == nil { return 2 }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SmokeCheck.Failure(message: "关闭视图后语法解析仍持有文档或文本视图")
    }

    private static func textViews(in root: NSView) -> [NSTextView] {
        (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap(textViews)
    }

    private static func checkVisibleColors(_ fixture: Fixture, text: NSTextView, context: String) throws {
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        var rect = text.visibleRect
        rect.origin.x -= text.textContainerInset.width
        rect.origin.y -= text.textContainerInset.height
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var checked = 0
        for token in fixture.tokens {
            let part = NSIntersectionRange(visible, token.range)
            for index in part.location..<NSMaxRange(part) {
                let color = layout.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
                guard color == token.color else {
                    throw SmokeCheck.Failure(message: "快速滚动出现未及时着色的文字：\(fixture.name)，\(context)，位置\(index)，实际\(String(describing: color))")
                }
                checked += 1
            }
        }
        guard checked > 0 else { throw SmokeCheck.Failure(message: "滚动检查未覆盖可见语法内容") }
    }
}
#endif
