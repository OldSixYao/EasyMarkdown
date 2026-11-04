import SwiftUI
import EasyMarkdownCore

struct MarkdownToolbar: View {
    let session: DocumentSession

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                headings
                separator
                inlineStyles
                separator
                lists
                separator
                code
                separator
                button(.link, icon: "link")
                button(.image, icon: "photo")
                button(.table, icon: "tablecells")
                button(.horizontalRule, icon: "minus")
            }
            HStack(spacing: 4) {
                headings
                separator
                inlineStyles
                separator
                button(.quote, icon: "text.quote")
                button(.bulletList, icon: "list.bullet")
                button(.codeBlock, icon: "chevron.left.forwardslash.chevron.right")
                button(.link, icon: "link")
                Menu {
                    menuItem(.orderedList, icon: "list.number")
                    menuItem(.taskList, icon: "checklist")
                    menuItem(.inlineCode, icon: "chevron.left.slash.chevron.right")
                    menuItem(.image, icon: "photo")
                    menuItem(.table, icon: "tablecells")
                    menuItem(.horizontalRule, icon: "minus")
                } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .toolbarHoverFeedback(L10n.text("更多 Markdown 语法"))
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .padding(.horizontal, 20).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(.bar)
        .disabled(session.isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Markdown 语法工具栏"))
        .accessibilityIdentifier("markdownToolbar")
    }

    private var headings: some View {
        Menu {
            ForEach(1...6, id: \.self) { level in
                Button(L10n.format("H%d  ·  %d 级标题", level, level)) { session.applyMarkdown?(.heading(level)) }
            }
            Divider()
            Button(L10n.text("正文（移除标题）")) { session.applyMarkdown?(.paragraph) }
        } label: {
            Text(L10n.text("标题")).fontWeight(.medium).frame(height: 26)
        }.menuStyle(.borderlessButton).fixedSize()
            .toolbarHoverFeedback(L10n.text("标题级别 H1–H6"))
    }

    private var inlineStyles: some View {
        Group {
            button(.bold, icon: "bold")
            button(.italic, icon: "italic")
            button(.strikethrough, icon: "strikethrough")
        }
    }

    private var lists: some View {
        Group {
            button(.quote, icon: "text.quote")
            button(.bulletList, icon: "list.bullet")
            button(.orderedList, icon: "list.number")
            button(.taskList, icon: "checklist")
        }
    }

    private var code: some View {
        Group {
            button(.inlineCode, icon: "chevron.left.slash.chevron.right")
            button(.codeBlock, icon: "chevron.left.forwardslash.chevron.right")
        }
    }

    private var separator: some View { Divider().frame(height: 16).padding(.horizontal, 5) }

    private func button(_ command: MarkdownCommand, icon: String) -> some View {
        Button { session.applyMarkdown?(command) } label: {
            Image(systemName: icon).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .toolbarHoverFeedback(command.title)
        .accessibilityIdentifier("markdown.\(command.title)")
    }

    private func menuItem(_ command: MarkdownCommand, icon: String) -> some View {
        Button { session.applyMarkdown?(command) } label: { Label(command.title, systemImage: icon) }
    }
}
