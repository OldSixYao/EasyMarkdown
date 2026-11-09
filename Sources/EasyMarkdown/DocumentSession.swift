import AppKit
import Observation
import CryptoKit
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

struct ReaderSearchResume {
    let revision: UInt64
    let query: String
    let index: Int
    let offset: Int
}

@MainActor @Observable
final class DocumentSession {
    var state: DocumentState
    var mode: ViewMode = .read {
        didSet { previewActivity.update(active: isWindowActive, needed: kind == .markdown && mode != .edit) }
    }
    let previewActivity = PreviewActivity()
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
    var isFormatting = false
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
    @ObservationIgnored let imageBudgetOwner = UUID()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var draftWriteTask: Task<Void, Never>?
    @ObservationIgnored private var firstPendingDraftEdit: ContinuousClock.Instant?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var formatTask: Task<Void, Never>?
    @ObservationIgnored private var formatGeneration = 0
    @ObservationIgnored var readerSearchResume: ReaderSearchResume?
    @ObservationIgnored private var directorySubscription: DirectoryMonitor.Subscription?
    @ObservationIgnored private var pendingReloadForce = false
    @ObservationIgnored private var reloadAgain = false
    @ObservationIgnored private var reloadAgainForce = false
    var isWindowActive = true
    @ObservationIgnored private var lastSignature: String?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private(set) var reloadReadCount = 0
    @ObservationIgnored var replaceText: ((String) -> Void)?
    @ObservationIgnored var applyMarkdown: ((MarkdownCommand) -> Void)?
    @ObservationIgnored var editorFindAction: ((EditorFindRequest) -> Bool)?
    @ObservationIgnored var scrollEditorTo: ((SplitScrollPosition) -> Void)?
    @ObservationIgnored var scrollPreviewTo: ((SplitScrollPosition) -> Void)?
    @ObservationIgnored var alignPreviewToEditor: (() -> Void)?
    @ObservationIgnored var captureSourcePosition: (() -> SplitScrollPosition?)?

    private var sourcePositionKey: String? {
        guard let url else { return nil }
        let hash = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "sourceReadingPosition." + hash
    }

    func savedSourcePosition() -> SplitScrollPosition? {
        guard let key = sourcePositionKey else { return nil }
        if let value = UserDefaults.standard.dictionary(forKey: key), let offset = value["offset"] as? Double,
           let progress = value["progress"] as? Double {
            return SplitScrollPosition(offset: offset, progress: progress)
        }
        let legacyKey = key.replacingOccurrences(of: "sourceReadingPosition.", with: "readingPosition.")
        guard let ratio = UserDefaults.standard.dictionary(forKey: legacyKey)?["ratio"] as? Double else { return nil }
        return SplitScrollPosition(offset: Double(state.text.utf16.count) * ratio, progress: ratio)
    }

    func saveSourcePosition(_ position: SplitScrollPosition) {
        guard usesNativeReader, let key = sourcePositionKey else { return }
        UserDefaults.standard.set(position.arguments, forKey: key)
    }

    func showSearch() {
        if mode == .read && !usesNativeReader { showFind = true }
        else { requestEditorFind(.showFindInterface) }
    }

    func closeSearch() {
        showFind = false
        search = ""
        searchResultCount = nil
        if mode == .read && usesNativeReader { requestEditorFind(.hideFindInterface) }
    }

