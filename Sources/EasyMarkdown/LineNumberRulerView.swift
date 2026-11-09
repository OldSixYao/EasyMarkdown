import AppKit
import EasyMarkdownCore

@MainActor final class LineNumberRulerView: NSRulerView {
    override var wantsDefaultClipping: Bool { true }
    // This is a display gutter; native ruler clicks must not add paragraph tab stops.
    override func mouseDown(with event: NSEvent) {}
    struct Label {
        let number: Int
        let characterOffset: Int
        let baseline: CGFloat
    }

    private weak var textView: NSTextView?
    private var observer: NSObjectProtocol?
    private var refresh: DispatchWorkItem?
    private(set) var index: LineNumberIndex
    var metricsDidChange: (() -> Void)?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        index = LineNumberIndex(textView.string as NSString)
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = desiredThickness
        setAccessibilityElement(false)
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage, queue: .main) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let storage = event.object as? NSTextStorage,
                          storage.editedMask.contains(.editedCharacters) else { return }
                    self.index.applyEdit(in: storage.editedRange, lengthDelta: storage.changeInLength,
                        text: storage.string as NSString)
                    self.needsDisplay = true
                    // Retiling while NSTextStorage processes an edit can reenter layout.
                    self.refresh?.cancel()
                    let refresh = DispatchWorkItem { [weak self] in self?.metricsDidChange?() }
                    self.refresh = refresh
                    DispatchQueue.main.async(execute: refresh)
                }
            }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        refresh?.cancel()
    }

    private var numberFont: NSFont {
        .monospacedDigitSystemFont(ofSize: textView?.font?.pointSize ?? 14, weight: .regular)
    }

    var desiredThickness: CGFloat {
        ceil((String(repeating: "8", count: max(2, String(index.lineCount).count)) as NSString)
            .size(withAttributes: [.font: numberFont]).width) + 20
    }

    func refreshMetrics() {
        if ruleThickness != desiredThickness { ruleThickness = desiredThickness }
        needsDisplay = true
    }

    func invalidate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        refresh?.cancel()
        refresh = nil
        metricsDidChange = nil
        clientView = nil
        textView = nil
    }

    /// Layout is requested only for the viewport, including wrapped line fragments.
    func visibleLabels() -> [Label] {
        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer,
              text.visibleRect.width > 0 else { return [] }
        let origin = text.textContainerOrigin
        let viewport = text.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        layout.ensureLayout(forBoundingRect: viewport, in: container)
        let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: viewport, in: container)
        let source = text.string as NSString
        var labels: [Label] = []
        if glyphs.length > 0 {
            layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
                let offset = layout.characterIndexForGlyph(at: range.location)
                let position = self.index.position(atUTF16Offset: offset, in: source)
                guard position.lineStart == offset else { return }
                let baseline = origin.y + rect.minY + layout.location(forGlyphAt: range.location).y
                labels.append(Label(number: position.number, characterOffset: offset,
                    baseline: self.convert(NSPoint(x: 0, y: baseline), from: text).y))
            }
        }
        let last = index.position(atUTF16Offset: source.length, in: source)
        if last.lineStart == source.length {
            let font = text.font ?? numberFont
            let rect = source.length == 0
                ? NSRect(x: 0, y: 0, width: container.containerSize.width, height: layout.defaultLineHeight(for: font))
                : layout.extraLineFragmentRect
            if (source.length == 0 || layout.extraLineFragmentTextContainer === container), rect.intersects(viewport) {
                let baseline = origin.y + rect.minY + layout.defaultBaselineOffset(for: font)
                labels.append(Label(number: last.number, characterOffset: source.length,
                    baseline: convert(NSPoint(x: 0, y: baseline), from: text).y))
            }
        }
        return labels
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.secondaryLabelColor]
        for label in visibleLabels() {
            let value = String(label.number) as NSString
            let width = value.size(withAttributes: attributes).width
            value.draw(at: NSPoint(x: ruleThickness - width - 10, y: label.baseline - numberFont.ascender),
                withAttributes: attributes)
        }
    }
}
