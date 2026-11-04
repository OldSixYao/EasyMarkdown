import SwiftUI
import EasyMarkdownCore

struct SourceEditor: NSViewRepresentable {
    let session: DocumentSession
    @AppStorage("editorFontSize") private var fontSize = 14.0

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = NSTextView(frame: .zero)
        text.isRichText = false
        text.allowsUndo = true
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
        text.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        text.string = session.state.text
        text.delegate = context.coordinator
        text.setAccessibilityLabel(L10n.text("文档源码编辑器"))
        scroll.documentView = text
        context.coordinator.textView = text
        context.coordinator.observeScrolling(scroll)
        session.applyMarkdown = { [weak coordinator = context.coordinator] command in
            coordinator?.apply(command)
        }
        session.replaceText = { [weak text] value in
            guard let text else { return }
            text.breakUndoCoalescing()
            text.insertText(value, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
            text.undoManager?.setActionName(L10n.text("格式化"))
        }
        session.editorFindAction = { [weak coordinator = context.coordinator] request in
            coordinator?.performFind(request) ?? false
        }
        DispatchQueue.main.async { [weak text, weak coordinator = context.coordinator] in
            guard let text else { return }
            text.window?.makeFirstResponder(text)
            coordinator?.highlight()
            coordinator?.session.flushEditorFindRequest()
        }
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = context.coordinator.textView else { return }
        if text.font?.pointSize != CGFloat(fontSize) {
            text.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        if text.string != session.state.text && !text.hasMarkedText() {
            context.coordinator.updatingText = true
            let range = text.selectedRange()
            let visible = scroll.contentView.bounds.origin
            text.string = session.state.text
            let count = (text.string as NSString).length
            let start = min(range.location, count)
            text.setSelectedRange(NSRange(location: start, length: min(range.length, count - start)))
            text.undoManager?.removeAllActions()
            scroll.contentView.scroll(to: visible)
            context.coordinator.highlight()
            context.coordinator.updatingText = false
        }
        text.isEditable = !session.isSaving
        if session.pendingEditorFind != nil {
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                coordinator?.session.flushEditorFindRequest()
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
        coordinator.highlightTask = nil
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
        var scrollObserver: NSObjectProtocol?
        var synchronizedY: CGFloat?
        var updatingText = false

        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        init(session: DocumentSession) { self.session = session }

        func performFind(_ request: EditorFindRequest) -> Bool {
            guard let textView, let window = textView.window, textView.delegate === self else { return false }
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
            session.scrollEditorTo = { [weak self] position in self?.scroll(to: position) }
            session.alignPreviewToEditor = { [weak self] in
                guard let self, let position = self.scrollPosition() else { return }
                self.session.editorDidScroll(position)
            }
        }

        func scrollPosition() -> SplitScrollPosition? {
            guard let textView, let scroll = textView.enclosingScrollView,
                  let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
            layout.ensureLayout(for: container)
            let top = scroll.contentView.bounds.minY
            let maximum = max(0, textView.bounds.height - scroll.contentView.bounds.height)
            let progress = maximum > 0 ? min(1, max(0, top / maximum)) : 0
            guard layout.numberOfGlyphs > 0 else { return SplitScrollPosition(offset: 0, progress: progress) }
            let glyph = min(layout.numberOfGlyphs - 1, layout.glyphIndex(for:
                NSPoint(x: 0, y: max(0, top - textView.textContainerInset.height)), in: container))
            var glyphRange = NSRange()
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphRange)
            let characters = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let fraction = min(1, max(0, (top - textView.textContainerInset.height - rect.minY) / max(1, rect.height)))
            return SplitScrollPosition(offset: Double(characters.location) + Double(characters.length) * fraction,
                                       progress: progress)
        }

        private func didScroll() {
            scheduleHighlight()
            guard session.mode == .split, session.synchronizeSplitScroll,
                  !updatingText, let textView, textView.string == session.state.text,
                  let top = textView.enclosingScrollView?.contentView.bounds.minY else { return }
            // A matching bounds notification acknowledges a synchronized move.
            if let synchronizedY, abs(top - synchronizedY) < 1 { return }
            synchronizedY = nil
            if let position = scrollPosition() { session.editorDidScroll(position) }
        }

        private func scroll(to position: SplitScrollPosition) {
            guard let textView, let scroll = textView.enclosingScrollView,
                  let layout = textView.layoutManager, let container = textView.textContainer,
                  !textView.hasMarkedText() else { return }
            layout.ensureLayout(for: container)
            let length = (textView.string as NSString).length
            let maximum = max(0, textView.bounds.height - scroll.contentView.bounds.height)
            var y: CGFloat
            if position.progress <= 0.0001 { y = 0 }
            else if position.progress >= 0.9999 { y = maximum }
            else if length > 0 {
                let offset = min(Double(length - 1), position.offset)
                let glyph = layout.glyphIndexForCharacter(at: Int(offset))
                var glyphRange = NSRange()
                let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphRange)
                let characters = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                let fraction = (offset - Double(characters.location)) / Double(max(1, characters.length))
                y = textView.textContainerInset.height + rect.minY + rect.height * min(1, max(0, fraction))
            } else { y = 0 }
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
            guard let textView else { return }
            session.edit(textView.string)
            scheduleHighlight()
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
            (#"`[^`\n]+`"#, .systemOrange),
            (#"\[[^\]]+\]\([^\)]+\)"#, .systemTeal)
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
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: entire)
            guard source.utf8.count < 200_000, storage.length > 0 else { return }
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
            for (expression, color) in rules {
                expression.enumerateMatches(in: source, range: range) { match, _, _ in
                    if let match {
                        layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: match.range)
                    }
                }
            }
        }

    }
}
