import Foundation
import EasyMarkdownCore

enum SourceHighlighting {
    static let maximumLineLength = 4_096
    static let maximumScanLength = 200_000

    enum Style { case key, string, literal, comment, code, link, heading }
    private enum FieldContext { case json, jsonc }

    private struct Rule {
        let pattern: String
        let style: Style?
        let parts: [(String, Style)]
        let attributeRegion: String?
        let fieldContext: FieldContext?
        let scalarKind: DocumentKind?

        init(_ pattern: String, _ style: Style?, parts: [(String, Style)] = [], attributeRegion: String? = nil,
             fieldContext: FieldContext? = nil, scalarKind: DocumentKind? = nil) {
            self.pattern = pattern
            self.style = style
            self.parts = parts
            self.attributeRegion = attributeRegion
            self.fieldContext = fieldContext
            self.scalarKind = scalarKind
        }
    }

    /// One alternation consumes each token once. Quotes and comments cannot
    /// start another match inside an already consumed string or comment.
    private struct Grammar {
        let expression: NSRegularExpression
        let rules: [Rule]

        init(_ rules: [Rule]) {
            self.rules = rules
            expression = try! NSRegularExpression(pattern: rules.enumerated().map {
                "(?<token\($0.offset)>\($0.element.pattern))"
            }.joined(separator: "|"))
        }

