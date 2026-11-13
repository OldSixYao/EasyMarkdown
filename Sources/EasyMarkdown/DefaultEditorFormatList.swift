import AppKit
import SwiftUI
import EasyMarkdownCore

/// 直接持有列表的滚动容器，避免依赖 SwiftUI 内部视图层级及布局时机。
struct DefaultEditorFormatList: NSViewRepresentable {
    let formats: [DefaultEditorFormat]
    let associations: [DefaultEditorFormat: DefaultEditorAssociation]
    @Binding var selection: DefaultEditorFormat
    let selectionRequest: Int
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.setAccessibilityIdentifier("default-editor-format-scroll")

        let table = NSTableView()
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.backgroundColor = .textBackgroundColor
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.setAccessibilityLabel(L10n.text("文件类型"))
        table.setAccessibilityIdentifier("default-editor-format")

        let title = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("format"))
        title.minWidth = 180
        title.width = 340
        let status = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("association"))
        let labels = ["已设为默认", "部分已设为默认", "其他应用", "未设置"].map(L10n.text)
        status.width = ceil(labels.map {
            ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width
        }.max() ?? 80) + 40
        status.resizingMask = []
        table.addTableColumn(title)
        table.addTableColumn(status)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let formatsChanged = coordinator.parent.formats != formats
        let changed = formatsChanged || coordinator.parent.associations != associations
        let revealSelection = coordinator.parent.selectionRequest != selectionRequest
        coordinator.parent = self
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        table.isEnabled = isEnabled
        if changed || table.numberOfRows != formats.count { table.reloadData() }
        if let index = formats.firstIndex(of: selection) {
            let needsSelection = table.selectedRow != index
            if needsSelection { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            if needsSelection || revealSelection || formatsChanged { table.scrollRowToVisible(index) }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: DefaultEditorFormatList
        var isUpdating = false

        init(_ parent: DefaultEditorFormatList) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.formats.count }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, parent.isEnabled, let table = notification.object as? NSTableView,
                  parent.formats.indices.contains(table.selectedRow) else { return }
            parent.selection = parent.formats[table.selectedRow]
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { parent.isEnabled }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = NSTableRowView()
            view.setAccessibilityIdentifier("default-editor-row-" + parent.formats[row].rawValue)
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier else { return nil }
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier)
            let format = parent.formats[row]
            let association = parent.associations[format] ?? DefaultEditorAssociation(state: .unset, applicationName: nil)
            if identifier.rawValue == "format" {
                cell.textField?.stringValue = format.title
                cell.toolTip = format.title
            } else {
                cell.textField?.stringValue = association.label
                let color: NSColor = association.state == .current ? .systemGreen : .secondaryLabelColor
                cell.textField?.textColor = color
                let symbol: String
                switch association.state {
                case .current: symbol = "checkmark.circle.fill"
                case .partial: symbol = "circle.lefthalf.filled"
                case .other: symbol = "app"
                case .unset: symbol = "circle.dashed"
                }
                cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: association.label)
                cell.imageView?.contentTintColor = color
                cell.toolTip = association.applicationName ?? association.label
            }
            return cell
        }

        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)
            ])
            if identifier.rawValue == "association" {
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                label.setContentHuggingPriority(.required, for: .horizontal)
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.imageView = icon
                cell.addSubview(icon)
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor, constant: 4),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 12),
                    icon.heightAnchor.constraint(equalToConstant: 12),
                    label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
                ])
            } else {
                label.font = .systemFont(ofSize: NSFont.systemFontSize)
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true
            }
            return cell
        }
    }
}
