import AppKit
import SwiftUI
import EasyMarkdownCore
import UniformTypeIdentifiers

@MainActor
final class MarkdownDocument: NSDocument {
    let session: DocumentSession

    init(snapshot: FileSnapshot, url: URL) {
        session = DocumentSession(snapshot: snapshot)
        super.init()
        fileURL = url
        fileType = "EasyMarkdown Document"
        session.document = self
        hasUndoManager = true
        updateUndoLimit(forByteCount: snapshot.data.count)
    }

    func updateUndoLimit(forByteCount count: Int) {
        // Estimate each undo group as a full-document replacement. This bounds
        // history depth, not exact heap bytes; AppKit also retains redo data.
        let levels = max(1, min(100, (32 * 1024 * 1024) / max(1, count)))
        if undoManager?.levelsOfUndo != levels { undoManager?.levelsOfUndo = levels }
    }

    nonisolated override class var autosavesInPlace: Bool { false }
    nonisolated override class var autosavesDrafts: Bool { false }
    nonisolated override class var readableTypes: [String] { ["EasyMarkdown Document"] }
    nonisolated override class var writableTypes: [String] { readableTypes }
    nonisolated override class func isNativeType(_ type: String) -> Bool { true }

    // AppKit adjusts its internal counter after undo notifications. The buffer's
    // cached baseline comparison is authoritative, including undo back to clean.
    override var isDocumentEdited: Bool { session.state.isDirty }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if let url = fileURL {
            savePanel.nameFieldStringValue = url.lastPathComponent
            savePanel.allowedContentTypes = []
            savePanel.allowsOtherFileTypes = true
        }
        return true
    }

    override func makeWindowControllers() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingView(rootView: DocumentView(session: session)
            .frame(minWidth: 620, minHeight: 420))
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 620, height: 420)
        window.setContentSize(NSSize(width: 980, height: 760))
        window.center()
        addWindowController(NSWindowController(window: window))
        session.start()
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        Task {
            do {
                try await session.performSave(to: url, operation: saveOperation)
                completionHandler(nil)
            } catch {
                await session.reload(force: true)?.value
                completionHandler(error)
            }
        }
    }

    // NSDocument's automatic revert would otherwise discard local unsaved text.
    nonisolated override func presentedItemDidChange() {
        Task { @MainActor [weak self] in self?.session.scheduleReload() }
    }

    nonisolated override func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        Task { @MainActor [weak self] in
            self?.session.state.markMissing()
            completionHandler(nil)
        }
    }

    nonisolated override func presentedItemDidMove(to newURL: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fileURL = newURL
            self.session.start()
            self.session.flash(L10n.text("文件位置已更新"))
        }
    }

    override func close() {
        session.stop(discardDraft: true)
        undoManager?.removeAllActions()
        let windows = windowControllers.compactMap(\.window)
        super.close()
        // AppKit can retain a closed window; it must not retain the entire document UI.
        for window in windows { window.contentView = nil }
    }
}
