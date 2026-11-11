import AppKit

/// 记录可见行的字符锚点及其屏幕位置，全文长度变化后仍定位到同一内容。
struct SourceViewport {
    var offset: Int
    let lineOffset: CGFloat
    let x: CGFloat
    let atTop: Bool

    @MainActor init?(_ text: NSTextView) {
        guard let scroll = text.enclosingScrollView, let layout = text.layoutManager,
              let container = text.textContainer, text.textStorage?.length ?? 0 > 0 else { return nil }
        let top = scroll.contentView.bounds.minY
        let point = NSPoint(x: 0, y: max(0, top - text.textContainerInset.height))
        let visible = NSRect(origin: point, size: NSSize(width: container.containerSize.width, height: 1))
        layout.ensureLayout(forBoundingRect: visible, in: container)
        let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: container)
        guard glyphs.length > 0 else { return nil }
        let glyph = min(NSMaxRange(glyphs) - 1, layout.glyphIndex(for: point, in: container))
        var range = NSRange()
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
        offset = layout.characterIndexForGlyph(at: range.location)
        lineOffset = top - text.textContainerInset.height - line.minY
        x = scroll.contentView.bounds.minX
        atTop = top <= 0
    }

    @MainActor func restore(in text: NSTextView) {
        guard let scroll = text.enclosingScrollView, let layout = text.layoutManager else { return }
        let length = text.textStorage?.length ?? 0
        var y: CGFloat = 0
        if !atTop && length > 0 {
            let character = min(length - 1, max(0, offset))
            layout.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
            let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil)
            y = text.textContainerInset.height + line.minY + lineOffset
        }
        scroll.contentView.scroll(to: NSPoint(x: x, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
