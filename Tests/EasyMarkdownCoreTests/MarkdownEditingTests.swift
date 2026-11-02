import Foundation
#if !STANDALONE_CHECKS
import XCTest
@testable import EasyMarkdownCore
#endif

final class MarkdownEditingTests: XCTestCase {
    private func apply(_ command: MarkdownCommand, _ text: String, _ selection: NSRange) -> (String, NSRange) {
        let edit = MarkdownEditing.edit(command, text: text, selection: selection)
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertTrue(NSMaxRange(edit.selection) <= (result as NSString).length)
        return (result, edit.selection)
    }

    func testInlineFormattingPreservesUnicodeSelectionAndToggles() {
        let input = "前面 📝 中文内容 后面"
        let range = (input as NSString).range(of: "📝 中文内容")
        let (formatted, selection) = apply(.bold, input, range)
        XCTAssertEqual(formatted, "前面 **📝 中文内容** 后面")
        XCTAssertEqual((formatted as NSString).substring(with: selection), "📝 中文内容")
        let (restored, restoredSelection) = apply(.bold, formatted, selection)
        XCTAssertEqual(restored, input)
        XCTAssertEqual(restoredSelection, range)
        let (combined, combinedSelection) = apply(.italic, formatted, selection)
        XCTAssertEqual(combined, "前面 ***📝 中文内容*** 后面")
        let (boldAgain, _) = apply(.italic, combined, combinedSelection)
        XCTAssertEqual(boldAgain, formatted)
    }

    func testEmptySelectionInsertsEditablePlaceholder() {
        let (formatted, selection) = apply(.heading(2), "", NSRange(location: 0, length: 0))
        XCTAssertEqual(formatted, "## 标题")
        XCTAssertEqual((formatted as NSString).substring(with: selection), "标题")
        let (code, codeSelection) = apply(.inlineCode, "文字", NSRange(location: 2, length: 0))
        XCTAssertEqual(code, "文字`代码`")
        XCTAssertEqual((code as NSString).substring(with: codeSelection), "代码")
    }

    func testMultilinePrefixesExcludeNextUnselectedLine() {
        let input = "第一行\n第二行\n不选中的行\n"
        let range = NSRange(location: 0, length: ("第一行\n第二行\n" as NSString).length)
        let (formatted, selection) = apply(.quote, input, range)
        XCTAssertEqual(formatted, "> 第一行\n> 第二行\n不选中的行\n")
        let (restored, _) = apply(.quote, formatted, selection)
        XCTAssertEqual(restored, input)
    }

    func testHeadingAndListConversionDoNotStackPrefixes() {
        let (heading, _) = apply(.heading(3), "# 标题\n正文", NSRange(location: 3, length: 0))
        XCTAssertEqual(heading, "### 标题\n正文")
        let (paragraph, _) = apply(.paragraph, heading, NSRange(location: 4, length: 0))
        XCTAssertEqual(paragraph, "标题\n正文")
        let input = "- [x] 第一项\n- 第二项\n\n- 第三项"
        let (numbered, _) = apply(.orderedList, input, NSRange(location: 0, length: (input as NSString).length))
        XCTAssertEqual(numbered, "1. 第一项\n2. 第二项\n\n3. 第三项")
    }

    func testCRLFAndIndentationSurviveLineCommands() {
        let input = "  第一项\r\n  第二项\r\n第三项"
        let selection = NSRange(location: 0, length: ("  第一项\r\n  第二项\r\n" as NSString).length)
        let (formatted, _) = apply(.taskList, input, selection)
        XCTAssertEqual(formatted, "  - [ ] 第一项\r\n  - [ ] 第二项\r\n第三项")
    }

    func testCodeContainingBackticksUsesSafeDelimiters() {
        let inline = "a`b"
        let (code, _) = apply(.inlineCode, inline, NSRange(location: 0, length: 3))
        XCTAssertEqual(code, "``a`b``")
        let nested = "```swift\nprint(1)\n```"
        let (block, selection) = apply(.codeBlock, nested, NSRange(location: 0, length: (nested as NSString).length))
        XCTAssertEqual(block, "````\n```swift\nprint(1)\n```\n````\n")
        XCTAssertEqual((block as NSString).substring(with: selection), nested)
    }

    func testLinkTableAndDividerKeepUserContent() {
        let (link, selection) = apply(.link, "链接[一]", NSRange(location: 0, length: 5))
        XCTAssertEqual(link, "[链接\\[一\\]](https://example.com)")
        XCTAssertEqual((link as NSString).substring(with: selection), "https://example.com")
        let (table, _) = apply(.table, "A|B", NSRange(location: 0, length: 3))
        XCTAssertTrue(table.contains("| A\\|B | 内容 |"))
        let (divider, _) = apply(.horizontalRule, "保留这段\n下一段", NSRange(location: 0, length: 4))
        XCTAssertEqual(divider, "保留这段\n\n---\n\n下一段")
    }
}
