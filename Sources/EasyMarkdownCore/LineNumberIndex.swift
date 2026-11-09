import Foundation

/// Only sparse UTF-16 checkpoints are retained, never a second copy of the text.
public struct LineNumberIndex: Sendable {
    public struct Position: Equatable, Sendable {
        public let number: Int
        public let lineStart: Int
    }

    private struct Checkpoint: Sendable {
        var offset: Int
        var number: Int
        var lineStart: Int
    }

    private static let stride = 4_096
    private var checkpoints: [Checkpoint] = []
    public private(set) var utf16Length = 0
    public var lineCount: Int { checkpoints.last?.number ?? 1 }
    var checkpointCount: Int { checkpoints.count }
    private(set) var lastScannedUTF16Count = 0

    public init(_ text: NSString) { rebuild(text) }

    public mutating func rebuild(_ text: NSString) {
        utf16Length = text.length
        checkpoints = [Checkpoint(offset: 0, number: 1, lineStart: 0)]
        scan(text, through: text.length)
        lastScannedUTF16Count = text.length
    }

    /// NSTextStorage's editedRange uses the new text; delta is new minus old length.
    public mutating func applyEdit(in editedRange: NSRange, lengthDelta: Int, text: NSString) {
        let oldEnd = NSMaxRange(editedRange) - lengthDelta
        guard editedRange.location >= 0, editedRange.length >= 0,
              NSMaxRange(editedRange) <= text.length,
              oldEnd >= editedRange.location, oldEnd <= utf16Length,
              text.length - utf16Length == lengthDelta else {
            rebuild(text)
            return
        }

        // Include both sides of CRLF, and rescan at least one checkpoint block.
        let left = checkpointIndex(at: max(0, editedRange.location - 1))
        let suffix = checkpoints.partitionIndex { $0.offset >= oldEnd + Self.stride }
        let oldSuffix = suffix < checkpoints.count ? checkpoints[suffix] : nil
        let end = oldSuffix.map { $0.offset + lengthDelta } ?? text.length
        let tail = suffix < checkpoints.count ? Array(checkpoints[(suffix + 1)...]) : []
        let start = checkpoints[left].offset
        checkpoints.removeSubrange((left + 1)...)
        scan(text, through: end)
        if let oldSuffix, let anchor = checkpoints.last {
            let lineDelta = anchor.number - oldSuffix.number
            checkpoints.append(contentsOf: tail.map {
                Checkpoint(offset: $0.offset + lengthDelta, number: $0.number + lineDelta,
                    lineStart: $0.lineStart <= oldSuffix.offset ? anchor.lineStart : $0.lineStart + lengthDelta)
            })
        }
        utf16Length = text.length
        lastScannedUTF16Count = end - start
    }

    public func position(atUTF16Offset offset: Int, in text: NSString) -> Position {
        guard text.length == utf16Length else {
            return LineNumberIndex(text).position(atUTF16Offset: offset, in: text)
        }
        let end = min(text.length, max(0, offset))
        let checkpoint = checkpoints[checkpointIndex(at: end)]
        var number = checkpoint.number
        var lineStart = checkpoint.lineStart
        if checkpoint.offset < end {
            for cursor in (checkpoint.offset + 1)...end where Self.startsLine(at: cursor, in: text) {
                number += 1
                lineStart = cursor
            }
        }
        return Position(number: number, lineStart: lineStart)
    }

    private func checkpointIndex(at offset: Int) -> Int {
        max(0, checkpoints.partitionIndex { $0.offset > offset } - 1)
    }

    private mutating func scan(_ text: NSString, through end: Int) {
        guard var current = checkpoints.last, current.offset < end else { return }
        for cursor in (current.offset + 1)...end {
            if Self.startsLine(at: cursor, in: text) {
                current.number += 1
                current.lineStart = cursor
            }
            // Keep the splice checkpoint sparse too, including after repeated edits.
            if cursor - checkpoints.last!.offset >= Self.stride,
               end - cursor >= Self.stride / 2 {
                current.offset = cursor
                checkpoints.append(current)
            }
        }
        current.offset = end
        checkpoints.append(current)
    }

    private static func startsLine(at offset: Int, in text: NSString) -> Bool {
        switch text.character(at: offset - 1) {
        case 0x0A, 0x85, 0x2028, 0x2029: return true
        case 0x0D: return offset == text.length || text.character(at: offset) != 0x0A
        default: return false
        }
    }
}

private extension Array {
    func partitionIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
