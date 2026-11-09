import AppKit
import WebKit
import CryptoKit
import EasyMarkdownCore

@main struct PerformanceHarness {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                if let path = ProcessInfo.processInfo.environment["EASYMARKDOWN_MEMORY_CHECK"] {
                    let directory = URL(fileURLWithPath: path)
                    switch ProcessInfo.processInfo.environment["EASYMARKDOWN_MEASUREMENT_SCENARIO"] {
                    case "configuration-memory": try await configurationMemory(directory: directory)
                    case "images-memory": try await imagesMemory(directory: directory)
                    default: try await extendedMemory(directory: directory)
                    }
                } else {
                    let output = URL(fileURLWithPath: CommandLine.arguments[2])
                    let result: Any
                    switch CommandLine.arguments[1] {
                    case "native": result = try native(directory: output)
                    case "interactive": result = try await interactive(directory: output)
                    case "draft": result = try await draft(directory: output)
                    default: result = try await web(directory: output)
                    }
                    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output.appendingPathComponent("metrics.json"))
                }
                exit(0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor private static func elapsed<T>(_ body: () throws -> T) rethrows -> (Double, T) {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try body()
        return ((ProcessInfo.processInfo.systemUptime - start) * 1000, result)
    }

    @MainActor private static func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<600 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.coderInvalidValue)
    }

    @MainActor private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

    @MainActor private static func native(directory: URL) throws -> [[String: Any]] {
        var records: [[String: Any]] = []
        for size in [100_000, 1_000_000, 5_000_000, 20_000_000] {
            let row = "一段用于测试的文字 a paragraph 1234567890 ordinary text.\n"
            let source = String(repeating: row, count: size / row.utf8.count)
            let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)),
                url: directory.appendingPathComponent("native-\(size).md"))
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
            view.isRichText = false
            view.string = source
            let coordinator = SourceEditor.Coordinator(session: doc.session)
            coordinator.textView = view
            var bridge: [Double] = [], edit: [Double] = [], dirty: [Double] = [], equality: [Double] = [], highlight: [Double] = []
            var sink = 0
            for index in 0..<7 {
                view.textStorage!.replaceCharacters(in: NSRange(location: view.textStorage!.length - 2, length: 1), with: String(index))
                let (time, value) = elapsed { view.string }; bridge.append(time)
                edit.append(elapsed { doc.session.edit(value) }.0)
                let (d, changed) = elapsed { doc.session.state.isDirty }; dirty.append(d); sink += changed ? 1 : 0
                let (e, equal) = elapsed { view.string == doc.session.state.text }; equality.append(e); sink += equal ? 1 : 0
                highlight.append(elapsed { coordinator.highlight() }.0)
            }
            view.string = source
            doc.session.edit(source)
            view.delegate = coordinator
            var delta: [Double] = []
            for index in 0..<7 {
                delta.append(elapsed {
                    let range = NSRange(location: view.textStorage!.length - 2, length: 1)
                    let value = String(index)
                    if view.shouldChangeText(in: range, replacementString: value) {
                        view.textStorage!.replaceCharacters(in: range, with: value)
                        view.didChangeText()
                    }
                }.0)
            }
            view.delegate = nil
            doc.updateChangeCount(.changeCleared); doc.close()
            records.append(["bytes": source.utf8.count, "bridgeMs": bridge, "sessionEditMs": edit,
                "dirtyMs": dirty, "equalityMs": equality, "highlightMs": highlight,
                "nativeEditNotificationMs": delta, "sink": sink])
        }
        return records
    }

    @MainActor private static func web(directory: URL) async throws -> Any {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 760), configuration: configuration)
        let window = NSWindow(contentRect: web.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "性能测量临时窗口"; window.contentView = web; window.orderFront(nil)
        defer { web.stopLoading(); window.orderOut(nil) }
        let page = AppResources.bundle.url(forResource: "reader", withExtension: "html", subdirectory: "Resources")!
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        try await wait { (try? await web.evaluateJavaScript("typeof window.updateDocument==='function'")) as? Bool == true }
        let script = try String(contentsOf: directory.appendingPathComponent("web.js"), encoding: .utf8)
        return try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { continuation.resume(with: $0) }
        }
    }

    @MainActor private static func draft(directory: URL) async throws -> [String: Any] {
        let row = "恢复基线 中文 plain text 1234567890\n"
        let source = String(repeating: row, count: 8_000_000 / row.utf8.count)
        let baseline = Data(source.utf8)
        let url = directory.appendingPathComponent("draft-fixture.md")
        let key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("EasyMarkdown/Drafts")
        var times: [Double] = [], stored = 0
        for index in 0..<7 {
            let draft = RecoveryDraft(baseline: baseline, text: source + "edit-\(index)", savedAt: Date())
            let start = ProcessInfo.processInfo.systemUptime
            try await DraftStore.shared.save(draft, for: url)
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        for file in [root.appendingPathComponent(key), root.appendingPathComponent(key + ".json")] {
            if let files = FileManager.default.enumerator(at: file, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let item as URL in files { stored += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
            }
            stored += (try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).flatMap { $0.isRegularFile == true ? $0.fileSize : 0 } ?? 0
        }
        let restored = try await DraftStore.shared.load(url)
        let matches = restored?.baseline == baseline && restored?.text == source + "edit-6"
        try await DraftStore.shared.remove(url)
        return ["baselineBytes": baseline.count, "saveMs": times, "storedBytes": stored, "roundTrip": matches]
    }

    @MainActor private static func document(_ source: String, url: URL, mode: ViewMode = .read) throws -> MarkdownDocument {
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)), url: url)
        NSDocumentController.shared.addDocument(doc)
        doc.session.mode = mode
        doc.makeWindowControllers(); doc.showWindows()
        return doc
    }

    @MainActor private static func interactive(directory: URL) async throws -> [String: Any] {
        let source = "# Input timing\n\n" + String(repeating: "Paragraph 中文 text **bold** with words.\n\n", count: 500)
        let doc = try document(source, url: directory.appendingPathComponent("interactive.md"), mode: .split)
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        let window = doc.windowControllers.first!.window!
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let root = window.contentView!
        var editor: NSTextView?, reader: WKWebView?
        try await wait {
            editor = views(root).compactMap { $0 as? NSTextView }.first { $0.delegate is SourceEditor.Coordinator }
            reader = views(root).compactMap { $0 as? WKWebView }.first
            guard editor != nil, let reader else { return false }
            return (try? await reader.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "Input timing"
        }
        let web = reader!, text = editor!
        try await Task.sleep(for: .milliseconds(300))
        var input: [Double] = [], preview: [Double] = []
        for index in 0..<12 {
            let marker = "input-measure-\(index)"
            let start = ProcessInfo.processInfo.systemUptime
            text.insertText(marker + " ", replacementRange: NSRange(location: 16, length: 0))
            input.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await wait {
                let value: Any? = try? await withCheckedThrowingContinuation { continuation in
                    web.callAsyncJavaScript("return content.textContent.includes(marker)",
                        arguments: ["marker": marker], in: nil, in: .page) { continuation.resume(with: $0) }
                }
                return value as? Bool == true
            }
            preview.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await Task.sleep(for: .milliseconds(50))
        }
        return ["bytes": source.utf8.count, "nativeInputMs": input, "inputToPreviewMs": preview,
                "pollIntervalMs": 20, "includesDebounceAndIPC": true]
    }

    @MainActor private static func extendedMemory(directory: URL) async throws {
        let paragraph = "## Section\n\n这是一段测试文字 **bold** and ordinary paragraph with `code`.\n\n"
        let source = "# Extended memory\n\n" + String(repeating: paragraph, count: 180)
        var docs: [MarkdownDocument] = []
        defer { for doc in docs { doc.updateChangeCount(.changeCleared); doc.close() } }
        try await MemoryCheck.checkpoint("extended_idle", directory: directory)
        for count in 1...10 {
            let doc = try document(source, url: directory.appendingPathComponent("window-\(count).md"))
            docs.append(doc)
            let root = doc.windowControllers.first!.window!.contentView!
            try await wait {
                guard let reader = views(root).compactMap({ $0 as? WKWebView }).first else { return false }
                return (try? await reader.evaluateJavaScript("document.querySelectorAll('h2').length")) as? Int == 180
            }
            if [1, 5, 10].contains(count) {
                try await MemoryCheck.checkpoint("windows_\(count)", directory: directory)
            }
        }
        try await Task.sleep(for: .seconds(32))
        try await MemoryCheck.checkpoint("windows_10_after_idle", directory: directory)
        for doc in docs { doc.updateChangeCount(.changeCleared); doc.close() }
        docs.removeAll()
        try await MemoryCheck.checkpoint("all_windows_closed", directory: directory)
        let plain = String(repeating: "name = 'value'\n# 中文 configuration\n", count: 2_000)
        let config = try document(plain, url: directory.appendingPathComponent("native-reader.toml"))
        docs.append(config)
        try await Task.sleep(for: .seconds(1))
        try await MemoryCheck.checkpoint("configuration_read", directory: directory)
        config.close(); docs.removeAll()
        let editing = try document(source, url: directory.appendingPathComponent("long-edit.md"), mode: .split)
        docs.append(editing)
        let root = editing.windowControllers.first!.window!.contentView!
        var text: NSTextView?
        try await wait {
            text = views(root).compactMap { $0 as? NSTextView }.first { $0.delegate is SourceEditor.Coordinator }
            return text != nil
        }
        for index in 0..<240 {
            text!.insertText("x", replacementRange: NSRange(location: 24, length: index == 0 ? 0 : 1))
            if [59, 119, 239].contains(index) {
                try await MemoryCheck.checkpoint("editing_\(index + 1)", directory: directory)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        editing.updateChangeCount(.changeCleared); editing.close(); docs.removeAll()
        try await MemoryCheck.checkpoint("extended_closed", directory: directory)
        try Data("done".utf8).write(to: directory.appendingPathComponent("done"))
    }

    @MainActor private static func configurationMemory(directory: URL) async throws {
        try await MemoryCheck.checkpoint("configuration_idle", directory: directory)
        let source = String(repeating: "name = 'value'\n# 中文 configuration\n", count: 2_000)
        let doc = try document(source, url: directory.appendingPathComponent("configuration.toml"))
        let root = doc.windowControllers.first!.window!.contentView!
        try await Task.sleep(for: .seconds(2))
        let liveReaders = views(root).filter { $0 is WKWebView }.count
        try await MemoryCheck.checkpoint("configuration_read", directory: directory, extra: ["webViews": liveReaders])
        doc.close()
        try await MemoryCheck.checkpoint("configuration_closed", directory: directory)
        try Data("done".utf8).write(to: directory.appendingPathComponent("done"))
    }

    @MainActor private static func imagesMemory(directory: URL) async throws {
        try autoreleasepool {
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 6000, pixelsHigh: 4000,
                bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceWhite, bytesPerRow: 6000, bitsPerPixel: 8)!
            image.bitmapData!.initialize(repeating: 160, count: 6000 * 4000)
            let png = image.representation(using: .png, properties: [:])!
            for index in 0..<5 { try png.write(to: directory.appendingPathComponent("large-\(index).png")) }
        }
        try await MemoryCheck.checkpoint("images_idle_after_fixture", directory: directory)
        let source = "# Images memory\n\n" + (0..<5).map { "![Image \($0)](large-\($0).png)\n\n" }.joined()
        let doc = try document(source, url: directory.appendingPathComponent("images.md"))
        let root = doc.windowControllers.first!.window!.contentView!
        var reader: WKWebView?
        try await wait {
            reader = views(root).compactMap { $0 as? WKWebView }.first
            guard let reader else { return false }
            return (try? await reader.evaluateJavaScript("document.querySelector('img')?.naturalWidth")) as? Int == 6000
        }
        let web = reader!
        try await Task.sleep(for: .seconds(1))
        try await MemoryCheck.checkpoint("images_top", directory: directory)
        for index in [2, 4, 0] {
            _ = try await web.evaluateJavaScript("document.images[\(index)].scrollIntoView();true")
            try await Task.sleep(for: .seconds(1))
            try await MemoryCheck.checkpoint("images_at_\(index)", directory: directory)
        }
        doc.close()
        try await MemoryCheck.checkpoint("images_closed", directory: directory)
        try Data("done".utf8).write(to: directory.appendingPathComponent("done"))
    }
}
