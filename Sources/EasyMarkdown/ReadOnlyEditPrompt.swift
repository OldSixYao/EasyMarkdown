import AppKit
import EasyMarkdownCore

/// 在文档窗口分发键盘事件前提示，覆盖原生阅读和网页排版阅读。
@MainActor final class ReadOnlyEditPrompt {
    private weak var session: DocumentSession?
    private var alert: NSAlert?

    init(session: DocumentSession) { self.session = session }

    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let session, !session.closed, session.mode == .read,
              isEditingKey(event), isDocumentFocused(in: window, session: session) else { return false }
        if alert != nil { return true }
        guard window.isKeyWindow, NSApp.isActive, window.attachedSheet == nil,
              NSApp.modalWindow == nil, !session.isSaving, !session.isLoadingExternal,
              !session.showExternal, session.errorMessage == nil else { return false }
        // 长按后取消提示时，等待下一次独立按键，避免立即重复弹窗。
        guard !event.isARepeat else { return true }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text("当前是只读模式，是否开始编辑？")
        alert.addButton(withTitle: L10n.text("确定"))
        alert.addButton(withTitle: L10n.text("取消")).keyEquivalent = "\u{1b}"
        alert.window.identifier = NSUserInterfaceItemIdentifier("readOnlyEditConfirmation")
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.alert = nil
            guard let session = self.session, !session.closed else { return }
            if response == .alertFirstButtonReturn, session.mode == .read {
                session.mode = .edit
                session.editorFocusRequest += 1
            }
            session.externalChangePrompt.schedule()
        }
        return true
    }

    func stop() {
        if let alert, let window = alert.window.sheetParent {
            window.endSheet(alert.window, returnCode: .abort)
        }
        alert = nil
    }

    private func isDocumentFocused(in window: NSWindow, session: DocumentSession) -> Bool {
        if let text = window.firstResponder as? NSTextView {
            guard !text.isEditable, let coordinator = text.delegate as? SourceEditor.Coordinator else { return false }
            return coordinator.session === session && !coordinator.isSecondary && !coordinator.isOverride
        }
        // 原生字段编辑器和其他输入控件自行处理键盘，不干扰查找或工具栏操作。
        if window.firstResponder is NSControl { return false }
        return true
    }

    private func isEditingKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.control) { return false }
        if modifiers.contains(.command) {
            // 复制、查找和应用快捷键沿用原行为；剪切、粘贴表达编辑意图。
            return ["v", "x"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
        }
        if event.keyCode == 51 || event.keyCode == 117 { return true }
        // 空格、回车、Tab、方向键和功能键用于阅读滚动、激活按钮及切换焦点。
        guard let characters = event.characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.contains {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) &&
                !(0xF700...0xF8FF).contains($0.value)
        }
    }
}
