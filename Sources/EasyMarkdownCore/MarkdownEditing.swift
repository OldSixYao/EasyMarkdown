import Foundation

public enum MarkdownCommand: Equatable, Sendable {
    case heading(Int), paragraph, bold, italic, strikethrough
    case quote, bulletList, orderedList, taskList
    case inlineCode, codeBlock, link, image, table, horizontalRule

    public var title: String {
        switch self {
        case .heading(let level): return "\(level) 级标题"
        case .paragraph: return "正文"
        case .bold: return "粗体"
        case .italic: return "斜体"
        case .strikethrough: return "删除线"
        case .quote: return "引用"
        case .bulletList: return "无序列表"
        case .orderedList: return "有序列表"
        case .taskList: return "任务列表"
        case .inlineCode: return "行内代码"
        case .codeBlock: return "代码块"
        case .link: return "链接"
        case .image: return "图片"
        case .table: return "表格"
        case .horizontalRule: return "分隔线"
        }
    }
}

/// Ranges use UTF-16 to match NSTextView, including Chinese and emoji selections.
public struct MarkdownEdit: Sendable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange
}

public enum MarkdownEditing {
    public static func edit(_ command: MarkdownCommand, text: String, selection: NSRange) -> MarkdownEdit {
        let source = text as NSString
        let start = min(max(0, selection.location), source.length)
        let range = NSRange(location: start, length: min(max(0, selection.length), source.length - start))
        let selected = source.substring(with: range)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"

        func replace(_ replacement: String, range target: NSRange? = nil,
                     select relative: NSRange) -> MarkdownEdit {
            let target = target ?? range
            return MarkdownEdit(range: target, replacement: replacement,
                selection: NSRange(location: target.location + relative.location, length: relative.length))
        }
        func wrap(_ delimiter: String, placeholder: String) -> MarkdownEdit {
            let count = (delimiter as NSString).length
            func isActive(left: Int, right: Int) -> Bool {
                // One asterisk is italic; two are bold; three combine both.
                delimiter == "*" ? left % 2 == 1 && right % 2 == 1 : left >= count && right >= count
            }
            let marker = (delimiter as NSString).character(at: 0)
            func run(_ string: NSString, from index: Int, step: Int) -> Int {
                var cursor = index
                var count = 0
                while cursor >= 0, cursor < string.length, string.character(at: cursor) == marker {
                    count += 1; cursor += step
                }
                return count
            }
            let selectedSource = selected as NSString
            if selected.hasPrefix(delimiter), selected.hasSuffix(delimiter), range.length >= count * 2,
               isActive(left: run(selectedSource, from: 0, step: 1),
                        right: run(selectedSource, from: selectedSource.length - 1, step: -1)) {
                let inner = (selected as NSString).substring(with: NSRange(location: count, length: range.length - count * 2))
                return replace(inner, select: NSRange(location: 0, length: (inner as NSString).length))
            }
            if start >= count, NSMaxRange(range) + count <= source.length,
               source.substring(with: NSRange(location: start - count, length: count)) == delimiter,
               source.substring(with: NSRange(location: NSMaxRange(range), length: count)) == delimiter,
               isActive(left: run(source, from: start - 1, step: -1), right: run(source, from: NSMaxRange(range), step: 1)) {
                return replace(selected, range: NSRange(location: start - count, length: range.length + 2 * count),
                               select: NSRange(location: 0, length: range.length))
            }
            let body = selected.isEmpty ? placeholder : selected
            return replace(delimiter + body + delimiter,
                           select: NSRange(location: count, length: (body as NSString).length))
        }

        switch command {
        case .bold: return wrap("**", placeholder: "粗体文字")
        case .italic: return wrap("*", placeholder: "斜体文字")
        case .strikethrough: return wrap("~~", placeholder: "删除线文字")
        case .inlineCode:
            let runs = selected.components(separatedBy: CharacterSet(charactersIn: "`").inverted)
                .map(\.count).max() ?? 0
            let delimiter = String(repeating: "`", count: max(1, runs + 1))
            let body = selected.isEmpty ? "代码" : selected
            let padding = body.hasPrefix("`") || body.hasSuffix("`") ||
                (body.hasPrefix(" ") && body.hasSuffix(" ") && !body.trimmingCharacters(in: .whitespaces).isEmpty) ? " " : ""
            return replace(delimiter + padding + body + padding + delimiter,
                select: NSRange(location: delimiter.count + padding.count, length: (body as NSString).length))
        case .link, .image:
            let isImage = command == .image
            let label = selected.isEmpty ? (isImage ? "图片说明" : "链接文字") : selected
            let escaped = label.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            let prefix = (isImage ? "![" : "[") + escaped + "]("
            let destination = isImage ? "图片路径" : "https://example.com"
            return replace(prefix + destination + ")",
                           select: NSRange(location: (prefix as NSString).length, length: (destination as NSString).length))
        case .codeBlock:
            let target = lineRange(source, selection: range)
            let raw = source.substring(with: target)
            let body = raw.isEmpty ? "代码" : raw
            let longest = body.components(separatedBy: CharacterSet(charactersIn: "`").inverted)
                .map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longest + 1))
            let lead = target.location > 0 && !source.substring(to: target.location).hasSuffix(newline + newline) ? newline : ""
            let bodyEnd = body.hasSuffix("\n") || body.hasSuffix("\r") ? "" : newline
            let prefix = lead + fence + newline
            return replace(prefix + body + bodyEnd + fence + newline, range: target,
                select: NSRange(location: (prefix as NSString).length, length: (body as NSString).length))
        case .horizontalRule:
            // Insert below the current block without discarding selected text.
            let target = lineRange(source, selection: range)
            let position = NSMaxRange(target)
            let before = source.substring(to: position)
            let lead = before.isEmpty || before.hasSuffix(newline + newline) ? "" : before.hasSuffix(newline) ? newline : newline + newline
            let insertion = lead + "---" + newline + newline
            return replace(insertion, range: NSRange(location: position, length: 0),
                           select: NSRange(location: (insertion as NSString).length, length: 0))
        case .table:
            let cell = selected.isEmpty ? "内容" : selected.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            let before = source.substring(to: start)
            let lead = before.isEmpty || before.hasSuffix(newline + newline) ? "" : before.hasSuffix(newline) ? newline : newline + newline
            let prefix = lead + "| 标题 1 | 标题 2 |" + newline + "| --- | --- |" + newline + "| "
            return replace(prefix + cell + " | 内容 |" + newline + newline,
                           select: NSRange(location: (prefix as NSString).length, length: (cell as NSString).length))
        default:
            return lineEdit(command, source: source, selection: range, newline: newline)
        }
    }

    private static func lineRange(_ source: NSString, selection: NSRange) -> NSRange {
        // A selection ending at the next line's start should not format that line.
        source.lineRange(for: NSRange(location: selection.location, length: max(0, selection.length - 1)))
    }

    private static func lineEdit(_ command: MarkdownCommand, source: NSString,
                                 selection: NSRange, newline: String) -> MarkdownEdit {
        let target = lineRange(source, selection: selection)
        let original = source.substring(with: target)
        let hasTrailingNewline = original.hasSuffix("\n") || original.hasSuffix("\r")
        var lines = original.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }
        if lines.isEmpty { lines = [""] }

        let headingPattern = #"^( {0,3})#{1,6}[ \t]+"#
        let listPattern = #"^(\s*)(?:[-+*][ \t]+(?:\[[ xX]\][ \t]+)?|\d+[.)][ \t]+)"#
        let pattern: String
        switch command {
        case .heading, .paragraph: pattern = headingPattern
        case .quote: pattern = #"^(\s*)>[ \t]?"#
        case .taskList: pattern = #"^(\s*)[-+*][ \t]+\[[ xX]\][ \t]+"#
        case .orderedList: pattern = #"^(\s*)\d+[.)][ \t]+"#
        default: pattern = #"^(\s*)[-+*][ \t]+(?!\[[ xX]\][ \t]+)"#
        }
        func match(_ pattern: String, _ line: String) -> NSTextCheckingResult? {
            try? NSRegularExpression(pattern: pattern).firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        }
        let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let remove: Bool
        switch command {
        case .heading(let level):
            remove = !nonempty.isEmpty && nonempty.allSatisfy { match("^( {0,3})" + String(repeating: "#", count: min(6, max(1, level))) + #"[ \t]+"#, $0) != nil }
        case .paragraph: remove = true
        default: remove = !nonempty.isEmpty && nonempty.allSatisfy { match(pattern, $0) != nil }
        }
        var firstDelta = 0
        var placeholderSelection: NSRange?
        var number = 0
        let transformed = lines.enumerated().map { index, line -> String in
            if lines.count > 1 && line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            number += 1
            let prefix: String
            switch command {
            case .heading(let level): prefix = String(repeating: "#", count: min(6, max(1, level))) + " "
            case .paragraph: prefix = ""
            case .quote: prefix = "> "
            case .orderedList: prefix = "\(number). "
            case .taskList: prefix = "- [ ] "
            default: prefix = "- "
            }
            let stripPattern: String
            switch command {
            case .bulletList, .orderedList, .taskList: stripPattern = listPattern
            default: stripPattern = pattern
            }
            let matched = match(stripPattern, line)
            let indentation = matched.map { (line as NSString).substring(with: $0.range(at: 1)) } ?? String(line.prefix { $0 == " " || $0 == "\t" })
            let stripped = matched.map { (line as NSString).substring(from: NSMaxRange($0.range)) } ?? String(line.dropFirst(indentation.count))
            var body = stripped
            if body.isEmpty && !remove && selection.length == 0 {
                switch command {
                case .heading: body = "标题"
                case .quote: body = "引用文字"
                default: body = "列表项"
                }
                placeholderSelection = NSRange(location: (indentation + prefix as NSString).length, length: (body as NSString).length)
            }
            let result = indentation + (remove ? "" : prefix) + body
            if index == 0 { firstDelta = (result as NSString).length - (line as NSString).length }
            return result
        }.joined(separator: newline) + (hasTrailingNewline ? newline : "")
        let resultLength = (transformed as NSString).length
        let relative: NSRange
        if let placeholderSelection { relative = placeholderSelection }
        else if selection.length == 0 {
            relative = NSRange(location: min(resultLength, max(0, selection.location - target.location + firstDelta)), length: 0)
        } else {
            relative = NSRange(location: 0, length: resultLength - (hasTrailingNewline ? (newline as NSString).length : 0))
        }
        return MarkdownEdit(range: target, replacement: transformed,
            selection: NSRange(location: target.location + relative.location, length: relative.length))
    }
}
