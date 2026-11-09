import SwiftUI
import EasyMarkdownCore

struct SourceEditor: NSViewRepresentable {
    let session: DocumentSession
    var isReadOnly = false
    var isSecondary = false
    var overrideText: String? = nil
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @AppStorage("readerFontSize") private var readerFontSize = 16.0

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, isSecondary: isSecondary, isOverride: overrideText != nil)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = NSTextView(frame: .zero)
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
        context.coordinator.observeScrolling(scroll)
        if !isSecondary && overrideText == nil {
        session.applyMarkdown = { [weak coordinator = context.coordinator] command in
            coordinator?.apply(command)
        }
        session.replaceText = { [weak text, weak coordinator = context.coordinator] value in
            guard let text, let coordinator, text.delegate === coordinator,
                  text.isEditable, !text.hasMarkedText() else { return }
            text.breakUndoCoalescing()
            text.insertText(value, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
            text.breakUndoCoalescing()
            text.undoManager?.setActionName(L10n.text("格式化"))
        }
        session.editorFindAction = { [weak coordinator = context.coordinator] request in
            coordinator?.performFind(request) ?? false
        }
        }
        DispatchQueue.main.async { [weak text, weak coordinator = context.coordinator] in
            guard let text else { return }
            if coordinator?.isSecondary == false && coordinator?.isOverride == false {
                text.window?.makeFirstResponder(text)
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
        if text.font?.pointSize != CGFloat(size) {
            text.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let coordinator = context.coordinator
        let needsReplacement = overrideText.map { $0 != coordinator.overrideText } ??
            (coordinator.appliedRevision != session.state.revision)
        if needsReplacement && !text.hasMarkedText() {
            context.coordinator.updatingText = true
            let range = text.selectedRange()
            let visible = scroll.contentView.bounds.origin
            if overrideText == nil, isSecondary,
               coordinator.appliedRevision &+ 1 == session.state.revision,
               let change = session.state.lastChange,
               change.range.location <= (text.textStorage?.length ?? 0),
               change.range.length <= (text.textStorage?.length ?? 0) - change.range.location {
                let replacement = (session.state.text as NSString).substring(with:
                    NSRange(location: change.range.location, length: change.replacementLength))
                text.textStorage?.replaceCharacters(in: change.range, with: replacement)
            } else {
                text.string = overrideText ?? session.state.text
            }
            coordinator.appliedRevision = session.state.revision
            coordinator.overrideText = overrideText
            let count = (text.string as NSString).length
            let start = min(range.location, count)
            text.setSelectedRange(NSRange(location: start, length: min(range.length, count - start)))
            if !isSecondary && overrideText == nil { text.undoManager?.removeAllActions() }
            scroll.contentView.scroll(to: visible)
            context.coordinator.highlight()
            context.coordinator.updatingText = false
        }
        text.isEditable = !isReadOnly && !session.isSaving
        text.allowsUndo = !isReadOnly
        text.setAccessibilityLabel(L10n.text(isReadOnly ? "文档内容" : "文档源码编辑器"))
        if !isSecondary && overrideText == nil && session.pendingEditorFind != nil {
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                coordinator?.session.flushEditorFindRequest()
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
        coordinator.highlightTask = nil
        coordinator.scrollTask?.cancel()
        coordinator.scrollTask = nil
        coordinator.positionTask?.cancel()
        coordinator.positionTask = nil
        if let observer = coordinator.scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.scrollObserver = nil
        }
        if let text = coordinator.textView {
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
        var appliedRevision: UInt64
        let isSecondary: Bool
        let isOverride: Bool
        var overrideText: String?
        private var pendingChange: TextChange?
        private var highlightedRange: NSRange?

        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        init(session: DocumentSession, isSecondary: Bool = false, isOverride: Bool = false) {
            self.session = session
            self.isSecondary = isSecondary
            self.isOverride = isOverride
            appliedRevision = session.state.revision
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
            scheduleHighlight()
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
            if let range = highlightedRange, let change = pendingChange,
               change.range.location < NSMaxRange(range) {
                let delta = change.replacementLength - change.range.length
                let start = max(0, min(range.location, range.location + delta))
                let end = max(NSMaxRange(range), NSMaxRange(range) + delta)
                highlightedRange = NSRange(location: start, length: end - start)
            }
            session.edit(textView.string, change: pendingChange)
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
                guard !Task.isCancelled else { return }
                self?.highlight()
            }
        }

        private static func compile(_ rules: [(String, NSColor)]) -> [(NSRegularExpression, NSColor)] {
            rules.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
        }
        private static let markdownRules = compile([
            (#"(?m)^#{1,6}\s.+$"#, .systemBlue),
            (#"`[^`\n]+`"#, .systemOrange)
        ])
        private static let jsonRules = compile([
            (#"\"(?:[^\"\\]|\\.)*\""#, .systemGreen),
            (#"\b(?:true|false|null|-?\d+(?:\.\d+)?)\b"#, .systemPurple)
        ])
        private static let xmlRules = compile([
            (#"</?[\w:.-]+|/?>"#, .systemBlue),
            (#"\"[^\"]*\"|'[^']*'"#, .systemGreen),
            (#"<!--[\s\S]*?-->"#, .secondaryLabelColor)
        ])
        private static let configurationRules = compile([
            (#"(?m)^\s*(?:export[ \t]+)?[\w.\-]+(?=\s*[:=])"#, .systemBlue),
            (#"(?m)^\s*\[[^\r\n]+\]"#, .systemBlue),
            (#"\b(?:true|false|null|yes|no|on|off|\d+(?:\.\d+)?)\b"#, .systemPurple),
            (#"\"(?:[^\"\\\r\n]|\\.)*\"|'[^'\r\n]*'"#, .systemGreen),
            (#"(?m)^\s*[#;!][^\r\n]*$"#, .secondaryLabelColor)
        ])
        private static let jsoncRules = jsonRules + compile([
            (#"(?m)^\s*//[^\r\n]*$|/\*[\s\S]*?\*/"#, .secondaryLabelColor)
        ])

        func highlight() {
            guard let view = textView, !view.hasMarkedText(), let storage = view.textStorage,
                  let layout = view.layoutManager, let container = view.textContainer else { return }
            let source = view.string
            let entire = NSRange(location: 0, length: storage.length)
            // Color is presentation, not a text edit: avoid invalidating the
            // storage/layout or retaining attributed copies in the undo history.
            if let highlightedRange {
                layout.removeTemporaryAttribute(.foregroundColor,
                    forCharacterRange: NSIntersectionRange(highlightedRange, entire))
                self.highlightedRange = nil
            }
            guard (isOverride ? source.utf8.count : session.state.byteCount) < 200_000,
                  storage.length > 0 else { return }
            let rules: [(NSRegularExpression, NSColor)]
            switch session.kind {
            case .markdown: rules = Self.markdownRules
            case .json: rules = Self.jsonRules
            case .xml: rules = Self.xmlRules
            case .yaml, .toml, .ini, .configuration, .environment, .properties: rules = Self.configurationRules
            case .jsonc: rules = Self.jsoncRules
            case .text: return
            }
            var range = entire
            if session.kind != .xml && session.kind != .jsonc {
                // XML/JSONC block comments may begin outside the viewport.
                // Other rules stay line-local around the visible text.
                var visible = view.visibleRect.insetBy(dx: 0, dy: -250)
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
            let deadline = ProcessInfo.processInfo.systemUptime + 0.008
            for (expression, color) in rules {
                for range in ranges {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return }
                    expression.enumerateMatches(in: source, options: [.reportProgress], range: range) { match, _, stop in
                        if ProcessInfo.processInfo.systemUptime >= deadline { stop.pointee = true; return }
                        if let match {
                            layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: match.range)
                        }
                    }
                }
            }
            if session.kind == .markdown {
                for range in ranges {
                    for match in SourceHighlighting.markdownLinks(in: source as NSString, range: range) {
                        layout.addTemporaryAttribute(.foregroundColor, value: NSColor.systemTeal, forCharacterRange: match)
                    }
                }
            }
        }

    }
}
