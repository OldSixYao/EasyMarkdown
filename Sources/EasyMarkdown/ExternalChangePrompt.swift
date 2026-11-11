import AppKit
import EasyMarkdownCore

/// 每份文档独立排队，只有前台可交互的文档窗口才显示确认。
@MainActor final class ExternalChangePrompt {
    private weak var session: DocumentSession?
    private var observers: [NSObjectProtocol] = []
    private var presentation: DispatchWorkItem?
    private var alert: NSAlert?
    private var generation = 0
    private var manuallyRequested = false

    init(session: DocumentSession) { self.session = session }

    func start() {
        stop()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didEndSheetNotification, NSWindow.didDeminiaturizeNotification,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        schedule()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        cancel()
    }

    func cancel() {
        generation += 1
        presentation?.cancel()
        presentation = nil
        manuallyRequested = false
        if let alert, let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
        }
        alert = nil
    }

    func schedule(manual: Bool = false) {
        if manual { manuallyRequested = true }
        presentation?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.presentIfPossible() }
        presentation = work
        // 等待当前保存或关闭面板的结束回调和窗口焦点恢复。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func presentIfPossible() {
        presentation = nil
        guard let session, !session.closed else { return }
        guard let snapshot = session.state.external, !session.state.isMissing else {
            cancel()
            return
        }
        guard alert == nil, session.state.needsExternalConfirmation || manuallyRequested,
              !session.isSaving, !session.isLoadingExternal, !session.showExternal,
              session.errorMessage == nil, NSApp.isActive, NSApp.modalWindow == nil,
              let url = session.url,
              let window = session.document?.windowControllers.compactMap(\.window).first(where: {
                  $0.isKeyWindow && $0.isVisible && !$0.isMiniaturized && $0.attachedSheet == nil &&
                      ($0.tabGroup == nil || $0.tabGroup?.selectedWindow === $0)
              }) else { return }

        let revision = session.state.revision
        let baselineID = session.state.baseline.identity
        let generation = generation
        let alert = NSAlert()
        alert.messageText = L10n.format("文档「%@」已在其他位置修改，是否更新为最新内容？", url.lastPathComponent)
        alert.informativeText = session.state.isDirty ? L10n.text("更新将放弃当前尚未保存的修改。") : ""
        alert.addButton(withTitle: L10n.text("确定"))
        alert.addButton(withTitle: L10n.text("否")).keyEquivalent = "\u{1b}"
        alert.window.identifier = NSUserInterfaceItemIdentifier("externalChangeConfirmation")
        self.alert = alert
        manuallyRequested = false
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.generation == generation else { return }
            self.alert = nil
            guard let session = self.session, !session.closed, session.url == url else { return }
            if response == .alertFirstButtonReturn {
                guard session.state.external != nil else { return }
                // 弹窗后发生的新编辑没有获得放弃授权，必须重新询问。
                guard session.state.revision == revision, session.state.baseline.identity == baselineID else {
                    self.schedule(manual: true)
                    return
                }
                session.loadLatestExternal(expectedRevision: revision, from: url)
            } else if response == .alertSecondButtonReturn {
                // 弹窗期间出现的更新属于另一个版本，不能被旧的“否”消除。
                if session.state.external?.data == snapshot.data { session.state.keepCurrentContent() }
                self.schedule()
            }
        }
    }
}
