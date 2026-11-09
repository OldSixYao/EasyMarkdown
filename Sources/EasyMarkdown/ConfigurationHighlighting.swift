import Foundation
import EasyMarkdownCore

/// 识别完整配置值，避免把地址、命令和普通文字拆成零散的数字或关键字。
enum ConfigurationHighlighting {
    private static let number = #"[+\-]?(?:0[xX][\da-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|(?:\d[\d_]*(?:\.[\d_]*)?|\.[\d_]+)(?:[eE][+\-]?[\d_]+)?|\.(?:inf|nan))"#
    private static let scalar = try! NSRegularExpression(pattern: "(?:true|false|null|yes|no|on|off|~|" + number + ")", options: [.caseInsensitive])
    private static let tomlScalar = try! NSRegularExpression(pattern: "(?:true|false|inf|nan|" + number + ")")

    static func scalarStyle(in source: String, range: NSRange, kind: DocumentKind) -> SourceHighlighting.Style {
        let expression = kind == .toml ? tomlScalar : scalar
        return expression.firstMatch(in: source, options: [.anchored], range: range)?.range == range ? .literal : .string
    }

    static func enumerate(in source: String, kind: DocumentKind, limit: Int, deadline: TimeInterval,
                          using body: (NSRange, SourceHighlighting.Style) -> Void) {
        var scanner = Scanner(source: source, units: Array(source.utf16), deadline: deadline)
        if kind == .yaml { scanner.yaml(limit: limit) }
        else { scanner.assignments(kind: kind, limit: limit) }
        for (range, style) in scanner.tokens { body(range, style) }
    }

    private struct Scanner {
        let source: String
        let units: [UInt16]
        let deadline: TimeInterval
        var cursor = 0
        var tokens: [(NSRange, SourceHighlighting.Style)] = []

        private func hasTime(at index: Int) -> Bool {
            index & 255 != 0 || ProcessInfo.processInfo.systemUptime < deadline
        }

        private func isSpace(_ character: UInt16) -> Bool { character == 32 || character == 9 }
        private func isNewline(_ character: UInt16) -> Bool { character == 10 || character == 13 }

        private func lineEnd(from start: Int) -> Int {
            var end = start
            while end < units.count, !isNewline(units[end]), hasTime(at: end) { end += 1 }
            return end
        }

        private func nextLine(after end: Int) -> Int {
            guard end < units.count, isNewline(units[end]) else { return end }
            return min(units.count, end + (units[end] == 13 && end + 1 < units.count && units[end + 1] == 10 ? 2 : 1))
        }

        private func skippingSpaces(from start: Int) -> Int {
            var end = start
            while end < units.count, isSpace(units[end]), hasTime(at: end) { end += 1 }
            return end
        }

        private func trimmedEnd(from start: Int, to end: Int) -> Int {
            var end = end
            while end > start, isSpace(units[end - 1]), hasTime(at: end) { end -= 1 }
            return end
        }

        private mutating func emit(_ start: Int, _ end: Int, _ style: SourceHighlighting.Style) {
            if end > start { tokens.append((NSRange(location: start, length: end - start), style)) }
        }

        private func quotedEnd(from start: Int, yaml: Bool, multiline: Bool) -> Int {
            let quote = units[start]
            var end = start + 1
            while end < units.count, hasTime(at: end) {
                if !multiline, isNewline(units[end]) { break }
                if units[end] == 92, quote == 34 || !yaml {
                    end = min(units.count, end + 2)
                } else if units[end] == quote {
                    if yaml, quote == 39, end + 1 < units.count, units[end + 1] == quote { end += 2 }
                    else { return end + 1 }
                } else { end += 1 }
            }
            return end
        }

        private func yamlSeparator(at index: Int, flow: Bool) -> Bool {
            guard units[index] == 58 else { return false }
            guard index + 1 < units.count else { return true }
            let next = units[index + 1]
            return isSpace(next) || isNewline(next) || (flow && [44, 91, 93, 123, 125].contains(next))
        }

