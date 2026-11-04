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

final class LocalResourceHandler: NSObject, WKURLSchemeHandler {
    var root: URL?
    private static let imageQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "EasyMarkdown.ImagePreview"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    private var requests: [ObjectIdentifier: (operation: BlockOperation, task: any WKURLSchemeTask)] = [:]

    func cancelAll() {
        for request in requests.values { request.operation.cancel() }
        requests.removeAll()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let root else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        let operation = BlockOperation()
        requests[id] = (operation, urlSchemeTask)
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = autoreleasepool { Result { try PreviewImage.load(URL(fileURLWithPath: url.path), within: root) } }
            let delivered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self, weak operation] in
                defer { delivered.signal() }
                guard let self, let operation, !operation.isCancelled,
                      let request = self.requests.removeValue(forKey: id) else { return }
                switch result {
                case .success(let image):
                    request.task.didReceive(URLResponse(url: url, mimeType: image.mimeType,
                        expectedContentLength: image.data.count, textEncodingName: nil))
                    request.task.didReceive(image.data)
                    request.task.didFinish()
                case .failure(let error): request.task.didFailWithError(error)
                }
            }
            // Keep the queue slot until delivery, so a busy main thread cannot
            // accumulate an unbounded backlog of already-decoded image results.
            delivered.wait()
        }
        Self.imageQueue.addOperation(operation)
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.operation.cancel()
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
        coordinator.renderTask = nil
        coordinator.ready = false
        coordinator.previousText = nil
        coordinator.pendingScroll = nil
        coordinator.resources.cancelAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        coordinator.webView = nil
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownPreview
        weak var webView: WKWebView?
        let resources = LocalResourceHandler()
        var ready = false
        var previousText: String?
        var previousPreferences = ""
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
        var scrolling = false
        var renderTask: Task<Void, Never>?
        var isDisposed = false

        func synchronizeScroll(_ position: SplitScrollPosition) {
            pendingScroll = position
            flushScroll()
        }

        private func flushScroll() {
            guard ready, !rendering, !scrolling, let webView, let position = pendingScroll,
                  parent.overrideText == nil, parent.session.mode == .split,
                  parent.session.synchronizeSplitScroll else { return }
            pendingScroll = nil
            scrolling = true
            webView.callAsyncJavaScript("window.synchronizeSourceScroll(position)",
                arguments: ["position": position.arguments], in: nil, in: .page) { [weak self] _ in
                    self?.scrolling = false
                    self?.flushScroll()
                }
        }

        init(_ parent: MarkdownPreview) { self.parent = parent }
        var positionKey: String {
            let hash = SHA256.hash(data: Data((parent.session.url?.path ?? "").utf8))
                .map { String(format: "%02x", $0) }.joined()
            return "readingPosition." + hash
        }

        func update() {
            guard ready, !isDisposed, let webView else { return }
            if !hasAlignedScroll && previousText != nil && !rendering,
               parent.overrideText == nil && parent.session.mode == .split {
                hasAlignedScroll = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, !self.isDisposed else { return }
                    self.parent.session.alignPreviewToEditor?()
                }
            }
            resources.root = parent.session.url?.deletingLastPathComponent()
            let text = parent.overrideText ?? parent.session.state.text
            let preferences: [String: Any] = ["fontSize": parent.fontSize, "width": parent.width,
                "appearance": parent.appearance, "remoteImages": parent.remoteImages,
                "language": Bundle.main.preferredLocalizations.first ?? "zh-Hans",
                "strings": ["copy": L10n.text("复制代码"), "copied": L10n.text("已复制"),
                    "copyFailed": L10n.text("复制失败"), "content": L10n.text("文档内容"),
                    "truncated": L10n.text("大文件已使用纯文本预览，仅显示前 500,000 个字符。编辑模式可查看和编辑全文。"),
                    "remoteImage": L10n.text("远程图片未加载")]]
            let preferencesKey = "\(parent.fontSize):\(parent.width):\(parent.appearance):\(parent.remoteImages):\(parent.session.url?.absoluteString ?? ""):\(parent.session.kind.rawValue)"
            if !rendering && (previousText != text || previousPreferences != preferencesKey) {
                renderTask?.cancel()
                // Coalesce typing bursts before creating IPC arguments and a new DOM tree.
                renderTask = Task { @MainActor [weak self] in
                    if self?.previousText != nil {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard !Task.isCancelled, let self, !self.isDisposed else { return }
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

        private func updateSearch() {
            guard parent.overrideText == nil, !rendering,
                  previousText == parent.session.state.text, let webView else { return }
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
            searchTask = Task { @MainActor [weak self, weak webView] in
                if changed && !query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
                guard !Task.isCancelled, let self, !self.isDisposed, let webView else { return }
                webView.callAsyncJavaScript("return window.updateReaderSearch(query, backwards, request, offset)",
                    arguments: ["query": query, "backwards": backwards, "request": request, "offset": offset], in: nil, in: .page) { [weak self] result in
                        guard let self, !self.isDisposed, self.searchSerial == serial,
                              self.searchRevision == revision, !self.rendering,
                              self.previousText == self.parent.session.state.text else { return }
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
            searchTask?.cancel()
            searchSerial += 1
            searchRevision += 1
            previousText = text; previousPreferences = preferencesKey; rendering = true
            let position = UserDefaults.standard.dictionary(forKey: positionKey) ?? [:]
            // The reader already truncates at 500k characters; don't transfer 24 MB to
            // WebKit merely to discard it there. Keep one extra character for the notice.
            let previewText = text.utf16.count > 500_001 ? String(text.prefix(500_001)) : text
            webView.callAsyncJavaScript("window.updateDocument(text, kind, baseURL, preferences, position)",
                arguments: ["text": previewText, "kind": parent.session.kind.rawValue,
                    "baseURL": parent.session.url?.absoluteString ?? "file:///", "preferences": preferences,
                    "position": position], in: nil, in: .page) { [weak self] result in
                guard let self, !self.isDisposed else { return }
                self.rendering = false
                if case .failure(let error) = result { self.parent.session.errorMessage = L10n.format("预览失败：%@", error.localizedDescription) }
                else {
                    self.update()
                    if !self.hasAlignedScroll && self.parent.overrideText == nil && self.parent.session.mode == .split {
                        self.hasAlignedScroll = true
                        // Wait for the reader's initial position restoration to finish.
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(100))
                            self?.parent.session.alignPreviewToEditor?()
                        }
                    }
                    self.flushScroll()
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !isDisposed, message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready": ready = true; update()
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
                      previousText == parent.session.state.text,
                      let payload = body["payload"] as? [String: Any],
                      let offset = payload["offset"] as? Double,
                      let progress = payload["progress"] as? Double else { return }
                parent.session.previewDidScroll(SplitScrollPosition(offset: offset, progress: progress))
            case "link":
                if let href = body["payload"] as? String { openLink(href) }
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

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                if let url = navigationAction.request.url { openLink(url.absoluteString) }
            } else { decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel) }
        }
    }
}
