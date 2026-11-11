import Foundation
#if !STANDALONE_CHECKS
import XCTest
@testable import EasyMarkdownCore
#endif

final class DocumentStateTests: XCTestCase {
    private func snapshot(_ text: String) throws -> FileSnapshot { try FileSnapshot(data: Data(text.utf8)) }

    func testCleanDocumentWaitsForExternalConfirmation() throws {
        var state = DocumentState(snapshot: try snapshot("before"))
        state.receive(try snapshot("after"))
        XCTAssertEqual(state.text, "before")
        XCTAssertEqual(state.baseline.text, "before")
        XCTAssertEqual(state.external?.text, "after")
        XCTAssertFalse(state.isDirty)
        XCTAssertTrue(state.hasConflict)
        XCTAssertTrue(state.needsExternalConfirmation)
        XCTAssertEqual(state.revision, 0)
    }

    func testExternalChangesNeverOverwriteUnsavedBuffer() throws {
        var state = DocumentState(snapshot: try snapshot("baseline"))
        state.text = "local edit"
        state.receive(try snapshot("external edit"))
        XCTAssertEqual(state.text, "local edit")
        XCTAssertEqual(state.baseline.text, "baseline")
        XCTAssertEqual(state.external?.text, "external edit")
        XCTAssertTrue(state.isDirty)
        state.receive(try snapshot("newer external edit"))
        XCTAssertEqual(state.external?.text, "newer external edit")
    }

    func testExternalRevertClearsStaleConflict() throws {
        var state = DocumentState(snapshot: try snapshot("baseline"))
        state.text = "local"
        state.receive(try snapshot("external"))
        state.receive(try snapshot("baseline"))
        XCTAssertFalse(state.hasConflict)
        XCTAssertEqual(state.text, "local")
        XCTAssertTrue(state.isDirty)
    }

    func testDecliningExternalVersionPreservesBufferAndDeduplicatesNotifications() throws {
        for dirty in [false, true] {
            var state = DocumentState(snapshot: try snapshot("baseline"))
            if dirty { state.edit("local edit") }
            let revision = state.revision
            state.receive(try snapshot("external"))
            state.keepCurrentContent()
            for _ in 0..<3 { state.receive(try snapshot("external")) }
            XCTAssertFalse(state.needsExternalConfirmation)
            XCTAssertEqual(state.external?.text, "external")
            XCTAssertEqual(state.text, dirty ? "local edit" : "baseline")
            XCTAssertEqual(state.baseline.text, "baseline")
            XCTAssertEqual(state.isDirty, dirty)
            XCTAssertEqual(state.revision, revision)
            state.receive(try snapshot("new external"))
            XCTAssertTrue(state.needsExternalConfirmation)
            XCTAssertEqual(state.external?.text, "new external")
        }
    }

    func testExternalBaselineReturnAndMissingFileClearPendingConfirmation() throws {
        var state = DocumentState(snapshot: try snapshot("baseline"))
        state.receive(try snapshot("baseline"))
        XCTAssertFalse(state.needsExternalConfirmation)
        state.receive(try snapshot("external"))
        state.keepCurrentContent()
        state.receive(try snapshot("baseline"))
        XCTAssertFalse(state.hasConflict)
        XCTAssertFalse(state.needsExternalConfirmation)
        state.receive(try snapshot("external"))
        XCTAssertTrue(state.needsExternalConfirmation)
        state.markMissing()
        XCTAssertFalse(state.needsExternalConfirmation)
        XCTAssertTrue(state.external == nil)
        XCTAssertTrue(state.isMissing)
        XCTAssertEqual(state.text, "baseline")
    }

    func testConfirmationAcceptsFreshlyReadSnapshotEvenIfDiskReverted() throws {
        var state = DocumentState(snapshot: try snapshot("baseline"))
        state.edit("local")
        state.receive(try snapshot("external"))
        state.acceptExternal(try snapshot("latest"))
        XCTAssertEqual(state.text, "latest")
        XCTAssertEqual(state.baseline.text, "latest")
        XCTAssertFalse(state.isDirty)
        XCTAssertFalse(state.needsExternalConfirmation)
        state.edit("another edit")
        state.receive(try snapshot("new external"))
        state.acceptExternal(try snapshot("latest"))
        XCTAssertEqual(state.text, "latest")
        XCTAssertFalse(state.isDirty)
        XCTAssertFalse(state.hasConflict)
    }

    func testSaveAsClearsDeclinedExternalVersion() throws {
        var state = DocumentState(snapshot: try snapshot("baseline"))
        state.edit("local")
        state.receive(try snapshot("external"))
        state.keepCurrentContent()
        state.didSave(try snapshot("local"), savedText: "local")
        XCTAssertEqual(state.text, "local")
        XCTAssertFalse(state.isDirty)
        XCTAssertFalse(state.hasConflict)
        XCTAssertFalse(state.needsExternalConfirmation)
    }

