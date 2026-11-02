import AppKit
import WebKit
import EasyMarkdownCore

/// Opt-in profiling scenario. Uses only its own temporary document and windows.
@MainActor enum MemoryCheck {
    private final class WeakSession {
        weak var value: DocumentSession?
        init(_ value: DocumentSession) { self.value = value }
    }
    static func run(directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Memory benchmark.md")
            let text = "# Memory benchmark\n\n" + (1...180).map { index in
                "## Section \(index)\n\n这是一段用于重复测量的文字，包含 **粗体**、[链接](https://example.com) 和 `code`。 " +
                String(repeating: "A simple paragraph for reading and editing. ", count: 4) +
                "\n\n```swift\nlet section = \(index)\nprint(section)\n```\n\n"
            }.joined()
            try Data(text.utf8).write(to: url)
            try await checkpoint("idle", directory: directory)
            var doc: MarkdownDocument? = MarkdownDocument(snapshot: try FileSnapshot(data: Data(text.utf8)), url: url)
            NSDocumentController.shared.addDocument(doc!)
            doc!.makeWindowControllers(); doc!.showWindows()
            NSApp.activate(ignoringOtherApps: true)
            try await waitForPreview(doc!)
            try await checkpoint("read", directory: directory)
            doc!.session.mode = .split
            try await waitForPreview(doc!)
            try await checkpoint("split", directory: directory)
            doc!.session.mode = .edit
            try await Task.sleep(for: .seconds(2))
            try await checkpoint("edit", directory: directory)
            for _ in 0..<8 {
                doc!.session.mode = .read
                try await waitForPreview(doc!)
                doc!.session.mode = .split
                try await waitForPreview(doc!)
                doc!.session.mode = .edit
                try await Task.sleep(for: .milliseconds(120))
            }
            try await checkpoint("edit_after_8_cycles", directory: directory)
            doc!.session.mode = .read
            try await waitForPreview(doc!)
            try await checkpoint("read_after_8_cycles", directory: directory)
            let session = WeakSession(doc!.session)
            doc!.updateChangeCount(.changeCleared)
            doc!.close()
            doc = nil
            try await Task.sleep(for: .seconds(2))
            try await checkpoint("closed", directory: directory, extra: ["sessionReleased": session.value == nil])
            try Data("done".utf8).write(to: directory.appendingPathComponent("done"))
            NSApp.terminate(nil)
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error"))
            exit(1)
        }
    }

    private static func waitForPreview(_ doc: MarkdownDocument) async throws {
        for _ in 0..<150 {
            if let root = doc.windowControllers.first?.window?.contentView,
               let web = views(root).compactMap({ $0 as? WKWebView }).first,
               (try? await web.evaluateJavaScript("document.querySelectorAll('h2').length")) as? Int == 180 {
                try await Task.sleep(for: .milliseconds(180))
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "MemoryCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Preview did not finish rendering"])
    }

    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

    static func checkpoint(_ name: String, directory: URL, extra: [String: Any] = [:]) async throws {
        try await Task.sleep(for: .seconds(1))
        var payload = extra
        payload["stage"] = name
        payload["pid"] = ProcessInfo.processInfo.processIdentifier
        try JSONSerialization.data(withJSONObject: payload).write(to: directory.appendingPathComponent(name + ".ready"), options: .atomic)
        for _ in 0..<600 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".ack").path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "MemoryCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Profiler did not acknowledge \(name)"])
    }
}
