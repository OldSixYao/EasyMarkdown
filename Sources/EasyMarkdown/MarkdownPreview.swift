import SwiftUI
import WebKit
import UniformTypeIdentifiers
import CryptoKit
import EasyMarkdownCore

private final class WeakReaderMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

struct MarkdownPreview: NSViewRepresentable {
    let session: DocumentSession
    var overrideText: String? = nil
    @AppStorage("readerFontSize") private var fontSize = 16.0
    @AppStorage("readerWidth") private var width = 780.0
    @AppStorage("remoteImages") private var remoteImages = false
    @AppStorage("appearance") private var appearance = "system"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(WeakReaderMessageHandler(context.coordinator), name: "reader")
        configuration.setURLSchemeHandler(context.coordinator.resources, forURLScheme: "document-resource")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        if overrideText == nil {
            session.scrollPreviewTo = { [weak coordinator = context.coordinator] position in
                coordinator?.synchronizeScroll(position)
            }
            session.previewActivity.bind(id: context.coordinator.activityID) { [weak coordinator = context.coordinator] finish in
                guard let coordinator else { finish(nil); return }
                coordinator.prepareForSleep(finish)
            }
        }
        if let page = AppResources.bundle.url(forResource: "reader", withExtension: "html", subdirectory: "Resources") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.isDisposed = true
        coordinator.renderTask?.cancel()
        coordinator.searchTask?.cancel()
        coordinator.alignmentTask?.cancel()
        coordinator.renderTask = nil
        coordinator.ready = false
        coordinator.previousRevision = nil
        coordinator.previousOverride = nil
        coordinator.pendingScroll = nil
        coordinator.resources.cancelAll()
        if coordinator.parent.overrideText == nil {
            coordinator.parent.session.previewActivity.unbind(id: coordinator.activityID)
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        coordinator.webView = nil
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownPreview
        weak var webView: WKWebView?
        let resources: LocalResourceHandler
        var ready = false
        var previousRevision: UInt64?
        var previousOverride: String?
        var previousPreferences = ""
        private var previousResourceContext = ""
        var previousTarget: String?
        var previousScrollRequest = 0
        var previousSearch = ""
        var previousFindRequest = 0
        var searchRevision = 0
        var previousSearchRevision = -1
        var searchSerial = 0
        var searchTask: Task<Void, Never>?
        var rendering = false
        var pendingScroll: SplitScrollPosition?
        var hasAlignedScroll = false
        var alignmentTask: Task<Void, Never>?
        var scrolling = false
        var renderTask: Task<Void, Never>?
        var isDisposed = false
        let activityID = UUID()
        private var cachedPositionPath: String?
        private var cachedPositionKey = ""

        var contentIsCurrent: Bool {
            previousRevision == parent.session.state.revision && previousOverride == parent.overrideText
        }

        func prepareForSleep(_ finish: @escaping (NSImage?) -> Void) {
            guard ready, !isDisposed, let webView else { finish(nil); return }
            let revision = parent.session.state.revision
            webView.callAsyncJavaScript("return {position:capturePosition(),search:{query:readerSearch.query,index:readerSearch.index,offset:readerSearch.offset}}",
                arguments: [:], in: nil, in: .page) { [weak self, weak webView] result in
                guard let self, !self.isDisposed, let webView else { finish(nil); return }
                if case .success(let value) = result, let value = value as? [String: Any] {
                    if let position = value["position"] as? [String: Any] {
                        UserDefaults.standard.set(position, forKey: self.positionKey)
                    }
                    if let search = value["search"] as? [String: Any], let query = search["query"] as? String,
                       let index = search["index"] as? Int, let offset = search["offset"] as? Int {
                        self.parent.session.readerSearchResume = ReaderSearchResume(revision: revision,
                            query: query, index: index, offset: offset)
                    }
                }
                let options = WKSnapshotConfiguration()
                options.snapshotWidth = NSNumber(value: min(480, webView.bounds.width))
                webView.takeSnapshot(with: options) { image, _ in finish(image) }
            }
        }

        func synchronizeScroll(_ position: SplitScrollPosition) {
            pendingScroll = position
            flushScroll()
        }

        private func flushScroll() {
            guard ready, !rendering, !scrolling, let webView, let position = pendingScroll,
                  parent.overrideText == nil,
                  parent.session.mode == .read || (parent.session.mode == .split && parent.session.synchronizeSplitScroll) else { return }
            pendingScroll = nil
            scrolling = true
            webView.callAsyncJavaScript("window.synchronizeSourceScroll(position)",
                arguments: ["position": position.arguments], in: nil, in: .page) { [weak self] _ in
                    self?.scrolling = false
                    self?.flushScroll()
                }
        }

        init(_ parent: MarkdownPreview) {
            self.parent = parent
            resources = LocalResourceHandler(owner: parent.session.imageBudgetOwner)
            super.init()
            resources.onBudgetChange = { [weak self] in
                guard let self, !self.isDisposed else { return }
                self.webView?.callAsyncJavaScript("window.retryReaderImages()", arguments: [:],
                    in: nil, in: .page, completionHandler: nil)
            }
        }
        var positionKey: String {
            let path = parent.session.url?.path ?? ""
            if path == cachedPositionPath { return cachedPositionKey }
            let hash = SHA256.hash(data: Data(path.utf8))
                .map { String(format: "%02x", $0) }.joined()
            cachedPositionPath = path
            cachedPositionKey = "readingPosition." + hash
            return cachedPositionKey
        }

        func update() {
            guard ready, !isDisposed, let webView else { return }
            alignSourcePositionIfNeeded()
            resources.root = parent.session.url?.deletingLastPathComponent()
            resources.remoteImages = parent.remoteImages
            let preferences: [String: Any] = ["fontSize": parent.fontSize, "width": parent.width,
                "appearance": parent.appearance, "remoteImages": parent.remoteImages,
                "selectionStatistics": parent.overrideText == nil, "statisticsRevision": String(parent.session.state.revision),
                "language": Bundle.main.preferredLocalizations.first ?? "zh-Hans",
                "strings": ["copy": L10n.text("复制代码"), "copied": L10n.text("已复制"),
                    "copyFailed": L10n.text("复制失败"), "content": L10n.text("文档内容"),
                    "truncated": L10n.text("大文件已使用纯文本预览，仅显示前 500,000 个字符。编辑模式可查看和编辑全文。"),
                    "remoteImage": L10n.text("远程图片未加载"),
                    "imageLoading": L10n.text("正在加载图片…"),
                    "imageBudget": L10n.text("图片暂缓加载，滚动后重试或查看原图。"),
                    "imageUnavailable": L10n.text("图片无法预览，可查看原图。"),
                    "openImage": L10n.text("查看原图")]]
            let preferencesKey = "\(parent.fontSize):\(parent.width):\(parent.appearance):\(parent.remoteImages):\(parent.session.url?.absoluteString ?? ""):\(parent.session.kind.rawValue)"
            if !rendering && (!contentIsCurrent || previousPreferences != preferencesKey) {
                renderTask?.cancel()
                // Coalesce typing bursts before creating IPC arguments and a new DOM tree.
                renderTask = Task { @MainActor [weak self] in
                    if self?.previousRevision != nil {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard !Task.isCancelled, let self, !self.isDisposed else { return }
                    let text = self.parent.overrideText ?? self.parent.session.state.text
                    self.render(text: text, preferences: preferences, preferencesKey: preferencesKey)
                }
            }
            updateSearch()
            if let target = parent.session.scrollTarget,
               target != previousTarget || parent.session.scrollRequest != previousScrollRequest {
                previousTarget = target
                previousScrollRequest = parent.session.scrollRequest
                webView.callAsyncJavaScript("document.getElementById(target)?.scrollIntoView()",
                    arguments: ["target": target], in: nil, in: .page, completionHandler: nil)
            }
        }

        private func alignSourcePositionIfNeeded() {
            guard !rendering, contentIsCurrent, parent.overrideText == nil, alignmentTask == nil else { return }
            let session = parent.session
            guard (session.mode == .read && session.pendingReaderSourcePosition != nil) ||
                    (session.mode == .split && !hasAlignedScroll) else { return }
            alignmentTask = Task { @MainActor [weak self] in
                // 阅读页也会分帧恢复布局，等它结束后再交接当前源码位置。
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, !self.isDisposed else { return }
                self.alignmentTask = nil
                guard !self.rendering, self.contentIsCurrent else { self.update(); return }
                let session = self.parent.session
                if session.mode == .read, let position = session.pendingReaderSourcePosition {
                    session.pendingReaderSourcePosition = nil
                    self.synchronizeScroll(position)
                } else if session.mode == .split && !self.hasAlignedScroll {
                    self.hasAlignedScroll = true
                    session.alignPreviewToEditor?()
                }
            }
        }

        private func updateSearch() {
            guard parent.overrideText == nil, !rendering,
                  contentIsCurrent, let webView else { return }
            let session = parent.session
            let query = session.showFind && session.mode == .read ? session.search : ""
            guard query != previousSearch || session.findRequest != previousFindRequest ||
                    searchRevision != previousSearchRevision else { return }
            let changed = query != previousSearch || searchRevision != previousSearchRevision
            previousSearch = query
            previousFindRequest = session.findRequest
            previousSearchRevision = searchRevision
            searchTask?.cancel()
            searchSerial += 1
            let serial = searchSerial
            let revision = searchRevision
            let request = session.findRequest
            let backwards = session.findBackwards
            let offset = session.findOffset
            var arguments: [String: Any] = ["query": query, "backwards": backwards, "request": request, "offset": offset]
            if let resume = session.readerSearchResume, resume.revision == session.state.revision,
               resume.query == query, !query.isEmpty {
                arguments["resume"] = ["index": resume.index, "offset": resume.offset]
            }
            session.readerSearchResume = nil
            searchTask = Task { @MainActor [weak self, weak webView] in
                if changed && !query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
                guard !Task.isCancelled, let self, !self.isDisposed, let webView else { return }
                webView.callAsyncJavaScript("return window.updateReaderSearch(query, backwards, request, offset, typeof resume==='undefined'?null:resume)",
                    arguments: arguments, in: nil, in: .page) { [weak self] result in
                        guard let self, !self.isDisposed, self.searchSerial == serial,
                              self.searchRevision == revision, !self.rendering,
                              self.contentIsCurrent else { return }
                        let session = self.parent.session
                        let current = session.showFind && session.mode == .read ? session.search : ""
                        guard current == query, session.findRequest == request else { return }
                        if case .success(let value) = result, let value = value as? [String: Any],
                           value["query"] as? String == query, let count = value["count"] as? Int {
                            session.searchResultCount = query.isEmpty ? nil : count
                            session.searchIsTruncated = value["truncated"] as? Bool ?? false
                        }
                    }
            }
        }

        private func render(text: String, preferences: [String: Any], preferencesKey: String) {
            guard let webView, ready, !rendering else { return }
            let resourceContext = "\(parent.remoteImages):\(parent.session.url?.absoluteString ?? ""):\(parent.session.kind.rawValue)"
            let styleOnly = contentIsCurrent && previousResourceContext == resourceContext
            searchTask?.cancel()
            searchSerial += 1
            searchRevision += 1
            previousRevision = parent.session.state.revision
            previousOverride = parent.overrideText
            previousPreferences = preferencesKey
            previousResourceContext = resourceContext
            rendering = true
            let position = UserDefaults.standard.dictionary(forKey: positionKey) ?? [:]
            var arguments: [String: Any] = ["preferences": preferences]
            let script: String
            if styleOnly {
                script = "window.updateReaderPreferences(preferences)"
            } else {
                let preview = PreviewText(text)
                script = "window.updateDocument(text, kind, baseURL, preferences, position, truncated)"
                arguments.merge(["text": preview.text, "truncated": preview.isTruncated, "kind": parent.session.kind.rawValue,
                    "baseURL": parent.session.url?.absoluteString ?? "file:///", "preferences": preferences,
                    "position": position]) { _, new in new }
            }
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
                guard let self, !self.isDisposed else { return }
                self.rendering = false
                if case .failure(let error) = result { self.parent.session.errorMessage = L10n.format("预览失败：%@", error.localizedDescription) }
                else {
                    if self.parent.overrideText == nil && self.contentIsCurrent {
                        self.parent.session.previewActivity.didRender()
                    }
                    self.update()
                    self.flushScroll()
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !isDisposed, message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready": ready = true; update()
            case "editRequest":
                guard parent.overrideText == nil, let window = webView?.window else { return }
                parent.session.readOnlyEditPrompt.request(in: window)
            case "headings":
                guard parent.overrideText == nil, let payload = body["payload"],
                      let data = try? JSONSerialization.data(withJSONObject: payload),
                      let headings = try? JSONDecoder().decode([Heading].self, from: data) else { return }
                parent.session.headings = headings
            case "activeHeading":
                guard parent.overrideText == nil else { return }
                let id = body["payload"] as? String
                guard id == nil || parent.session.headings.contains(where: { $0.id == id }) else { return }
                if parent.session.activeHeadingID != id { parent.session.activeHeadingID = id }
            case "position":
                if parent.overrideText == nil, let position = body["payload"] as? [String: Any] {
                    UserDefaults.standard.set(position, forKey: positionKey)
                }
            case "sourceScroll":
                guard parent.overrideText == nil, !rendering,
                      contentIsCurrent,
                      let payload = body["payload"] as? [String: Any],
                      let offset = payload["offset"] as? Double,
                      let progress = payload["progress"] as? Double else { return }
                parent.session.previewDidScroll(SplitScrollPosition(offset: offset, progress: progress))
            case "selection":
                guard parent.overrideText == nil, parent.session.mode != .edit, contentIsCurrent,
                      let payload = body["payload"] as? [String: Any],
                      payload["revision"] as? String == String(parent.session.state.revision),
                      let text = payload["text"] as? String,
                      text.utf16.count <= PreviewText.maximumUTF16Count else { return }
                guard !text.isEmpty || parent.session.statisticsSelectionOwner == activityID ||
                        payload["interaction"] as? Bool == true else { return }
                parent.session.updateReaderSelection(text, owner: activityID)
            case "link":
                if let href = body["payload"] as? String { openLink(href) }
            case "imageRequest":
                guard let payload = body["payload"] as? [String: Any],
                      let request = payload["request"] as? String, request.count <= 64,
                      request.utf8.allSatisfy({ (48...57).contains($0) }),
                      let source = payload["source"] as? String else { return }
                resources.requestImage(id: request, source: source) { [weak self] result in
                    guard let self, !self.isDisposed else { return }
                    self.webView?.callAsyncJavaScript("window.completeReaderImage(request, result)",
                        arguments: ["request": request, "result": result], in: nil, in: .page, completionHandler: nil)
                }
            case "imageRelease":
                if let request = body["payload"] as? String { resources.releaseImage(id: request) }
            case "openImage":
                if let source = body["payload"] as? String { openImage(source) }
            case "copyCode":
                guard let payload = body["payload"] as? [String: Any],
                      let request = payload["request"] as? Int,
                      let text = payload["text"] as? String else { return }
                NSPasteboard.general.clearContents()
                let success = NSPasteboard.general.setString(text, forType: .string)
                webView?.callAsyncJavaScript("window.completeCodeCopy(request, success)",
                    arguments: ["request": request, "success": success], in: nil, in: .page, completionHandler: nil)
            default: break
            }
        }

        func openLink(_ href: String) {
            guard let url = URL(string: href, relativeTo: parent.session.url)?.absoluteURL,
                  let scheme = url.scheme?.lowercased() else { return }
            if ["https", "http", "mailto"].contains(scheme) { NSWorkspace.shared.open(url) }
            else if url.isFileURL { (NSApp.delegate as? AppDelegate)?.open(url) }
        }

        private func openImage(_ source: String) {
            guard let url = URL(string: source) else { return }
            if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil {
                NSWorkspace.shared.open(url)
            } else if url.isFileURL, let root = resources.root,
                      UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                Task {
                    let permitted = await Task.detached(priority: .utility) {
                        let target = url.standardizedFileURL.resolvingSymlinksInPath()
                        let folder = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                        return target.path.hasPrefix(folder) ? target : nil
                    }.value
                    if let permitted { NSWorkspace.shared.open(permitted) }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                if let url = navigationAction.request.url { openLink(url.absoluteString) }
            } else { decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel) }
        }
    }
}
