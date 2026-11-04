import AppKit
import Observation
import EasyMarkdownCore

enum ViewMode: String, CaseIterable { case read = "阅读", edit = "编辑", split = "分栏" }

struct EditorFindRequest {
    let action: NSTextFinder.Action
    var query: String? = nil
}

struct Heading: Identifiable, Decodable {
    let id: String
    let title: String
    let level: Int
}

@MainActor @Observable
final class DocumentSession {
    var state: DocumentState
    var mode: ViewMode = .read
    var showOutline = false
    var showFind = false
    var search = "" {
        didSet {
            if search != oldValue { searchResultCount = nil; findBackwards = false }
        }
    }
    var findRequest = 0
    var findBackwards = false
    var findOffset = 0
    var searchResultCount: Int?
    var searchIsTruncated = false
    var pendingEditorFind: EditorFindRequest?
    var headings: [Heading] = []
    var activeHeadingID: String?
    var scrollTarget: String?
    var scrollRequest = 0
    var status = ""
    var errorMessage: String?
    var recovery: RecoveryDraft?
    var isSaving = false
    var saveFailure: String?
    var saveStateLabel: String {
        if isSaving { return L10n.text("正在保存…") }
        if state.isDirty { return saveFailure == nil ? L10n.text("未保存") : L10n.text("保存失败 · 未保存") }
        return L10n.text("已保存")
    }
    var showExternal = false
    var synchronizeSplitScroll = true
    @ObservationIgnored weak var document: MarkdownDocument?
    @ObservationIgnored let store = FileStore()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var directorySource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var lastSignature: String?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored var replaceText: ((String) -> Void)?
    @ObservationIgnored var applyMarkdown: ((MarkdownCommand) -> Void)?
    @ObservationIgnored var editorFindAction: ((EditorFindRequest) -> Bool)?
    @ObservationIgnored var scrollEditorTo: ((SplitScrollPosition) -> Void)?
    @ObservationIgnored var scrollPreviewTo: ((SplitScrollPosition) -> Void)?
    @ObservationIgnored var alignPreviewToEditor: (() -> Void)?

    func showSearch() {
        if mode == .read { showFind = true }
        else { requestEditorFind(.showFindInterface) }
    }

    func closeSearch() {
        showFind = false
        search = ""
        searchResultCount = nil
    }

    func navigateSearch(backwards: Bool = false) {
        if mode == .read {
            guard !search.isEmpty else { return }
            showFind = true
            findBackwards = backwards
            findOffset += backwards ? -1 : 1
            findRequest += 1
        } else {
            requestEditorFind(backwards ? .previousMatch : .nextMatch)
        }
    }

    func showReplace() {
        guard !isSaving else { return }
        let query = mode == .read ? search : nil
        showFind = false
        searchResultCount = nil
        if mode == .read { mode = .edit }
        requestEditorFind(.showReplaceInterface, query: query)
    }

    func requestEditorFind(_ action: NSTextFinder.Action, query: String? = nil) {
        pendingEditorFind = EditorFindRequest(action: action, query: query)
        flushEditorFindRequest()
    }

    func flushEditorFindRequest() {
        guard mode != .read, let request = pendingEditorFind,
              editorFindAction?(request) == true else { return }
        pendingEditorFind = nil
    }

    func editorDidScroll(_ position: SplitScrollPosition) {
        guard mode == .split, synchronizeSplitScroll else { return }
        scrollPreviewTo?(position)
    }

    func previewDidScroll(_ position: SplitScrollPosition) {
        guard mode == .split, synchronizeSplitScroll else { return }
        scrollEditorTo?(position)
    }

    init(snapshot: FileSnapshot) { state = DocumentState(snapshot: snapshot) }
    var url: URL? { document?.fileURL }
    var kind: DocumentKind { DocumentKind(url: url) }

    func start() {
        closed = false
        watchDirectory()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.closed == false else { return }
                // End the synchronous access to self before waiting for file I/O.
                let load = self?.reload(force: false)
                await load?.value
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
        if let url {
            Task { [weak self] in
                do {
                    let draft = try await DraftStore.shared.load(url)
                    guard let self, !self.closed, let draft, draft.text != self.state.text else { return }
                    self.recovery = draft
                } catch { self?.errorMessage = L10n.format("恢复草稿无法读取：%@", error.localizedDescription) }
            }
        }
    }

    func stop(discardDraft: Bool) {
        closed = true
        pollTask?.cancel(); reloadTask?.cancel(); loadTask?.cancel(); draftTask?.cancel(); statusTask?.cancel(); watchTask?.cancel()
        pollTask = nil; reloadTask = nil; draftTask = nil; statusTask = nil
        loadTask = nil
        watchTask = nil
        replaceText = nil; applyMarkdown = nil; editorFindAction = nil
        pendingEditorFind = nil
        scrollEditorTo = nil; scrollPreviewTo = nil; alignPreviewToEditor = nil
        recovery = nil
        headings = []
        activeHeadingID = nil
        directorySource?.cancel(); directorySource = nil
        if discardDraft, let url { Task { try? await DraftStore.shared.remove(url) } }
    }

    private func watchDirectory() {
        directorySource?.cancel()
        directorySource = nil
        watchTask?.cancel()
        // The deep benchmark never writes externally; exclude filesystem watcher
        // setup (which can wait on file-provider/TCC services) from renderer timings.
        if ProcessInfo.processInfo.environment["EASYMARKDOWN_MEMORY_PROFILE"] == "deep" { return }
        guard let url else { return }
        let path = url.deletingLastPathComponent().path
        watchTask = Task { [weak self] in
            // File providers and volume authorization can block open(). Never
            // keep the window/event loop waiting for directory monitoring.
            let descriptor = await Task.detached(priority: .utility) { open(path, O_EVTONLY) }.value
            guard let self, !Task.isCancelled, !self.closed, self.url == url, descriptor >= 0 else {
                if descriptor >= 0 { close(descriptor) }
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib], queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleReload() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.directorySource = source
        }
    }

