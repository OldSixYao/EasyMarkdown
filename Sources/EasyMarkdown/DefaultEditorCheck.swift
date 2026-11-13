#if DEBUG
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EasyMarkdownCore
import CoreServices

@MainActor enum DefaultEditorCheck {
    static func run(output: URL) async {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try await applicationCopies(directory: output)
            try await batchAssociations()
            try await list(directory: output)
            try await liveAssociations(directory: output)
            try Data("passed\n".utf8).write(to: output.appendingPathComponent("result.txt"))
            print("PASS: 默认编辑器副本识别、系统状态、滚动、选择、批量设置、失败和取消检查")
            NSApp.terminate(nil)
        } catch {
            print("FAIL: 默认编辑器检查：\(error)")
            exit(1)
        }
    }

    static func list(directory: URL) async throws {
        let accessibility = EditorStatisticsCheck.setAccessibilityTestingEnabled(true)
        defer { EditorStatisticsCheck.setAccessibilityTestingEnabled(accessibility) }
        let suiteName = "app.easymarkdown.default-editor-check.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else { throw CocoaError(.fileReadUnknown) }
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let app = URL(fileURLWithPath: "/Applications/EasyMarkdown.app")
        var defaults: [String: URL] = [:]
        var writes: [String] = []
        let model = DefaultEditorSettings(applicationURL: app, query: { defaults[$0.identifier] },
            set: { url, type in writes.append(type.identifier); defaults[type.identifier] = url },
            canSet: { true }, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let controller = NSWindowController(window: window)
        window.title = L10n.text("默认编辑器")
        let root = NSHostingView(rootView: SettingsView(updates: UpdateController(), defaultEditor: model))
        window.contentView = root
        controller.showWindow(nil)
        defer { controller.close() }
        try await Task.sleep(for: .milliseconds(400))
        if let outer = views(root).compactMap({ $0 as? NSScrollView }).first, let document = outer.documentView {
            document.scroll(NSPoint(x: 0, y: document.frame.height))
        }
        try await Task.sleep(for: .milliseconds(400))
        try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("list-top.png"))
        let scrolls = views(root).compactMap { $0 as? NSScrollView }
        guard let table = views(root).compactMap({ $0 as? NSTableView }).first,
              let scroll = table.enclosingScrollView,
              scroll.hasVerticalScroller, !scroll.autohidesScrollers, scroll.scrollerStyle == .legacy,
              let scroller = scroll.verticalScroller, !scroller.isHidden, scroller.frame.width > 0,
              let scrollAction = scroller.action,
              let document = scroll.documentView, document.frame.height > scroll.contentView.bounds.height else {
            throw SmokeCheck.Failure(message: "文件类型列表没有独立、常驻且可滚动的垂直滚动条")
        }
        try require(scrolls.count >= 2 && table.numberOfRows == model.formats.count,
                    "文件列表没有保持独立滚动或显示全部类型")
        let outerOrigin = scrolls.first?.contentView.bounds.origin
        // 通过原生滚动条动作滚到底部，核对实际可见行及外层表单的位置。
        scroller.doubleValue = 1
        try require(NSApp.sendAction(scrollAction, to: scroller.target, from: scroller), "滚动条没有可用动作")
        try await wait("拖动滚动条后未显示最后一行") {
            scroll.documentVisibleRect.intersects(table.rect(ofRow: table.numberOfRows - 1))
        }
        try require(scrolls.first?.contentView.bounds.origin == outerOrigin, "列表滚动带动了外层设置表单")
        try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("list-bottom.png"))

        table.scrollRowToVisible(0)
        window.makeFirstResponder(table)
        let point = table.convert(NSPoint(x: 40, y: table.rect(ofRow: 1).midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw CocoaError(.coderInvalidValue) }
            NSApp.postEvent(event, atStart: false)
        }
        try await wait("鼠标选择未同步到设置状态") { model.format == .text }
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125) else { throw CocoaError(.coderInvalidValue) }
        table.keyDown(with: down)
        try await wait("键盘选择未同步到设置状态") { model.format == .json }

        _ = model.addExtension(".jsonc")
        try await wait("选择下方文件类型后，列表没有滚动到对应选中项") {
            table.selectedRow == model.formats.count - 1 && scroll.documentVisibleRect.maxY >= document.frame.height - 2
        }
        table.scrollRowToVisible(0)
        _ = model.addExtension(".jsonc")
        try await wait("重复选择同一后缀未滚动到已有行") {
            scroll.documentVisibleRect.maxY >= document.frame.height - 2
        }
        try require(model.addExtension("emscrolltest"), "未添加测试自定义后缀")
        try await wait("新增自定义项没有选中或保持可见") {
            table.numberOfRows == model.formats.count && table.selectedRow == 0 && scroll.documentVisibleRect.minY < 2
        }
        model.removeSelectedExtension()
        try await wait("移除自定义项后未恢复选中内置类型") {
            table.numberOfRows == model.formats.count && table.selectedRow == 0 && model.format == .markdown
        }
        table.scrollRowToVisible(table.numberOfRows - 1)
        let before = scroll.contentView.bounds.origin
        model.refresh()
        try await Task.sleep(for: .milliseconds(150))
        try require(scroll.contentView.bounds.origin == before, "刷新状态重置了用户的列表滚动位置")
        guard let button = element(in: root, identifier: "make-all-default-editor") else {
            throw SmokeCheck.Failure(message: "设置窗口缺少全部设为默认按钮")
        }
        try require(boolean("isAccessibilityEnabled", of: button), "尚未全部关联时批量按钮不可用")
        try require(boolean("accessibilityPerformPress", of: button), "未能点击全部设为默认按钮")
        try await wait("一键设置按钮未完成全部关联或未禁用") {
            model.allDefault && !model.isSetting && !boolean("isAccessibilityEnabled", of: button)
        }
        try require(!writes.isEmpty && model.batchMessage != nil, "按钮未执行批量关联或未显示成功结果")
        try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("all-default.png"))
    }

    static func batchAssociations() async throws {
        let suiteName = "app.easymarkdown.batch-default-check.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else { throw CocoaError(.fileReadUnknown) }
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let app = URL(fileURLWithPath: "/Applications/EasyMarkdown.app")
        let other = URL(fileURLWithPath: "/Applications/Other.app")
        var defaults = Dictionary(uniqueKeysWithValues: DefaultEditorFormat.markdown.contentTypes.map { ($0.identifier, app) })
        var writes: [String] = []
        var resume: CheckedContinuation<Void, Never>?
        let model = DefaultEditorSettings(applicationURL: app, query: { defaults[$0.identifier] },
            set: { url, type in
                writes.append(type.identifier)
                if writes.count == 1 { await withCheckedContinuation { resume = $0 } }
                defaults[type.identifier] = url
            }, canSet: { true }, preferences: preferences)
        _ = model.addExtension("text")
        _ = model.addExtension("embatchtest")
        model.format = .json
        let originallyDefault = Set(defaults.keys)
        let expected = Set(model.formats.flatMap(\.contentTypes).map(\.identifier)).subtracting(originallyDefault)
        try require(writes.isEmpty && !model.allDefault, "初始化或添加后缀擅自更改了默认应用")
        let task = Task { await model.makeAllDefault() }
        try await wait("批量设置未进入等待状态") { resume != nil }
        try require(model.isSetting && model.isSettingAll, "批量设置未显示运行状态")
        let formatsBefore = model.formats
        let writesBefore = writes
        await model.makeDefault()
        await model.makeAllDefault()
        try require(!model.addExtension("blocked") && model.formats == formatsBefore && writes == writesBefore,
                    "批量设置期间允许重复请求或修改列表")
        resume?.resume()
        await task.value
        try require(Set(writes) == expected && writes.count == expected.count && model.allDefault &&
            model.format == .json && !model.isSetting && !model.isSettingAll && model.errorMessage == nil && model.batchMessage != nil,
            "批量设置未覆盖自定义项、去重、跳过已关联类型、保持选中项或重新查询结果")
        let completed = writes
        await model.makeAllDefault()
        try require(writes == completed, "全部已经关联后仍向系统重复请求")
        defaults[DefaultEditorFormat.json.contentType.identifier] = other
        model.refresh()
        try require(!model.allDefault && !model.isDefault && model.batchMessage == nil, "外部更改后未刷新批量状态")

        var partialDefaults: [String: URL] = [:]
        var partialWrites: [String] = []
        let failingType = DefaultEditorFormat.json.contentType.identifier
        let ignoredTypes = Set(DefaultEditorFormat.yaml.contentTypes.map(\.identifier))
        let partial = DefaultEditorSettings(applicationURL: app, query: { partialDefaults[$0.identifier] },
            set: { url, type in
                partialWrites.append(type.identifier)
                if type.identifier == failingType { throw CocoaError(.fileWriteNoPermission) }
                if !ignoredTypes.contains(type.identifier) { partialDefaults[type.identifier] = url }
            }, canSet: { true }, preferences: preferences)
        await partial.makeAllDefault()
        try require(partial.association(for: .json).state == .unset && partial.association(for: .yaml).state == .unset &&
            partial.association(for: .jsonc).state == .current && partialWrites.contains(DefaultEditorFormat.jsonc.contentType.identifier) &&
            !partial.allDefault && !partial.isSetting && partial.batchMessage == nil &&
            partial.errorMessage?.contains(DefaultEditorFormat.json.title) == true &&
            partial.errorMessage?.contains(DefaultEditorFormat.yaml.title) == true,
            "批量失败未继续剩余类型，或把未生效的关联显示为成功")

        let cancellations: [Error] = [CocoaError(.userCancelled), NSError(domain: NSOSStatusErrorDomain, code: -128), CancellationError()]
        for error in cancellations {
            var attempts = 0
            let cancelled = DefaultEditorSettings(applicationURL: app, query: { _ in nil },
                set: { _, _ in attempts += 1; throw error }, canSet: { true }, preferences: preferences)
            await cancelled.makeAllDefault()
            try require(attempts == 1 && !cancelled.allDefault && !cancelled.isSetting && cancelled.errorMessage != nil,
                        "用户取消后继续请求关联或错误显示全部成功")
        }
        var unavailableWrites = 0
        let unavailable = DefaultEditorSettings(applicationURL: app, query: { _ in nil },
            set: { _, _ in unavailableWrites += 1 }, canSet: { false }, preferences: preferences)
        await unavailable.makeAllDefault()
        try require(unavailableWrites == 0 && !unavailable.isSetting && unavailable.errorMessage != nil,
                    "不可设置的应用仍尝试写入关联")
    }

    static func applicationCopies(directory: URL) async throws {
        let suiteName = "app.easymarkdown.application-copy-check.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else { throw CocoaError(.fileReadUnknown) }
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let fixtures = directory.appendingPathComponent("application-identities", isDirectory: true)
        let identifier = "app.easymarkdown.identity-fixture"
        // 仅创建可读取元数据的资源包，不注册、启动或修改真实应用副本。
        func bundle(_ name: String, identifier: String?) throws -> URL {
            let url = fixtures.appendingPathComponent(name + ".bundle", isDirectory: true)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleName": "EasyMarkdown", "CFBundlePackageType": "BNDL"]
            if let identifier { info["CFBundleIdentifier"] = identifier }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let running = try bundle("Running", identifier: identifier)
        let installed = try bundle("Installed", identifier: identifier)
        let other = try bundle("Other", identifier: "app.easymarkdown.other-fixture")
        try require(Bundle(url: running)?.bundleIdentifier == identifier && Bundle(url: installed)?.bundleIdentifier == identifier,
                    "测试应用元数据不可用")
        var defaults = Dictionary(uniqueKeysWithValues: Set(DefaultEditorFormat.allCases.flatMap(\.contentTypes).map(\.identifier))
            .map { ($0, installed) })
        var writes: [String] = []
        let model = DefaultEditorSettings(applicationURL: running, query: { defaults[$0.identifier] },
            set: { _, type in writes.append(type.identifier); defaults[type.identifier] = installed },
            canSet: { true }, preferences: preferences)
        try require(model.allDefault && model.isDefault && model.formats.allSatisfy { model.association(for: $0).state == .current },
                    "同一应用的安装版与构建版路径不同，被误报为全部未设为默认")
        await model.makeAllDefault()
        try require(writes.isEmpty && model.errorMessage == nil, "同标识应用已经默认，仍重复写入或显示失败")

        model.format = .json
        defaults[DefaultEditorFormat.json.contentType.identifier] = other
        model.refresh()
        try require(!model.isDefault && !model.allDefault && model.association(for: .json).state == .other,
                    "名称相同但标识不同的应用被错误当成当前应用")
        await model.makeAllDefault()
        try require(writes == [DefaultEditorFormat.json.contentType.identifier] && model.allDefault && model.errorMessage == nil,
                    "批量设置成功后系统返回安装版路径，被误报为关联未生效")
        defaults[DefaultEditorFormat.json.contentType.identifier] = other
        model.refresh()
        await model.makeDefault()
        try require(model.isDefault && model.errorMessage == nil, "单项设置未正确识别同标识的安装版")

        if let format = model.formats.first(where: { $0.contentTypes.count > 1 }), let last = format.contentTypes.last {
            defaults[last.identifier] = other
            model.format = format
            model.refresh()
            try require(model.association(for: format).state == .partial && !model.allDefault,
                        "同应用多路径识别掩盖了真实的部分关联状态")
        }

        let anonymous = try bundle("Anonymous", identifier: nil)
        let anotherAnonymous = try bundle("AnotherAnonymous", identifier: nil)
        var anonymousDefault = anotherAnonymous
        let noIdentifier = DefaultEditorSettings(applicationURL: anonymous, query: { _ in anonymousDefault },
            set: { _, _ in }, canSet: { true }, preferences: preferences)
        try require(!noIdentifier.allDefault, "缺失标识的不同应用被当成同一应用")
        anonymousDefault = anonymous
        noIdentifier.refresh()
        try require(noIdentifier.allDefault, "缺失标识时未保留同一路径的识别能力")
    }

    static func liveAssociations(directory: URL) async throws {
        let suiteName = "app.easymarkdown.live-default-check.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName), let identifier = Bundle.main.bundleIdentifier else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { preferences.removePersistentDomain(forName: suiteName) }
        // 使用真实系统查询与真实应用标识，只读检查，禁止写入系统关联。
        let model = DefaultEditorSettings(set: { _, _ in throw CocoaError(.featureUnsupported) },
            canSet: { false }, preferences: preferences)
        var rows: [[String: Any]] = []
        var confirmed = 0
        for format in model.formats {
            let types = format.contentTypes
            let handlers = types.map {
                LSCopyDefaultRoleHandlerForContentType($0.identifier as CFString, .all)?.takeRetainedValue() as String?
            }
            if handlers.allSatisfy({ $0?.caseInsensitiveCompare(identifier) == .orderedSame }) {
                try require(model.association(for: format).state == .current,
                            "系统已关联当前应用标识，界面仍显示未默认：" + format.title)
                confirmed += 1
            }
            rows.append(["format": format.rawValue, "types": types.map(\.identifier),
                "handlers": handlers.map { $0 ?? "" },
                "applicationPaths": types.map { NSWorkspace.shared.urlForApplication(toOpen: $0)?.path ?? "" },
                "displayState": String(describing: model.association(for: format).state)])
        }
        let report: [String: Any] = ["readOnly": true, "applicationIdentifier": identifier,
            "runningApplication": Bundle.main.bundleURL.path, "confirmedDefaultFormats": confirmed, "formats": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("system-associations.json"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let controller = NSWindowController(window: window)
        window.title = L10n.text("默认编辑器")
        window.contentView = NSHostingView(rootView: Form {
            DefaultEditorSection(settings: model)
        }.formStyle(.grouped).frame(width: 560, height: 360))
        controller.showWindow(nil)
        defer { controller.close() }
        try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("system-defaults.png"))
        print("系统实际关联只读检查：\(confirmed) 种类型已关联当前应用，界面状态一致")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeCheck.Failure(message: message) }
    }

    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw SmokeCheck.Failure(message: message)
    }

    private static func element(in root: Any, identifier: String, depth: Int = 0) -> NSObject? {
        guard depth < 30, let object = root as? NSObject else { return nil }
        if property("accessibilityIdentifier", of: object) as? String == identifier { return object }
        for child in property("accessibilityChildren", of: object) as? [Any] ?? [] {
            if let found = element(in: child, identifier: identifier, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func property(_ name: String, of object: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    // SwiftUI 辅助功能节点没有声明完整协议，按其真实布尔返回类型调用。
    private static func boolean(_ name: String, of object: NSObject) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        let method = unsafeBitCast(object.method(for: selector), to: Method.self)
        return method(object, selector)
    }

    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
}
#endif
