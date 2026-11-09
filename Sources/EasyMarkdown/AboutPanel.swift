import EasyMarkdownCore
import AppKit

@MainActor enum AboutPanel {
    static let repositoryURL = URL(string: "https://github.com/OldSixYao/EasyMarkdown")!

    static func options(bundle: Bundle = .main) -> [NSApplication.AboutPanelOptionKey: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 8
        let credits = NSMutableAttributedString(string: L10n.text("安静阅读，随手修改。\n\nGitHub 仓库\n"), attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        credits.append(NSAttributedString(string: "github.com/OldSixYao/EasyMarkdown", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.linkColor,
            .link: repositoryURL,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .paragraphStyle: paragraph
        ]))
        var result: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "EasyMarkdown",
            .applicationVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: credits
        ]
        if let url = bundle.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            result[.applicationIcon] = icon
        } else {
            result[.applicationIcon] = NSApp.applicationIconImage
        }
        return result
    }

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: options())
        for window in NSApp.windows where window.windowController?.document == nil {
            window.tabbingMode = .disallowed
        }
    }
}