        mutating func yaml(limit: Int) {
            var flowDepth = 0
            var continuationIndent: Int?
            var pendingIndent: Int?
            var forceString = false
            while cursor < min(limit, units.count), ProcessInfo.processInfo.systemUptime < deadline {
                let character = units[cursor]
                if isSpace(character) || isNewline(character) { cursor += 1; continue }
                let line = lineStart(at: cursor)
                let indentation = skippingSpaces(from: line) - line
                if let indent = continuationIndent, indentation <= indent { continuationIndent = nil }
                // 普通多行值的后续缩进行是同一个字符串，不能再解释数字或冒号。
                if continuationIndent != nil, flowDepth == 0, character != 35 {
                    let end = lineEnd(from: cursor)
                    emit(cursor, trimmedEnd(from: cursor, to: end), .string)
                    cursor = nextLine(after: end)
                    continue
                }
                if [45, 63].contains(character), cursor + 1 == units.count || isSpace(units[cursor + 1]) || isNewline(units[cursor + 1]) {
                    cursor += 1; continue
                }
                switch character {
                case 35:
                    let end = lineEnd(from: cursor)
                    emit(cursor, end, .comment); cursor = end
                case 91, 123:
                    flowDepth += 1; pendingIndent = nil; forceString = false; cursor += 1
                case 93, 125:
                    flowDepth = max(0, flowDepth - 1); cursor += 1
                case 44 where flowDepth > 0:
                    cursor += 1
                case 58 where yamlSeparator(at: cursor, flow: flowDepth > 0):
                    cursor += 1
                case 124 where flowDepth == 0, 62 where flowDepth == 0:
                    if yamlBlock() { pendingIndent = nil; forceString = false }
                    else { yamlPlain(flow: false, continuationIndent: &continuationIndent, pendingIndent: &pendingIndent, forceString: &forceString) }
                case 34, 39:
                    let end = quotedEnd(from: cursor, yaml: true, multiline: true)
                    let following = skippingSpaces(from: end)
                    let isKey = following < units.count && units[following] == 58
                    emit(cursor, end, isKey ? .key : .string)
                    pendingIndent = isKey ? yamlIndentation(at: cursor) : nil
                    if !isKey { forceString = false }
                    cursor = end
                case 38, 42, 33:
                    // 锚点、别名和类型标签属于值；其后的值仍独立识别。
                    var end = cursor + 1
                    while end < units.count, !isSpace(units[end]), !isNewline(units[end]),
                          ![44, 91, 93, 123, 125].contains(units[end]), hasTime(at: end) { end += 1 }
                    emit(cursor, end, .string)
                    if character == 33 {
                        forceString = String(decoding: units[cursor..<end], as: UTF16.self) == "!!str"
                    } else if character == 42 { pendingIndent = nil }
                    cursor = end
                default:
                    yamlPlain(flow: flowDepth > 0, continuationIndent: &continuationIndent, pendingIndent: &pendingIndent, forceString: &forceString)
                }
            }
        }

        private func lineStart(at index: Int) -> Int {
            var start = index
            while start > 0, !isNewline(units[start - 1]), hasTime(at: start) { start -= 1 }
            return start
        }

        private mutating func yamlPlain(flow: Bool, continuationIndent: inout Int?, pendingIndent: inout Int?, forceString: inout Bool) {
            let start = cursor
            while cursor < units.count, !isNewline(units[cursor]), hasTime(at: cursor) {
                let character = units[cursor]
                if flow, [44, 91, 93, 123, 125].contains(character) { break }
                if character == 35, cursor > start, isSpace(units[cursor - 1]) { break }
                if yamlSeparator(at: cursor, flow: flow) { break }
                cursor += 1
            }
            let end = trimmedEnd(from: start, to: cursor)
            guard end > start else { cursor = min(units.count, cursor + 1); return }
            let isKey = cursor < units.count && yamlSeparator(at: cursor, flow: flow)
            let range = NSRange(location: start, length: end - start)
            let style: SourceHighlighting.Style = isKey ? .key : forceString ? .string : scalarStyle(in: source, range: range, kind: .yaml)
            emit(start, end, style)
            if !isKey, !flow, style == .string {
                let first = skippingSpaces(from: lineStart(at: start))
                continuationIndent = units[first] == 45 ? yamlIndentation(at: start) : pendingIndent ?? yamlIndentation(at: start)
            }
            pendingIndent = isKey ? yamlIndentation(at: start) : nil
            if !isKey { forceString = false }
        }

        private func yamlIndentation(at start: Int) -> Int {
            let line = lineStart(at: start)
            let first = skippingSpaces(from: line)
            if first < start, units[first] == 45 {
                let keyStart = skippingSpaces(from: first + 1)
                if units[keyStart..<start].contains(58) { return keyStart - line }
            }
            return first - line
        }

