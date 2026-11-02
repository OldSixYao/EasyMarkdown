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
        var results: [String] = []
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
            // Real toolbar clicks and Cmd-Z arrive in separate event-loop turns.
            // Let AppKit finish the previous event's undo group before this action.
            try await Task.sleep(for: .milliseconds(50))
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
            let untrusted = "# Safety\n\n<img src=x onerror=\"window.injected=true\"><script>window.injected=true</script><iframe src=\"https://example.com\"></iframe>\n\n![remote](https://example.com/tracker.png)\n\n```json\n{\"ok\":true}\n```"
            try Data(untrusted.utf8).write(to: copy, options: .atomic)
            try await eventually { (try? await reader.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "Safety" }
            let safe = try await reader.evaluateJavaScript("!window.injected && !document.querySelector('#content script, #content iframe, #content [onerror]') && !!document.querySelector('.image-placeholder') && !!document.querySelector('.hljs-attr')") as? Bool
            guard safe == true else { throw Failure(message: "Sanitization, remote-image default or syntax highlighting failed") }
            results.append("Untrusted HTML sanitized; remote images blocked by default; code highlighted")

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
              transfer == 500_001, doc.session.state.text.count == 2_000_000 else {
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
