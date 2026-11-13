import SwiftUI
import EasyMarkdownCore

private typealias EditorSectionState<Value> = State<Value>

struct DefaultEditorSection: View {
    @Bindable var settings: DefaultEditorSettings
    @EditorSectionState private var newExtension = ""

    var body: some View {
        Section(L10n.text("默认编辑器")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.text("文件类型"))
                    Spacer()
                    Button(L10n.text("全部设为默认")) {
                        Task { await settings.makeAllDefault() }
                    }
                    .fixedSize()
                    .disabled(settings.isSetting || settings.allDefault)
                    .help(L10n.text("将列表中的全部文件类型（含自定义后缀）设为由 EasyMarkdown 默认打开。"))
                    .accessibilityIdentifier("make-all-default-editor")
                }
                DefaultEditorFormatList(formats: settings.formats, associations: settings.associations,
                    selection: $settings.format, selectionRequest: settings.selectionRequest, isEnabled: !settings.isSetting)
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
}
