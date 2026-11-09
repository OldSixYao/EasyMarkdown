import Foundation

public struct TextStatistics: Equatable, Sendable {
    public let lineCount: Int
    public let characterCount: Int

    public init(lineCount: Int, characterCount: Int) {
        self.lineCount = lineCount
        self.characterCount = characterCount
    }
}

public struct DocumentStatistics: Equatable, Sendable {
    public var total: TextStatistics
    public var selection: TextStatistics?

    public init(total: TextStatistics = .init(lineCount: 1, characterCount: 0), selection: TextStatistics? = nil) {
        self.total = total
        self.selection = selection
    }
}

/// Sparse prefix counts retain no text. Coordinates follow NSTextStorage's UTF-16 edits.
public struct DocumentStatisticsIndex: Sendable {
    private struct Checkpoint: Sendable {
        var offset: Int
        var count: Int
    }

    private static let stride = 4_096
    private var characters: [Checkpoint] = []
    private var lines: LineNumberIndex
    public private(set) var lastScannedUTF16Count = 0
    public private(set) var lastSelectionScannedUTF16Count = 0
    public private(set) var rebuildCount = 0

    public init(_ text: NSString) {
        lines = LineNumberIndex(text)
        rebuildCharacters(text)
    }

    public var total: TextStatistics {
        TextStatistics(lineCount: lines.lineCount, characterCount: characters.last?.count ?? 0)
    }

    public mutating func rebuild(_ text: NSString) {
        lines.rebuild(text)
        rebuildCharacters(text)
    }

    private mutating func rebuildCharacters(_ text: NSString) {
        characters = [Checkpoint(offset: 0, count: 0)]
        scan(text, through: text.length)
        lastScannedUTF16Count = text.length
        rebuildCount += 1
    }

    /// editedRange is in the new text; lengthDelta is new length minus old length.
    public mutating func applyEdit(in editedRange: NSRange, lengthDelta: Int, text: NSString) {
        guard editedRange.location >= 0, editedRange.location <= text.length,
              editedRange.length >= 0, editedRange.length <= text.length - editedRange.location,
              text.length - lines.utf16Length == lengthDelta else { rebuild(text); return }
        let oldEnd = NSMaxRange(editedRange) - lengthDelta
        guard oldEnd >= editedRange.location, oldEnd <= lines.utf16Length else { rebuild(text); return }

        // Begin before the edit so a combining mark/ZWJ can join the previous character.
        let left = checkpointIndex(at: max(0, editedRange.location - 1))
        var suffix = lowerBound(oldEnd + Self.stride)
        // Regional indicators may change pairing far beyond the edit. Reuse the
        // suffix only at an actual composed-character boundary in the new text.
        while suffix < characters.count {
            let offset = characters[suffix].offset + lengthDelta
            if offset == text.length || text.rangeOfComposedCharacterSequence(at: offset).location == offset { break }
            suffix += 1
        }
        let oldSuffix = suffix < characters.count ? characters[suffix] : nil
        let end = oldSuffix.map { $0.offset + lengthDelta } ?? text.length
        let tail = suffix < characters.count ? Array(characters[(suffix + 1)...]) : []
        let start = characters[left].offset
        characters.removeSubrange((left + 1)...)
        scan(text, through: end)
        if let oldSuffix, let anchor = characters.last {
            let countDelta = anchor.count - oldSuffix.count
            characters.append(contentsOf: tail.map {
                Checkpoint(offset: $0.offset + lengthDelta, count: $0.count + countDelta)
            })
        }
        lines.applyEdit(in: editedRange, lengthDelta: lengthDelta, text: text)
        lastScannedUTF16Count = end - start
    }

    public mutating func statistics(in text: NSString, selectedRanges: [NSRange]) -> DocumentStatistics {
        if text.length != lines.utf16Length { rebuild(text) }
        lastSelectionScannedUTF16Count = 0
        let ranges = Self.merged(selectedRanges.compactMap { range in
            guard range.location >= 0, range.location < text.length, range.length > 0 else { return nil }
            return NSRange(location: range.location, length: min(range.length, text.length - range.location))
        })
        guard !ranges.isEmpty else { return DocumentStatistics(total: total) }

        let lineRanges = Self.merged(ranges.map { range in
            let start = lines.position(atUTF16Offset: range.location, in: text).number
            let end = lines.position(atUTF16Offset: NSMaxRange(range) - 1, in: text).number
            return NSRange(location: start, length: end - start + 1)
        })
        // Native selections normally use whole characters. Expand partial ranges
        // too, and merge again so overlapping selections never count one twice.
        let characterRanges = Self.merged(ranges.map { text.rangeOfComposedCharacterSequences(for: $0) })
        let count = characterRanges.reduce(0) { result, range in
            result + prefixCount(at: NSMaxRange(range), in: text) - prefixCount(at: range.location, in: text)
        }
        return DocumentStatistics(total: total, selection: TextStatistics(
            lineCount: lineRanges.reduce(0) { $0 + $1.length }, characterCount: count))
    }

    private mutating func prefixCount(at offset: Int, in text: NSString) -> Int {
        let point = characters[checkpointIndex(at: offset)]
        lastSelectionScannedUTF16Count += offset - point.offset
        return point.count + Self.count(in: text, from: point.offset, to: offset)
    }

    private mutating func scan(_ text: NSString, through end: Int) {
        guard var current = characters.last else { return }
        while current.offset < end {
            let proposed = min(end, current.offset + Self.stride)
            let boundary = NSMaxRange(text.rangeOfComposedCharacterSequence(at: proposed - 1))
            let next = min(end, boundary)
            current.count += Self.count(in: text, from: current.offset, to: next)
            current.offset = next
            // Avoid accumulating tiny checkpoints after repeated insertions.
            if characters.count > 1, next - characters[characters.count - 2].offset < Self.stride {
                characters[characters.count - 1] = current
            } else {
                characters.append(current)
            }
        }
    }

    private static func count(in text: NSString, from start: Int, to end: Int) -> Int {
        guard end > start else { return 0 }
        return text.substring(with: NSRange(location: start, length: end - start))
            .reduce(into: 0) { if !$1.isWhitespace { $0 += 1 } }
    }

    private func lowerBound(_ offset: Int) -> Int {
        var low = 0, high = characters.count
        while low < high {
            let middle = low + (high - low) / 2
            if characters[middle].offset < offset { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func checkpointIndex(at offset: Int) -> Int {
        let slot = lowerBound(offset)
        if slot < characters.count, characters[slot].offset == offset { return slot }
        return max(0, slot - 1)
    }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let previous = result.last, range.location <= NSMaxRange(previous) {
                result[result.count - 1] = NSUnionRange(previous, range)
            } else { result.append(range) }
        }
        return result
    }
}
