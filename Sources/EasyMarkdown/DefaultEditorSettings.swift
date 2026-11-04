import AppKit
import Observation
import UniformTypeIdentifiers
import EasyMarkdownCore

enum DefaultEditorFormat: Hashable, CaseIterable {
    case markdown, text, json, xml, yaml, toml, ini, configuration, environment, properties, jsonc
    case custom(String)

    static let allCases: [Self] = [.markdown, .text, .json, .xml, .yaml, .toml, .ini, .configuration, .environment, .properties, .jsonc]

    var rawValue: String {
        if case .custom(let ext) = self { return "custom." + ext }
        return String(describing: self)
    }

    var extensions: [String] {
        switch self {
        case .markdown: return ["md", "markdown", "mdown", "mkd"]
        case .text: return ["txt"]
        case .yaml: return ["yaml", "yml"]
        case .configuration: return ["conf", "cfg", "cnf"]
        case .environment: return ["env"]
        case .custom(let ext): return [ext]
        default: return [rawValue]
        }
    }

    static func normalizedExtension(_ input: String) -> String? {
        var ext = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ext.hasPrefix(".") { ext.removeFirst() }
        guard ext.range(of: #"^[a-z0-9_+\-]{1,32}$"#, options: .regularExpression) != nil else { return nil }
        return ext
    }

    var title: String {
        switch self {
        case .markdown: return "Markdown (.md, .markdown, .mdown, .mkd)"
        case .text: return "TXT (.txt)"
        case .json: return "JSON (.json)"
        case .xml: return "XML (.xml)"
        case .yaml: return "YAML (.yaml, .yml)"
        case .toml: return "TOML (.toml)"
        case .ini: return "INI (.ini)"
        case .configuration: return "CONF (.conf, .cfg, .cnf)"
        case .environment: return "ENV (.env)"
        case .properties: return "Properties (.properties)"
        case .jsonc: return "JSONC (.jsonc)"
        case .custom(let ext): return "." + ext
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: return UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
        case .text: return .plainText
        case .json: return .json
        case .xml: return .xml
        case .yaml: return UTType(importedAs: "public.yaml", conformingTo: .text)
        case .custom(let ext):
            // Keep the system's preferred identifier, including dynamic types
            // for unknown extensions. Adding a suffix never rewrites the app.
            guard let type = UTType(filenameExtension: ext) else {
                preconditionFailure("Invalid custom extension")
            }
            return type
        case .toml, .ini, .configuration, .environment, .properties, .jsonc:
            // Honor a concrete type already registered by another editor. Our
            // exported declarations provide stable types when none exists.
            let ext = extensions[0]
            if let type = UTType(filenameExtension: ext), !type.isDynamic { return type }
            return UTType(exportedAs: "app.easymarkdown.\(rawValue)", conformingTo: .plainText)
        }
    }

    var contentTypes: [UTType] {
        var types = [contentType]
        for ext in extensions {
            if let type = UTType(filenameExtension: ext), !type.isDynamic, !types.contains(type) { types.append(type) }
        }
        return types
    }
}

struct DefaultEditorAssociation {
    enum State { case current, partial, other, unset }
    let state: State
    let applicationName: String?

    var label: String {
        switch state {
        case .current: return L10n.text("已设为默认")
        case .partial: return L10n.text("部分已设为默认")
        case .other: return L10n.text("其他应用")
        case .unset: return L10n.text("未设置")
        }
    }
}

/// The displayed state comes from Launch Services, never a saved toggle. Tests
/// inject both operations so they cannot change the user's actual associations.
@MainActor @Observable final class DefaultEditorSettings {
    var format: DefaultEditorFormat = .markdown {
        didSet { if format != oldValue { refresh() } }
    }
    private(set) var isSetting = false
    private(set) var isDefault = false
    private(set) var errorMessage: String?
    private(set) var currentApplicationName: String?
    private(set) var customExtensions: [String] = []
    private(set) var associations: [DefaultEditorFormat: DefaultEditorAssociation] = [:]
    private(set) var extensionError: String?
    var formats: [DefaultEditorFormat] { customExtensions.reversed().map { .custom($0) } + DefaultEditorFormat.allCases }
    let applicationURL: URL
    @ObservationIgnored private let preferences: UserDefaults
    private static let extensionsKey = "customEditorExtensions"
    @ObservationIgnored private let query: (UTType) -> URL?
    @ObservationIgnored private let set: (URL, UTType) async throws -> Void
    @ObservationIgnored private let canSet: () -> Bool

