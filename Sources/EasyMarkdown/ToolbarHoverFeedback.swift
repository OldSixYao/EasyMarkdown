import SwiftUI

// Disambiguate the property wrapper from newer SDKs' State macro.
private typealias HoverState<Value> = State<Value>

/// Adds feedback without changing a control's layout or taking editor focus.
private struct ToolbarHoverFeedback: ViewModifier {
    let name: String
    @Environment(\.isEnabled) private var isEnabled
    @HoverState private var isHovered = false

    private var highlighted: Bool { isEnabled && isHovered }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(highlighted ? 0.18 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(highlighted ? 0.55 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
            .help(name)
            .accessibilityLabel(name)
    }
}

extension View {
    func toolbarHoverFeedback(_ name: String) -> some View {
        modifier(ToolbarHoverFeedback(name: name))
    }
}
