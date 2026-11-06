#if DEBUG
import AppKit
import WebKit
import EasyMarkdownCore

/// Real editor/renderer checks for bounded work and asynchronous result ownership.
@MainActor enum PerformanceSafetyCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private final class WeakSession {
        weak var value: DocumentSession?
        init(_ value: DocumentSession) { self.value = value }
    }

    static func run(directory: URL) async throws {
        try highlightingAndLayout(directory: directory)
        try await formatting(directory: directory)
        try await reader()
    }

    private static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure("Performance safety check timed out")
    }

    private static func highlightingAndLayout(directory: URL) throws {
        let input = "[中文📝](https://example.com)\n" + String(repeating: "[", count: 16_000) + "\n[next](file.md)\n"
        let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(input.utf8)), url: directory.appendingPathComponent("highlight.md"))
        defer { doc.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        text.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        text.string = input
        scroll.documentView = text
        let coordinator = SourceEditor.Coordinator(session: doc.session)
        coordinator.textView = text
        let start = ProcessInfo.processInfo.systemUptime
        coordinator.highlight()
        guard ProcessInfo.processInfo.systemUptime - start < 0.5 else {
            throw Failure("Unclosed long line still blocks highlighting")
        }
        let layout = text.layoutManager!
        guard layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor == .systemTeal else {
            throw Failure("Unicode link lost its highlight")
        }
        let longStart = (input as NSString).range(of: String(repeating: "[", count: 100)).location
        guard layout.temporaryAttribute(.foregroundColor, atCharacterIndex: longStart, effectiveRange: nil) == nil else {
            throw Failure("Overlong line did not fall back to default color")
        }
        let links = SourceHighlighting.markdownLinks(in: "[中文📝](a) [next](b)" as NSString,
            range: NSRange(location: 0, length: ("[中文📝](a) [next](b)" as NSString).length))
        guard links.map({ ("[中文📝](a) [next](b)" as NSString).substring(with: $0) }) == ["[中文📝](a)", "[next](b)"] else {
            throw Failure("Linear link scanner changed UTF-16 boundaries")
        }
        let scanned = SourceHighlighting.boundedLineRanges(in: input as NSString,
            range: NSRange(location: 0, length: (input as NSString).length))
        guard scanned.count == 2,
              (input as NSString).substring(with: scanned[1]) == "[next](file.md)\n" else {
            throw Failure("Skipping an overlong line also dropped the following short line")
        }
        // Fresh layout: measuring the first visible line must not lay out the tail.
        text.string = String(repeating: "中文 paragraph for measuring wrapping and scrolling.\n", count: 80_000)
        guard let position = coordinator.scrollPosition(), position.offset < 100,
              layout.firstUnlaidCharacterIndex() < text.textStorage!.length / 2 else {
            throw Failure("Top scroll synchronization laid out the full large document")
        }
        text.textContainer?.containerSize.width = 460
        guard let position = coordinator.scrollPosition(), position.offset < 100,
              layout.firstUnlaidCharacterIndex() < text.textStorage!.length / 2 else {
            throw Failure("Resizing forces full-document layout")
        }
    }

    private static func formatting(directory: URL) async throws {
        let original = "{\"name\":\"中文\",\"value\":1}"
        let url = directory.appendingPathComponent("format.json")
        try Data(original.utf8).write(to: url)
        let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data(original.utf8)), url: url)
        NSDocumentController.shared.addDocument(doc)
        doc.session.mode = .edit
        doc.makeWindowControllers(); doc.showWindows()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        try await waitFor { doc.session.replaceText != nil }
        let expected = try DocumentFormatter.format(original, kind: .json)
        await doc.session.format()?.value
        try await waitFor { doc.session.state.text == expected }
        try await Task.sleep(for: .milliseconds(30))
        doc.undoManager?.undo()
        guard doc.session.state.text == original else { throw Failure("Background formatting lost native undo") }
        doc.undoManager?.redo()
        guard doc.session.state.text == expected else { throw Failure("Background formatting lost native redo") }

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await DocumentFormattingService.shared.blockForCheck(entered: entered, release: release) }
        defer { release.signal() }
        try await waitFor { entered.wait(timeout: .now()) == .success }
        doc.session.edit(original)
        let pending = doc.session.format()
        guard pending != nil, doc.session.isFormatting else { throw Failure("Formatting did not queue asynchronously") }
        // Returning to the same text still supersedes the original request.
        doc.session.edit("{\"newer\":true}")
        doc.session.edit(original)
        var replacements = 0
        let replace = doc.session.replaceText
        doc.session.replaceText = { _ in replacements += 1 }
        var closing: MarkdownDocument? = MarkdownDocument(snapshot: try FileSnapshot(data: Data(original.utf8)),
            url: directory.appendingPathComponent("closing-format.json"))
        closing!.session.mode = .edit
        closing!.session.replaceText = { _ in replacements += 1 }
        let closingTask = closing!.session.format()
        let reference = WeakSession(closing!.session)
        closing!.close(); closing = nil
        try await waitFor { reference.value == nil }
        release.signal(); await blocker.value
        await pending?.value; await closingTask?.value
        guard replacements == 0, !doc.session.isFormatting, doc.session.state.text == original else {
            throw Failure("Stale formatting replaced edited or closed content")
        }
        doc.session.replaceText = replace
        doc.session.edit("{invalid")
        await doc.session.format()?.value
        guard doc.session.errorMessage != nil, doc.session.state.text == "{invalid", !doc.session.isFormatting else {
            throw Failure("Invalid formatting did not retain content and report its error")
        }
        doc.session.errorMessage = nil
    }

    private static func reader() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 760))
        guard let page = AppResources.bundle.url(forResource: "reader", withExtension: "html", subdirectory: "Resources") else {
            throw Failure("Reader resource missing")
        }
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        var ready = false
        for _ in 0..<150 {
            if (try? await web.evaluateJavaScript("typeof window.updateDocument === 'function'")) as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard ready else { throw Failure("Reader did not load") }
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript("""
            const prefs={fontSize:16,width:780,appearance:'system',remoteImages:false};
            const update=text=>window.updateDocument(text,'markdown','file:///tmp/test.md',prefs,{});
            const titles=['Same','Same','Same-1','Same','Same-1','中文','中文','中文-1'];
            const seen=new Set();
            const expected=titles.map(title=>{const base=title.toLowerCase();let id=base,n=1;while(seen.has(id))id=base+'-'+n++;seen.add(id);return id;});
            update(titles.map(title=>'# '+title+'\\n\\n').join(''));
            if(JSON.stringify([...content.querySelectorAll('h1')].map(e=>e.id))!==JSON.stringify(expected)) throw Error('Mixed slug collisions changed');
            const text='# Repeated\\n\\n'.repeat(4000);
            update(text);
            const start=performance.now();update(text+'tail');
            if(performance.now()-start>1000)throw Error('Repeated headings still stall rendering');
            if(document.querySelectorAll('#repeated-3999').length!==1)throw Error('Repeated heading IDs lost');
            update('# Search\\n\\nalpha **beta** alpha 中文\\n\\n[alpha](https://example.com)\\n');
            const first=window.updateReaderSearch('alpha',false,0,0);
            const index=readerSearchIndex;
            const second=window.updateReaderSearch('beta',false,0,0);
            if(first.count!==3 || second.count!==1 || index!==readerSearchIndex) throw Error('Search index not reused or counts changed');
            if(window.updateReaderSearch('alpha beta',false,0,0).count!==1)throw Error('Inline-spanning search broke');
            window.updateReaderSearch('',false,0,0);
            if(readerSearchIndex!==null)throw Error('Closed search retained its index');
            window.updateReaderSearch('alpha',false,0,0);
            dispatchEvent(new Event('resize'));
            if(readerSearchIndex!==null)throw Error('Resize retained stale visibility index');
            const resized=window.updateReaderSearch('alpha',true,1,-1);
            if(resized.count!==3 || resized.index!==2)throw Error('Resize lost matches or backwards navigation');
            update('changed alpha');
            if(window.updateReaderSearch('alpha',false,0,0).count!==1)throw Error('Document update retained old matches');
            return true;
            """, arguments: [:], in: nil, in: .page) { continuation.resume(with: $0) }
        }
        guard result as? Bool == true else { throw Failure("Reader performance checks failed") }
        web.stopLoading()
    }
}

private extension DocumentFormattingService {
    func blockForCheck(entered: DispatchSemaphore, release: DispatchSemaphore) {
        entered.signal()
        release.wait()
    }
}
#endif