        private mutating func yamlBlock() -> Bool {
            let start = cursor
            var indicatorEnd = start + 1
            while indicatorEnd < units.count, [43, 45, 49, 50, 51, 52, 53, 54, 55, 56, 57].contains(units[indicatorEnd]) {
                indicatorEnd += 1
            }
            let following = skippingSpaces(from: indicatorEnd)
            guard following == units.count || isNewline(units[following]) || units[following] == 35 else { return false }
            let headerEnd = lineEnd(from: following)
            let indentation = yamlIndentation(at: start)
            emit(start, indicatorEnd, .string)
            if following < headerEnd { emit(following, headerEnd, .comment) }
            let bodyStart = nextLine(after: headerEnd)
            var end = bodyStart
            while end < units.count, ProcessInfo.processInfo.systemUptime < deadline {
                let contentStart = skippingSpaces(from: end)
                if contentStart < units.count, !isNewline(units[contentStart]), contentStart - end <= indentation { break }
                let next = nextLine(after: lineEnd(from: contentStart))
                guard next > end else { break }
                end = next
            }
            emit(bodyStart, end, .string)
            cursor = end
            return true
        }

        mutating func assignments(kind: DocumentKind, limit: Int) {
            while cursor < min(limit, units.count), ProcessInfo.processInfo.systemUptime < deadline {
                cursor = skippingSpaces(from: cursor)
                guard cursor < units.count else { return }
                if isNewline(units[cursor]) { cursor = nextLine(after: cursor); continue }
                let end = lineEnd(from: cursor)
                if isComment(at: cursor, kind: kind, lineStart: true) {
                    emit(cursor, end, .comment); cursor = nextLine(after: end); continue
                }
                if units[cursor] == 91, kind == .ini || kind == .configuration,
                   let close = units[cursor..<end].firstIndex(of: 93) {
                    emit(cursor, close + 1, .key); cursor = close + 1
                    assignmentValue(kind: kind)
                    continue
                }
                var separator = cursor
                while separator < end, hasTime(at: separator) {
                    let character = units[separator]
                    if character == 92 { separator = min(end, separator + 2); continue }
                    if character == 61 || (kind != .environment && character == 58) || (kind == .properties && isSpace(character)) { break }
                    separator += 1
                }
                if separator < end {
                    emit(cursor, trimmedEnd(from: cursor, to: separator), .key)
                    cursor = skippingSpaces(from: separator)
                    if cursor < end, units[cursor] == 61 || units[cursor] == 58 { cursor += 1 }
                } else if kind == .properties {
                    emit(cursor, trimmedEnd(from: cursor, to: end), .key)
                    cursor = nextLine(after: end); continue
                }
                assignmentValue(kind: kind)
            }
        }

        private func isComment(at index: Int, kind: DocumentKind, lineStart: Bool = false) -> Bool {
            let character = units[index]
            if kind == .properties { return lineStart && (character == 35 || character == 33) }
            if kind == .environment { return character == 35 }
            let boundary = lineStart || index == 0 || isSpace(units[index - 1])
            return boundary && (character == 35 || character == 59 || (lineStart && kind == .configuration && character == 33))
        }

        private mutating func assignmentValue(kind: DocumentKind) {
            cursor = skippingSpaces(from: cursor)
            let start = cursor
            var quote: UInt16 = 0
            while cursor < units.count, hasTime(at: cursor) {
                let character = units[cursor]
                if isNewline(character) {
                    if kind != .environment || quote == 0 { break }
                } else if character == 92, kind != .environment || quote != 39 {
                    let next = cursor + 1
                    if next < units.count, isNewline(units[next]) {
                        if kind == .properties { cursor = nextLine(after: next); continue }
                    } else { cursor = min(units.count, next + 1); continue }
                } else if character == quote { quote = 0 }
                else if quote == 0 {
                    if isComment(at: cursor, kind: kind) { break }
                    if (character == 34 || character == 39), cursor == start || isSpace(units[cursor - 1]) || kind == .environment { quote = character }
                }
                cursor += 1
            }
            let end = trimmedEnd(from: start, to: cursor)
            if end > start { emit(start, end, scalarStyle(in: source, range: NSRange(location: start, length: end - start), kind: kind)) }
            if cursor < units.count, isComment(at: cursor, kind: kind) {
                let end = lineEnd(from: cursor)
                emit(cursor, end, .comment); cursor = end
            }
            cursor = nextLine(after: cursor)
        }
    }
}
