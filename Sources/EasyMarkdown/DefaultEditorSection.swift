import SwiftUI
import EasyMarkdownCore

private typealias EditorSectionState<Value> = State<Value>

struct DefaultEditorSection: View {
    @Bindable var settings: DefaultEditorSettings
    @EditorSectionState private var newExtension = ""

    var body: some View {
        Section(L10n.text("默认编辑器")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("文件类型"))
                List(selection: Binding<DefaultEditorFormat?>(
                    get: { settings.format },
                    set: { if let format = $0 { settings.format = format } }
                )) {
                    ForEach(settings.formats, id: \.self) { format in
                        let association = settings.association(for: format)
                        HStack(spacing: 8) {
                            Text(format.title).lineLimit(2)
                            Spacer(minLength: 4)
                            Label(association.label, systemImage: icon(for: association.state))
                                .font(.caption)
                                .foregroundStyle(association.state == .current ? Color.green : .secondary)
                                .fixedSize()
                        }
                        .tag(format)
                        .help(association.applicationName ?? association.label)
                        .accessibilityIdentifier("default-editor-row-" + format.rawValue)
                        .background(PersistentListScroller().allowsHitTesting(false))
                    }
                }
                // New suffixes appear first. Reset scrolling when the custom
                // collection changes so the added, selected row is visible.
                .id(settings.customExtensions)
                .listStyle(.inset)
                .frame(height: 130)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .accessibilityLabel(L10n.text("文件类型"))
                .accessibilityIdentifier("default-editor-format")
            }
            .disabled(settings.isSetting)
            HStack(spacing: 8) {
                TextField(L10n.text("新后缀，例如 .log"), text: $newExtension)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("custom-editor-extension")
                    .onSubmit(addExtension)
                Button(L10n.text("添加"), action: addExtension)
                    .disabled(newExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("add-editor-extension")
                if case .custom = settings.format {
                    Button(L10n.text("移除")) { settings.removeSelectedExtension() }
                        .help(L10n.text("仅从列表移除，不恢复系统默认应用。"))
                        .accessibilityIdentifier("remove-editor-extension")
                }
            }
            .disabled(settings.isSetting)
            if let error = settings.extensionError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(settings.status).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("default-editor-status")
                Spacer(minLength: 8)
                if settings.isSetting { ProgressView().controlSize(.small) }
                Button(L10n.text("设为默认")) {
                    Task { await settings.makeDefault() }
                }
                .fixedSize()
                .disabled(settings.isSetting || settings.isDefault)
                .accessibilityIdentifier("make-default-editor")
            }
            if let error = settings.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func addExtension() {
        if settings.addExtension(newExtension) { newExtension = "" }
    }

    private func icon(for state: DefaultEditorAssociation.State) -> String {
        switch state {
        case .current: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .other: return "app"
        case .unset: return "circle.dashed"
        }
    }
}

/// Configure only the scroll view enclosing a list row, leaving the settings
/// form's outer scroll view and the user's system preferences untouched.
private struct PersistentListScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerAnchor { ScrollerAnchor() }
    func updateNSView(_ view: ScrollerAnchor, context: Context) { view.showScroller() }

    final class ScrollerAnchor: NSView {
        override func layout() {
            super.layout()
            showScroller()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            showScroller()
            // List can reapply its own scroller style after its first layout.
            if window != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                    self?.showScroller()
                }
            }
        }

        func showScroller() {
            // SwiftUI may still be attaching the row during an update.
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.enclosingScrollView else { return }
                if !scroll.hasVerticalScroller { scroll.hasVerticalScroller = true }
                if scroll.autohidesScrollers { scroll.autohidesScrollers = false }
                if scroll.scrollerStyle != .legacy { scroll.scrollerStyle = .legacy }
            }
        }
    }
}
