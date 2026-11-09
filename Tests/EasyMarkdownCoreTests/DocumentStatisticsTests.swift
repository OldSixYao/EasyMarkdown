#if !STANDALONE_CHECKS
import XCTest
@testable import EasyMarkdownCore
#endif
import Foundation

final class DocumentStatisticsTests: XCTestCase {
    private func nonWhitespaceCount(_ text: String) -> Int {
        text.reduce(into: 0) { if !$1.isWhitespace { $0 += 1 } }
    }

    func testWholeDocumentWhitespaceUnicodeAndLineEndings() {
        for source in ["", " \t\n\r\n\u{85}\u{2028}\u{2029}\u{a0}\u{3000}",
                       "甲\n乙\n", "甲\r\n乙\r尾", "🧑🏽‍💻👨‍👩‍👧‍👦🇨🇳e\u{301}中文 #!", "क्‍षक्ष", "🇨 🇳"] {
            let text = source as NSString
            var index = DocumentStatisticsIndex(text)
            let result = index.statistics(in: text, selectedRanges: [])
            XCTAssertEqual(result.total.lineCount, LineNumberIndex(text).lineCount)
            XCTAssertEqual(result.total.characterCount, nonWhitespaceCount(source))
            XCTAssertEqual(result.selection, nil)
        }
        XCTAssertEqual(DocumentStatisticsIndex("甲\n乙\n").total, TextStatistics(lineCount: 3, characterCount: 2))
        XCTAssertEqual(DocumentStatisticsIndex("🇨 🇳").total.characterCount, 2)
        XCTAssertEqual(DocumentStatisticsIndex(String(repeating: "字", count: 20_000) as NSString).total.lineCount, 1)
    }

    func testSelectionsExcludeUnselectedNextLineAndCountWhitespace() {
        let text = "甲\r\n乙\n \t\n🧑🏽‍💻e\u{301}\n" as NSString
        var index = DocumentStatisticsIndex(text)
        func selected(_ range: NSRange) -> TextStatistics? {
            index.statistics(in: text, selectedRanges: [range]).selection
        }
        XCTAssertEqual(selected(NSRange(location: 0, length: 3)), .init(lineCount: 1, characterCount: 1))
        XCTAssertEqual(selected(NSRange(location: 0, length: 4)), .init(lineCount: 2, characterCount: 2))
        XCTAssertEqual(selected(NSRange(location: 5, length: 3)), .init(lineCount: 1, characterCount: 0))
        XCTAssertEqual(selected(NSRange(location: 8, length: text.length - 8)), .init(lineCount: 1, characterCount: 2))
        XCTAssertEqual(selected(NSRange(location: 0, length: text.length)), .init(lineCount: 4, characterCount: 4))
        XCTAssertEqual(selected(NSRange(location: 4, length: 0)), nil)
        XCTAssertEqual(selected(NSRange(location: 9, length: 1)), .init(lineCount: 1, characterCount: 1))
    }

