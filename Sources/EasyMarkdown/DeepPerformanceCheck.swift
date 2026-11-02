import AppKit
import WebKit
import EasyMarkdownCore

/// Opt-in Release benchmark; all edits and generated images are confined to its test directory.
@MainActor enum DeepPerformanceCheck {
    static func run(directory: URL) async {
        if ProcessInfo.processInfo.environment["EASYMARKDOWN_MEMORY_IMAGE_ONLY"] == "1" {
            await imageOnly(directory: directory)
            return
        }
        do {
            let text = "# Performance\n\n" + (1...300).map { index in
                "## Section \(index)\n\nParagraph \(index) 中文 📝 **bold** [link](https://example.com). " +
                String(repeating: "Text for measuring steady editing. ", count: 5) +
                "\n\n```swift\nlet item = \(index)\nprint(item)\n```\n\n"
            }.joined()
            let url = directory.appendingPathComponent("Performance.md")
            try Data(text.utf8).write(to: url)
            let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(text.utf8)), url: url)
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers(); doc.showWindows()
            NSApp.activate(ignoringOtherApps: true)
            let reader = try await preview(doc, heading: "Performance")
            try await MemoryCheck.checkpoint("deep_read", directory: directory)
            doc.session.mode = .split
            try await Task.sleep(for: .milliseconds(300))
            guard let root = doc.windowControllers.first?.window?.contentView,
                  let editor = views(root).compactMap({ $0 as? NSTextView }).first,
                  let coordinator = editor.delegate as? SourceEditor.Coordinator else {
                throw CocoaError(.coderInvalidValue)
            }
            var highlightTimes: [Double] = []
            for _ in 0..<20 {
                let start = ProcessInfo.processInfo.systemUptime
                coordinator.highlight()
                highlightTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            let result: Any = try await withCheckedThrowingContinuation { continuation in
                reader.callAsyncJavaScript("""
                const prefs = {fontSize:16,width:780,appearance:'system',remoteImages:false};
                const changing = [], same = [];
                for (let i=0;i<20;i++) {
                    const next = text.replace('Paragraph 150 ', 'Paragraph 150 edit-' + i + ' ');
                    let start = performance.now();
                    window.updateDocument(next, 'markdown', baseURL, prefs, {});
                    changing.push(performance.now()-start);
                }
                for (let i=0;i<10;i++) {
                    const start = performance.now();
                    window.updateDocument(text, 'markdown', baseURL, prefs, {});
                    same.push(performance.now()-start);
                }
                document.getElementById('section-280').scrollIntoView();
                const mappingStart = performance.now();
                for(let i=0;i<200;i++) { sourcePosition(); capturePosition(); }
                return {changingRenderMs:changing, sameRenderMs:same, mapping200Ms:performance.now()-mappingStart};
                """, arguments: ["text": text, "baseURL": url.absoluteString], in: nil, in: .page) { result in
                    continuation.resume(with: result)
                }
            }
            guard var metrics = result as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
            metrics["highlightMs"] = highlightTimes
            metrics["inputBytes"] = text.utf8.count
            try await MemoryCheck.checkpoint("after_continuous_render", directory: directory)
            doc.session.mode = .read
            doc.session.edit("# Large image\n\n![Fixture](large-fixture.png)\n")
            let imageReader = try await preview(doc, heading: "Large image")
            for _ in 0..<150 {
                if ((try? await imageReader.evaluateJavaScript("document.querySelector('img')?.naturalWidth")) as? Int ?? 0) > 0 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let width = try await imageReader.evaluateJavaScript("document.querySelector('img')?.naturalWidth") as? Int, width > 0 else {
                throw NSError(domain: "DeepPerformanceCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Image did not load"])
            }
            metrics["imagePreviewPixels"] = width
            try await MemoryCheck.checkpoint("large_image", directory: directory)
            try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("metrics.json"))
            doc.updateChangeCount(.changeCleared); doc.close()
            try await MemoryCheck.checkpoint("deep_closed", directory: directory)
            try Data("done".utf8).write(to: directory.appendingPathComponent("done"))
            NSApp.terminate(nil)
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error"))
            exit(1)
        }
    }

    private static func imageOnly(directory: URL) async {
        do {
            let text = "# Large image\n\n![Fixture](large-fixture.png)\n"
            let url = directory.appendingPathComponent("Image.md")
            try Data(text.utf8).write(to: url)
            let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(text.utf8)), url: url)
            NSDocumentController.shared.addDocument(doc)
            let start = ProcessInfo.processInfo.systemUptime
            doc.makeWindowControllers(); doc.showWindows()
            NSApp.activate(ignoringOtherApps: true)
            let reader = try await preview(doc, heading: "Large image")
            var width = 0
            for _ in 0..<150 {
                width = (try? await reader.evaluateJavaScript("document.querySelector('img')?.naturalWidth")) as? Int ?? 0
                if width > 0 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard width > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let metrics: [String: Any] = ["imagePreviewPixels": width, "openAndImageMs": (ProcessInfo.processInfo.systemUptime - start) * 1000]
            try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("metrics.json"))
            try await MemoryCheck.checkpoint("image_only", directory: directory)
            doc.close()
            try Data("done".utf8).write(to: directory.appendingPathComponent("done"))
            NSApp.terminate(nil)
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error"))
            exit(1)
        }
    }

    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private static func preview(_ doc: MarkdownDocument, heading: String) async throws -> WKWebView {
        for _ in 0..<150 {
            if let root = doc.windowControllers.first?.window?.contentView,
               let reader = views(root).compactMap({ $0 as? WKWebView }).first,
               (try? await reader.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == heading {
                try await Task.sleep(for: .milliseconds(150))
                return reader
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "DeepPerformanceCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Preview did not render"])
    }
}
