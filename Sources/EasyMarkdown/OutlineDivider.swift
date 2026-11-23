import AppKit
import SwiftUI
import EasyMarkdownCore

struct OutlineDivider: NSViewRepresentable {
    static let thickness: CGFloat = 8

    @Binding var outlineWidth: CGFloat
    let limits: ClosedRange<CGFloat>

    private var visibleWidth: CGFloat { min(outlineWidth, limits.upperBound) }

    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        let label = L10n.text("调整大纲宽度")
        view.toolTip = label
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(label)
        view.setAccessibilityOrientation(.vertical)
        return view
    }

    func updateNSView(_ view: Handle, context: Context) {
        let previousWidth = view.accessibilityValue() as? CGFloat
        view.divider = self
        view.setAccessibilityValue(visibleWidth)
        view.setAccessibilityMinValue(limits.lowerBound)
        view.setAccessibilityMaxValue(limits.upperBound)
        if let previousWidth, previousWidth != visibleWidth {
            NSAccessibility.post(element: view, notification: .valueChanged)
        }
    }

    final class Handle: NSView {
        var divider: OutlineDivider?
        private var dragStart: (x: CGFloat, width: CGFloat)?

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: floor(bounds.midX), y: bounds.minY, width: 1, height: bounds.height).fill()
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            if #available(macOS 15, *) {
                addCursorRect(bounds, cursor: .columnResize)
            } else {
                addCursorRect(bounds, cursor: .resizeLeftRight)
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let divider else { return }
            dragStart = (event.locationInWindow.x, divider.visibleWidth)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            _ = resize(to: dragStart.width + event.locationInWindow.x - dragStart.x)
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
        }

        override func accessibilityPerformIncrement() -> Bool {
            guard let divider else { return false }
            return resize(to: divider.visibleWidth + 16)
        }

        override func accessibilityPerformDecrement() -> Bool {
            guard let divider else { return false }
            return resize(to: divider.visibleWidth - 16)
        }

        private func resize(to proposedWidth: CGFloat) -> Bool {
            guard let divider else { return false }
            let width = min(max(proposedWidth, divider.limits.lowerBound), divider.limits.upperBound)
            guard width != divider.visibleWidth else { return false }
            divider.outlineWidth = width
            return true
        }
    }
}