    func testMultipleSelectionsMergeCharactersAndLogicalLines() {
        let text = "甲乙丙\n丁戊\n己庚\n" as NSString
        var index = DocumentStatisticsIndex(text)
        let result = index.statistics(in: text, selectedRanges: [
            NSRange(location: 2, length: 4), NSRange(location: 0, length: 3),
            NSRange(location: 5, length: 1), NSRange(location: 8, length: 1),
            NSRange(location: NSNotFound, length: 10), NSRange(location: -1, length: 1)
        ])
        XCTAssertEqual(result.selection, .init(lineCount: 3, characterCount: 6))
        let sameLine = index.statistics(in: text, selectedRanges: [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
        XCTAssertEqual(sameLine.selection, .init(lineCount: 1, characterCount: 2))
        XCTAssertEqual(index.statistics(in: text, selectedRanges: [.init(location: 0, length: Int.max)]).selection?.characterCount, 7)
    }

    func testIncrementalEditsAndUndoAgreeWithFullRecount() {
        let original = String(repeating: "甲🧑🏽‍💻e\u{301} 🇨🇳\r\n", count: 1_000)
        var text = original as NSString
        var index = DocumentStatisticsIndex(text)
        var undo: [(NSRange, String)] = []
        var random: UInt64 = 91
        let replacements = ["", "\u{301}", "\u{200d}👩", "🇨", "\r", "\n", "\t ", "中文👨‍👩‍👧‍👦"]
        for step in 0..<160 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let point = Int(random % UInt64(text.length))
            var range = text.rangeOfComposedCharacterSequence(at: point)
            if step % 3 == 0 { range.length = 0 }
            if text.character(at: point) == 0x0D || text.character(at: point) == 0x0A {
                range = NSRange(location: point, length: 1)
            }
            let replacement = replacements[step % replacements.count]
            undo.append((NSRange(location: range.location, length: replacement.utf16.count), text.substring(with: range)))
            text = text.replacingCharacters(in: range, with: replacement) as NSString
            index.applyEdit(in: NSRange(location: range.location, length: replacement.utf16.count),
                            lengthDelta: replacement.utf16.count - range.length, text: text)
            XCTAssertEqual(index.total.characterCount, nonWhitespaceCount(text as String))
            XCTAssertEqual(index.total.lineCount, LineNumberIndex(text).lineCount)
        }
        for (range, replacement) in undo.reversed() {
            text = text.replacingCharacters(in: range, with: replacement) as NSString
            index.applyEdit(in: NSRange(location: range.location, length: replacement.utf16.count),
                            lengthDelta: replacement.utf16.count - range.length, text: text)
            XCTAssertEqual(index.total.characterCount, nonWhitespaceCount(text as String))
            XCTAssertEqual(index.total.lineCount, LineNumberIndex(text).lineCount)
        }
        XCTAssertEqual(text as String, original)
    }

    func testUnicodeBoundaryPropagationAndFullReplacement() {
        for source in [String(repeating: "🇨", count: 10_001),
                       "e" + String(repeating: "\u{301}", count: 10_000) + "尾",
                       String(repeating: "👩\u{200d}", count: 4_000) + "👩尾"] {
            var text = source as NSString
            var index = DocumentStatisticsIndex(text)
            for (range, replacement) in [(NSRange(location: 0, length: 0), "🇳"),
                                         (NSRange(location: 4_096, length: 0), "\u{200d}字"),
                                         (NSRange(location: 0, length: 1), "e\u{301}")] {
                text = text.replacingCharacters(in: range, with: replacement) as NSString
                index.applyEdit(in: NSRange(location: range.location, length: replacement.utf16.count),
                                lengthDelta: replacement.utf16.count - range.length, text: text)
                XCTAssertEqual(index.total.characterCount, nonWhitespaceCount(text as String))
            }
            let length = text.length
            text = "全量\r\n替换 🧑🏽‍💻" as NSString
            index.applyEdit(in: NSRange(location: 0, length: text.length), lengthDelta: text.length - length, text: text)
            XCTAssertEqual(index.total, DocumentStatisticsIndex(text).total)
            index.applyEdit(in: NSRange(location: NSNotFound, length: 0), lengthDelta: 0, text: text)
            XCTAssertEqual(index.total, DocumentStatisticsIndex(text).total)
        }
    }

    func testLargeDocumentEditsAndSelectionsStayLocal() {
        var text = String(repeating: "甲乙 📝\n", count: 100_000) as NSString
        var index = DocumentStatisticsIndex(text)
        for step in 0..<80 {
            let range = NSRange(location: 20 + step, length: 0)
            text = text.replacingCharacters(in: range, with: "字") as NSString
            index.applyEdit(in: NSRange(location: range.location, length: 1), lengthDelta: 1, text: text)
            XCTAssertTrue(index.lastScannedUTF16Count < 20_000)
            let result = index.statistics(in: text, selectedRanges: [NSRange(location: text.length - 20, length: 15)])
            XCTAssertEqual(result.total.characterCount, 300_000 + step + 1)
            XCTAssertTrue(index.lastSelectionScannedUTF16Count < 12_288)
        }
        XCTAssertEqual(index.rebuildCount, 1)
        let all = index.statistics(in: text, selectedRanges: [NSRange(location: 0, length: text.length)])
        XCTAssertEqual(all.selection?.characterCount, index.total.characterCount)
        XCTAssertEqual(index.lastSelectionScannedUTF16Count, 0)
    }
}
