import Foundation
#if !STANDALONE_CHECKS
import XCTest
@testable import EasyMarkdownCore
#endif

final class TextPositionMappingTests: XCTestCase {
    func testFormattingKeepsUnicodeSelectionAndDocumentEdges() throws {
        let source = "[\n{\"value\":\"第一项\"},\n{\"value\":\"中文📝e\u{301}\"}\n]\n"
        let target = try DocumentFormatter.format(source, kind: .json)
        let range = (source as NSString).range(of: "中文📝e\u{301}")
        let result = TextPositionMapping.map([0, range.location, NSMaxRange(range), source.utf16.count], from: source, to: target)
        XCTAssertEqual(result[0], 0)
        XCTAssertEqual(result[3], target.utf16.count)
        XCTAssertEqual((target as NSString).substring(with: NSRange(location: result[1], length: result[2] - result[1])), "中文📝e\u{301}")
    }

    func testNewlineConversionKeepsEveryContentOffset() {
        let source = "甲\n乙\n📝尾\n"
        let target = "甲\r\n乙\r\n📝尾\r\n"
        XCTAssertEqual(TextPositionMapping.map([0, 2, 4, 6, 8], from: source, to: target), [0, 3, 6, 8, 11])
        XCTAssertEqual(TextPositionMapping.map([6, 3, 0], from: target, to: source), [4, 2, 0])
        XCTAssertEqual(TextPositionMapping.map([1, 2], from: "甲  乙", to: "甲\n  乙"), [1, 2])
    }

    func testReorderedFieldsAndInsertedDeclarationKeepContentAnchors() {
        let source = "{\"alpha\":\"甲一二三四五六七八九\",\"beta\":\"乙一二三四五六七八九\"}"
        let target = "{\n  \"beta\": \"乙一二三四五六七八九\",\n  \"alpha\": \"甲一二三四五六七八九\"\n}"
        let range = (source as NSString).range(of: "甲一二三四五六七八九")
        let mapped = TextPositionMapping.map([range.location, NSMaxRange(range)], from: source, to: target)
        XCTAssertEqual((target as NSString).substring(with: NSRange(location: mapped[0], length: mapped[1] - mapped[0])), "甲一二三四五六七八九")
        let xml = "<root><first>甲</first><second>正在阅读的位置</second></root>"
        let formatted = "<?xml version=\"1.0\"?>\n<root>\n  <first>甲</first>\n  <second>正在阅读的位置</second>\n</root>\n"
        let offset = (xml as NSString).range(of: "正在阅读的位置").location
        XCTAssertEqual(TextPositionMapping.map([offset], from: xml, to: formatted), [(formatted as NSString).range(of: "正在阅读的位置").location])
    }

    func testRemovedContentAndEmptyReplacementStayInBounds() {
        let source = "原来的内容\n已经删除\n"
        let target = "新内容\n"
        let result = TextPositionMapping.map([0, 5, source.utf16.count], from: source, to: target)
        XCTAssertTrue(result.allSatisfy { $0 >= 0 && $0 <= target.utf16.count })
        XCTAssertEqual(TextPositionMapping.map([0, 5, source.utf16.count], from: source, to: ""), [0, 0, 0])
        XCTAssertEqual(TextPositionMapping.map([], from: source, to: target), [])
    }
}
