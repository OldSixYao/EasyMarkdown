import Foundation

/// An edit in the native text view's UTF-16 coordinates, before replacement.
public struct TextChange: Sendable {
    public let range: NSRange
    public let replacementLength: Int
    public let utf8Delta: Int

    public init(range: NSRange, replacement: String, removed: String) {
        self.init(range: range, replacementLength: replacement.utf16.count,
                  utf8Delta: replacement.utf8.count - removed.utf8.count)
    }

    public init(range: NSRange, replacementLength: Int, utf8Delta: Int) {
        self.range = range
        self.replacementLength = replacementLength
        self.utf8Delta = utf8Delta
    }
}

/// Sparse indices let a small edit near the end of a Unicode baseline stay small.
/// Indices share the immutable String storage; they do not retain a UTF-16 copy.
struct TextCoordinates: Sendable {
    private static let stride = 4_096
    private let text: String
    private let checkpoints: [String.Index]
    let length: Int

    init(_ text: String) {
        self.text = text
        let view = text.utf16
        length = view.count
        var indices = [view.startIndex]
        var cursor = view.startIndex
        var offset = 0
        while offset + Self.stride <= length {
            cursor = view.index(cursor, offsetBy: Self.stride)
            indices.append(cursor)
            offset += Self.stride
        }
        checkpoints = indices
    }

    func substring(_ range: NSRange) -> String {
        let view = text.utf16
        let slot = range.location / Self.stride
        let start = view.index(checkpoints[slot], offsetBy: range.location % Self.stride)
        let end = view.index(start, offsetBy: range.length)
        return String(decoding: view[start..<end], as: UTF16.self)
    }
}