    init(applicationURL: URL = Bundle.main.bundleURL,
         query: @escaping (UTType) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
         set: @escaping (URL, UTType) async throws -> Void = { app, type in
             try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                 NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                     if let error { continuation.resume(throwing: error) }
                     else { continuation.resume() }
                 }
             }
         },
         canSet: (() -> Bool)? = nil,
         preferences: UserDefaults = .standard) {
        self.applicationURL = applicationURL
        self.query = query
        self.set = set
        self.preferences = preferences
        let builtIn = Set(DefaultEditorFormat.allCases.flatMap(\.extensions))
        var seen = builtIn
        customExtensions = (preferences.stringArray(forKey: Self.extensionsKey) ?? []).compactMap {
            guard let ext = DefaultEditorFormat.normalizedExtension($0), seen.insert(ext).inserted else { return nil }
            return ext
        }
        self.canSet = canSet ?? {
            applicationURL.pathExtension == "app" &&
                Bundle(url: applicationURL)?.executableURL != nil &&
                (try? applicationURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true
        }
        refresh()
    }

    var status: String {
        if isSetting { return L10n.text("正在设置默认编辑器…") }
        if isDefault { return L10n.text("EasyMarkdown 已是此类型的默认应用。") }
        if let currentApplicationName { return L10n.format("当前默认应用：%@", currentApplicationName) }
        return L10n.text("此类型尚未设置默认应用。")
    }

    func refresh() {
        guard !isSetting else { return }
        errorMessage = nil
        for format in formats { readStatus(for: format) }
    }

    func association(for format: DefaultEditorFormat) -> DefaultEditorAssociation {
        associations[format] ?? DefaultEditorAssociation(state: .unset, applicationName: nil)
    }

    @discardableResult
    func addExtension(_ input: String) -> Bool {
        guard !isSetting else { return false }
        guard let ext = DefaultEditorFormat.normalizedExtension(input) else {
            extensionError = L10n.text("请输入单个后缀（如 log 或 .log），使用 1–32 个字母、数字、连字符、下划线或加号。")
            return false
        }
        if let existing = formats.first(where: { $0.extensions.contains(ext) }) {
            format = existing
            extensionError = L10n.text("此后缀已在列表中，已选中对应类型。")
            return false
        }
        customExtensions.append(ext)
        preferences.set(customExtensions, forKey: Self.extensionsKey)
        extensionError = nil
        format = .custom(ext)
        return true
    }

    func removeSelectedExtension() {
        guard !isSetting, case .custom(let ext) = format else { return }
        customExtensions.removeAll { $0 == ext }
        associations.removeValue(forKey: format)
        preferences.set(customExtensions, forKey: Self.extensionsKey)
        extensionError = nil
        format = .markdown
    }

    private func readStatus(for format: DefaultEditorFormat) {
        let current = format.contentTypes.map { query($0)?.resolvingSymlinksInPath().standardizedFileURL }
        let ours = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        let state: DefaultEditorAssociation.State
        if current.allSatisfy({ $0 == ours }) { state = .current }
        else if current.contains(ours) { state = .partial }
        else if current.contains(where: { $0 != nil }) { state = .other }
        else { state = .unset }
        let name: String?
        if current.dropFirst().allSatisfy({ $0 == current[0] }) {
            name = current[0].map { FileManager.default.displayName(atPath: $0.path) }
        } else { name = L10n.text("多个应用") }
        associations[format] = DefaultEditorAssociation(state: state, applicationName: name)
        if self.format == format {
            isDefault = state == .current
            currentApplicationName = name
        }
    }

    func makeDefault() async {
        guard !isSetting else { return }
        guard canSet() else {
            errorMessage = L10n.text("请将 EasyMarkdown 安装到 Applications，并运行应用后再设置默认编辑器。")
            return
        }
        let selected = format
        isSetting = true
        errorMessage = nil
        extensionError = nil
        do {
            for type in selected.contentTypes { try await set(applicationURL, type) }
            readStatus(for: selected)
            if association(for: selected).state != .current {
                errorMessage = L10n.text("系统尚未将此应用设为默认。请在 Finder 的“显示简介 → 打开方式”中选择 EasyMarkdown，再点击“全部更改”。")
            }
        } catch {
            readStatus(for: selected)
            errorMessage = L10n.format("无法设置默认编辑器：%@", error.localizedDescription)
        }
        isSetting = false
        // A custom suffix may share a system type with another row.
        for format in formats { readStatus(for: format) }
    }
}