    func scheduleReload() {
        guard !closed else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let load = self?.reload(force: true)
            await load?.value
        }
    }

    @discardableResult
    func reload(force: Bool) -> Task<Void, Never>? {
        guard !closed, !isSaving, let url else { return nil }
        loadTask?.cancel()
        reloadGeneration += 1
        let generation = reloadGeneration
        loadTask = Task { [weak self, store, lastSignature] in
            do {
                try Task.checkCancellation()
                let signature = try await store.signature(url)
                try Task.checkCancellation()
                guard force || signature != lastSignature else { return }
                let snapshot = try await store.read(url)
                guard !Task.isCancelled, let self, !self.closed, self.url == url,
                      !self.isSaving, generation == self.reloadGeneration else { return }
                let changed = snapshot.data != self.state.baseline.data
                self.state.receive(snapshot)
                self.lastSignature = signature
                self.synchronizeDirtyState()
                if changed && !self.state.hasConflict { self.flash(L10n.text("已加载最新内容")) }
            } catch {
                guard !Task.isCancelled else { return }
                let missing = await store.isMissing(url)
                guard !Task.isCancelled, let self, !self.closed, self.url == url,
                      !self.isSaving, generation == self.reloadGeneration else { return }
                // Atomic replacement can briefly remove the path. Retry through the poll loop.
                if missing { self.state.markMissing() }
                else { self.status = L10n.format("暂时无法更新：%@", error.localizedDescription) }
            }
        }
        return loadTask
    }

    func edit(_ text: String) {
        state.text = text
        synchronizeDirtyState()
        scheduleDraft()
    }

    func synchronizeDirtyState() {
        guard let document else { return }
        document.updateUndoLimit(forByteCount: state.text.utf8.count)
        document.updateChangeCount(state.isDirty ? .changeDone : .changeCleared)
    }

    private func scheduleDraft() {
        draftTask?.cancel()
        guard let url else { return }
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, self?.closed == false, let state = self?.state else { return }
            do {
                if state.isDirty {
                    let draft = RecoveryDraft(baseline: state.baseline.data, text: state.text, savedAt: Date())
                    try await DraftStore.shared.save(draft, for: url)
                }
                else { try await DraftStore.shared.remove(url) }
            } catch {
                guard !Task.isCancelled, self?.closed == false else { return }
                self?.status = L10n.format("草稿暂存失败：%@", error.localizedDescription)
            }
        }
    }

    func restoreDraft() {
        guard let recovery else { return }
        let current = state.baseline
        do {
            state = DocumentState(snapshot: try FileSnapshot(data: recovery.baseline))
            state.text = recovery.text
            state.receive(current)
            mode = .edit
            self.recovery = nil
            synchronizeDirtyState()
            scheduleDraft()
        } catch { errorMessage = error.localizedDescription }
    }

    func discardRecovery() {
        recovery = nil
        if let url { Task { try? await DraftStore.shared.remove(url) } }
    }

    func acceptExternal() {
        let alert = NSAlert()
        alert.messageText = L10n.text("加载外部版本？")
        alert.informativeText = L10n.text("本地尚未保存的修改将被放弃。你也可以先将本地内容另存为。")
        alert.addButton(withTitle: L10n.text("加载外部版本")); alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.acceptExternal()
        document?.undoManager?.removeAllActions()
        synchronizeDirtyState(); scheduleDraft()
    }

    func save(finishing: Bool = false) {
        guard let document, let url, !isSaving else { return }
        document.save(to: url, ofType: document.fileType ?? "EasyMarkdown Document", for: .saveOperation) { [weak self] error in
            guard let self else { return }
            if let error { self.errorMessage = error.localizedDescription }
            else if finishing && !self.state.isDirty { self.mode = .read }
        }
    }

    func performSave(to target: URL, operation: NSDocument.SaveOperationType) async throws {
        guard !isSaving else { throw CocoaError(.userCancelled) }
        isSaving = true
        defer { isSaving = false }
        let originalURL = url
        let sameFile = target.standardizedFileURL == originalURL?.standardizedFileURL
        let savedText = state.text
        let snapshot: FileSnapshot
        do {
            snapshot = try await store.save(savedText, to: target, baseline: state.baseline,
                                            requireUnchanged: sameFile)
        } catch {
            saveFailure = error.localizedDescription
            throw error
        }
        saveFailure = nil
        draftTask?.cancel()
        state.didSave(snapshot, savedText: savedText)
        document?.fileURL = target
        document?.fileModificationDate = try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        lastSignature = nil
        if let originalURL { try? await DraftStore.shared.remove(originalURL) }
        if state.isDirty { scheduleDraft() }
        synchronizeDirtyState()
        watchDirectory()
        flash(L10n.text("已保存"))
    }

    func saveAs() { document?.saveAs(nil) }

    func format() {
        guard !isSaving else { return }
        do {
            let formatted = try DocumentFormatter.format(state.text, kind: kind)
            // Formatting is available while the editor is mounted and uses native undo.
            replaceText?(formatted)
        } catch { errorMessage = error.localizedDescription }
    }

    func flash(_ message: String) {
        statusTask?.cancel()
        status = message
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.status = ""
        }
    }
}
