#if !STANDALONE_CHECKS
import XCTest
@testable import EasyMarkdownCore
#endif
import Foundation

final class LineNumberTests: XCTestCase {
    private func assertMatchesNative(_ index: LineNumberIndex, _ text: NSString) {
        var starts = [0]
        var cursor = 0
        while cursor < text.length {
            var end = 0
            text.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: cursor, length: 0))
            guard end > cursor else { break }
            var contentEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
            if contentEnd < end { starts.append(end) }
            cursor = end
        }
        XCTAssertEqual(index.lineCount, starts.count)
        for offset in 0...text.length {
            let expected = starts.lastIndex(where: { $0 <= offset })!
            let actual = index.position(atUTF16Offset: offset, in: text)
            XCTAssertEqual(actual.number, expected + 1)
            XCTAssertEqual(actual.lineStart, starts[expected])
        }
    }

    func testEmptyTrailingAndUnicodeLinesMatchNativeText() {
        for source in ["", "abc", "\n", "\r\n", "一📝\r\n二\n\n尾\r", "a\u{85}b\u{2028}c\u{2029}"] {
            let text = source as NSString
            assertMatchesNative(LineNumberIndex(text), text)
        }
    }

    func testEditsAcrossCRLFAndCheckpointBoundaries() {
        let original = String(repeating: "中📝x\r\n", count: 2_000) + "尾\n"
        var text = original as NSString
        var index = LineNumberIndex(text)
        var undo: [(NSRange, String)] = []
        let replacements = ["", "\r", "\n", "\r\n", "📝\n中文", "\u{2028}"]
        var random: UInt64 = 73
        for step in 0..<180 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let offset = Int(random % UInt64(text.length))
            // Exercise CRLF boundaries directly, but preserve surrogate pairs.
            var range = text.rangeOfComposedCharacterSequence(at: offset)
            if text.character(at: offset) == 0x0D || text.character(at: offset) == 0x0A {
                range = NSRange(location: offset, length: 1)
            }
            let replacement = replacements[step % replacements.count]
            undo.append((NSRange(location: range.location, length: replacement.utf16.count), text.substring(with: range)))
            text = text.replacingCharacters(in: range, with: replacement) as NSString
            index.applyEdit(in: NSRange(location: range.location, length: replacement.utf16.count),
                lengthDelta: replacement.utf16.count - range.length, text: text)
            let fresh = LineNumberIndex(text)
            XCTAssertEqual(index.lineCount, fresh.lineCount)
            for point in [0, range.location, min(text.length, NSMaxRange(range) + 2), text.length / 2, text.length] {
                XCTAssertEqual(index.position(atUTF16Offset: point, in: text), fresh.position(atUTF16Offset: point, in: text))
            }
        }
        for (range, replacement) in undo.reversed() {
            text = text.replacingCharacters(in: range, with: replacement) as NSString
            index.applyEdit(in: NSRange(location: range.location, length: replacement.utf16.count),
                lengthDelta: replacement.utf16.count - range.length, text: text)
            XCTAssertEqual(index.lineCount, LineNumberIndex(text).lineCount)
        }
        XCTAssertEqual(text as String, original)
        let fresh = LineNumberIndex(text)
        for point in [0, 4_095, 4_096, 4_097, text.length - 1, text.length] {
            XCTAssertEqual(index.position(atUTF16Offset: point, in: text), fresh.position(atUTF16Offset: point, in: text))
        }
        for (range, replacement) in [
            (NSRange(location: 4_090, length: 5_000), "跨越多个索引块\r\n尾部"),
            (NSRange(location: 0, length: 0), String(repeating: "新行\n", count: 2_000)),
            (NSRange(location: 1, length: 8_000), ""),
        ] {
            text = text.replacingCharacters(in: range, with: replacement) as NSString
            index.applyEdit(in: NSRange(location: range.location, length: replacement.utf16.count),
                lengthDelta: replacement.utf16.count - range.length, text: text)
            let rebuilt = LineNumberIndex(text)
            XCTAssertEqual(index.lineCount, rebuilt.lineCount)
            for point in stride(from: 0, through: text.length, by: 97) {
                XCTAssertEqual(index.position(atUTF16Offset: point, in: text), rebuilt.position(atUTF16Offset: point, in: text))
            }
        }
        let removedLength = text.length
        text = "" as NSString
        index.applyEdit(in: NSRange(location: 0, length: 0), lengthDelta: -removedLength, text: text)
        assertMatchesNative(index, text)
        text = "中文\r\n\n📝\n" as NSString
        index.applyEdit(in: NSRange(location: 0, length: text.length), lengthDelta: text.length, text: text)
        assertMatchesNative(index, text)
    }

    func testLargeEditsStaySparseAndLocal() {
        var text = String(repeating: "行\n", count: 100_000) as NSString
        var index = LineNumberIndex(text)
        for step in 0..<100 {
            let offset = 10 + step
            text = text.replacingCharacters(in: NSRange(location: offset, length: 0), with: "字") as NSString
            index.applyEdit(in: NSRange(location: offset, length: 1), lengthDelta: 1, text: text)
            XCTAssertTrue(index.lastScannedUTF16Count < 16_384)
            XCTAssertTrue(index.checkpointCount < text.length / 2_048 + 3)
        }
        XCTAssertEqual(index.lineCount, 100_001)
        let long = String(repeating: "x", count: 200_000) as NSString
        index.rebuild(long)
        XCTAssertEqual(index.position(atUTF16Offset: long.length - 1, in: long).lineStart, 0)
        XCTAssertEqual(index.lineCount, 1)
    }
}
