import AppKit
import Combine
import Sparkle
import SwiftUI
import EasyMarkdownCore

/// One updater for the application menu and every settings window.
@MainActor
final class UpdateController: NSObject, ObservableObject, NSMenuItemValidation {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var lastCheck: Date?
    @Published private(set) var notice: String?
    private var controller: SPUStandardUpdaterController?

    var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return L10n.format("版本 %@（构建号 %@）", version, build)
    }

    static func unavailableReason(bundleURL: URL, isReadOnly: Bool) -> String? {
        guard bundleURL.pathExtension == "app" else {
            return L10n.text("请使用完整的 EasyMarkdown 应用包检查更新。")
        }
        if isReadOnly || bundleURL.path.contains("/AppTranslocation/") {
            return L10n.text("请先将 EasyMarkdown 拖入“应用程序”，退出后从“应用程序”重新打开，再检查更新。")
        }
        return nil
    }

    func start() {
        guard controller == nil else { return }
        let url = Bundle.main.bundleURL
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if let reason = Self.unavailableReason(bundleURL: url, isReadOnly: readOnly) {
            notice = reason
            canCheckForUpdates = true // Keep the explanation reachable from the menu.
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            let updater = controller.updater
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
            updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
        } catch {
            notice = L10n.format("无法启动更新检查：%@", error.localizedDescription)
            canCheckForUpdates = true
        }
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    @objc func checkForUpdates(_ sender: Any?) {
        if let notice {
            let alert = NSAlert()
            alert.messageText = L10n.text("检查更新")
            alert.informativeText = notice
            alert.addButton(withTitle: L10n.text("好"))
            alert.runModal()
        } else if canCheckForUpdates {
            controller?.checkForUpdates(sender)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheckForUpdates }
}

struct SoftwareUpdateSection: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Section(L10n.text("软件更新")) {
            HStack {
                Text(updates.version).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("检查更新…")) { updates.checkForUpdates(nil) }
                    .disabled(!updates.canCheckForUpdates)
                    .accessibilityIdentifier("check-for-updates")
            }
            Toggle(L10n.text("每天自动检查更新"), isOn: Binding(
                get: { updates.automaticallyChecks },
                set: { updates.setAutomaticallyChecks($0) }
            ))
            .disabled(updates.notice != nil)
            .accessibilityIdentifier("automatic-update-checks")
            Text(L10n.text("发现新版本时提示，下载和安装前由你确认。"))
                .font(.caption).foregroundStyle(.secondary)
            if let notice = updates.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            } else if let date = updates.lastCheck {
                Text(L10n.format("上次检查：%@", date.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
