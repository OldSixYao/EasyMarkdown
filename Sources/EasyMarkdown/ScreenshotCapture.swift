#if DEBUG
import AppKit
import WebKit
import EasyMarkdownCore

/// Captures only a dedicated sample window, never the desktop or personal documents.
@MainActor enum ScreenshotCapture {
    static func run(output: URL) async {
        var document: MarkdownDocument?
        let defaults = UserDefaults.standard
        let keys = ["appearance", "readerFontSize", "editorFontSize", "readerWidth", "remoteImages"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            defaults.set("light", forKey: "appearance")
            defaults.set(16, forKey: "readerFontSize")
            defaults.set(14, forKey: "editorFontSize")
            defaults.set(780, forKey: "readerWidth")
            defaults.set(false, forKey: "remoteImages")
            NSApp.appearance = NSAppearance(named: .aqua)
            let sample = """
            # EasyMarkdown

            安静阅读，随手修改。

            macOS 原生 Markdown 阅读与编辑工具。打开文件即可阅读，修改时切换到源码或分栏预览。

            ## 阅读与实时更新

            在其他编辑器中修改并保存，这里的内容会自动刷新，并尽量保持当前阅读位置。左侧大纲会高亮正在阅读的章节。

            > 本地有未保存修改时，外部更新不会覆盖你的编辑。

            ## 编辑与分栏预览

            使用顶部工具栏快速插入 **粗体**、*斜体*、标题、列表和代码。分栏模式支持双向同步滚动。

            - [x] 原生撤销与重做
            - [x] 清晰的未保存状态
            - [x] 随时切换阅读与编辑

            ## 文档格式

            | 格式 | 支持功能 |
            | --- | --- |
            | Markdown | 排版、大纲、源码、分栏预览 |
            | TXT | 纯文本查看与编辑 |
            | JSON / XML | 高亮、编辑、格式化 |

            ## 简单的代码示例

            ```swift
            let document = "EasyMarkdown"
            let liveReload = true
            print("安静阅读，随手修改。")
            ```

            ## 本地文件与隐私

            Markdown 渲染资源随应用打包，离线可用；远程图片默认关闭。本地文件由你掌控。
            """ + "\n"
            let file = output.appendingPathComponent("EasyMarkdown 示例.md")
            try await DraftStore.shared.remove(file)
            try Data(sample.utf8).write(to: file)
            let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(sample.utf8)), url: file)
            document = doc
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers(); doc.showWindows()
            guard let window = doc.windowControllers.first?.window else { throw CocoaError(.coderInvalidValue) }
            window.setContentSize(NSSize(width: 1100, height: 780))
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await waitForReader(window)
            doc.session.showOutline = true
            try await Task.sleep(for: .milliseconds(300))
            try await jump(window, to: "EasyMarkdown")
            try await capture(window, to: output.appendingPathComponent("reading-outline.png"))

            doc.session.showOutline = false
            doc.session.mode = .edit
            try await Task.sleep(for: .milliseconds(300))
            doc.session.replaceText?(sample.replacingOccurrences(of: "安静阅读，随手修改。", with: "安静阅读，随手修改。让文档回归简单。"))
            if let editor = descendants(window.contentView!).compactMap({ $0 as? NSTextView }).first {
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                editor.enclosingScrollView?.contentView.scroll(to: .zero)
            }
            try await capture(window, to: output.appendingPathComponent("editor-toolbar.png"))

            doc.session.mode = .split
            try await waitForReader(window)
            try await capture(window, to: output.appendingPathComponent("split-preview.png"))

            doc.session.mode = .read
            try await doc.session.performSave(to: file, operation: .saveOperation)
            defaults.set("dark", forKey: "appearance")
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try await waitForReader(window)
            try await jump(window, to: "文档格式")
            try await capture(window, to: output.appendingPathComponent("dark-reading.png"))
            doc.updateChangeCount(.changeCleared); doc.close()
            document = nil
            print("Captured four sample-window screenshots in \(output.path)")
        } catch {
            document?.updateChangeCount(.changeCleared); document?.close()
            print("Screenshot capture failed: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
    }

    private static func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    private static func waitForReader(_ window: NSWindow) async throws {
        for _ in 0..<100 {
            if let root = window.contentView, let web = descendants(root).compactMap({ $0 as? WKWebView }).first,
               (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "EasyMarkdown" {
                try await Task.sleep(for: .milliseconds(250))
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CocoaError(.coderInvalidValue)
    }
    private static func jump(_ window: NSWindow, to title: String) async throws {
        guard let root = window.contentView, let web = descendants(root).compactMap({ $0 as? WKWebView }).first else { return }
        _ = try await web.evaluateJavaScript("document.getElementById('\(title.lowercased())')?.scrollIntoView();true")
        try await Task.sleep(for: .milliseconds(200))
    }
    private static func capture(_ window: NSWindow, to file: URL) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        window.displayIfNeeded()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try process.run()
        // Do not block the UI while the compositor produces the window image.
        while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: file.path) else {
            throw NSError(domain: "ScreenshotCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to capture sample window. Screen recording permission may be required."])
        }
    }
}
#endif
