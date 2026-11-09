#if DEBUG
import AppKit
import WebKit
import EasyMarkdownCore

/// Runs in the actual application process, with a real window and WebKit renderer.
@MainActor enum SmokeCheck {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() async {
        let output = URL(fileURLWithPath: CommandLine.arguments.last ?? "/tmp/easymarkdown-smoke")
        var results: [String] = [] {
            didSet {
                if let last = results.last { FileHandle.standardError.write(Data(("CHECK: " + last + "\n").utf8)) }
            }
        }
        var document: MarkdownDocument?
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon",
                  let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                  let icon = NSImage(contentsOf: iconURL),
                  icon.representations.contains(where: { $0.pixelsWide >= 1024 }) else {
                throw Failure(message: "Packaged app icon is missing or invalid")
            }
            results.append("Packaged macOS icon is configured and includes a 1024-pixel representation")
            let about = AboutPanel.options()
            guard about[.applicationIcon] is NSImage,
                  about[.applicationVersion] as? String == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let credits = about[.credits] as? NSAttributedString else {
                throw Failure(message: "About panel is missing its app icon or version")
            }
            let repositoryRange = (credits.string as NSString).range(of: "github.com/OldSixYao/EasyMarkdown")
            guard repositoryRange.location != NSNotFound,
                  credits.attribute(.link, at: repositoryRange.location, effectiveRange: nil) as? URL == AboutPanel.repositoryURL else {
                throw Failure(message: "About panel repository is not a clickable link")
            }
            results.append("About panel includes the app icon, bundle version and clickable GitHub repository link")
            try SourceHighlightingCheck.run()
            results.append("各格式的字符串、注释、数值及行内代码互不覆盖，原生阅读和分栏预览高亮一致")
            (NSApp.delegate as? AppDelegate)?.showWelcome(nil)
            try await Task.sleep(for: .milliseconds(200))
            guard let welcome = NSApp.windows.first(where: { $0.title == "EasyMarkdown" }),
                  let welcomeContent = welcome.contentView,
                  welcomeContent.bounds.width >= 720, welcomeContent.bounds.height >= 560,
                  welcome.contentMinSize.width >= 640, welcome.contentMinSize.height >= 520,
                  welcome.styleMask.contains(.resizable) else {
                let dimensions = NSApp.windows.map { "\($0.title): content=\(String(describing: $0.contentView?.bounds.size)), minimum=\($0.contentMinSize), frame=\($0.frame.size)" }
                throw Failure(message: "Welcome window collapsed below its intended opening size: \(dimensions)")
            }
            if let bitmap = welcomeContent.bitmapImageRepForCachingDisplay(in: welcomeContent.bounds) {
                welcomeContent.cacheDisplay(in: welcomeContent.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: output.appendingPathComponent("welcome.png"))
                }
            }
            welcome.close()
            results.append("Welcome opens at 720 × 560 with a 640 × 520 minimum and supports resizing")
            try await EditorWorkspaceCheck.check(directory: output.appendingPathComponent("editor-workspace"))
            results.append("编辑行号按逻辑行显示并保留输入、撤销和局部排版；原生标签支持即时合并、拆分和关闭取消")
            results.append("底部统计在阅读与编辑中常驻，鼠标拖选实时更新实际文字，分栏跟随当前选区并保留大文件局部扫描")
            let url = output.appendingPathComponent("自动刷新 测试.md")
            let source = ("# First heading\n\nOriginal content\n\n[Reference link][guide]\n\n[guide]: https://example.com\n\n| 文档 | 状态 |\n| --- | --- |\n| Markdown | 可阅读 |\n\n- [x] 支持任务\n\n" +
                (1...50).map { "## Section \($0)\n\nParagraph \($0) 文档 📝\n\n" }.joined())
                .replacingOccurrences(of: "\n", with: "\r\n")
            try Data(source.utf8).write(to: url)
            let snapshot = try FileSnapshot(data: Data(source.utf8))
            let doc = MarkdownDocument(snapshot: snapshot, url: url)
            document = doc
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers(); doc.showWindows()
            NSApp.activate(ignoringOtherApps: true)
            guard let root = doc.windowControllers.first?.window?.contentView else { throw Failure(message: "No window") }
            var web: WKWebView?
            try await eventually {
                web = descendants(root).compactMap { $0 as? WKWebView }.first
                guard let web else { return false }
                return (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "First heading"
            }
            results.append("Markdown rendered in real WKWebView")
            guard let web else { throw Failure(message: "No reader") }
            doc.session.showOutline = true
            try await Task.sleep(for: .milliseconds(200))
            _ = try await web.evaluateJavaScript("window.scrollTo(0,0);updateActiveHeading();true")
            try await eventually(description: "Outline selects first heading") { doc.session.activeHeadingID == "first-heading" }
            doc.session.scrollTarget = "section-10"
            doc.session.scrollRequest += 1
            try await eventually(description: "Outline follows jump to section 10") { doc.session.activeHeadingID == "section-10" }
            guard (try await web.evaluateJavaScript("!!document.querySelector('table') && !!document.querySelector('input[type=checkbox]') && !!document.querySelector('a[href=\"https://example.com\"]')")) as? Bool == true else {
                throw Failure(message: "Source mapping broke GFM tables, tasks or reference links")
            }
            _ = try await web.evaluateJavaScript("document.getElementById('section-25').scrollIntoView()")
            try await eventually(description: "Outline follows scroll to section 25") { doc.session.activeHeadingID == "section-25" }
            results.append("Outline selection follows reading position and native heading jumps")
            try await Task.sleep(for: .milliseconds(350))
            let before = try await web.evaluateJavaScript("document.getElementById('section-25').getBoundingClientRect().top") as? Double ?? 0
            let updated = "# Updated heading\n\nNew paragraph inserted above.\n\n" + source
            let started = Date()
            try Data(updated.utf8).write(to: url, options: .atomic)
            try await eventually {
                (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "Updated heading"
            }
            let latency = Date().timeIntervalSince(started)
            try await Task.sleep(for: .milliseconds(150))
            let after = try await web.evaluateJavaScript("document.getElementById('section-25').getBoundingClientRect().top") as? Double ?? -999
            guard abs(before - after) < 5 else {
                let position = try await web.evaluateJavaScript("JSON.stringify(capturePosition())")
                throw Failure(message: "Reading position shifted \(before) -> \(after); \(String(describing: position))")
            }
            results.append(String(format: "External atomic replacement refreshed in %.3f seconds; reading anchor retained", latency))

            doc.session.showOutline = false
            try await Task.sleep(for: .milliseconds(100))
            doc.session.mode = .split
            try await eventually { doc.session.replaceText != nil }
            doc.session.replaceText?(updated + "\nLocal edit\n")
            guard doc.session.state.isDirty else { throw Failure(message: "Native editing did not mark document dirty") }
            guard doc.session.saveStateLabel == "未保存" else { throw Failure(message: "Dirty document did not show unsaved state") }
            guard let editor = descendants(root).compactMap({ $0 as? NSTextView }).first,
                  editor.undoManager?.canUndo == true else { throw Failure(message: "Native editing did not register undo") }
            try await eventually {
                guard let preview = descendants(root).compactMap({ $0 as? WKWebView }).first else { return false }
                return (try? await preview.evaluateJavaScript("document.getElementById('content').textContent.includes('Local edit')")) as? Bool == true
            }
            results.append("Split preview follows local edits without saving the original file")
            guard let splitReader = descendants(root).compactMap({ $0 as? WKWebView }).first,
                  let editorScroll = editor.enclosingScrollView,
                  let editorLayout = editor.layoutManager,
                  let editorContainer = editor.textContainer else {
                throw Failure(message: "Split scrolling views unavailable")
            }
            guard splitReader === web else { throw Failure(message: "Entering split view unnecessarily rebuilt the visible reader") }
            try await Task.sleep(for: .milliseconds(150))
            editorLayout.ensureLayout(for: editorContainer)
            let sourceRange = (editor.string as NSString).range(of: "## Section 32")
            let glyph = editorLayout.glyphIndexForCharacter(at: sourceRange.location)
            let sourceRect = editorLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            editorScroll.contentView.scroll(to: NSPoint(x: 0, y: sourceRect.minY + editor.textContainerInset.height))
            editorScroll.reflectScrolledClipView(editorScroll.contentView)
            try await eventually {
                guard let offset = (try? await splitReader.evaluateJavaScript("sourcePosition().offset")) as? Double else { return false }
                return abs(offset - Double(sourceRange.location)) < 12
            }
            try await eventually(description: "Outline matches the visible synchronized preview chapter") {
                guard let id = (try? await splitReader.evaluateJavaScript("lastActiveHeading")) as? String else { return false }
                return ["section-32", "section-33"].contains(id) && doc.session.activeHeadingID == id
            }
            _ = try await splitReader.evaluateJavaScript("document.getElementById('section-12').scrollIntoView()")
            let expected = (editor.string as NSString).range(of: "## Section 12").location
            try await eventually {
                let y = editorScroll.contentView.bounds.minY - editor.textContainerInset.height
                let firstGlyph = editorLayout.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: editorContainer)
                let offset = editorLayout.characterIndexForGlyph(at: min(firstGlyph, editorLayout.numberOfGlyphs - 1))
                return abs(offset - expected) < 65
            }
            let stableY = editorScroll.contentView.bounds.minY
            try await Task.sleep(for: .milliseconds(250))
            guard abs(editorScroll.contentView.bounds.minY - stableY) < 1 else {
                throw Failure(message: "Synchronized scroll produced a feedback loop")
            }
            doc.session.synchronizeSplitScroll = false
            _ = try await splitReader.evaluateJavaScript("document.getElementById('section-40').scrollIntoView()")
            try await Task.sleep(for: .milliseconds(180))
            guard abs(editorScroll.contentView.bounds.minY - stableY) < 1 else {
                throw Failure(message: "Disabled synchronization still scrolled the editor")
            }
            doc.session.synchronizeSplitScroll = true
            _ = try await splitReader.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight)")
            try await eventually {
                abs(editorScroll.contentView.bounds.maxY - editor.bounds.height) < 2
            }
            try await eventually(description: "Outline selects last heading at bottom") { doc.session.activeHeadingID == "section-50" }
            editorScroll.contentView.scroll(to: .zero)
            editorScroll.reflectScrolledClipView(editorScroll.contentView)
            try await eventually { ((try? await splitReader.evaluateJavaScript("scrollY")) as? Double ?? -1) < 1 }
            guard editor.window?.firstResponder === editor else { throw Failure(message: "Scroll synchronization stole editor focus") }
            results.append("Split scrolling works in both directions by source block, reaches top/bottom, avoids feedback and can be disabled")
            // These programmatic actions do not generate AppKit input events.
            // Wake the application event loop so AppKit can close its own undo
            // group before the next simulated toolbar click.
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: false)
            }
            try await eventually(description: "previous editing event closes its undo group") {
                editor.undoManager?.groupingLevel == 0
            }
            let beforeFormatting = doc.session.state.text
            let selection = (editor.string as NSString).range(of: "Local edit")
            editor.setSelectedRange(selection)
            doc.session.applyMarkdown?(.bold)
            try await eventually { doc.session.state.text.contains("**Local edit**") }
            try await Task.sleep(for: .milliseconds(30))
            guard (editor.string as NSString).substring(with: editor.selectedRange()) == "Local edit",
                  editor.window?.firstResponder === editor else {
                throw Failure(message: "Toolbar action lost selection or editor focus")
            }
            editor.undoManager?.undo()
            guard doc.session.state.text == beforeFormatting else {
                throw Failure(message: "Toolbar undo mismatch: before=\(beforeFormatting.utf8.count) after=\(doc.session.state.text.utf8.count) editor=\(editor.string.utf8.count) grouping=\(editor.undoManager?.groupingLevel ?? -1) tail=\(doc.session.state.text.suffix(60))")
            }
            editor.undoManager?.redo()
            guard doc.session.state.text.contains("**Local edit**") else { throw Failure(message: "Toolbar action did not redo") }
            editor.undoManager?.undo()
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            doc.session.applyMarkdown?(.codeBlock)
            guard doc.session.state.text.replacingOccurrences(of: "\r\n", with: "\n").contains("```\n代码\n```"),
                  (editor.string as NSString).substring(with: editor.selectedRange()) == "代码" else {
                throw Failure(message: "Code template did not select its editable placeholder")
            }
            editor.undoManager?.undo()
            guard doc.session.state.text == beforeFormatting else { throw Failure(message: "Code template undo lost content") }
            results.append("Markdown toolbar commands format native selections, retain focus, support undo/redo and insert editable code templates")
            let local = doc.session.state.text
            let external = "# External conflict\n\nAnother editor saved.\n"
            try Data(external.utf8).write(to: url, options: .atomic)
            try await eventually { doc.session.state.external?.text == external }
            guard doc.session.state.text == local else { throw Failure(message: "Local edit was overwritten") }
            do {
                try await doc.session.performSave(to: url, operation: .saveOperation)
                throw Failure(message: "Conflicted save unexpectedly succeeded")
            } catch DocumentError.externalChange {}
            guard doc.session.saveStateLabel == "保存失败 · 未保存", doc.session.saveFailure != nil else {
                throw Failure(message: "Failed save did not retain the unsaved failure state")
            }
            guard try String(contentsOf: url, encoding: .utf8) == external else { throw Failure(message: "Disk overwritten") }
            results.append("Native NSTextView edits register undo; external conflicts preserve local buffer and block stale save")

            let copy = output.appendingPathComponent("保留本地版本.md")
            try await doc.session.performSave(to: copy, operation: .saveAsOperation)
            guard try String(contentsOf: copy, encoding: .utf8) == local,
                  try String(contentsOf: url, encoding: .utf8) == external else { throw Failure(message: "Save As did not retain both files") }
            guard !doc.isDocumentEdited else { throw Failure(message: "Successful save remained dirty") }
            guard doc.session.saveStateLabel == "已保存", doc.session.saveFailure == nil else {
                throw Failure(message: "Successful save did not clear its error and show saved state")
            }
            results.append("Save state distinguishes unsaved edits, failed saves and successfully saved contents")
            results.append("Save As preserves both files and clears document dirty state")

            doc.session.mode = .read
            try await eventually {
                !descendants(root).contains { $0 is NSTextView } && descendants(root).contains { $0 is WKWebView }
            }
            guard let reader = descendants(root).compactMap({ $0 as? WKWebView }).first else { throw Failure(message: "Reader missing") }
            try await eventually { (try? await reader.evaluateJavaScript("typeof window.updateDocument")) as? String == "function" }
            let untrusted = "# Safety\n\n<img src=x onerror=\"window.injected=true\"><script>window.injected=true</script><iframe src=\"https://example.com\"></iframe>\n\n![remote](https://example.com/tracker.png)\n\n```json\n{\"model\":\"gpt-image-2.6-sunburst\",\"text\":\"true null 42\",\"count\":-2.6e+10,\"ok\":true}\n```"
            try Data(untrusted.utf8).write(to: copy, options: .atomic)
            try await eventually { (try? await reader.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "Safety" }
            let safe = try await reader.evaluateJavaScript("!window.injected && !document.querySelector('#content script, #content iframe, #content [onerror]') && !!document.querySelector('.image-placeholder') && !!document.querySelector('.hljs-attr')") as? Bool
            guard safe == true else { throw Failure(message: "Sanitization, remote-image default or syntax highlighting failed") }
            let codeColors = try await reader.evaluateJavaScript(#"""
            (() => {
              const block = document.querySelector('pre code.language-json');
              const strings = [...block.querySelectorAll('.hljs-string')];
              return ['"gpt-image-2.6-sunburst"', '"true null 42"'].every(value =>
                strings.some(node => node.textContent === value && node.children.length === 0)) &&
                block.querySelector('.hljs-number')?.textContent === '-2.6e+10' &&
                getComputedStyle(block.querySelector('.hljs-attr')).color !== getComputedStyle(strings[0]).color;
            })()
            """#) as? Bool
            guard codeColors == true else { throw Failure(message: "排版阅读的代码块错误拆分了字符串或数值颜色") }
            results.append("Untrusted HTML sanitized; remote images blocked by default; code highlighted")

            try await codeCopyProbe(reader: reader, document: doc, file: copy, output: output)
            results.append("Code copy writes exact inline, fenced, indented and empty text to the native clipboard; linked code does not navigate")
            results.append("Copy controls support focus, feedback, dark/light and narrow layouts, fixed block buttons, incremental reuse and split preview")

            let image = NSImage(size: NSSize(width: 10, height: 10))
            image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 10, height: 10).fill(); image.unlockFocus()
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: output.appendingPathComponent("图片 测试.png"))
            try Data("# Local image\n\n![本地](图片%20测试.png)\n".utf8).write(to: copy, options: .atomic)
            do {
                try await eventually { ((try? await reader.evaluateJavaScript("document.querySelector('img')?.naturalWidth")) as? Int ?? 0) > 0 }
            } catch {
                let html = try? await reader.evaluateJavaScript("document.getElementById('content').innerHTML")
                throw Failure(message: "Local image failed: \(String(describing: html))")
            }
            results.append("Local relative image with Unicode and spaces loads through restricted resource handler")

            try await Task.sleep(for: .milliseconds(150))
            let imageSnapshot = try await reader.takeSnapshot(configuration: nil)
            if let tiff = imageSnapshot.tiffRepresentation,
               let representation = NSBitmapImageRep(data: tiff),
               let data = representation.representation(using: .png, properties: [:]) {
                try data.write(to: output.appendingPathComponent("reader.png"))
            }
            try FileManager.default.removeItem(at: copy)
            try await eventually { doc.session.state.isMissing }
            guard doc.session.state.text.contains("Local image") else { throw Failure(message: "Deletion discarded content") }
            results.append("Deletion retains displayed content")
            // Simulate a recoverable draft alongside a changed on-disk version.
            let recovery = RecoveryDraft(baseline: Data("old baseline".utf8), text: "recover my unsaved edit", savedAt: Date())
            try await DraftStore.shared.save(recovery, for: url)
            let recoveredDoc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(external.utf8)), url: url)
            NSDocumentController.shared.addDocument(recoveredDoc)
            recoveredDoc.makeWindowControllers()
            try await eventually { recoveredDoc.session.recovery != nil }
            recoveredDoc.session.restoreDraft()
            guard recoveredDoc.session.state.text == recovery.text,
                  recoveredDoc.session.state.external?.text == external,
                  recoveredDoc.isDocumentEdited else { throw Failure(message: "Recovery did not retain the draft and disk conflict") }
            recoveredDoc.updateChangeCount(.changeCleared); recoveredDoc.close()
            results.append("Recovery restores unsaved draft and detects a changed disk version")

            let sample = "# EasyMarkdown\n\n安静阅读，随手修改。\n\n## 自动跟随文件更新\n\n在其他编辑器中修改并保存，文档会自动刷新，尽量保持当前阅读位置。\n\n> 阅读为主，偶尔修改。外部版本不会覆盖尚未保存的本地内容。\n\n## 常用格式\n\n| 文档 | 阅读与编辑 |\n| --- | --- |\n| Markdown | 排版、大纲、分栏预览 |\n| TXT | 纯文本阅读和编辑 |\n| JSON / XML | 高亮与格式化 |\n\n```json\n{\"name\": \"EasyMarkdown\", \"liveReload\": true}\n```\n"
            try Data(sample.utf8).write(to: copy, options: .atomic)
            try await eventually { (try? await reader.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "EasyMarkdown" }
            _ = try await reader.evaluateJavaScript("window.scrollTo(0,0)")
            try await Task.sleep(for: .milliseconds(100))
            let sampleSnapshot = try await reader.takeSnapshot(configuration: nil)
            if let tiff = sampleSnapshot.tiffRepresentation,
               let representation = NSBitmapImageRep(data: tiff),
               let data = representation.representation(using: .png, properties: [:]) {
                try data.write(to: output.appendingPathComponent("preview.png"))
            }
            doc.updateChangeCount(.changeCleared)
            doc.close()
            document = nil
            let closedSession = try await closeLifecycleProbe(directory: output)
            try await eventually { closedSession.value == nil }
            results.append("Closing releases the session; visible panes are reused; typing renders are coalesced; large preview transfer is capped")
            results.append("Incremental rendering retains unchanged nodes, updates reference links and filters raw images; syntax colors remain temporary")
            try await searchProbe(directory: output)
            results.append("Reader search count and bidirectional navigation share visible text matches, ignore controls, survive reloads and preserve native input focus")
            results.append("Native replace opens with the reader query, supports single/all/empty replacements and undo; search shortcuts route correctly in read/edit/split modes")
            try await localizationProbe(directory: output)
            results.append("Packaged app selects Simplified Chinese; native replace, file panels and unsaved close/quit prompts are Chinese with cancel/save/discard preserved")
            try await defaultEditorProbe()
            results.append("Default editor reads system state, scopes changes to the selected type, verifies results and handles failure without changing real associations in tests")
            try await PerformanceSafetyCheck.run(directory: output)
            results.append("Bounded highlighting/layout, asynchronous formatting undo/cancellation, duplicate headings and reusable search indexes pass")
            try await MemorySafetyCheck.run(directory: output)
            results.append("Closed sessions release while reload/draft I/O is blocked; cancelled drafts stay discarded; small and large document undo histories evict old groups")
            try await LightweightCheck.run(directory: output)
            results.append("Incremental native edits, cached clean undo, shared targeted monitoring, atomic split/legacy drafts, continuous recovery, image budgets/eviction and sleeping readers preserve content and state")
            try await ConfigurationCheck.documents(directory: output)
            results.append("YAML/TOML/INI/CONF/CFG/CNF/ENV/Properties/JSONC use native highlighted read-only text with native search and split editing, preserving comments, BOM and CRLF")
            try await ConfigurationCheck.associations()
            results.append("Configuration defaults are explicit and scoped to the selected format, with stable Finder types and extension aliases; dotenv variants do not claim .local files")
            try await ConfigurationCheck.customExtensions(directory: output)
            results.append("Every default-editor row reflects system state; custom extensions validate, deduplicate and persist, set only the selected type, and remove without changing defaults")
            let report = ["status": "passed", "checks": results] as [String: Any]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("report.json"))
            print("PASS: app smoke checks\n" + results.joined(separator: "\n"))
            NSApp.terminate(nil)
        } catch {
            let report: [String: Any] = ["status": "failed", "checks": results, "error": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("report.json"))
            }
            print("FAIL: \(error)")
            document?.updateChangeCount(.changeCleared)
            document?.close()
            exit(1)
        }
    }

    private static func eventually(description: String = "application update", _ condition: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(message: "Timed out waiting for \(description)")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func readerScript(_ reader: WKWebView, _ script: String, arguments: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            reader.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) {
                continuation.resume(with: $0)
            }
        }
    }

    private static func searchProbe(directory: URL) async throws {
        let appearance = UserDefaults.standard.object(forKey: "appearance")
        let appAppearance = NSApp.appearance
        defer {
            if let appearance { UserDefaults.standard.set(appearance, forKey: "appearance") }
            else { UserDefaults.standard.removeObject(forKey: "appearance") }
            NSApp.appearance = appAppearance
        }
        let findPasteboard = NSPasteboard(name: .find)
        let savedFind = (findPasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            findPasteboard.clearContents()
            if !savedFind.isEmpty { findPasteboard.writeObjects(savedFind) }
        }
        let url = directory.appendingPathComponent("search.md")
        let source = "# Search checks\n\nAlpha alpha ALPHA\n\n中**文** 与 [链接](https://example.com/alpha)\n\n`alpha <&> .* [x]`\n\n```text\nalpha\n  中文\n```\n\nfoo\n\nbar\n\n<span hidden>alpha 隐藏</span>\n\naaaa\n"
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)), url: url)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers(); doc.showWindows()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        guard let window = doc.windowControllers.first?.window, let root = window.contentView else {
            throw Failure(message: "Search test has no window")
        }
        var reader: WKWebView?
        try await eventually(description: "search fixture renders") {
            reader = descendants(root).compactMap { $0 as? WKWebView }.first
            guard let reader else { return false }
            return (try? await reader.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "Search checks"
        }
        guard let reader else { throw Failure(message: "Search fixture has no reader") }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        doc.session.showSearch()
        doc.session.search = "alpha"
        try await eventually(description: "five visible alpha matches") { doc.session.searchResultCount == 5 }
        guard (try await reader.evaluateJavaScript("readerSearch.index===0 && readerSearch.range.toString()==='Alpha'")) as? Bool == true else {
            throw Failure(message: "Search did not select the first literal match")
        }
        let focus = window.firstResponder
        let menu = NSApp.mainMenu?.items.first { $0.title == "编辑" }?.submenu
        guard let next = menu?.items.first(where: { $0.title == "查找下一个" }),
              let previous = menu?.items.first(where: { $0.title == "查找上一个" }),
              let replace = menu?.items.first(where: { $0.title == "查找并替换…" }),
              previous.keyEquivalentModifierMask == [.command, .shift],
              replace.keyEquivalentModifierMask == [.command, .option] else {
            throw Failure(message: "Find menu commands or key equivalents missing")
        }
        func invoke(_ item: NSMenuItem) async throws {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await eventually(description: "search document becomes the native menu target") {
                NSApp.keyWindow === window && NSDocumentController.shared.currentDocument === doc
            }
            guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else {
                throw Failure(message: "Find menu action was not delivered: \(item.title)")
            }
        }
        try await invoke(previous)
        try await eventually(description: "previous wraps to last match") {
            (try? await reader.evaluateJavaScript("readerSearch.index")) as? Int == 4
        }
        try await invoke(next)
        try await eventually(description: "next wraps to first match") {
            (try? await reader.evaluateJavaScript("readerSearch.index")) as? Int == 0
        }
        for index in 1...4 {
            doc.session.navigateSearch()
            try await eventually(description: "counted match \(index) is navigable") {
                (try? await reader.evaluateJavaScript("readerSearch.index")) as? Int == index
            }
        }
        doc.session.navigateSearch()
        doc.session.navigateSearch()
        doc.session.navigateSearch(backwards: true)
        try await eventually(description: "coalesced opposite navigation retains net movement") {
            (try? await reader.evaluateJavaScript("readerSearch.index")) as? Int == 0
        }
        guard window.firstResponder === focus else { throw Failure(message: "Reader search navigation stole search field focus") }
        for (query, count) in [("中文", 2), ("foo bar", 0), ("foo\nbar", 0), ("aa", 2), (".* [x]", 1), ("复制代码", 0), ("隐藏", 0), ("不存在", 0)] {
            doc.session.search = query
            try await eventually(description: "visible match count for \(query)") { doc.session.searchResultCount == count }
        }
        doc.session.search = "中文"
        try await eventually { doc.session.searchResultCount == 2 }
        guard (try await reader.evaluateJavaScript("readerSearch.range.toString()==='中文' && readerSearch.range.startContainer!==readerSearch.range.endContainer")) as? Bool == true else {
            throw Failure(message: "Inline emphasis broke a visible text match")
        }
        doc.session.search = "alpha"
        doc.session.search = "aa"
        doc.session.search = "链接"
        try await eventually(description: "latest rapid query wins") { doc.session.searchResultCount == 1 }
        doc.session.closeSearch()
        try await eventually(description: "closing clears ranges and count") {
            guard doc.session.searchResultCount == nil else { return false }
            return (try? await reader.evaluateJavaScript("readerSearch.count===0 && !readerSearch.range")) as? Bool == true
        }
        doc.session.showSearch()
        doc.session.search = "alpha"
        try await eventually { doc.session.searchResultCount == 5 }
        let changed = source.replacingOccurrences(of: "Alpha alpha ALPHA", with: "alpha")
        try Data(changed.utf8).write(to: url, options: .atomic)
        try await eventually(description: "external refresh recounts search") { doc.session.searchResultCount == 3 }
        guard (try await reader.evaluateJavaScript("readerSearch.index")) as? Int == 0 else { throw Failure(message: "Refresh did not reset the current match") }

        // Direct DOM cases also exercise the selection fallback and clipped preview count.
        let edgeCases = try await readerScript(reader, #"""
            const prefs={fontSize:16,width:780,appearance:'system',remoteImages:false};
            window.updateDocument('line  one\nnext **word**\n\n<code>top</code>','markdown','file:///',prefs,{});
            const space=window.updateReaderSearch('line one next word',false,0).count===1;
            window.updateDocument('prefix '.repeat(71429),'markdown','file:///',prefs,{});
            const clipped=window.updateReaderSearch('prefix',false,0);
            const truncated=clipped.truncated && clipped.count===71428;
            window.updateDocument('fallback fallback','text','file:///',prefs,{});
            const descriptor=Object.getOwnPropertyDescriptor(globalThis,'Highlight');
            Object.defineProperty(globalThis,'Highlight',{value:undefined,configurable:true});
            window.updateReaderSearch('fallback',false,0);
            const fallback=readerSearch.selection && getSelection().toString()==='fallback';
            window.updateReaderSearch('',false,0);
            const cleared=!getSelection().rangeCount;
            if(descriptor) Object.defineProperty(globalThis,'Highlight',descriptor);
            else delete globalThis.Highlight;
            return {space,truncated,fallback,cleared};
            """#)
        guard let edge = edgeCases as? [String: Bool], edge.values.allSatisfy({ $0 }) else {
            throw Failure(message: "Search whitespace/truncation/fallback checks failed: \(edgeCases)")
        }
        // Restore through the real document renderer before entering native replace.
        try Data(source.utf8).write(to: url, options: .atomic)
        try await eventually(description: "search fixture restores") {
            guard doc.session.searchResultCount == 5 else { return false }
            return (try? await reader.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "Search checks"
        }
        doc.session.search = "alpha"
        window.setContentSize(NSSize(width: 620, height: 520))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            UserDefaults.standard.set(name, forKey: "appearance")
            NSApp.appearance = NSAppearance(named: appearance)
            try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("search-\(name).png"))
        }
        let clipboardChange = NSPasteboard.general.changeCount
        try await invoke(replace)
        var editor: NSTextView?
        try await eventually(description: "native replace bar opens after editor mounts") {
            editor = descendants(root).compactMap { $0 as? NSTextView }.first { $0.delegate is SourceEditor.Coordinator }
            return editor?.enclosingScrollView?.isFindBarVisible == true && doc.session.pendingEditorFind == nil
        }
        guard let editor, let scroll = editor.enclosingScrollView, let bar = scroll.findBarView else {
            throw Failure(message: "Native replace bar missing")
        }
        let fields = descendants(bar).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        let findButtons = descendants(bar).flatMap { view -> [String] in
            if let button = view as? NSButton { return [button.title] }
            if let segments = view as? NSSegmentedControl {
                return (0..<segments.segmentCount).compactMap { segments.label(forSegment: $0) }
            }
            return []
        }
        guard findButtons.contains("替换"), findButtons.contains("全部"), findButtons.contains("完成") else {
            throw Failure(message: "Native find/replace controls are not Chinese: \(findButtons)")
        }
        guard fields.count >= 2, let findField = fields.first(where: { $0.stringValue == "alpha" }),
              let replacementField = fields.first(where: { $0 !== findField }) else {
            throw Failure(message: "Native replacement did not receive reader query: \(fields.map { "\(type(of: $0))=\($0.stringValue)" })")
        }
        guard doc.session.mode == .edit, editor.string == source, !doc.session.state.isDirty,
              NSPasteboard.general.changeCount == clipboardChange else {
            throw Failure(message: "Entering replace changed document content or the general clipboard")
        }
        try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("native-replace.png"))
        func setField(_ field: NSTextField, value: String) throws {
            window.makeFirstResponder(field)
            guard let fieldEditor = field.currentEditor() as? NSTextView else { throw Failure(message: "Native find field has no editor") }
            fieldEditor.selectAll(nil)
            fieldEditor.insertText(value, replacementRange: NSRange(location: 0, length: (fieldEditor.string as NSString).length))
            window.makeFirstResponder(editor)
        }
        try setField(replacementField, value: "替换<&>")
        // Committing the field editor posts native find-bar notifications.
        // Deliver them before issuing the next simulated menu action.
        try await Task.sleep(for: .milliseconds(100))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await invoke(next)
        do {
            try await eventually(description: "native next selects source match") { editor.selectedRange().length == 5 }
        } catch {
            throw Failure(message: "Native next failed: range=\(editor.selectedRange()) query=\(findField.stringValue) replacement=\(replacementField.stringValue) request=\(doc.session.findRequest) pending=\(String(describing: doc.session.pendingEditorFind?.action.rawValue)) currentDocument=\(NSDocumentController.shared.currentDocument === doc) keyWindow=\(NSApp.keyWindow === window)")
        }
        let first = editor.selectedRange()
        try await invoke(next)
        try await eventually { editor.selectedRange().location > first.location }
        try await invoke(previous)
        try await eventually { editor.selectedRange() == first }
        try await Task.sleep(for: .milliseconds(50))
        doc.session.requestEditorFind(.replace)
        try await eventually(description: "native single replace updates buffer and statistics") {
            doc.session.state.text.contains("替换<&>") &&
                doc.session.editorStatistics.total == DocumentStatisticsIndex(doc.session.state.text as NSString).total
        }
        guard doc.session.state.isDirty, try String(contentsOf: url, encoding: .utf8) == source else {
            throw Failure(message: "Single replace was saved automatically or failed to mark dirty")
        }
        try await Task.sleep(for: .milliseconds(50))
        editor.undoManager?.undo()
        try await eventually(description: "single replace undo") { doc.session.state.text == source }
        try await Task.sleep(for: .milliseconds(50))
        editor.undoManager?.redo()
        try await eventually { doc.session.state.text.contains("替换<&>") }
        try await Task.sleep(for: .milliseconds(50))
        editor.undoManager?.undo()
        try await eventually { doc.session.state.text == source }
        try await Task.sleep(for: .milliseconds(50))
        doc.session.requestEditorFind(.replaceAll)
        try await eventually(description: "native replace all and statistics") {
            !doc.session.state.text.lowercased().contains("alpha") &&
                doc.session.editorStatistics.total == DocumentStatisticsIndex(doc.session.state.text as NSString).total
        }
        guard doc.session.state.text.components(separatedBy: "替换<&>").count - 1 == 7 else {
            throw Failure(message: "Native replace all did not include Markdown source/hidden matches")
        }
        try await Task.sleep(for: .milliseconds(50))
        editor.undoManager?.undo()
        try await eventually(description: "replace all undo and statistics") {
            doc.session.state.text == source && doc.session.editorStatistics.total == DocumentStatisticsIndex(source as NSString).total
        }
        try setField(findField, value: "中文")
        try setField(replacementField, value: "")
        try await Task.sleep(for: .milliseconds(50))
        doc.session.requestEditorFind(.replaceAll)
        try await eventually(description: "empty replacement removes literal source matches and updates statistics") {
            !doc.session.state.text.contains("中文") &&
                doc.session.editorStatistics.total == DocumentStatisticsIndex(doc.session.state.text as NSString).total
        }
        guard doc.session.state.text.contains("中**文**") else { throw Failure(message: "Source replacement unexpectedly matched across Markdown marks") }
        try await Task.sleep(for: .milliseconds(50))
        editor.undoManager?.undo()
        try await eventually { doc.session.state.text == source }
        try setField(findField, value: "no such result")
        doc.session.requestEditorFind(.replaceAll)
        guard doc.session.state.text == source else { throw Failure(message: "No-match replacement modified document") }
        try setField(findField, value: "alpha")
        doc.session.mode = .split
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await invoke(next)
        try await eventually(description: "split next targets native editor") { editor.selectedRange().length == 5 }
        let splitFirst = editor.selectedRange()
        try await invoke(next)
        try await eventually { editor.selectedRange().location > splitFirst.location }
        try await invoke(previous)
        try await eventually { editor.selectedRange() == splitFirst }
        try setField(replacementField, value: "分栏替换")
        try await Task.sleep(for: .milliseconds(50))
        doc.session.requestEditorFind(.replace)
        try await eventually(description: "split replace updates preview") {
            guard let preview = descendants(root).compactMap({ $0 as? WKWebView }).first else { return false }
            return (try? await preview.evaluateJavaScript("content.textContent.includes('分栏替换')")) as? Bool == true
        }
        try await doc.session.performSave(to: url, operation: .saveOperation)
        guard !doc.session.state.isDirty, try String(contentsOf: url, encoding: .utf8) == doc.session.state.text else {
            throw Failure(message: "Saving replacement failed")
        }
        doc.session.mode = .read
        try await eventually { !descendants(root).contains { ($0 as? NSTextView)?.delegate is SourceEditor.Coordinator } }
        doc.session.showReplace()
        try await eventually(description: "reopening replace consumes pending request") {
            guard let editor = descendants(root).compactMap({ $0 as? NSTextView }).first(where: { $0.delegate is SourceEditor.Coordinator }) else { return false }
            return editor.enclosingScrollView?.isFindBarVisible == true && doc.session.pendingEditorFind == nil
        }
    }

    private final class CloseDecision: NSObject {
        var result: Bool?
        @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
            result = shouldClose
        }
        @objc func controller(_ controller: NSDocumentController, didCloseAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
            result = didCloseAll
        }
    }

    private static func defaultEditorProbe() async throws {
        let application = URL(fileURLWithPath: "/Applications/EasyMarkdown.app")
        let other = URL(fileURLWithPath: "/Applications/Other.app")
        var defaults: [String: URL] = [:]
        var requests: [String] = []
        let model = DefaultEditorSettings(applicationURL: application,
            query: { defaults[$0.identifier] ?? other },
            set: { app, type in requests.append(type.identifier); defaults[type.identifier] = app }, canSet: { true })
        guard requests.isEmpty, model.format == .markdown, !model.isDefault else {
            throw Failure(message: "Default editor modified associations on initialization")
        }
        await model.makeDefault()
        guard model.isDefault, model.errorMessage == nil, !model.isSetting,
              requests == ["net.daringfireball.markdown"] else {
            throw Failure(message: "Markdown default application was not scoped/verified")
        }
        model.format = .json
        guard !model.isDefault, requests.count == 1 else { throw Failure(message: "Changing file type modified associations or retained stale status") }
        await model.makeDefault()
        guard requests == ["net.daringfireball.markdown", "public.json"], model.isDefault else {
            throw Failure(message: "JSON selection changed the wrong default application")
        }
        model.format = .markdown
        guard model.isDefault else { throw Failure(message: "Returning to Markdown did not query system state") }
        defaults["net.daringfireball.markdown"] = other
        model.refresh()
        guard !model.isDefault else { throw Failure(message: "External default application change was not reflected") }
        let failure = DefaultEditorSettings(applicationURL: application, query: { _ in other },
            set: { _, _ in throw CocoaError(.userCancelled) }, canSet: { true })
        await failure.makeDefault()
        guard !failure.isSetting, !failure.isDefault, failure.errorMessage != nil else {
            throw Failure(message: "Default editor cancellation claimed success or blocked retry")
        }
        let unchanged = DefaultEditorSettings(applicationURL: application, query: { _ in other },
            set: { _, _ in }, canSet: { true })
        await unchanged.makeDefault()
        guard !unchanged.isDefault, unchanged.errorMessage != nil else { throw Failure(message: "Unconfirmed default application change claimed success") }
        let unavailable = DefaultEditorSettings(applicationURL: application, query: { _ in nil },
            set: { _, type in requests.append(type.identifier) }, canSet: { false })
        let before = requests
        await unavailable.makeDefault()
        guard requests == before, unavailable.errorMessage != nil else { throw Failure(message: "Uninstalled/readonly application attempted to change defaults") }
        guard let types = Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]],
              let markdown = types.first(where: { $0["UTTypeIdentifier"] as? String == "net.daringfireball.markdown" }),
              let tags = markdown["UTTypeTagSpecification"] as? [String: Any],
              tags["public.filename-extension"] as? [String] == ["md", "markdown", "mdown", "mkd"] else {
            throw Failure(message: "Markdown aliases are missing from the imported type declaration")
        }
    }

    private static func localizationProbe(directory: URL) async throws {
        guard Bundle.main.developmentLocalization == "en",
              Set(Bundle.main.localizations).isSuperset(of: ["zh-Hans", "zh-Hant", "en"]),
              Bundle.main.preferredLocalizations.first == "zh-Hans",
              Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: "zh-Hans.lproj") != nil else {
            throw Failure(message: "Main app bundle has no active Simplified Chinese localization: \(Bundle.main.preferredLocalizations)")
        }
        let open = NSOpenPanel()
        let save = NSSavePanel()
        guard open.prompt == "打开", ["存储", "保存"].contains(save.prompt) else {
            throw Failure(message: "Native file panel prompts are not Chinese: \(open.prompt ?? "nil"), \(save.prompt ?? "nil")")
        }
        let file = directory.appendingPathComponent("中文保存提示.md")
        let original = "# 未修改的磁盘内容\n"
        try Data(original.utf8).write(to: file)
        let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(original.utf8)), url: file)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers(); doc.showWindows()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        guard let window = doc.windowControllers.first?.window else { throw Failure(message: "Localization window missing") }
        window.makeKeyAndOrderFront(nil)
        doc.session.edit("# 需要保存的修改\n")
        let decision = CloseDecision()
        for action in ["取消", "退出取消", "存储", "不存储"] {
            decision.result = nil
            if action == "退出取消" {
                // The same close-all path used by applicationShouldTerminate, without terminating the test process.
                NSDocumentController.shared.closeAllDocuments(withDelegate: decision,
                    didCloseAllSelector: #selector(CloseDecision.controller(_:didCloseAll:contextInfo:)), contextInfo: nil)
            } else {
                doc.canClose(withDelegate: decision,
                    shouldClose: #selector(CloseDecision.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            }
            try await eventually(description: "Chinese unsaved changes sheet") { window.attachedSheet != nil }
            guard let sheet = window.attachedSheet, let view = sheet.contentView else { throw Failure(message: "Save sheet has no content") }
            let buttons = descendants(view).compactMap { $0 as? NSButton }
            let titles = buttons.map(\.title)
            guard titles.contains("取消"), titles.contains(where: { ["存储", "保存"].contains($0) }),
                  titles.contains(where: { ["不存储", "不保存"].contains($0) }) else {
                throw Failure(message: "Unsaved changes buttons are not Chinese: \(titles)")
            }
            let message = descendants(view).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: " ")
            guard message.contains("修改") || message.contains("更改") else {
                throw Failure(message: "Unsaved changes message is not Chinese: \(message)")
            }
            if action == "取消" {
                try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("save-confirmation-zh.png"))
            }
            let choices = action == "退出取消" ? ["取消"] : action == "存储" ? ["存储", "保存"] : action == "不存储" ? ["不存储", "不保存"] : ["取消"]
            guard let button = buttons.first(where: { choices.contains($0.title) }) else { throw Failure(message: "Save action not found") }
            button.performClick(nil)
            try await eventually(description: "localized save decision completes") { decision.result != nil && window.attachedSheet == nil }
            if action.contains("取消") {
                guard decision.result == false, doc.isDocumentEdited,
                      try String(contentsOf: file, encoding: .utf8) == original else {
                    throw Failure(message: "Cancel did not preserve the unsaved document")
                }
            } else if action == "存储" {
                guard decision.result == true, !doc.isDocumentEdited,
                      try String(contentsOf: file, encoding: .utf8) == doc.session.state.text else {
                    throw Failure(message: "Localized save did not save the edited text")
                }
                doc.session.edit("# 放弃本次修改\n")
            } else {
                guard decision.result == true,
                      try String(contentsOf: file, encoding: .utf8) == "# 需要保存的修改\n" else {
                    throw Failure(message: "Localized discard overwrote the saved file")
                }
            }
        }
    }

    private static func codeCopyProbe(reader: WKWebView, document: MarkdownDocument, file: URL, output: URL) async throws {
        // Restore every available clipboard representation after the native copy checks.
        let clipboard = NSPasteboard.general
        let savedItems = (clipboard.pasteboardItems ?? []).map { item in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        }
        defer {
            clipboard.clearContents()
            if !savedItems.isEmpty { clipboard.writeObjects(savedItems) }
        }
        let inline = #"中文 <&> "引号" \路径 $(test) ${value}"#
        let fenced = "const 文本 = \"<&> 中文\";\n\tconsole.log(文本);\n// " + String(repeating: "long ", count: 80) + "\n"
        let longInline = String(repeating: "长代码", count: 100)
        let source = "# Copy `标题`\n\n正文 `" + inline + "`。\n\n[`链接代码`](https://example.com/copy-must-not-open)\n\n`" + longInline + "`\n\n可更新段落\n\n```javascript\n" + fenced + "```\n\n    缩进代码 <&>\n        保留空格\n\n```\n```\n"
        try Data(source.utf8).write(to: file, options: .atomic)
        try await eventually(description: "copy buttons render") {
            (try? await reader.evaluateJavaScript("document.querySelectorAll('.code-copy-button').length")) as? Int == 7
        }
        guard (try await reader.evaluateJavaScript("[...document.querySelectorAll('.code-copy-button')].every(b=>getComputedStyle(b).opacity==='0' && b.tabIndex===0 && b.getAttribute('aria-label')==='复制代码')")) as? Bool == true else {
            throw Failure(message: "Copy controls are not hidden, labelled and keyboard focusable")
        }
        guard document.session.headings.first?.title == "Copy 标题",
              !document.session.state.isDirty else { throw Failure(message: "Copy controls changed headings or document state") }
        _ = try await reader.evaluateJavaScript("window.__copyHeading=document.querySelector('h1');window.__copyBlock=document.querySelector('pre');window.__copyButton=document.querySelector('pre>.code-copy-button');true")
        let cases = [
            ("h1 .code-copy-button", "标题"),
            ("p .code-copy-button", inline),
            ("a .code-copy-button", "链接代码"),
            ("pre:nth-of-type(1)>.code-copy-button", fenced),
            ("pre:nth-of-type(2)>.code-copy-button", "缩进代码 <&>\n    保留空格\n"),
            // marked renders even an empty fenced block with a final newline.
            ("pre:nth-of-type(3)>.code-copy-button", "\n")
        ]
        for (selector, expected) in cases {
            clipboard.clearContents()
            _ = try await readerScript(reader, "document.querySelector(selector).click(); return true", arguments: ["selector": selector])
            try await eventually(description: "native copy of \(selector)") { clipboard.string(forType: .string) == expected }
            try await eventually(description: "copy success feedback") {
                (try? await readerScript(reader, "return document.querySelector(selector).dataset.copyState === 'success'", arguments: ["selector": selector])) as? Bool == true
            }
        }
        guard (try await reader.evaluateJavaScript("document.querySelector('h1').textContent==='Copy 标题' && readingBlocks[0].key==='Copy 标题' && pendingCopies.size===0")) as? Bool == true else {
            throw Failure(message: "Copy feedback contaminated heading/reading text or left pending requests")
        }
        // Force a failed response without changing the clipboard, then retry normally.
        _ = try await reader.evaluateJavaScript("const failed=document.querySelector('p .code-copy-button');const state=copyTargets.get(failed);state.request=++nextCopyRequest;pendingCopies.set(state.request,new WeakRef(failed));window.completeCodeCopy(state.request,false);true")
        guard (try await reader.evaluateJavaScript("document.querySelector('p .code-copy-button').getAttribute('aria-label')==='复制失败'")) as? Bool == true else {
            throw Failure(message: "Copy failure was not reported")
        }
        _ = try await reader.evaluateJavaScript("document.querySelector('p .code-copy-button').click();true")
        try await eventually { (try? await reader.evaluateJavaScript("document.querySelector('p .code-copy-button').dataset.copyState")) as? String == "success" }
        try await eventually(description: "copy feedback resets") {
            (try? await reader.evaluateJavaScript("[...document.querySelectorAll('.code-copy-button')].every(b=>!b.dataset.copyState && b.title==='复制代码')")) as? Bool == true
        }
        guard let window = reader.window else { throw Failure(message: "Copy keyboard test has no window") }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(reader)
        try await eventually(description: "reader receives keyboard focus") {
            (try? await reader.evaluateJavaScript("document.hasFocus()")) as? Bool == true
        }
        let layout = try await readerScript(reader, #"""
            const button=document.querySelector('pre>.code-copy-button');
            button.focus();
            const focusVisible=document.activeElement===button && getComputedStyle(button).opacity==='1';
            if (!focusVisible) throw new Error(JSON.stringify({active:document.activeElement.outerHTML.slice(0,300),opacity:getComputedStyle(button).opacity,hasFocus:document.hasFocus(),tabIndex:button.tabIndex}));
            const scroll=document.querySelector('.code-copy-scroll');
            const before=button.getBoundingClientRect().left;
            scroll.scrollLeft=150;
            const fixed=scroll.scrollLeft>0 && Math.abs(button.getBoundingClientRect().left-before)<1;
            content.style.maxWidth='290px';
            const bounds=content.getBoundingClientRect();
            const narrow=[...content.querySelectorAll('.code-copy-inline,pre')].every(e=>{
              const r=e.getBoundingClientRect();return r.left>=bounds.left && r.right<=bounds.right;
            });
            return {focusVisible,fixed,narrow,connected:sourceBlocks.every(b=>b.element.isConnected)};
            """#)
        guard let checks = layout as? [String: Bool], checks.values.allSatisfy({ $0 }) else {
            throw Failure(message: "Copy focus, horizontal scrolling or narrow layout failed: \(layout)")
        }
        _ = try await reader.evaluateJavaScript("document.querySelector('p .code-copy-button').focus();true")
        clipboard.clearContents()
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else {
                throw Failure(message: "Could not create copy keyboard event")
            }
            NSApp.sendEvent(event)
        }
        try await eventually(description: "Space activates the focused copy button") { clipboard.string(forType: .string) == inline }
        for appearance in ["light", "dark"] {
            _ = try await readerScript(reader, "document.documentElement.dataset.appearance=appearance;document.querySelector('h1 .code-copy-button').focus();window.scrollTo(0,0);return true", arguments: ["appearance": appearance])
            try await Task.sleep(for: .milliseconds(100))
            let image = try await reader.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent("code-copy-\(appearance).png"))
            }
        }
        _ = try await reader.evaluateJavaScript("content.style.removeProperty('max-width');document.querySelector('pre>.code-copy-button').blur();true")
        let updated = source.replacingOccurrences(of: "可更新段落", with: "已更新段落").replacingOccurrences(of: inline, with: "更新后的代码")
        try Data(updated.utf8).write(to: file, options: .atomic)
        try await eventually(description: "copy fixture reloads updated code") { (try? await reader.evaluateJavaScript("content.textContent.includes('已更新段落')")) as? Bool == true }
        guard (try await reader.evaluateJavaScript("document.querySelector('h1')===window.__copyHeading && document.querySelector('pre')===window.__copyBlock && document.querySelector('pre>.code-copy-button')===window.__copyButton && content.querySelectorAll('.code-copy-button').length===7 && sourceBlocks.every(b=>b.element.isConnected)")) as? Bool == true else {
            throw Failure(message: "Incremental code copy duplicated controls or discarded unchanged nodes")
        }
        document.session.mode = .split
        try await eventually(description: "copy split editor mounts") {
            guard let root = window.contentView else { return false }
            return descendants(root).contains { $0 is NSTextView } && document.session.replaceText != nil
        }
        document.session.replaceText?(updated.replacingOccurrences(of: "更新后的代码", with: "分栏编辑代码"))
        try await eventually(description: "copy split preview updates") { (try? await reader.evaluateJavaScript("content.textContent.includes('分栏编辑代码')")) as? Bool == true }
        _ = try await reader.evaluateJavaScript("document.querySelector('p .code-copy-button').click();true")
        try await eventually(description: "copy split preview writes new text") { clipboard.string(forType: .string) == "分栏编辑代码" }
        try await document.session.performSave(to: file, operation: .saveOperation)
        document.session.mode = .read
        // Non-Markdown and truncated previews must not gain whole-document controls.
        guard (try await readerScript(reader, #"""
            const prefs={fontSize:16,width:780,appearance:'system',remoteImages:false};
            let clean=true;
            for(const kind of ['text','json','xml']) {
              window.updateDocument('plain text',kind,'file:///',prefs,{});
              clean=clean && !content.querySelector('button');
            }
            window.updateDocument('x'.repeat(500001),'markdown','file:///',prefs,{});
            return clean && !content.querySelector('button') && !!content.querySelector('.notice');
            """#)) as? Bool == true else { throw Failure(message: "Copy controls leaked into plain/truncated previews") }
    }

    private final class WeakSession {
        weak var value: DocumentSession?
        init(_ value: DocumentSession) { self.value = value }
    }

    private static func closeLifecycleProbe(directory: URL) async throws -> WeakSession {
        let url = directory.appendingPathComponent("lifecycle.md")
        try Data("# Lifecycle\n\nClose this document.\n".utf8).write(to: url)
        let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(contentsOf: url)), url: url)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers(); doc.showWindows()
        try await eventually {
            guard let root = doc.windowControllers.first?.window?.contentView,
                  let web = descendants(root).compactMap({ $0 as? WKWebView }).first else { return false }
            return (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "Lifecycle"
        }
        doc.session.mode = .split
        try await Task.sleep(for: .milliseconds(200))
        guard let root = doc.windowControllers.first?.window?.contentView,
              let web = descendants(root).compactMap({ $0 as? WKWebView }).first,
              let editor = descendants(root).compactMap({ $0 as? NSTextView }).first else {
            throw Failure(message: "Lifecycle split panes unavailable")
        }
        guard let coordinator = editor.delegate as? SourceEditor.Coordinator else { throw Failure(message: "Editor coordinator missing") }
        coordinator.highlight()
        let headingColor = editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
        let storageColor = editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        guard headingColor == .systemBlue, storageColor != .systemBlue else {
            throw Failure(message: "Syntax colors were not temporary display attributes")
        }
        _ = try await web.evaluateJavaScript("window.__firstBlock=document.querySelector('h1');window.__renderCalls=0; window.__transferredLength=0; const update=window.updateDocument; window.updateDocument=(...args)=>{window.__renderCalls++;window.__transferredLength=args[0].length;return update(...args)};true")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        for _ in 0..<25 {
            editor.insertText("x", replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(10))
        }
        try await eventually {
            (try? await web.evaluateJavaScript("document.getElementById('content').textContent.includes('xxxxxxxxxxxxxxxxxxxxxxxxx')")) as? Bool == true
        }
        guard let calls = try await web.evaluateJavaScript("window.__renderCalls") as? Int,
              calls < 10 else { throw Failure(message: "Typing still re-rendered for every keystroke") }
        guard (try await web.evaluateJavaScript("document.querySelector('h1')===window.__firstBlock")) as? Bool == true else {
            throw Failure(message: "Local editing rebuilt an unchanged Markdown block")
        }
        let incrementalSafe: Any = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript("""
                const prefs={fontSize:16,width:780,appearance:'system',remoteImages:false};
                const head='# Stable\\n\\n[Reference][target]\\n\\n';
                const tail='\\n\\n```json\\n{"ok":true}\\n```\\n';
                window.updateDocument(head+'First paragraph'+tail+'\\n[target]: https://example.com/first', 'markdown', baseURL, prefs, {});
                const code=document.querySelector('pre');
                window.updateDocument(head+'Second paragraph'+tail+'\\n[target]: https://example.com/second', 'markdown', baseURL, prefs, {});
                const linkCorrect=document.querySelector('a')?.getAttribute('href')==='https://example.com/second';
                const codeRetained=document.querySelector('pre')===code;
                window.updateDocument('<img src="https://example.com/tracker.png" onerror="window.injected=true">\\n\\n<script>window.injected=true</script>', 'markdown', baseURL, prefs, {});
                const safe=!document.querySelector('#content img[src^="https:"], #content script, #content [onerror]') && !!document.querySelector('.image-placeholder') && !window.injected;
                return linkCorrect && codeRetained && safe && sourceBlocks.every(block=>block.element.isConnected);
                """, arguments: ["baseURL": url.absoluteString], in: nil, in: .page) { continuation.resume(with: $0) }
        }
        guard incrementalSafe as? Bool == true else {
            throw Failure(message: "Incremental rendering broke references, safe node reuse or remote image filtering")
        }
        doc.session.mode = .edit
        try await Task.sleep(for: .milliseconds(100))
        guard descendants(root).compactMap({ $0 as? NSTextView }).first === editor else {
            throw Failure(message: "Split-to-edit unnecessarily recreated the editor")
        }
        doc.session.mode = .split
        try await eventually {
            guard let preview = descendants(root).compactMap({ $0 as? WKWebView }).first else { return false }
            return (try? await preview.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "Lifecycle"
        }
        guard let preview = descendants(root).compactMap({ $0 as? WKWebView }).first else {
            throw Failure(message: "Recreated preview unavailable")
        }
        _ = try await preview.evaluateJavaScript("const original=window.updateDocument; window.updateDocument=(...args)=>{window.__transferredLength=args[0].length;return original(...args)};true")
        doc.session.mode = .read
        try await Task.sleep(for: .milliseconds(100))
        doc.session.edit(String(repeating: "x", count: 2_000_000))
        try await eventually {
            (try? await preview.evaluateJavaScript("!!document.querySelector('.notice')")) as? Bool == true
        }
        guard let transfer = try await preview.evaluateJavaScript("window.__transferredLength") as? Int,
              transfer == PreviewText.maximumUTF16Count, doc.session.state.text.count == 2_000_000 else {
            throw Failure(message: "Large-preview cap truncated original data or transferred the entire file")
        }
        try await eventually(description: "Outline clears selection when headings disappear") { doc.session.activeHeadingID == nil }
        let reference = WeakSession(doc.session)
        doc.updateChangeCount(.changeCleared)
        doc.close()
        return reference
    }

}
#endif
