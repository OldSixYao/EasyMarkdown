import Foundation

enum SourceHighlighting {
    static let maximumLineLength = 4_096
    static let maximumScanLength = 200_000

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
    static func markdownLinks(in source: NSString, range: NSRange) -> [NSRange] {
        enum State { case text, label(Int), opening(Int), address(Int, Int) }
        var state = State.text
        var matches: [NSRange] = []
        for index in range.location..<NSMaxRange(range) {
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
