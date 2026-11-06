import EasyMarkdownCore

/// Serial background work keeps simultaneous large formatting requests bounded.
/// Cancellation skips queued work and discards completed work; Foundation's
/// synchronous parser itself cannot be interrupted while it is running.
actor DocumentFormattingService {
    static let shared = DocumentFormattingService()

    func format(_ text: String, kind: DocumentKind) throws -> String {
        try Task.checkCancellation()
        let result = try DocumentFormatter.format(text, kind: kind)
        try Task.checkCancellation()
        return result
    }
}