    func navigateSearch(backwards: Bool = false) {
        if mode == .read && !usesNativeReader {
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
        let query = mode == .read && !usesNativeReader ? search : nil
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
        guard mode != .read || usesNativeReader else { return }
        guard let request = pendingEditorFind,
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
    var usesNativeReader: Bool { kind != .markdown }

    func setWindowActive(_ active: Bool) {
        guard !closed else { return }
        let changed = isWindowActive != active
        isWindowActive = active
        previewActivity.update(active: active, needed: kind == .markdown && mode != .edit)
        if active && changed { scheduleReload() }
    }

    func updateWindowActivity() {
        let active = NSApp.isActive && document?.windowControllers.contains(where: {
            $0.window?.isKeyWindow == true && $0.window?.isMiniaturized == false
        }) == true
        setWindowActive(active)
    }

    func start() {
        closed = false
        if loadTask != nil {
            loadTask?.cancel()
            loadTask = nil
            reloadGeneration += 1
        }
        reloadAgain = false
        reloadAgainForce = false
        pendingReloadForce = false
        lastSignature = nil
        watchDirectory()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.closed == false else { return }
                // End the synchronous access to self before waiting for file I/O.
                if let subscription = self?.directorySubscription {
                    DirectoryMonitor.shared.ensureWatching(subscription)
                }
                let load = self?.reload(force: false)
                await load?.value
                try? await Task.sleep(for: .seconds(self?.isWindowActive == true ? 3 : 15))
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
        if usesNativeReader, let position = captureSourcePosition?() { saveSourcePosition(position) }
        closed = true
        previewActivity.stop()
        cancelFormatting()
        pollTask?.cancel(); reloadTask?.cancel(); loadTask?.cancel(); draftTask?.cancel(); draftWriteTask?.cancel(); statusTask?.cancel()
        pollTask = nil; reloadTask = nil; draftTask = nil; statusTask = nil
        loadTask = nil
        reloadGeneration += 1
        reloadAgain = false
        reloadAgainForce = false
        pendingReloadForce = false
        draftWriteTask = nil
        firstPendingDraftEdit = nil
        replaceText = nil; applyMarkdown = nil; editorFindAction = nil
        pendingEditorFind = nil
        scrollEditorTo = nil; scrollPreviewTo = nil; alignPreviewToEditor = nil
        captureSourcePosition = nil
        recovery = nil
        headings = []
        activeHeadingID = nil
        if let directorySubscription { DirectoryMonitor.shared.unsubscribe(directorySubscription) }
        directorySubscription = nil
        if discardDraft, let url { Task { try? await DraftStore.shared.remove(url) } }
    }

    private func watchDirectory() {
        if let directorySubscription { DirectoryMonitor.shared.unsubscribe(directorySubscription) }
        directorySubscription = nil
        // The deep benchmark never writes externally; exclude filesystem watcher
        // setup (which can wait on file-provider/TCC services) from renderer timings.
        if ProcessInfo.processInfo.environment["EASYMARKDOWN_MEMORY_PROFILE"] == "deep" { return }
        guard let url else { return }
        directorySubscription = DirectoryMonitor.shared.subscribe(to: url) { [weak self] in
            self?.scheduleReload(force: false)
        }
    }

    func scheduleReload(force: Bool = true) {
        guard !closed else { return }
        pendingReloadForce = pendingReloadForce || force
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let force = self?.pendingReloadForce == true
            self?.pendingReloadForce = false
            let load = self?.reload(force: force)
            await load?.value
        }
    }

    @discardableResult
    func reload(force: Bool) -> Task<Void, Never>? {
        guard !closed, !isSaving, let url else { return nil }
        if let loadTask {
            reloadAgain = true
            reloadAgainForce = reloadAgainForce || force
            return loadTask
        }
        reloadGeneration += 1
        let generation = reloadGeneration
        loadTask = Task { [weak self, store, lastSignature] in
            defer { self?.finishReload(generation: generation) }
            do {
                try Task.checkCancellation()
                let signature = try await store.signature(url)
                try Task.checkCancellation()
                guard force || signature != lastSignature else { return }
                let snapshot = try await store.read(url)
                guard !Task.isCancelled, let self, !self.closed, self.url == url,
                      !self.isSaving, generation == self.reloadGeneration else { return }
                self.reloadReadCount += 1
                let changed = snapshot.data != self.state.baseline.data
                let oldRevision = self.state.revision
                self.state.receive(snapshot)
                if oldRevision != self.state.revision { self.cancelFormatting() }
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

    private func finishReload(generation: Int) {
        guard generation == reloadGeneration else { return }
        loadTask = nil
        if reloadAgain && !closed {
            let force = reloadAgainForce
            reloadAgain = false
            reloadAgainForce = false
            scheduleReload(force: force)
        }
    }

    func edit(_ text: String, change: TextChange? = nil) {
        cancelFormatting()
        state.edit(text, change: change)
        synchronizeDirtyState()
        scheduleDraft()
    }

    func synchronizeDirtyState() {
        guard let document else { return }
        document.updateUndoLimit(forByteCount: state.byteCount)
        document.updateChangeCount(state.isDirty ? .changeDone : .changeCleared)
    }

    private func scheduleDraft() {
        draftTask?.cancel()
        guard url != nil, !closed else { return }
        let now = ContinuousClock.now
        if firstPendingDraftEdit == nil { firstPendingDraftEdit = now }
        let remaining = now.duration(to: firstPendingDraftEdit!.advanced(by: .seconds(2)))
        let delay = max(.zero, min(.milliseconds(500), remaining))
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushDraft()
        }
    }

    private func flushDraft() {
        draftTask = nil
        guard !closed, draftWriteTask == nil, let url else { return }
        firstPendingDraftEdit = nil
        let revision = state.revision
        let draft = state.isDirty ? RecoveryDraft(baseline: state.baseline.data, text: state.text,
            savedAt: Date(), baselineID: state.baseline.identity) : nil
        // An active writer keeps only its value snapshot. New input replaces
        // the pending timer, rather than cancelling every in-progress write.
        draftWriteTask = Task { [weak self] in
            do {
                if let draft { try await DraftStore.shared.save(draft, for: url) }
                else { try await DraftStore.shared.remove(url) }
            } catch {
                if !Task.isCancelled, self?.closed == false {
                    self?.status = L10n.format("草稿暂存失败：%@", error.localizedDescription)
                }
            }
            guard !Task.isCancelled, let self, !self.closed else { return }
            self.draftWriteTask = nil
            if self.state.revision != revision { self.scheduleDraft() }
        }
    }

    func restoreDraft() {
        guard let recovery else { return }
        cancelFormatting()
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
        cancelFormatting()
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
        cancelFormatting()
        isSaving = true
        defer { isSaving = false }
        loadTask?.cancel()
        loadTask = nil
        reloadGeneration += 1
        reloadAgain = false
        reloadAgainForce = false
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
        draftWriteTask?.cancel()
        draftWriteTask = nil
        firstPendingDraftEdit = nil
        state.didSave(snapshot, savedText: savedText)
        document?.fileURL = target
        previewActivity.update(active: isWindowActive, needed: kind == .markdown && mode != .edit)
        document?.fileModificationDate = try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        lastSignature = nil
        if let originalURL { try? await DraftStore.shared.remove(originalURL) }
        if state.isDirty { scheduleDraft() }
        synchronizeDirtyState()
        watchDirectory()
        flash(L10n.text("已保存"))
    }

    func saveAs() { document?.saveAs(nil) }

    private func cancelFormatting() {
        formatTask?.cancel()
        formatTask = nil
        formatGeneration += 1
        isFormatting = false
    }

    @discardableResult
    func format() -> Task<Void, Never>? {
        guard !closed, !isSaving, !isFormatting, mode != .read, replaceText != nil,
              kind == .json || kind == .xml else { return nil }
        let text = state.text, kind = kind, url = url
        let generation = formatGeneration
        isFormatting = true
        formatTask = Task { [weak self] in
            do {
                let formatted = try await DocumentFormattingService.shared.format(text, kind: kind)
                guard !Task.isCancelled, let self, !self.closed,
                      self.formatGeneration == generation else { return }
                self.formatTask = nil
                self.isFormatting = false
                guard !self.isSaving, self.mode != .read, self.url == url,
                      formatted != text else { return }
                // Apply through the editor only after validating the captured
                // revision. Native undo and input-method composition stay intact.
                self.replaceText?(formatted)
            } catch {
                guard !Task.isCancelled, let self, !self.closed,
                      self.formatGeneration == generation else { return }
                self.formatTask = nil
                self.isFormatting = false
                self.errorMessage = error.localizedDescription
            }
        }
        return formatTask
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
