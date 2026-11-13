import SwiftUI
import EasyMarkdownCore

/// NSTextView defers its selection notification until mouse-up during a drag.
/// Observe the intermediate native ranges without changing selection behavior.
@MainActor final class StatisticsTextView: NSTextView {
    var selectionDidChange: (() -> Void)?

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        selectionDidChange?()
    }
}

struct SourceEditor: NSViewRepresentable {
    let session: DocumentSession
    var isReadOnly = false
    var isSecondary = false
    var overrideText: String? = nil
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @AppStorage("readerFontSize") private var readerFontSize = 16.0
    @AppStorage(EditorPreferences.showLineNumbers, store: EditorPreferences.store) private var showLineNumbers = true

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, isSecondary: isSecondary, isOverride: overrideText != nil)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = StatisticsTextView(frame: .zero)
        text.isRichText = false
        text.allowsUndo = !isReadOnly
        text.isEditable = !isReadOnly && !session.isSaving
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.textContainerInset = NSSize(width: 28, height: 26)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.font = .monospacedSystemFont(ofSize: isReadOnly ? readerFontSize : fontSize, weight: .regular)
        text.string = overrideText ?? session.state.text
        text.delegate = context.coordinator
        text.setAccessibilityLabel(L10n.text(isReadOnly ? "文档内容" : "文档源码编辑器"))
        scroll.documentView = text
        context.coordinator.textView = text
        text.selectionDidChange = { [weak coordinator = context.coordinator] in coordinator?.selectionDidChange() }
        context.coordinator.observeStatistics()
        context.coordinator.observeScrolling(scroll)
        context.coordinator.updateLineNumbers(scroll, visible: showLineNumbers && !isReadOnly && !isSecondary && overrideText == nil)
        if !isSecondary && overrideText == nil {
        session.applyMarkdown = { [weak coordinator = context.coordinator] command in
            coordinator?.apply(command)
        }
        session.replaceText = { [weak coordinator = context.coordinator] value in
            coordinator?.replacePreservingPosition(value)
        }
        session.editorFindAction = { [weak coordinator = context.coordinator] request in
            coordinator?.performFind(request) ?? false
        }
        }
        DispatchQueue.main.async { [weak text, weak coordinator = context.coordinator] in
            guard let text else { return }
            if coordinator?.isSecondary == false && coordinator?.isOverride == false {
                if text.window?.isKeyWindow == true { text.window?.makeFirstResponder(text) }
                if coordinator?.session.usesNativeReader == true,
                   let position = coordinator?.session.savedSourcePosition() {
                    coordinator?.scroll(to: position)
                }
            }
            coordinator?.highlight()
            coordinator?.session.flushEditorFindRequest()
        }
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = context.coordinator.textView else { return }
        let size = isReadOnly ? readerFontSize : fontSize
        let fontChanged = text.font?.pointSize != CGFloat(size)
        if fontChanged {
            text.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let coordinator = context.coordinator
        let needsReplacement = overrideText.map { $0 != coordinator.overrideText } ??
            (coordinator.appliedRevision != session.state.revision)
        if needsReplacement && !text.hasMarkedText() {
            let incrementalChange = overrideText == nil && isSecondary && coordinator.appliedRevision &+ 1 == session.state.revision
                ? session.state.lastChange : nil
            let keepsUndo = !isSecondary && overrideText == nil && session.normalizedSaveRevision == session.state.revision
            let position = coordinator.replacementPosition(for: overrideText ?? session.state.text, change: incrementalChange)
            context.coordinator.updatingText = true
            coordinator.invalidateHighlighting()
            if let change = incrementalChange,
               change.range.location <= (text.textStorage?.length ?? 0),
               change.range.length <= (text.textStorage?.length ?? 0) - change.range.location {
                let replacement = (session.state.text as NSString).substring(with:
                    NSRange(location: change.range.location, length: change.replacementLength))
                text.textStorage?.replaceCharacters(in: change.range, with: replacement)
            } else if keepsUndo {
                let wasEditable = text.isEditable
                text.isEditable = true
                text.breakUndoCoalescing()
                text.insertText(session.state.text, replacementRange: NSRange(location: 0, length: text.textStorage?.length ?? 0))
                text.breakUndoCoalescing()
                text.undoManager?.setActionName(L10n.text("保存"))
                text.isEditable = wasEditable
            } else {
                text.string = overrideText ?? session.state.text
            }
            coordinator.appliedRevision = session.state.revision
            coordinator.overrideText = overrideText
            coordinator.restore(position)
            if !isSecondary && overrideText == nil && !keepsUndo { text.undoManager?.removeAllActions() }
            context.coordinator.highlight()
            context.coordinator.updatingText = false
        } else if fontChanged || coordinator.highlightedKind != session.kind {
            coordinator.highlight()
        }
        let editable = !isReadOnly && !session.isSaving
        if text.isEditable != editable {
            let viewport = SourceViewport(text)
            text.isEditable = editable
            viewport?.restore(in: text)
        }
        if text.allowsUndo != !isReadOnly { text.allowsUndo = !isReadOnly }
        context.coordinator.updateLineNumbers(scroll, visible: showLineNumbers && !isReadOnly && !isSecondary && overrideText == nil)
        text.setAccessibilityLabel(L10n.text(isReadOnly ? "文档内容" : "文档源码编辑器"))
        coordinator.scheduleStatistics()
        if !isReadOnly, !isSecondary, overrideText == nil, coordinator.focusRequest != session.editorFocusRequest {
            coordinator.focusRequest = session.editorFocusRequest
            DispatchQueue.main.async { [weak text, weak coordinator] in
                guard let text, let coordinator, !coordinator.session.closed, text.isEditable,
                      let window = text.window, window.attachedSheet == nil else { return }
                window.makeFirstResponder(text)
            }
        }
        if !isSecondary && overrideText == nil && session.pendingEditorFind != nil {
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                coordinator?.session.flushEditorFindRequest()
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.verticalRulerView as? LineNumberRulerView)?.invalidate()
        scroll.verticalRulerView = nil
        coordinator.highlightTask?.cancel()
        coordinator.highlightTask = nil
        coordinator.invalidateHighlighting()
        coordinator.scrollTask?.cancel()
        coordinator.scrollTask = nil
        coordinator.positionTask?.cancel()
        coordinator.positionTask = nil
        coordinator.stopStatistics()
        if let observer = coordinator.scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.scrollObserver = nil
        }
        if let text = coordinator.textView {
            (text as? StatisticsTextView)?.selectionDidChange = nil
            text.undoManager?.removeAllActions(withTarget: text)
            text.delegate = nil
        }
        coordinator.textView = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let session: DocumentSession
        weak var textView: NSTextView?
        var highlightTask: Task<Void, Never>?
        var scrollTask: Task<Void, Never>?
        var positionTask: Task<Void, Never>?
        var scrollObserver: NSObjectProtocol?
        var synchronizedY: CGFloat?
        var updatingText = false
        var focusRequest = 0
        var appliedRevision: UInt64
        let isSecondary: Bool
        let isOverride: Bool
        var overrideText: String?
        private var pendingChange: TextChange?
        private var highlightedRange: NSRange?
        private var highlightedViewport: NSRect?
        fileprivate var highlightedKind: DocumentKind?
        private var highlightedContainerWidth: CGFloat?
        private var isHighlighting = false
        private var highlightGeneration: UInt64 = 0
        private var highlightSnapshot: [SourceHighlighting.Token]?
        private var highlightSnapshotKind: DocumentKind?
        private var highlightSnapshotRequested = false
        private var highlightSnapshotTask: Task<[SourceHighlighting.Token]?, Never>?
        private var highlightSnapshotCompletion: Task<Void, Never>?
        private(set) var statisticsIndex: DocumentStatisticsIndex?
        private var statisticsObserver: NSObjectProtocol?
        private var statisticsRefresh: Timer?
        private var statisticsDirty = true
        private var statisticsSelection: [NSRange]?
        private var statisticsMode: ViewMode?
        private let statisticsID = UUID()

        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            if let statisticsObserver { NotificationCenter.default.removeObserver(statisticsObserver) }
            statisticsRefresh?.invalidate()
            highlightSnapshotTask?.cancel()
            highlightSnapshotCompletion?.cancel()
        }

        init(session: DocumentSession, isSecondary: Bool = false, isOverride: Bool = false) {
            self.session = session
            self.isSecondary = isSecondary
            self.isOverride = isOverride
            appliedRevision = session.state.revision
        }

        func observeStatistics() {
            guard !isOverride, let textView else { return }
            statisticsObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                object: textView.textStorage, queue: .main) { [weak self] event in
                    MainActor.assumeIsolated {
                        guard let self, let storage = event.object as? NSTextStorage,
                              storage.editedMask.contains(.editedCharacters) else { return }
                        self.statisticsIndex?.applyEdit(in: storage.editedRange,
                            lengthDelta: storage.changeInLength, text: storage.string as NSString)
                        self.statisticsDirty = true
                        self.scheduleStatistics()
                    }
                }
            scheduleStatistics()
        }

        func scheduleStatistics() {
            guard !isOverride, statisticsRefresh == nil else { return }
            let refresh = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.statisticsRefresh = nil
                    self.refreshStatistics()
                }
            }
            statisticsRefresh = refresh
            // Publishing during an NSViewRepresentable update or text-storage
            // processing can reenter SwiftUI/layout. Coalesce on the next turn.
            // Common modes also run while AppKit tracks a mouse drag.
            RunLoop.main.add(refresh, forMode: .common)
        }

        private func refreshStatistics() {
            guard let textView, textView.delegate === self else { return }
            if statisticsMode != session.mode { statisticsSelection = nil; statisticsMode = session.mode }
            let ownsSelection = session.statisticsSelectionOwner == statisticsID || (!isSecondary && session.statisticsSelectionOwner == nil)
            guard !isSecondary || ownsSelection else { return }
            let source = textView.string as NSString
            if statisticsIndex == nil {
                statisticsIndex = DocumentStatisticsIndex(source)
                statisticsDirty = true
            }
            let ranges = textView.selectedRanges.map(\.rangeValue)
            guard statisticsDirty || statisticsSelection != ranges else { return }
            guard let statistics = statisticsIndex?.statistics(in: source, selectedRanges: ranges) else { return }
            statisticsSelection = ranges
            statisticsDirty = false
            if ownsSelection {
                if session.editorStatistics != statistics { session.editorStatistics = statistics }
            } else if session.editorStatistics.total != statistics.total {
                session.editorStatistics.total = statistics.total
            }
        }

        func stopStatistics() {
            if let statisticsObserver { NotificationCenter.default.removeObserver(statisticsObserver) }
            statisticsObserver = nil
            statisticsRefresh?.invalidate()
            statisticsRefresh = nil
            statisticsIndex = nil
        }

        func selectionDidChange() {
            guard !isOverride, !updatingText else { return }
            session.statisticsSelectionOwner = statisticsID
            // The same native ranges can become active again after selecting in
            // another pane; force that ownership change to publish too.
            statisticsSelection = nil
            scheduleStatistics()
        }

        func textViewDidChangeSelection(_ notification: Notification) { selectionDidChange() }

        func updateLineNumbers(_ scroll: NSScrollView, visible: Bool) {
            guard let text = textView else { return }
            let existing = scroll.verticalRulerView as? LineNumberRulerView
            guard visible || existing != nil else { return }
            let changesWidth = visible != (existing != nil) || (visible && existing?.desiredThickness != existing?.ruleThickness)
            let anchor = changesWidth && !text.hasMarkedText() && text.window != nil ? scrollPosition() : nil
            if visible {
                let ruler = existing ?? LineNumberRulerView(scrollView: scroll, textView: text)
                if existing == nil {
                    scroll.verticalRulerView = ruler
                    scroll.hasVerticalRuler = true
                    scroll.hasHorizontalRuler = false
                    scroll.rulersVisible = true
                    ruler.metricsDidChange = { [weak self, weak scroll] in
                        guard let scroll else { return }
                        self?.updateLineNumbers(scroll, visible: true)
                    }
                }
                ruler.refreshMetrics()
            } else {
                existing?.invalidate()
                scroll.rulersVisible = false
                scroll.hasVerticalRuler = false
                scroll.verticalRulerView = nil
            }
            if let anchor {
                scroll.tile()
                self.scroll(to: anchor)
            }
        }

        func performFind(_ request: EditorFindRequest) -> Bool {
            guard let textView, let window = textView.window, textView.delegate === self else { return false }
            if request.action == .showReplaceInterface && !textView.isEditable { return false }
            if let query = request.query {
                let pasteboard = NSPasteboard(name: .find)
                pasteboard.clearContents()
                pasteboard.setString(query, forType: .string)
            }
            window.makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = request.action.rawValue
            textView.performTextFinderAction(item)
            return true
        }

        func observeScrolling(_ scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.didScroll() }
                }
            guard !isOverride else { return }
            if isSecondary {
                session.scrollPreviewTo = { [weak self] position in self?.scroll(to: position) }
                return
            }
            session.scrollEditorTo = { [weak self] position in self?.scroll(to: position) }
            session.captureSourcePosition = { [weak self] in self?.scrollPosition() }
            session.alignPreviewToEditor = { [weak self] in
                guard let self, let position = self.scrollPosition() else { return }
                self.session.editorDidScroll(position)
            }
        }

        func scrollPosition() -> SplitScrollPosition? {
            guard let textView, let scroll = textView.enclosingScrollView,
                  let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
            let top = scroll.contentView.bounds.minY
            let point = NSPoint(x: 0, y: max(0, top - textView.textContainerInset.height))
            // Only lay out through the visible line, not the entire document.
            // numberOfGlyphs would also force glyph generation for the whole text.
            let visible = NSRect(origin: point, size: NSSize(width: container.containerSize.width, height: 1))
            layout.ensureLayout(forBoundingRect: visible, in: container)
            let visibleGlyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: container)
            let maximum = max(0, textView.bounds.height - scroll.contentView.bounds.height)
            let progress = maximum > 0 ? min(1, max(0, top / maximum)) : 0
            guard visibleGlyphs.length > 0 else {
                return SplitScrollPosition(offset: Double(textView.textStorage?.length ?? 0), progress: progress)
            }
            let glyph = min(NSMaxRange(visibleGlyphs) - 1, layout.glyphIndex(for: point, in: container))
            var glyphRange = NSRange()
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphRange)
            let characters = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let fraction = min(1, max(0, (top - textView.textContainerInset.height - rect.minY) / max(1, rect.height)))
            return SplitScrollPosition(offset: Double(characters.location) + Double(characters.length) * fraction,
                                       progress: progress)
        }

        private func didScroll() {
            (textView?.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.needsDisplay = true
            // 滚动不能复用输入防抖：连续事件会不断推迟着色，露出默认文字颜色。
            if !updatingText && pendingChange == nil { highlight(onlyIfNeeded: true) }
            if !isSecondary && !isOverride && session.usesNativeReader {
                positionTask?.cancel()
                positionTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, let self, let position = self.scrollPosition() else { return }
                    self.session.saveSourcePosition(position)
                }
            }
            guard session.mode == .split, session.synchronizeSplitScroll,
                  !isOverride, !updatingText, appliedRevision == session.state.revision, let textView,
                  let top = textView.enclosingScrollView?.contentView.bounds.minY else { return }
            // A matching bounds notification acknowledges a synchronized move.
            if let synchronizedY, abs(top - synchronizedY) < 1 { return }
            synchronizedY = nil
            guard scrollTask == nil else { return }
            scrollTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                self.scrollTask = nil
                guard self.session.mode == .split, self.session.synchronizeSplitScroll,
                      !self.updatingText, self.synchronizedY == nil,
                      self.appliedRevision == self.session.state.revision,
                      let position = self.scrollPosition() else { return }
                if self.isSecondary { self.session.previewDidScroll(position) }
                else { self.session.editorDidScroll(position) }
            }
        }

        struct ReplacementPosition {
            let ranges: [NSRange]
            var viewport: SourceViewport?
        }

        func replacementPosition(for value: String, change: TextChange? = nil) -> ReplacementPosition {
            guard let textView else { return ReplacementPosition(ranges: [], viewport: nil) }
            let ranges = textView.selectedRanges.map(\.rangeValue)
            var viewport = SourceViewport(textView)
            let offsets = ranges.flatMap { [$0.location, NSMaxRange($0)] } + (viewport.map { [$0.offset] } ?? [])
            let mapped: [Int]
            if let change, change.range.length != (textView.textStorage?.length ?? 0) {
                // 分栏逐次输入只平移受影响位置，不为每次按键扫描全文。
                mapped = offsets.map { offset in
                    if offset < change.range.location { return offset }
                    if offset >= NSMaxRange(change.range) { return offset + change.replacementLength - change.range.length }
                    return change.range.location + min(offset - change.range.location, change.replacementLength)
                }
            } else {
                mapped = TextPositionMapping.map(offsets, from: textView.string, to: value)
            }
            let selections = ranges.indices.map { index in
                let start = mapped[index * 2], end = mapped[index * 2 + 1]
                return NSRange(location: min(start, end), length: abs(end - start))
            }
            if viewport != nil { viewport?.offset = mapped.last! }
            return ReplacementPosition(ranges: selections, viewport: viewport)
        }

        func restore(_ position: ReplacementPosition) {
            guard let textView else { return }
            textView.setSelectedRanges(position.ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
            position.viewport?.restore(in: textView)
            synchronizedY = textView.enclosingScrollView?.contentView.bounds.minY
            scrollTask?.cancel()
            scrollTask = nil
        }

        func replacePreservingPosition(_ value: String) {
            guard let textView, textView.delegate === self, textView.isEditable, !textView.hasMarkedText() else { return }
            let position = replacementPosition(for: value)
            // 正文替换仍经过原生输入与撤销；禁止中间跳到末尾的通知传播到另一侧。
            scrollTask?.cancel()
            scrollTask = nil
            textView.breakUndoCoalescing()
            textView.insertText(value, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
            textView.breakUndoCoalescing()
            textView.undoManager?.setActionName(L10n.text("格式化"))
            updatingText = true
            restore(position)
            updatingText = false
            selectionDidChange()
        }

        fileprivate func scroll(to position: SplitScrollPosition) {
            guard let textView, let scroll = textView.enclosingScrollView,
                  let layout = textView.layoutManager,
                  !textView.hasMarkedText() else { return }
            let length = textView.textStorage?.length ?? 0
            var y: CGFloat
            if position.progress <= 0.0001 { y = 0 }
            else if length > 0 {
                let offset = position.progress >= 0.9999 ? Double(length - 1) :
                    min(Double(length - 1), max(0, position.offset))
                layout.ensureLayout(forCharacterRange: NSRange(location: Int(offset), length: 1))
                let glyph = layout.glyphIndexForCharacter(at: Int(offset))
                var glyphRange = NSRange()
                let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphRange)
                let characters = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                let fraction = (offset - Double(characters.location)) / Double(max(1, characters.length))
                y = textView.textContainerInset.height + rect.minY + rect.height * min(1, max(0, fraction))
            } else { y = 0 }
            let maximum = max(0, textView.bounds.height - scroll.contentView.bounds.height)
            if position.progress >= 0.9999 { y = maximum }
            y = min(maximum, max(0, y))
            synchronizedY = y
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func apply(_ command: MarkdownCommand) {
            guard let textView, textView.isEditable, !session.isSaving, session.kind == .markdown else { return }
            textView.window?.makeFirstResponder(textView)
            // Commit an active input-method composition before interpreting its range.
            if textView.hasMarkedText() { textView.unmarkText() }
            let edit = MarkdownEditing.edit(command, text: textView.string, selection: textView.selectedRange())
            textView.breakUndoCoalescing()
            textView.insertText(edit.replacement, replacementRange: edit.range)
            textView.breakUndoCoalescing()
            textView.undoManager?.setActionName(command.title)
            textView.setSelectedRange(edit.selection)
            textView.scrollRangeToVisible(edit.selection)
        }
        func textDidChange(_ notification: Notification) {
            guard let textView, !updatingText, !isSecondary, !isOverride else { return }
            invalidateHighlighting()
            if let range = highlightedRange, let change = pendingChange,
               change.range.location < NSMaxRange(range) {
                let delta = change.replacementLength - change.range.length
                let start = max(0, min(range.location, range.location + delta))
                let end = max(NSMaxRange(range), NSMaxRange(range) + delta)
                highlightedRange = NSRange(location: start, length: end - start)
            }
            session.edit(textView.string, change: pendingChange)
            selectionDidChange()
            pendingChange = nil
            appliedRevision = session.state.revision
            scheduleHighlight()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard !updatingText, let replacementString else { pendingChange = nil; return true }
            let source = textView.string as NSString
            guard affectedCharRange.location <= source.length,
                  affectedCharRange.length <= source.length - affectedCharRange.location else { return false }
            pendingChange = TextChange(range: affectedCharRange, replacement: replacementString,
                removed: source.substring(with: affectedCharRange))
            return true
        }

        func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                      replacementStrings: [String]?) -> Bool {
            guard let replacementStrings, affectedRanges.count == replacementStrings.count,
                  !affectedRanges.isEmpty else { pendingChange = nil; return true }
            if affectedRanges.count == 1 {
                return self.textView(textView, shouldChangeTextIn: affectedRanges[0].rangeValue,
                                     replacementString: replacementStrings[0])
            }
            let source = textView.string as NSString
            let ranges = affectedRanges.map(\.rangeValue)
            var start = source.length, end = 0, lengthDelta = 0, byteDelta = 0
            for (range, replacement) in zip(ranges, replacementStrings) {
                guard range.location <= source.length, range.length <= source.length - range.location else { return false }
                start = min(start, range.location)
                end = max(end, NSMaxRange(range))
                lengthDelta += replacement.utf16.count - range.length
                byteDelta += replacement.utf8.count - source.substring(with: range).utf8.count
            }
            pendingChange = TextChange(range: NSRange(location: start, length: end - start),
                replacementLength: end - start + lengthDelta, utf8Delta: byteDelta)
            return true
        }

        private func scheduleHighlight() {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.highlightTask = nil
                self.highlight()
            }
        }

        func invalidateHighlighting() {
            highlightGeneration &+= 1
            highlightedViewport = nil
            highlightSnapshot = nil
            highlightSnapshotRequested = false
            highlightSnapshotTask?.cancel()
            highlightSnapshotTask = nil
            highlightSnapshotCompletion?.cancel()
            highlightSnapshotCompletion = nil
        }

        private func prepareHighlightSnapshot(source: String, view: NSTextView) {
            guard !highlightSnapshotRequested else { return }
            highlightSnapshotRequested = true
            let generation = highlightGeneration
            let kind = session.kind
            // 后台只处理不可变正文和语法范围，不访问原生视图或颜色对象。
            let worker = Task.detached(priority: .userInitiated) {
                SourceHighlighting.snapshot(in: source, kind: kind)
            }
            highlightSnapshotTask = worker
            highlightSnapshotCompletion = Task { @MainActor [weak self, weak view] in
                let snapshot = await worker.value
                guard !Task.isCancelled, let self, let view, self.textView === view,
                      self.highlightGeneration == generation, self.session.kind == kind else { return }
                self.highlightSnapshotTask = nil
                self.highlightSnapshotCompletion = nil
                guard let snapshot, view.string == source else { return }
                self.highlightSnapshot = snapshot
                // 当前视口可能来自尚未完成的局部扫描，快照就绪后必须重新应用。
                self.highlight()
            }
        }

        private static func color(for style: SourceHighlighting.Style) -> NSColor {
            switch style {
            case .key: return .systemGreen
            case .string, .heading: return .systemBlue
            case .literal: return .systemPurple
            case .comment: return .secondaryLabelColor
            case .code: return .systemOrange
            case .link: return .systemTeal
            }
        }

        func highlight(onlyIfNeeded: Bool = false) {
            guard !isHighlighting, let view = textView, !view.hasMarkedText(), let storage = view.textStorage,
                  let layout = view.layoutManager, let container = view.textContainer else { return }
            if highlightSnapshotKind != session.kind {
                invalidateHighlighting()
                highlightSnapshotKind = session.kind
            }
            if onlyIfNeeded, highlightedKind == session.kind,
               highlightedContainerWidth == container.containerSize.width,
               let highlightedViewport, highlightedViewport.contains(view.visibleRect) { return }
            // 局部排版可能引起新的边界通知，防止同步滚动着色重入。
            isHighlighting = true
            defer { isHighlighting = false }
            highlightedViewport = nil
            highlightedKind = session.kind
            highlightedContainerWidth = container.containerSize.width
            let entire = NSRange(location: 0, length: storage.length)
            // Color is presentation, not a text edit: avoid invalidating the
            // storage/layout or retaining attributed copies in the undo history.
            if let highlightedRange {
                layout.removeTemporaryAttribute(.foregroundColor,
                    forCharacterRange: NSIntersectionRange(highlightedRange, entire))
                self.highlightedRange = nil
            }
            guard storage.length > 0, session.kind != .text,
                  isOverride || session.state.byteCount < SourceHighlighting.maximumScanLength else { return }
            let source = view.string
            guard !isOverride || source.utf8.count < SourceHighlighting.maximumScanLength else { return }
            prepareHighlightSnapshot(source: source, view: view)
            var range = entire
            let viewport = view.visibleRect
            let bufferedViewport = viewport.insetBy(dx: 0, dy: -max(250, viewport.height))
            if !viewport.isEmpty {
                // 所有格式都只更新视口及上下各一屏；词法扫描仍保留多行上下文。
                var visible = bufferedViewport
                visible.origin.x -= view.textContainerInset.width
                visible.origin.y -= view.textContainerInset.height
                let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
                if glyphs.length > 0 {
                    let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                    range = (source as NSString).lineRange(for: NSIntersectionRange(characters, entire))
                }
            }
            // Expanding a wrapped visible line must not turn highlighting into
            // an unbounded scan. Long logical lines keep the default text color.
            let ranges = SourceHighlighting.boundedLineRanges(in: source as NSString, range: range)
            highlightedRange = range
            var tokens: [SourceHighlighting.Token] = []
            let completed: Bool
            if let highlightSnapshot {
                // 保留词法输出次序，标题、链接等重叠样式继续按原有优先级覆盖。
                for token in highlightSnapshot {
                    let part = NSIntersectionRange(token.range, range)
                    if part.length > 0 { tokens.append(SourceHighlighting.Token(range: part, style: token.style)) }
                }
                completed = true
            } else {
                completed = SourceHighlighting.enumerate(in: source, kind: session.kind, ranges: ranges) { range, style in
                    tokens.append(SourceHighlighting.Token(range: range, style: style))
                }
            }
            for token in tokens {
                layout.addTemporaryAttribute(.foregroundColor, value: Self.color(for: token.style), forCharacterRange: token.range)
            }
            if completed, !viewport.isEmpty {
                // 接近预着色区边缘时提前刷新，未完成的扫描不能作为覆盖缓存。
                highlightedViewport = bufferedViewport.insetBy(dx: 0, dy: min(250, viewport.height / 2))
            }
        }

    }
}
