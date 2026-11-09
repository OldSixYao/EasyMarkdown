#if DEBUG
import AppKit
import WebKit
import CryptoKit
import EasyMarkdownCore

@MainActor enum LightweightCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message) }
    }
    private static func wait(_ message: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<150 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw Failure("Timed out: " + message)
    }
    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private static func script(_ web: WKWebView, _ source: String, _ arguments: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .page) { continuation.resume(with: $0) }
        }
    }

    static func run(directory: URL) async throws {
        try await nativeEditing(directory: directory)
        try await nativeReadingPosition(directory: directory)
        try await sharedMonitoring(directory: directory)
        try await drafts(directory: directory)
        try imageBudgets()
        try await sharedImageBudgets(directory: directory)
        try await ImageDownloadCheck.run()
        try await imagesAndSleep(directory: directory)
    }

    private static func nativeEditing(directory: URL) async throws {
        let source = String(repeating: "中文📝 paragraph for incremental editing.\n", count: 30_000)
        let url = directory.appendingPathComponent("incremental-native.md")
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)), url: url)
        NSDocumentController.shared.addDocument(doc)
        doc.session.mode = .edit
        doc.makeWindowControllers(); doc.showWindows()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        guard let root = doc.windowControllers.first?.window?.contentView else { throw Failure("Native window missing") }
        var editor: NSTextView?
        try await wait("native editor") {
            editor = views(root).compactMap { $0 as? NSTextView }.first { $0.delegate is SourceEditor.Coordinator }
            return editor != nil
        }
        guard let editor else { throw Failure("Editor missing") }
        let range = NSRange(location: editor.textStorage!.length - 2, length: 1)
        let old = (editor.string as NSString).substring(with: range)
        editor.breakUndoCoalescing()
        editor.insertText("X", replacementRange: range)
        editor.breakUndoCoalescing()
        try require(doc.session.state.isDirty && doc.isDocumentEdited, "Native delta did not mark dirty")
        doc.undoManager?.undo()
        try require(!doc.session.state.isDirty && !doc.isDocumentEdited && editor.string == source,
                    "Undo to baseline did not clear cached dirty state: cached=\(doc.session.state.isDirty), document=\(doc.isDocumentEdited), textMatches=\(editor.string == source)")
        doc.undoManager?.redo()
        try require(doc.session.state.isDirty, "Redo lost dirty state")
        let revision = doc.session.state.revision
        try await doc.session.performSave(to: url, operation: .saveOperation)
        try await Task.sleep(for: .milliseconds(150))
        try require(doc.session.state.revision == revision && doc.undoManager?.canUndo == true,
                    "Saving unchanged editor revision cleared undo")
        doc.undoManager?.undo()
        try require(doc.session.state.isDirty && (editor.string as NSString).substring(with: range) == old,
                    "Undo after save did not restore earlier content")
        let compositionRange = NSRange(location: 0, length: 0)
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: compositionRange)
        try require(editor.hasMarkedText(), "Native composition did not begin")
        doc.session.status = "composition check"
        try await Task.sleep(for: .milliseconds(50))
        try require(editor.hasMarkedText() && editor.string.hasPrefix("拼"), "View update replaced an active composition")
        editor.insertText("拼音", replacementRange: editor.markedRange())
        editor.unmarkText()
        try require(doc.session.state.text.hasPrefix("拼音") && doc.session.state.byteCount == editor.string.utf8.count,
                    "Composition commit lost text or incremental byte count")
    }

    private static func sharedMonitoring(directory: URL) async throws {
        let folder = directory.appendingPathComponent("shared-monitor", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let initialCount = DirectoryMonitor.shared.directoryCount
        var documents: [MarkdownDocument] = []
        defer { for doc in documents { doc.updateChangeCount(.changeCleared); doc.close() } }
        for index in 0..<3 {
            let url = folder.appendingPathComponent("document-\(index).md")
            let data = Data("# monitor \(index)\n".utf8)
            try data.write(to: url)
            let doc = MarkdownDocument(snapshot: try FileSnapshot(data: data), url: url)
            documents.append(doc)
            doc.session.start()
            await doc.session.reload(force: false)?.value
        }
        try require(DirectoryMonitor.shared.directoryCount == initialCount + 1, "Documents did not share directory watcher")
        try await Task.sleep(for: .milliseconds(400))
        let reads = documents.map { $0.session.reloadReadCount }
        try Data("unrelated".utf8).write(to: folder.appendingPathComponent("other-file.txt"), options: .atomic)
        try await Task.sleep(for: .milliseconds(500))
        try require(reads == documents.map { $0.session.reloadReadCount }, "Unrelated directory event reread documents")
        let changed = "# changed externally\n"
        try Data(changed.utf8).write(to: documents[1].fileURL!, options: .atomic)
        try await wait("targeted atomic replacement") { documents[1].session.state.text == changed }
        try require(documents[0].session.reloadReadCount == reads[0] && documents[2].session.reloadReadCount == reads[2],
                    "Targeted change reread siblings")
        let beforeForce = documents[0].session.reloadReadCount
        await documents[0].session.reload(force: true)?.value
        try require(documents[0].session.reloadReadCount == beforeForce + 1, "Explicit strong refresh was skipped")
    }

    private static func nativeReadingPosition(directory: URL) async throws {
        let url = directory.appendingPathComponent("native-reading-position.txt")
        let source = String(repeating: "中文 paragraph for native reading position.\n", count: 2_000)
        try Data(source.utf8).write(to: url)
        func open() throws -> MarkdownDocument {
            let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)), url: url)
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers(); doc.showWindows()
            return doc
        }
        let first = try open()
        let root = first.windowControllers.first!.window!.contentView!
        var view: NSTextView?
        try await wait("native reader mounts") {
            view = views(root).compactMap { $0 as? NSTextView }.first { $0.delegate is SourceEditor.Coordinator }
            return view != nil
        }
        try await Task.sleep(for: .milliseconds(100))
        guard let scroll = view?.enclosingScrollView else { throw Failure("Native read scroll missing") }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_000))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(250))
        first.close()
        let reopened = try open()
        defer { reopened.close() }
        let nextRoot = reopened.windowControllers.first!.window!.contentView!
        try await wait("native reader restores position") {
            guard let text = views(nextRoot).compactMap({ $0 as? NSTextView }).first(where: { $0.delegate is SourceEditor.Coordinator }),
                  let top = text.enclosingScrollView?.contentView.bounds.minY else { return false }
            return abs(top - 1_000) < 5
        }
    }

    private static func drafts(directory: URL) async throws {
        let folder = directory.appendingPathComponent("draft-format", isDirectory: true)
        let store = DraftStore(directory: folder)
        let url = directory.appendingPathComponent("draft-format.md")
        let baseline = Data(String(repeating: "baseline 中文\r\n", count: 10_000).utf8)
        let identity = UUID()
        let draft = RecoveryDraft(baseline: baseline, text: "unsaved 中文 📝", savedAt: Date(), baselineID: identity)
        try await store.save(draft, for: url)
        let key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let content = folder.appendingPathComponent(key)
        let first = try FileManager.default.contentsOfDirectory(at: content, includingPropertiesForKeys: [.contentModificationDateKey])
        guard let baselineFile = first.first(where: { $0.lastPathComponent.hasPrefix("baseline-") }) else { throw Failure("Baseline missing") }
        let date = try baselineFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let newer = RecoveryDraft(baseline: baseline, text: "latest 📝\n", savedAt: Date(), baselineID: identity)
        try await store.save(newer, for: url)
        let loaded = try await store.load(url)
        try require(loaded?.baseline == baseline && loaded?.text == newer.text, "Split draft did not round trip")
        try require(try baselineFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date,
                    "Unchanged baseline was rewritten")
        try Data("incomplete orphan".utf8).write(to: content.appendingPathComponent("text-orphan.utf8"))
        try require(try await store.load(url)?.text == newer.text, "Uncommitted draft replaced committed content")
        try await store.remove(url)
        let legacy = folder.appendingPathComponent(key + ".json")
        try JSONEncoder().encode(draft).write(to: legacy)
        try require(try await store.load(url)?.text == draft.text, "Legacy draft migration lost content")
        try require(!FileManager.default.fileExists(atPath: legacy.path), "Legacy migration retained duplicate payload")
        try await store.remove(url)
        try require(try await store.load(url) == nil, "Draft remove left recovery content")

        let continuousURL = directory.appendingPathComponent("continuous-draft.md")
        try Data("base".utf8).write(to: continuousURL)
        let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data("base".utf8)), url: continuousURL)
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        for index in 0..<24 {
            doc.session.edit("continuous-\(index)")
            try await Task.sleep(for: .milliseconds(100))
        }
        let intermediate = try await DraftStore.shared.load(continuousURL)
        try require(intermediate?.text.hasPrefix("continuous-") == true, "Continuous typing never wrote a recovery point")
        try await wait("latest draft after typing") { try await DraftStore.shared.load(continuousURL)?.text == "continuous-23" }
    }

    private static func imageBudgets() throws {
        let budget = ImageResourceBudget(limits: .init(documentDecoded: 100, totalDecoded: 150,
            documentEncoded: 100, totalEncoded: 150, documentCount: 2, totalCount: 3))
        let first = UUID(), second = UUID(), a = UUID(), b = UUID()
        try require(budget.reserve(id: a, owner: first, decoded: 80, encoded: 20), "First budget reservation failed")
        try require(!budget.reserve(id: UUID(), owner: first, decoded: 30, encoded: 20), "Document image budget overflow")
        try require(!budget.reserve(id: UUID(), owner: second, decoded: 80, encoded: 20), "Application image budget overflow")
        try require(budget.reserve(id: b, owner: second, decoded: 60, encoded: 20), "Independent document budget failed")
        budget.release(a)
        try require(budget.reserve(id: a, owner: first, decoded: 90, encoded: 20), "Released budget was not reusable")
        budget.release(a); budget.release(b)
        try require(budget.count == 0 && budget.decodedBytes == 0 && budget.encodedBytes == 0, "Image budget leaked charges")
        let encoded = "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'/%3E"
        let (data, mime) = try ImageDownload.dataURL(encoded)
        try require(mime == "image/svg+xml" && String(decoding: data, as: UTF8.self).hasPrefix("<svg"), "Data image percent decoding failed")
    }

    private static func sharedImageBudgets(directory: URL) async throws {
        let folder = directory.appendingPathComponent("image-budget-resources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vector = Data("<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='blue'/></svg>".utf8)
        for index in 0..<18 { try vector.write(to: folder.appendingPathComponent("vector-\(index).svg")) }
        let documentOwner = UUID()
        let primary = LocalResourceHandler(owner: documentOwner)
        let conflict = LocalResourceHandler(owner: documentOwner)
        let second = LocalResourceHandler(), third = LocalResourceHandler()
        for handler in [primary, conflict, second, third] { handler.root = folder }
        defer { for handler in [primary, conflict, second, third] { handler.cancelAll() } }
        func request(_ handler: LocalResourceHandler, _ index: Int, id: String? = nil) async -> [String: Any] {
            await withCheckedContinuation { continuation in
                handler.requestImage(id: id ?? String(index), source: folder.appendingPathComponent("vector-\(index).svg").absoluteString) {
                    continuation.resume(returning: $0)
                }
            }
        }
        for index in 0..<8 {
            let value = await request(primary, index)
            try require(value["url"] != nil, "Document image allowance was rejected early")
        }
        let same = await request(primary, 0, id: "same-source")
        try require(same["url"] != nil && primary.resourceCount == 8, "Same-view image source did not share resource")
        let deniedConflict = await request(conflict, 8)
        try require(deniedConflict["error"] as? String == "budget", "Conflict sheet bypassed document budget")
        for index in 8..<16 {
            let value = await request(second, index)
            try require(value["url"] != nil, "Second document image allowance was rejected early")
        }
        let deniedApplication = await request(third, 16)
        try require(deniedApplication["error"] as? String == "budget", "Image handler bypassed application budget")
        primary.releaseImage(id: "0")
        try require(primary.resourceCount == 8, "Releasing one reference discarded a shared image")
        primary.releaseImage(id: "same-source")
        let reused = await request(conflict, 8)
        try require(reused["url"] != nil, "Released image allowance could not be reused by conflict sheet")
    }

    private static func imagesAndSleep(directory: URL) async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==")!
        let imageFile = directory.appendingPathComponent("budget-fixture.png")
        try png.write(to: imageFile)
        let url = directory.appendingPathComponent("budget-images.md")
        let source = "# Image budget\n\n![local](budget-fixture.png)\n\n" +
            "![inline](data:image/png;base64,\(png.base64EncodedString()))\n\n" +
            String(repeating: "Paragraph with enough height to move images offscreen.\n\n", count: 160) +
            "![bottom](budget-fixture.png)\n"
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)), url: url)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers(); doc.showWindows()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        guard let root = doc.windowControllers.first?.window?.contentView else { throw Failure("Image window missing") }
        var reader: WKWebView?
        try await wait("image fixture renders") {
            reader = views(root).compactMap { $0 as? WKWebView }.first
            guard let reader else { return false }
            return (try? await reader.evaluateJavaScript("document.querySelector('h1')?.textContent==='Image budget' && !restoring")) as? Bool == true
        }
        _ = try await reader?.evaluateJavaScript("window.scrollTo(0,0);true")
        try await wait("budgeted local and inline images") {
            reader = views(root).compactMap { $0 as? WKWebView }.first
            guard let reader else { return false }
            return (try? await reader.evaluateJavaScript("[...document.images].filter(i=>i.naturalWidth>0).length")) as? Int == 2
        }
        guard let web = reader,
              let handler = web.configuration.urlSchemeHandler(forURLScheme: "document-resource") as? LocalResourceHandler else {
            throw Failure("Image handler missing")
        }
        try await wait("initial image position restoration finishes") {
            (try? await web.evaluateJavaScript("!restoring")) as? Bool == true
        }
        try require(handler.resourceCount == 2, "Offscreen image was eagerly admitted")
        _ = try await web.evaluateJavaScript("window.scrollTo(0,document.documentElement.scrollHeight);true")
        do {
            try await wait("offscreen images released") {
                let loaded = (try? await web.evaluateJavaScript("[...document.images].filter(i=>i.hasAttribute('src')).length")) as? Int
                return loaded == 1 && handler.resourceCount == 1
            }
        } catch {
            let state = try? await web.evaluateJavaScript("JSON.stringify({y:scrollY,max:document.documentElement.scrollHeight-innerHeight,images:[...readerImages.states.values()].map(s=>({near:s.near,state:s.state,request:s.request,top:s.frame.getBoundingClientRect().top,src:s.img.getAttribute('src')}))})")
            throw Failure("Offscreen image release failed: count=\(handler.resourceCount), state=\(String(describing: state))")
        }
        _ = try await web.evaluateJavaScript("window.scrollTo(0,0);true")
        try await wait("images reload on return") { handler.resourceCount == 2 }
        let reuse = try await script(web, #"""
            const prefs={fontSize:16,width:780,appearance:'system',remoteImages:false};
            const original=Array.from({length:200},(_,i)=>'## Heading '+i+'\n\nParagraph '+i+'\n\n').join('');
            window.updateDocument(original,'markdown','file:///',prefs,{});
            const headings=[...content.querySelectorAll('h2')];
            window.updateDocument(original.replace('Paragraph 0','Changed first').replace('Paragraph 199','Changed last'),'markdown','file:///',prefs,{});
            if(!headings.every((h,i)=>content.querySelectorAll('h2')[i]===h)) throw Error('Distant edit lost stable blocks');
            const generation=renderGeneration, blocks=renderedBlocks;
            window.updateReaderSearch('Paragraph',false,0,0);
            const searchIndex=readerSearchIndex;
            window.updateReaderPreferences({...prefs,appearance:'dark'});
            if(renderGeneration!==generation || renderedBlocks!==blocks || readerSearchIndex!==searchIndex) throw Error('Appearance reparsed content or search');
            return true;
            """#)
        try require(reuse as? Bool == true, "Block/style reuse failed")
        // Restore through the real session before checking sleep and search state.
        doc.session.edit(source + "\nstate restore\n")
        try await wait("session restored after direct renderer probe") {
            (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "Image budget"
        }
        doc.session.showSearch(); doc.session.search = "Paragraph"
        try await wait("search before sleep") { doc.session.searchResultCount == 160 }
        doc.session.navigateSearch(); doc.session.navigateSearch()
        try await wait("search navigation before sleep") {
            (try? await web.evaluateJavaScript("readerSearch.index")) as? Int == 2
        }
        _ = try await web.evaluateJavaScript("window.scrollTo(0,1000);true")
        try await Task.sleep(for: .milliseconds(100))
        let before = (try await web.evaluateJavaScript("scrollY")) as? Double ?? 0
        doc.session.setWindowActive(true)
        doc.session.previewActivity.idleDelay = .milliseconds(100)
        doc.session.setWindowActive(false)
        reader = nil
        try await wait("background reader sleeps") {
            !doc.session.previewActivity.isAwake && !views(root).contains(where: { $0 is WKWebView })
        }
        try require(handler.resourceCount == 0, "Sleeping reader retained image resources")
        doc.session.setWindowActive(true)
        try await wait("reader wakes at saved position") {
            guard let current = views(root).compactMap({ $0 as? WKWebView }).first,
                  current !== web, doc.session.searchResultCount == 160 else { return false }
            let y = (try? await current.evaluateJavaScript("scrollY")) as? Double ?? -1
            let index = (try? await current.evaluateJavaScript("readerSearch.index")) as? Int
            return abs(y - before) < 5 && index == 2
        }
    }
}
#endif
