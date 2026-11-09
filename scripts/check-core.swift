import Foundation

// The Command Line Tools SDK does not ship XCTest. Run the same suite without it.
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
func XCTAssertTrue(_ condition: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { let result = try condition(); precondition(result, "Expected true", file: file, line: line) }
    catch { preconditionFailure("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertFalse(_ condition: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { let result = try condition(); precondition(!result, "Expected false", file: file, line: line) }
    catch { preconditionFailure("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                 file: StaticString = #file, line: UInt = #line) {
    do {
        let a = try lhs(), b = try rhs()
        precondition(a == b, "\(a) != \(b)", file: file, line: line)
    } catch { preconditionFailure("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertNotEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs != rhs, "Values unexpectedly equal", file: file, line: line)
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression() } catch { return }
    preconditionFailure("Expected an error", file: file, line: line)
}
func XCTFail(_ message: String, file: StaticString = #file, line: UInt = #line) {
    preconditionFailure(message, file: file, line: line)
}

@main struct CoreChecks {
    static func main() async throws {
        let state = DocumentStateTests()
        try state.testCleanDocumentFollowsExternalChanges()
        try state.testExternalChangesNeverOverwriteUnsavedBuffer()
        try state.testExternalRevertClearsStaleConflict()
        try state.testIdenticalExternalEditBecomesClean()
        try state.testAcceptExternalAndMissingFileRecovery()
        try state.testTypingDuringSaveRetainsNewerChanges()
        let format = EncodingAndFormatTests()
        try format.testUTF16BOMAndCRLFArePreservedWhenEditing()
        try format.testUTF8BOMAndUnicodeRoundTrip()
        format.testBinaryAndInvalidUTF8AreRejected()
        try format.testJSONFormattingValidatesAndPreservesValues()
        try format.testXMLRejectsEntitiesAndInvalidContent()
        let markdown = MarkdownEditingTests()
        markdown.testInlineFormattingPreservesUnicodeSelectionAndToggles()
        markdown.testEmptySelectionInsertsEditablePlaceholder()
        markdown.testMultilinePrefixesExcludeNextUnselectedLine()
        markdown.testHeadingAndListConversionDoNotStackPrefixes()
        markdown.testCRLFAndIndentationSurviveLineCommands()
        markdown.testCodeContainingBackticksUsesSafeDelimiters()
        markdown.testLinkTableAndDividerKeepUserContent()
        let images = PreviewImageTests()
        try images.testLargeImagePassesThroughWithoutNativeDecoding()
        try images.testSmallAndAnimatedImagesPassThrough()
        try images.testDirectoryTraversalAndSymlinkEscapesAreRejected()
        try images.testOversizedRasterHeadersAreRejectedWithoutDecoding()
        try images.testAnimationBudgetAndSVGPassThrough()
        let configurations = ConfigurationTests()
        configurations.testConfigurationNamesAndAliases()
        try configurations.testConfigurationFormattingPreservesCommentsAndWhitespace()
        try await configurations.testConfigurationFileRoundTripPreservesBOMAndCRLF()
        let files = FileStoreTests()
        try files.setUpWithError()
        defer { try? files.tearDownWithError() }
        try await files.testSaveRefusesUnobservedExternalWrite()
        try await files.testAtomicReplacementChangesSignatureAndCanReload()
        try await files.testNormalSaveAndSaveAsPreserveBothVersions()
        try await files.testDeletedFileIsNotSilentlyRecreatedBySave()
        let performance = PerformanceStateTests()
        try performance.testDistantUnicodeEditsAndUndoRestoreCleanState()
        try performance.testCanonicalUnicodeEqualityRetainsEditCoordinates()
        try performance.testRandomEditsAgreeWithFullComparison()
        try performance.testSaveDoesNotInvalidateUnchangedEditorRevision()
        performance.testPreviewBudgetHandlesEmojiAndLongCombiningSequences()
        print("PASS: 35 core checks — file safety, configuration round trips, formatting, Markdown commands, image loading and incremental Unicode state")
    }
}