    func testIdenticalExternalEditStillNeedsConfirmation() throws {
        var state = DocumentState(snapshot: try snapshot("baseline"))
        state.text = "same edit"
        state.receive(try snapshot("same edit"))
        XCTAssertTrue(state.isDirty)
        XCTAssertTrue(state.hasConflict)
        XCTAssertEqual(state.baseline.text, "baseline")
        state.acceptExternal()
        XCTAssertFalse(state.isDirty)
        XCTAssertFalse(state.hasConflict)
    }

    func testAcceptExternalAndMissingFileRecovery() throws {
        var state = DocumentState(snapshot: try snapshot("base"))
        state.text = "local"
        state.markMissing()
        XCTAssertEqual(state.text, "local")
        XCTAssertTrue(state.hasConflict)
        state.receive(try snapshot("external"))
        XCTAssertFalse(state.isMissing)
        state.acceptExternal()
        XCTAssertEqual(state.text, "external")
        XCTAssertFalse(state.isDirty)
        XCTAssertFalse(state.hasConflict)
    }

    func testTypingDuringSaveRetainsNewerChanges() throws {
        var state = DocumentState(snapshot: try snapshot("base"))
        state.text = "saved + new typing"
        state.didSave(try snapshot("saved"), savedText: "saved")
        XCTAssertEqual(state.text, "saved + new typing")
        XCTAssertEqual(state.baseline.text, "saved")
        XCTAssertTrue(state.isDirty)
    }
}

final class FileStoreTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testSaveRefusesUnobservedExternalWrite() async throws {
        let url = folder.appendingPathComponent("文档 with spaces.md")
        try Data("base".utf8).write(to: url)
        let store = FileStore()
        let base = try await store.read(url)
        try Data("external".utf8).write(to: url, options: .atomic)
        do {
            _ = try await store.save("local", to: url, baseline: base, requireUnchanged: true)
            XCTFail("A stale baseline must not overwrite the disk")
        } catch DocumentError.externalChange {} 
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
    }

    func testAtomicReplacementChangesSignatureAndCanReload() async throws {
        let url = folder.appendingPathComponent("document.md")
        try Data("first".utf8).write(to: url)
        let store = FileStore()
        let before = try await store.signature(url)
        try Data("second".utf8).write(to: url, options: .atomic)
        let after = try await store.signature(url)
        let snapshot = try await store.read(url)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(snapshot.text, "second")
    }

    func testNormalSaveAndSaveAsPreserveBothVersions() async throws {
        let original = folder.appendingPathComponent("original.txt")
        let copy = folder.appendingPathComponent("copy.txt")
        try Data("original".utf8).write(to: original)
        let store = FileStore()
        let baseline = try await store.read(original)
        let saved = try await store.save("saved", to: original, baseline: baseline, requireUnchanged: true)
        _ = try await store.save("copy", to: copy, baseline: saved, requireUnchanged: false)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "saved")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "copy")
    }

    func testDeletedFileIsNotSilentlyRecreatedBySave() async throws {
        let url = folder.appendingPathComponent("deleted.md")
        try Data("base".utf8).write(to: url)
        let store = FileStore()
        let base = try await store.read(url)
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await store.save("local", to: url, baseline: base, requireUnchanged: true)
            XCTFail("Missing original requires explicit Save As")
        } catch DocumentError.missingFile {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

final class EncodingAndFormatTests: XCTestCase {
    func testUTF16BOMAndCRLFArePreservedWhenEditing() throws {
        let data = Data([0xFF, 0xFE]) + "标题\r\n内容\r\n".data(using: .utf16LittleEndian)!
        let baseline = try FileSnapshot(data: data)
        let saved = try baseline.replacingText("标题\n修改\n")
        XCTAssertEqual(saved.encoding, .utf16LE)
        XCTAssertTrue(saved.data.starts(with: [0xFF, 0xFE]))
        XCTAssertEqual(saved.text, "标题\r\n修改\r\n")
    }

    func testUTF8BOMAndUnicodeRoundTrip() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("你好 📝".utf8)
        let baseline = try FileSnapshot(data: data)
        XCTAssertEqual(try baseline.replacingText(baseline.text).data, data)
    }

    func testBinaryAndInvalidUTF8AreRejected() {
        XCTAssertThrowsError(try FileSnapshot(data: Data([0xC3, 0x28])))
        XCTAssertThrowsError(try FileSnapshot(data: Data([0, 1, 2])))
    }

    func testJSONFormattingValidatesAndPreservesValues() throws {
        let input = #"{"标题":"你好","nested":[true,1,null]}"#
        let output = try DocumentFormatter.format(input, kind: .json)
        let before = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! NSDictionary
        let after = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! NSDictionary
        XCTAssertEqual(before, after)
        XCTAssertThrowsError(try DocumentFormatter.format("{broken", kind: .json))
    }

    func testXMLRejectsEntitiesAndInvalidContent() throws {
        XCTAssertThrowsError(try DocumentFormatter.format("<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><x>&x;</x>", kind: .xml))
        XCTAssertThrowsError(try DocumentFormatter.format("<a><b></a>", kind: .xml))
        let output = try DocumentFormatter.format("<root><item>你好</item></root>", kind: .xml)
        XCTAssertTrue(output.contains("你好"))
    }
}
