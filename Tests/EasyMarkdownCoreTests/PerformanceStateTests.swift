#if !STANDALONE_CHECKS
import XCTest
@testable import EasyMarkdownCore
#endif
import Foundation

final class PerformanceStateTests: XCTestCase {
    private func apply(_ replacement: String, range: NSRange, to state: inout DocumentState) {
        let original = state.text as NSString
        let removed = original.substring(with: range)
        let changed = original.replacingCharacters(in: range, with: replacement)
        state.edit(changed, change: TextChange(range: range, replacement: replacement, removed: removed))
        XCTAssertEqual(state.byteCount, state.text.utf8.count)
        XCTAssertEqual(state.isDirty, state.text != state.baseline.text)
    }

    func testDistantUnicodeEditsAndUndoRestoreCleanState() throws {
        let source = String(repeating: "中文📝 paragraph\r\n", count: 2_000)
        var state = DocumentState(snapshot: try FileSnapshot(data: Data(source.utf8)))
        let originalRevision = state.revision
        var undo: [(NSRange, String)] = []
        for (needle, replacement) in [("paragraph", "new text"), ("📝", "👨‍👩‍👧‍👦"), ("中文", "测试")].reversed() {
            let text = state.text as NSString
            let range = text.range(of: needle, options: needle == "paragraph" ? .backwards : [])
            undo.append((NSRange(location: range.location, length: replacement.utf16.count), text.substring(with: range)))
            apply(replacement, range: range, to: &state)
            XCTAssertTrue(state.isDirty)
        }
        for (range, replacement) in undo.reversed() { apply(replacement, range: range, to: &state) }
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.text, source)
        XCTAssertTrue(state.revision > originalRevision)
    }

    func testCanonicalUnicodeEqualityRetainsEditCoordinates() throws {
        var state = DocumentState(snapshot: try FileSnapshot(data: Data("é tail".utf8)))
        apply("e\u{301}", range: NSRange(location: 0, length: 1), to: &state)
        XCTAssertFalse(state.isDirty)
        apply("changed", range: NSRange(location: 3, length: 4), to: &state)
        XCTAssertTrue(state.isDirty)
        apply("tail", range: NSRange(location: 3, length: 7), to: &state)
        XCTAssertFalse(state.isDirty)
        apply("é", range: NSRange(location: 0, length: 2), to: &state)
        XCTAssertFalse(state.isDirty)
    }

    func testRandomEditsAgreeWithFullComparison() throws {
        let source = String(repeating: "中文📝 abc é\r\n", count: 500)
        var state = DocumentState(snapshot: try FileSnapshot(data: Data(source.utf8)))
        var random: UInt64 = 47
        let choices = ["", "hello", "中文", "👨‍👩‍👧‍👦", "e\u{301}", "\r\n"]
        var undo: [(NSRange, String)] = []
        for step in 0..<300 {
            random = random &* 6364136223846793005 &+ 1
            let text = state.text as NSString
            let index = Int(random % UInt64(max(1, text.length)))
            let range = text.length > 0 ? text.rangeOfComposedCharacterSequence(at: index) : NSRange(location: 0, length: 0)
            let replacement = choices[step % choices.count]
            undo.append((NSRange(location: range.location, length: replacement.utf16.count), text.substring(with: range)))
            apply(replacement, range: range, to: &state)
        }
        for (range, replacement) in undo.reversed() { apply(replacement, range: range, to: &state) }
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.text, source)
    }

    func testSaveDoesNotInvalidateUnchangedEditorRevision() throws {
        var state = DocumentState(snapshot: try FileSnapshot(data: Data("original".utf8)))
        apply("changed", range: NSRange(location: 0, length: 8), to: &state)
        let revision = state.revision
        state.didSave(try FileSnapshot(data: Data(state.text.utf8)), savedText: state.text)
        XCTAssertEqual(state.revision, revision)
        XCTAssertFalse(state.isDirty)
    }

    func testPreviewBudgetHandlesEmojiAndLongCombiningSequences() {
        for source in [String(repeating: "👨‍👩‍👧‍👦", count: 100_000),
                       "a" + String(repeating: "\u{301}", count: 1_000_000),
                       String(repeating: "中", count: 600_000)] {
            let preview = PreviewText(source)
            XCTAssertTrue(preview.isTruncated)
            XCTAssertTrue(preview.text.utf16.count <= PreviewText.maximumUTF16Count)
            XCTAssertTrue(preview.text.utf8.count <= PreviewText.maximumBytes)
            XCTAssertFalse(preview.text.unicodeScalars.contains("\u{FFFD}"))
        }
        let small = PreviewText("中文 👨‍👩‍👧‍👦")
        XCTAssertFalse(small.isTruncated)
        XCTAssertEqual(small.text, "中文 👨‍👩‍👧‍👦")
    }
}
