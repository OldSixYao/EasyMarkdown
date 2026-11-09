import Foundation

public struct PreviewText: Sendable {
    public static let maximumUTF16Count = 500_000
    public static let maximumBytes = maximumUTF16Count * 3
    public let text: String
    public let isTruncated: Bool

    public init(_ source: String) {
        let view = source.utf16
        guard var end = view.index(view.startIndex, offsetBy: Self.maximumUTF16Count,
                                   limitedBy: view.endIndex), end != view.endIndex else {
            text = source
            isTruncated = false
            return
        }
        // UTF-16 bounds match JavaScript and TextKit. Never cut a surrogate pair,
        // or walk an arbitrarily large extended grapheme cluster with prefix().
        let last = view.index(before: end)
        if (0xD800...0xDBFF).contains(view[last]) { end = last }
        text = String(decoding: view[..<end], as: UTF16.self)
        isTruncated = true
    }
}