        func enumerate(in source: String, range: NSRange, deadline: TimeInterval, bounds: NSRange? = nil,
                       using body: (NSRange, Style) -> Void) -> Bool {
            var completed = true
            let text = source as NSString
            expression.enumerateMatches(in: source, options: [.reportProgress, .withoutAnchoringBounds], range: range) { match, _, stop in
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    completed = false
                    stop.pointee = true
                    return
                }
                guard let match else { return }
                if let bounds {
                    if NSMaxRange(match.range) <= bounds.location { return }
                    if match.range.location >= NSMaxRange(bounds) { stop.pointee = true; return }
                }
                for (index, rule) in rules.enumerated() {
                    let range = match.range(withName: "token\(index)")
                    guard range.location != NSNotFound else { continue }
                    if let style = rule.style {
                        let isField = rule.fieldContext.map {
                            isJSONField(in: text, after: NSMaxRange(range), context: $0, deadline: deadline)
                        } ?? false
                        guard ProcessInfo.processInfo.systemUptime < deadline else {
                            completed = false
                            stop.pointee = true
                            return
                        }
                        let valueStyle = rule.scalarKind.map { ConfigurationHighlighting.scalarStyle(in: source, range: range, kind: $0) } ?? style
                        body(range, isField ? .key : valueStyle)
                    }
                    for (name, style) in rule.parts {
                        let part = match.range(withName: name)
                        if part.location != NSNotFound, part.length > 0 { body(part, style) }
                    }
                    if let name = rule.attributeRegion {
                        let attributes = match.range(withName: name)
                        if attributes.length > 0,
                           !xmlAttributes.enumerate(in: source, range: attributes, deadline: deadline, bounds: bounds, using: body) {
                            completed = false
                            stop.pointee = true
                        }
                    }
                    break
                }
            }
            return completed
        }
    }

    /// 只检查完整字符串后面的分隔符，JSONC 允许字段名与冒号之间带注释。
    /// 注释逐个读取，避免通过多层重复正则向后试探。
    private static func isJSONField(in source: NSString, after start: Int, context: FieldContext,
                                    deadline: TimeInterval) -> Bool {
        var cursor = start
        while cursor < source.length {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            switch source.character(at: cursor) {
            case 9, 10, 13, 32:
                cursor += 1
            case 47 where context == .jsonc && cursor + 1 < source.length:
                switch source.character(at: cursor + 1) {
                case 47:
                    cursor += 2
                    while cursor < source.length, source.character(at: cursor) != 10, source.character(at: cursor) != 13 {
                        if cursor & 255 == 0, ProcessInfo.processInfo.systemUptime >= deadline { return false }
                        cursor += 1
                    }
                case 42:
                    cursor += 2
                    var closed = false
                    while cursor + 1 < source.length {
                        if cursor & 255 == 0, ProcessInfo.processInfo.systemUptime >= deadline { return false }
                        if source.character(at: cursor) == 42, source.character(at: cursor + 1) == 47 {
                            cursor += 2
                            closed = true
                            break
                        }
                        cursor += 1
                    }
                    guard closed else { return false }
                default: return false
                }
            default: return source.character(at: cursor) == 58
            }
        }
        return false
    }

    private static let closedQuoted = #""(?:[^"\\\r\n]|\\[^\r\n])*""#
    private static let closedSingleQuoted = #"'[^'\r\n]*'"#
    private static let tomlFieldPart = "(?:[A-Za-z0-9_\\-]+|" + closedQuoted + "|" + closedSingleQuoted + ")"
    private static let tomlField = #"(?<![\w.\-])"# + tomlFieldPart + "(?:[ \\t]*\\.[ \\t]*" + tomlFieldPart + #")*(?=[ \t]*=)"#
    private static let quoted = #""(?:[^"\\\r\n]|\\(?:[^\r\n]|\z))*(?:"|(?=\r|\n|\z))"#
    private static let jsonLiteral = #"(?<![\w.+\-])(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+\-]?\d+)?)(?![\w.+\-])"#
    private static let key = #"(?m)^[ \t]*(?:export[ \t]+)?[\w.\-]+(?=[ \t]*[:=])"#
    private static let section = #"(?m)^[ \t]*\[[^\r\n]+\]"#
    private static let blockComment = #"/\*[\s\S]*?(?:\*/|\z)"#
    // Consume ordinary words so literals cannot begin halfway through a value.
    private static let word = #"[^\s"'{}\[\],:=#;!<>`]+"#

    private static let json = Grammar([
        Rule(closedQuoted, .string, fieldContext: .json), Rule(quoted, .string),
        Rule(jsonLiteral, .literal), Rule(word, nil)
    ])
    private static let jsonc = Grammar([
        Rule(#"//[^\r\n]*"#, .comment), Rule(blockComment, .comment),
        Rule(closedQuoted, .string, fieldContext: .jsonc), Rule(quoted, .string),
        Rule(jsonLiteral, .literal), Rule(word, nil)
    ])
    private static let xml = Grammar([
        Rule(#"<!--[\s\S]*?(?:-->|\z)"#, .comment),
        Rule(#"<!\[CDATA\[(?<xmlData>[\s\S]*?)(?:\]\]>|\z)"#, nil, parts: [("xmlData", .string)]),
        Rule(#"<!DOCTYPE(?:[^>"'\[]|"[^"]*"|'[^']*'|\[(?:[^\]"']|"[^"]*"|'[^']*')*\])*(?:>|\z)"#, .key),
        Rule(#"(?<xmlOpen></?[\w:.-]+|<\?[\w:.-]+)(?<xmlAttributes>(?:[^<>"'/?]|"[^"]*(?:"|\z)|'[^']*(?:'|\z))*)(?<xmlClose>(?:/|\?)?>|\z)"#, nil,
             parts: [("xmlOpen", .key), ("xmlClose", .key)], attributeRegion: "xmlAttributes"),
        Rule(#"[^<]+"#, .string)
    ])
    private static let xmlAttributes = Grammar([
        Rule(#"[\w:.-]+(?=[ \t\r\n]*=)"#, .key),
        Rule(#""[^"]*(?:"|\z)"#, .string), Rule(#"'[^']*(?:'|\z)"#, .string)
    ])
    private static let toml = Grammar([
        Rule(#"#[^\r\n]*"#, .comment),
        Rule(tomlField, .key),
        Rule(#""""(?:[^"\\]|\\(?:[\s\S]|\z)|"(?!""))*(?:"{3,5}|\z)"#, .string),
        Rule(#"'''[\s\S]*?(?:'{3,5}|\z)"#, .string),
        Rule(quoted, .string), Rule(#"'[^'\r\n]*(?:'|(?=\r|\n|\z))"#, .string),
        Rule(key, .key), Rule(section, .key),
        Rule(#"[^\s,\[\]{}=#]+"#, .string, scalarKind: .toml)
    ])
    private static let markdownCode = Grammar([
        Rule(#"(?m)^ {0,3}(?<backtickFence>`{3,})[^\r\n]*(?:\r\n|\r|\n|\z)[\s\S]*?(?:^ {0,3}\k<backtickFence>`*[ \t]*(?=\r|\n|\z)|\z)"#, .code),
        Rule(#"(?m)^ {0,3}(?<tildeFence>~{3,})[^\r\n]*(?:\r\n|\r|\n|\z)[\s\S]*?(?:^ {0,3}\k<tildeFence>~*[ \t]*(?=\r|\n|\z)|\z)"#, .code),
        Rule(#"<!--[\s\S]*?(?:-->|\z)"#, .comment),
        Rule(#"(?<!`)(?<inlineTicks>`+)(?!`)[^\r\n]*?\k<inlineTicks>(?!`)"#, .code)
    ])
    private static let markdownHeading = try! NSRegularExpression(pattern: #"(?m)^#{1,6}\s.+$"#)

    /// Multiline grammars scan from the start to retain lexical context, but
    /// only bounded visible lines receive temporary display attributes.
    static func enumerate(in source: String, kind: DocumentKind, ranges: [NSRange],
                          using body: (NSRange, Style) -> Void) {
        guard !ranges.isEmpty else { return }
        let bounds = NSRange(location: ranges[0].location, length: NSMaxRange(ranges[ranges.count - 1]) - ranges[0].location)
        if [.yaml, .ini, .configuration, .environment, .properties].contains(kind) {
            ConfigurationHighlighting.enumerate(in: source, kind: kind, limit: NSMaxRange(bounds),
                deadline: ProcessInfo.processInfo.systemUptime + 0.008) { match, style in
                for intersection in intersections(of: match, with: ranges) { body(intersection, style) }
            }
            return
        }
        let grammar: Grammar
        let multiline: Bool
        switch kind {
        case .json: (grammar, multiline) = (json, false)
        case .jsonc: (grammar, multiline) = (jsonc, true)
        case .xml: (grammar, multiline) = (xml, true)
        case .toml: (grammar, multiline) = (toml, true)
        case .markdown: (grammar, multiline) = (markdownCode, true)
        case .text, .yaml, .ini, .configuration, .environment, .properties: return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.008
        let scanRanges = multiline ? [NSRange(location: 0, length: (source as NSString).length)] : ranges
        var protected: [NSRange] = []
        for range in scanRanges {
            guard grammar.enumerate(in: source, range: range, deadline: deadline, bounds: bounds, using: { match, style in
                if kind == .markdown { protected.append(match) }
                for intersection in intersections(of: match, with: ranges) { body(intersection, style) }
            }) else { return }
        }
        guard kind == .markdown else { return }
        // Code and HTML comments retain their colors even inside a heading or
        // link. Only the remaining parts of those larger constructs are styled.
        for range in ranges {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return }
            markdownHeading.enumerateMatches(in: source, options: [.reportProgress, .withoutAnchoringBounds], range: range) { match, _, stop in
                guard ProcessInfo.processInfo.systemUptime < deadline else { stop.pointee = true; return }
                if let match {
                    for part in excluding(protected, from: match.range) { body(part, .heading) }
                }
            }
            for match in markdownLinks(in: source as NSString, range: range, deadline: deadline) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return }
                for part in excluding(protected, from: match) { body(part, .link) }
            }
        }
    }

    private static func intersections(of range: NSRange, with ranges: [NSRange]) -> [NSRange] {
        var low = 0, high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(ranges[middle]) <= range.location { low = middle + 1 }
            else { high = middle }
        }
        var result: [NSRange] = []
        while low < ranges.count, ranges[low].location < NSMaxRange(range) {
            let intersection = NSIntersectionRange(range, ranges[low])
            if intersection.length > 0 { result.append(intersection) }
            low += 1
        }
        return result
    }

    private static func excluding(_ protected: [NSRange], from range: NSRange) -> [NSRange] {
        var cursor = range.location
        var result: [NSRange] = []
        for intersection in intersections(of: range, with: protected) {
            if cursor < intersection.location { result.append(NSRange(location: cursor, length: intersection.location - cursor)) }
            cursor = NSMaxRange(intersection)
        }
        if cursor < NSMaxRange(range) { result.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor)) }
        return result
    }

    /// Keep consecutive short lines together so multiline comments still match.
    /// A long logical line is skipped rather than highlighted using a false boundary.
    static func boundedLineRanges(in source: NSString, range: NSRange) -> [NSRange] {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: source.length))
        var cursor = range.location
        var remaining = maximumScanLength
        var ranges: [NSRange] = []
        while cursor < NSMaxRange(range), remaining > 0 {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            let end = min(NSMaxRange(line), NSMaxRange(range))
            guard end > cursor else { break }
            if line.length <= maximumLineLength, end - cursor <= remaining {
                let next = NSRange(location: cursor, length: end - cursor)
                if let last = ranges.last, NSMaxRange(last) == cursor {
                    ranges[ranges.count - 1].length += next.length
                } else { ranges.append(next) }
                remaining -= next.length
            }
            cursor = end
        }
        return ranges
    }

    /// A single UTF-16 pass replaces the link regex's repeated suffix scans on
    /// unclosed brackets/URLs. This is basic presentation, not a Markdown parser.
    static func markdownLinks(in source: NSString, range: NSRange, deadline: TimeInterval = .infinity) -> [NSRange] {
        enum State { case text, label(Int), opening(Int), address(Int, Int) }
        var state = State.text
        var matches: [NSRange] = []
        for index in range.location..<NSMaxRange(range) {
            if index & 255 == 0, ProcessInfo.processInfo.systemUptime >= deadline { break }
            let character = source.character(at: index)
            if character == 10 || character == 13 { state = .text; continue }
            switch state {
            case .text:
                if character == 91 { state = .label(index) }
            case .label(let start):
                if character == 93 { state = index > start + 1 ? .opening(start) : .text }
            case .opening(let start):
                if character == 40 { state = .address(start, index + 1) }
                else { state = character == 91 ? .label(index) : .text }
            case .address(let start, let addressStart):
                if character == 41 {
                    if index > addressStart { matches.append(NSRange(location: start, length: index - start + 1)) }
                    state = .text
                }
            }
        }
        return matches
    }
}
