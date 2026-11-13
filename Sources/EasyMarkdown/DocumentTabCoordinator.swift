import AppKit

/// Explicit window tabbing keeps the application's preference independent of the system default.
@MainActor final class DocumentTabCoordinator: NSObject, NSMenuItemValidation {
    static let shared = DocumentTabCoordinator()
    private static let identifier = NSWindow.TabbingIdentifier("app.easymarkdown.documents")

    private final class Entry {
        weak var window: NSWindow?
        var presented = false
        init(_ window: NSWindow) { self.window = window }
    }

    private var entries: [Entry] = []
    private weak var lastActiveWindow: NSWindow?
    private var notifications: [NSObjectProtocol] = []
    private var groups: [NSKeyValueObservation] = []
    private var refresh: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var changingGroups = false
    private(set) var isEnabled = true

    private var windows: [NSWindow] { entries.compactMap(\.window) }
    private var activeWindow: NSWindow? { windows.first(where: \.isKeyWindow) }
    private var hasBlockingOperation: Bool {
        NSApp.modalWindow != nil || windows.contains { window in
            window.attachedSheet != nil || (window.windowController?.document as? MarkdownDocument)?.session.isSaving == true
        }
    }

    func start() {
        guard notifications.isEmpty else { return }
        NSWindow.allowsAutomaticWindowTabbing = false
        isEnabled = EditorPreferences.store.bool(forKey: EditorPreferences.documentTabsEnabled)
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: UserDefaults.didChangeNotification,
            object: EditorPreferences.store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyPreference() }
            })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didEndSheetNotification, NSApplication.didBecomeActiveNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let window = event.object as? NSWindow, window.isKeyWindow {
                        if self.windows.contains(where: { $0 === window }) { self.lastActiveWindow = window }
                        else { window.tabbingMode = .disallowed }
                    }
                    self.scheduleRefresh()
                }
            })
        }
        notifications.append(center.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { _ in MainActor.assumeIsolated { EditorPreferences.finishChecks() } })
    }

    func register(_ window: NSWindow) {
        start()
        entries.removeAll { $0.window == nil }
        entries.append(Entry(window))
        window.tabbingIdentifier = Self.identifier
        window.tabbingMode = isEnabled ? .preferred : .disallowed
    }

    func unregister(_ window: NSWindow) {
        entries.removeAll { $0.window == nil || $0.window === window }
        if lastActiveWindow === window { lastActiveWindow = nil }
        // Release KVO's group ownership before AppKit closes the last tab.
        groups.removeAll()
        scheduleRefresh()
    }

    func prepareToShow(_ window: NSWindow) {
        guard let entry = entries.first(where: { $0.window === window }), !entry.presented else { return }
        applyPreference()
        let shown = entries.filter { $0.presented }.compactMap(\.window)
        let target = lastActiveWindow.flatMap { candidate in shown.first { $0 === candidate } }
            ?? NSApp.orderedWindows.first { candidate in shown.contains { $0 === candidate } }
            ?? shown.first
        entry.presented = true
        if isEnabled, let target, target !== window {
            append(window, to: target)
        }
    }

    func didShow(_ window: NSWindow) {
        if let group = window.tabGroup { group.selectedWindow = window }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        lastActiveWindow = window
        scheduleRefresh()
    }

    func applyPreference() {
        guard !changingGroups else { return }
        let requested = EditorPreferences.store.bool(forKey: EditorPreferences.documentTabsEnabled)
        guard requested != isEnabled else {
            retry?.cancel()
            retry = nil
            return
        }
        guard !hasBlockingOperation else {
            retry?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyPreference() }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            return
        }
        retry?.cancel()
        retry = nil
        changingGroups = true
        let key = NSApp.keyWindow
        let all = groupedWindows()
        let selected = activeWindow ?? lastActiveWindow.flatMap { value in all.first { $0 === value } } ?? all.first
        isEnabled = requested
        if requested {
            for window in all { window.tabbingMode = .preferred }
            if let selected {
                for window in all where window !== selected {
                    if selected.tabGroup?.windows.contains(where: { $0 === window }) != true {
                        append(window, to: selected)
                    }
                }
                selected.tabGroup?.selectedWindow = selected
            }
        } else {
            // Keep the native order when the split windows are later re-merged.
            entries = all.compactMap { window in entries.first { $0.window === window } }
            var cascade = selected.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) } ?? .zero
            for window in all {
                if let group = window.tabGroup, group.windows.count > 1 {
                    group.removeWindow(window)
                    cascade = window.cascadeTopLeft(from: cascade)
                }
                if !window.isMiniaturized { window.orderFront(nil) }
                if window.tabGroup?.isTabBarVisible == true { window.toggleTabBar(nil) }
                window.tabbingMode = .disallowed
            }
        }
        key?.makeKeyAndOrderFront(nil)
        changingGroups = false
        synchronizeGroups()
    }

    private func append(_ window: NSWindow, to target: NSWindow) {
        if let group = target.tabGroup { group.addWindow(window) }
        else { target.addTabbedWindow(window, ordered: .above) }
    }

    private func groupedWindows() -> [NSWindow] {
        let all = windows
        var visited = Set<ObjectIdentifier>()
        return all.flatMap { $0.tabGroup?.windows ?? [$0] }.filter { member in
            all.contains(where: { $0 === member }) && visited.insert(ObjectIdentifier(member)).inserted
        }
    }

    private func scheduleRefresh() {
        refresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyPreference()
            self?.synchronizeGroups()
        }
        refresh = work
        DispatchQueue.main.async(execute: work)
    }

    private func synchronizeGroups() {
        guard !changingGroups else { return }
        groups.removeAll()
        var observed = Set<ObjectIdentifier>()
        for window in windows {
            if let group = window.tabGroup, observed.insert(ObjectIdentifier(group)).inserted {
                let visible = isEnabled && group.windows.count > 1
                if group.isTabBarVisible != visible { (group.selectedWindow ?? window).toggleTabBar(nil) }
                groups.append(group.observe(\.windows, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                })
            }
            (window.windowController?.document as? MarkdownDocument)?.session.updateWindowActivity()
        }
    }

    @objc func newTab(_ sender: Any?) {
        guard isEnabled else { return }
        (NSApp.delegate as? AppDelegate)?.openPanel(sender)
    }

    @objc func nextTab(_ sender: Any?) { activeWindow?.selectNextTab(sender) }
    @objc func previousTab(_ sender: Any?) { activeWindow?.selectPreviousTab(sender) }
    @objc func moveTabToNewWindow(_ sender: Any?) { activeWindow?.moveTabToNewWindow(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard isEnabled else { return false }
        if menuItem.action == #selector(newTab(_:)) { return true }
        return (activeWindow?.tabGroup?.windows.count ?? 0) > 1
    }
}

@MainActor final class DocumentWindow: NSWindow {
    override func newWindowForTab(_ sender: Any?) { DocumentTabCoordinator.shared.newTab(sender) }

    override func sendEvent(_ event: NSEvent) {
        if handleReadOnlyInput(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 剪切、粘贴会先经过快捷键分发，不进入普通键盘分发。
        if handleReadOnlyInput(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleReadOnlyInput(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let document = windowController?.document as? MarkdownDocument else { return false }
        return document.session.readOnlyEditPrompt.handle(event, in: self)
    }
}
