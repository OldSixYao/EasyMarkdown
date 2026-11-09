import EasyMarkdownCore
import SwiftUI

struct EditorStatusBar: View {
    let session: DocumentSession

    static func totalLabel(_ statistics: DocumentStatistics) -> String {
        L10n.format("共 %d 行 · %d 字符", statistics.total.lineCount, statistics.total.characterCount)
    }

    static func selectionLabel(_ statistics: DocumentStatistics) -> String? {
        statistics.selection.map { L10n.format("已选 %d 行 · %d 字符", $0.lineCount, $0.characterCount) }
    }

    var body: some View {
        let statistics = session.editorStatistics
        let total = Self.totalLabel(statistics)
        let selection = Self.selectionLabel(statistics)
        let help = L10n.text("字符数不含空白字符")
        HStack(spacing: 12) {
            Text(total)
            Spacer(minLength: 0)
            if let selection { Text(selection) }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([total, selection, help].compactMap { $0 }.joined(separator: " · "))
        .accessibilityIdentifier("editorStatistics")
    }
}
