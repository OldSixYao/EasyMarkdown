import Foundation

/// 在格式化、换行转换等全文替换后恢复少量 UTF-16 位置，不建立逐字符索引。
public enum TextPositionMapping {
    public static func map(_ offsets: [Int], from source: String, to replacement: String) -> [Int] {
        guard !offsets.isEmpty else { return [] }
        if (source as NSString).compare(replacement, options: .literal) == .orderedSame {
            return offsets.map { min(replacement.utf16.count, max(0, $0)) }
        }
        let old = compact(source) as NSString
        let new = compact(replacement) as NSString
        let sourceLength = source.utf16.count
        let targetLength = replacement.utf16.count
        let sorted = offsets.enumerated().sorted { $0.element < $1.element }
        var positions = Array(repeating: 0, count: offsets.count)
        var whitespaceDistances = Array<Int?>(repeating: nil, count: offsets.count)
        var index = 0, compactOffset = 0, previousContentEnd = 0
        for (offset, unit) in source.utf16.enumerated() {
            while index < sorted.count && sorted[index].element <= offset {
                positions[sorted[index].offset] = compactOffset
                if isFormattingWhitespace(unit) {
                    whitespaceDistances[sorted[index].offset] = max(0, offset - previousContentEnd)
                }
                index += 1
            }
            if !isFormattingWhitespace(unit) { compactOffset += 1; previousContentEnd = offset + 1 }
        }
        while index < sorted.count {
            positions[sorted[index].offset] = compactOffset
            index += 1
        }
        if old != new {
            positions = positions.map { match($0, in: old, replacement: new) }
        }
        let destinations = positions.enumerated().sorted { $0.element < $1.element }
        var result = Array(repeating: targetLength, count: offsets.count)
        index = 0
        compactOffset = 0
        previousContentEnd = 0
        for (offset, unit) in replacement.utf16.enumerated() where !isFormattingWhitespace(unit) {
            while index < destinations.count && destinations[index].element <= compactOffset {
                let destination = destinations[index].offset
                result[destination] = whitespaceDistances[destination].map { min(offset, previousContentEnd + $0) } ?? offset
                index += 1
            }
            compactOffset += 1
            previousContentEnd = offset + 1
        }
        for index in offsets.indices {
            if offsets[index] <= 0 { result[index] = 0 }
            else if offsets[index] >= sourceLength { result[index] = targetLength }
        }
        return result
    }

    private static func compact(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t\\r\\n]+", with: "", options: .regularExpression)
    }

    private static func isFormattingWhitespace(_ unit: UInt16) -> Bool {
        unit == 32 || unit == 9 || unit == 13 || unit == 10
    }

    private static func match(_ offset: Int, in source: NSString, replacement: NSString) -> Int {
        let expected = min(replacement.length, Int(Double(offset) / Double(max(1, source.length)) * Double(replacement.length)))
        // JSON 字段可能重排，XML 可能增添声明；先匹配上下文，再逐步缩小到相邻内容。
        for radius in [32, 16, 8] {
            for (before, after) in [(radius, radius), (0, radius), (radius, 0)] {
                let start = max(0, offset - before), end = min(source.length, offset + after)
                guard end > start else { continue }
                let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
                let needle = source.substring(with: range)
                var search = NSRange(location: 0, length: replacement.length)
                var best: Int?
                while search.length > 0 {
                    let found = replacement.range(of: needle, options: .literal, range: search)
                    guard found.location != NSNotFound else { break }
                    let candidate = found.location + offset - range.location
                    if best == nil || abs(candidate - expected) < abs(best! - expected) { best = candidate }
                    search = NSRange(location: NSMaxRange(found), length: replacement.length - NSMaxRange(found))
                }
                if let best { return min(replacement.length, max(0, best)) }
            }
        }
        return expected
    }
}
