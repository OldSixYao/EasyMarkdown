#if DEBUG
import AppKit
import WebKit
import EasyMarkdownCore
import UniformTypeIdentifiers
import SwiftUI

@MainActor enum ConfigurationCheck {
    static func run(output: URL) async {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try await documents(directory: output)
            try await associations()
            try await customExtensions(directory: output)
            let report: [String: Any] = ["status": "passed", "configurationDocuments": 11, "defaultEditorFormats": 7, "customExtensionsAndRowStatus": true]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("report.json"))
            print("PASS: 11 configuration documents, 7 default-editor formats, custom extensions and per-row status")
            NSApp.terminate(nil)
        } catch {
            print("FAIL: configuration checks: \(error)")
            exit(1)
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeCheck.Failure(message: message) }
    }

    private static func wait(_ message: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SmokeCheck.Failure(message: "Timed out: " + message)
    }

    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

    static func documents(directory: URL) async throws {
        let pasteboard = NSPasteboard(name: .find)
        let savedFind = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); if !savedFind.isEmpty { pasteboard.writeObjects(savedFind) } }
        let fixtures: [(String, String)] = [
            ("compose.yaml", "# 注释\r\nname: demo\r\nenabled: true\r\nscript: '<script>window.injected=true</script>'\r\n"),
            ("workflow.yml", "name: demo\r\nsteps:\r\n  - run: echo hello\r\n"),
            ("Cargo.toml", "[package]\r\nname = 'demo'\r\n# keep comment\r\n"),
            ("settings.ini", "[app]\r\nname = demo\r\n; comment\r\n"),
            ("app.conf", "name = demo\r\n# comment\r\n"),
            ("app.cfg", "name = demo\r\n"), ("my.cnf", "[client]\r\nname = demo\r\n"),
            (".env", "NAME=demo\r\nSECRET='fake-fixture'\r\n"),
            (".env.local", "export NAME=demo\r\n# comment\r\n"),
            ("app.properties", "name=demo\r\nmessage=你好\\nworld\r\n"),
            ("settings.jsonc", "{\r\n  // keep comment\r\n  \"name\": \"demo\",\r\n}\r\n")
        ]
        for (name, source) in fixtures {
            let url = directory.appendingPathComponent(name)
            let original = Data([0xEF, 0xBB, 0xBF]) + Data(source.utf8)
            try original.write(to: url)
            let doc = MarkdownDocument(snapshot: try FileSnapshot(data: original), url: url)
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers(); doc.showWindows()
            defer { doc.updateChangeCount(.changeCleared); doc.close() }
            guard let root = doc.windowControllers.first?.window?.contentView else {
                throw SmokeCheck.Failure(message: "Configuration window missing")
            }
            var reader: NSTextView?
            try await wait(name + " text preview") {
                reader = views(root).compactMap { $0 as? NSTextView }.first { $0.delegate is SourceEditor.Coordinator }
                guard let reader else { return false }
                return !reader.isEditable && reader.string == source
            }
            guard let reader else { throw SmokeCheck.Failure(message: "Configuration reader missing") }
            try require(!views(root).contains(where: { $0 is WKWebView }), "Configuration reader unexpectedly created a web process")
            try require(doc.session.headings.isEmpty, "Configuration was parsed as Markdown")
            doc.session.requestEditorFind(.showFindInterface, query: "demo")
            try await wait("configuration native find bar") { reader.enclosingScrollView?.isFindBarVisible == true }
            doc.session.navigateSearch()
            try await wait("configuration native search") {
                (reader.string as NSString).substring(with: reader.selectedRange()) == "demo"
            }
            try require(!doc.session.state.isDirty, "Read-only search modified configuration")
            doc.session.closeSearch()
            doc.session.mode = .split
            var editor: NSTextView?
            try await wait("configuration source editor") {
                editor = views(root).compactMap { $0 as? NSTextView }.first { $0.delegate is SourceEditor.Coordinator && $0.isEditable }
                return editor != nil
            }
            guard let editor, let coordinator = editor.delegate as? SourceEditor.Coordinator else {
                throw SmokeCheck.Failure(message: "Configuration editor coordinator missing")
            }
            coordinator.highlight()
            let key = name == "settings.jsonc" ? "\"name\"" : name.hasPrefix(".env") ? "NAME" : "name"
            let offset = (editor.string as NSString).range(of: key).location
            try require(offset != NSNotFound && editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) != nil,
                "Configuration editor has no syntax color: " + name)
            let match = (editor.string as NSString).range(of: "demo")
            editor.insertText("changed", replacementRange: match)
            try require(doc.session.state.isDirty, "Configuration edit did not mark unsaved")
            try await doc.session.performSave(to: url, operation: .saveOperation)
            let expected = source.replacingOccurrences(of: "demo", with: "changed")
            try require(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF]) + Data(expected.utf8), "Configuration save changed whitespace, comments or BOM: " + name)
            try await wait("configuration split preview follows edit") {
                views(root).compactMap { $0 as? NSTextView }.contains {
                    ($0.delegate as? SourceEditor.Coordinator)?.isSecondary == true &&
                        !$0.isEditable && $0.string == expected
                }
            }
            if name == "compose.yaml", let window = doc.windowControllers.first?.window {
                try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("configuration-yaml.png"))
            }
        }
    }

    static func associations() async throws {
        let app = URL(fileURLWithPath: "/Applications/EasyMarkdown.app")
        var defaults: [String: URL] = [:]
        var writes: [String] = []
        let model = DefaultEditorSettings(applicationURL: app, query: { defaults[$0.identifier] },
            set: { url, type in writes.append(type.identifier); defaults[type.identifier] = url }, canSet: { true })
        let formats: [DefaultEditorFormat] = [.yaml, .toml, .ini, .configuration, .environment, .properties, .jsonc]
        let documentTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        let declared = documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        let extensions = documentTypes.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
        for format in formats {
            writes = []
            model.format = format
            try require(writes.isEmpty, "Selecting configuration type changed default application")
            let types = format.contentTypes
            try require(types.allSatisfy { !$0.isDynamic && $0.conforms(to: .text) }, "Configuration type is dynamic or not text: \(format.rawValue), \(types.map(\.identifier))")
            await model.makeDefault()
            try require(model.isDefault && model.errorMessage == nil && writes == types.map(\.identifier), "Configuration default was not scoped and verified")
            // A stable fallback must be listed even if another editor owns an alias.
            let fallback = format == .yaml ? "public.yaml" : "app.easymarkdown." + format.rawValue
            try require(declared.contains(fallback), "Missing configuration document declaration")
        }
        for ext in ["yaml", "yml", "toml", "ini", "conf", "cfg", "cnf", "env", "properties", "jsonc"] {
            try require(extensions.contains(ext), "Missing Finder extension: " + ext)
            let type = UTType(filenameExtension: ext)
            try require(type != nil && type?.isDynamic == false, "Extension did not register a stable type: " + ext)
        }
        try require(!extensions.contains("local"), "Dotenv variants must not take over all .local files")
    }

    static func customExtensions(directory: URL? = nil) async throws {
        let suiteName = "app.easymarkdown.extension-check.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else { throw CocoaError(.fileReadUnknown) }
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let app = URL(fileURLWithPath: "/Applications/EasyMarkdown.app")
        let other = URL(fileURLWithPath: "/Applications/Other.app")
        var defaults = [DefaultEditorFormat.markdown.contentType.identifier: app,
                        DefaultEditorFormat.json.contentType.identifier: other]
        var writes: [String] = []
        let model = DefaultEditorSettings(applicationURL: app, query: { defaults[$0.identifier] },
            set: { url, type in writes.append(type.identifier); defaults[type.identifier] = url },
            canSet: { true }, preferences: preferences)
        try require(model.association(for: .markdown).state == .current && model.association(for: .json).state == .other &&
            model.association(for: .yaml).state == .unset, "List row statuses did not reflect individual system associations")
        defaults[DefaultEditorFormat.yaml.contentType.identifier] = app
        model.refresh()
        try require(model.association(for: .yaml).state == .current, "Unselected row did not refresh after external changes")
        for input in ["", ".", "*.log", "a/b", "a b", "a.b", "💡", String(repeating: "x", count: 33)] {
            try require(!model.addExtension(input) && model.extensionError != nil, "Invalid extension was accepted: " + input)
        }
        try require(!model.addExtension(" .YML ") && model.format == .yaml && model.customExtensions.isEmpty,
            "Built-in extension duplicate did not select its existing row")
        let suffix = "emtest" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        try require(model.addExtension(" ." + suffix.uppercased() + " ") && model.customExtensions == [suffix] &&
            model.format == .custom(suffix) && model.extensionError == nil && writes.isEmpty,
            "Adding a normalized custom extension changed defaults or failed to select it")
        try require(!model.addExtension(suffix) && model.customExtensions == [suffix], "Duplicate custom extension was added")
        let type = DefaultEditorFormat.custom(suffix).contentType
        try require(type == UTType(filenameExtension: suffix) && type.isDynamic,
            "Unknown extension did not use its preferred system dynamic type")
        let restored = DefaultEditorSettings(applicationURL: app, query: { defaults[$0.identifier] },
            set: { _, _ in }, canSet: { true }, preferences: preferences)
        try require(restored.customExtensions == [suffix], "Custom extension did not persist across model instances")
        await model.makeDefault()
        try require(writes == [type.identifier] && model.isDefault && model.association(for: .custom(suffix)).state == .current,
            "Custom default was not scoped, verified and displayed in its row")
        if let directory {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            let controller = NSWindowController(window: window)
            window.title = L10n.text("默认编辑器")
            window.contentView = NSHostingView(rootView: Form {
                DefaultEditorSection(settings: model)
            }.formStyle(.grouped).frame(width: 560, height: 540))
            controller.showWindow(nil)
            defer { controller.close() }
            try await Task.sleep(for: .milliseconds(250))
            try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("custom-extension-default.png"))
        }
        defaults[type.identifier] = other
        model.refresh()
        try require(!model.isDefault && model.association(for: .custom(suffix)).state == .other,
            "Custom row did not reflect external reassignment")
        let before = writes
        model.removeSelectedExtension()
        try require(model.customExtensions.isEmpty && model.format == .markdown && writes == before && defaults[type.identifier] == other,
            "Removing a custom row changed the system default or left stale selection")
        let removed = DefaultEditorSettings(applicationURL: app, query: { _ in nil }, set: { _, _ in }, preferences: preferences)
        try require(removed.customExtensions.isEmpty, "Custom extension removal was not persisted")
        let failing = DefaultEditorSettings(applicationURL: app, query: { _ in nil },
            set: { _, _ in throw CocoaError(.userCancelled) }, canSet: { true }, preferences: preferences)
        _ = failing.addExtension(suffix)
        await failing.makeDefault()
        try require(!failing.isDefault && failing.errorMessage != nil && failing.association(for: .custom(suffix)).state == .unset,
            "Cancelled custom association claimed success")
    }
}
#endif
