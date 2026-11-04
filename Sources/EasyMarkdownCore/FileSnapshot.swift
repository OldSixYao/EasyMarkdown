import Foundation

public enum DocumentError: LocalizedError {
    case tooLarge, unsupportedEncoding, externalChange, missingFile, invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return L10n.text("文件超过首版支持的 24 MB 上限，请使用其他编辑器打开。")
        case .unsupportedEncoding: return L10n.text("无法按 UTF-8 或带 BOM 的 UTF-16 读取文件。请先将文件转换为 UTF-8。")
        case .externalChange: return L10n.text("文件已在其他位置修改。请先处理外部版本，或将本地内容另存为。")
        case .missingFile: return L10n.text("文件已被移动或删除。当前内容已保留，你可以另存为。")
        case .invalidFormat(let message): return message
        }
    }
}

public struct FileSnapshot: Equatable, Sendable {
    public static let maximumBytes = 24 * 1024 * 1024
    public enum Encoding: String, Codable, Sendable {
        case utf8, utf8BOM, utf16LE, utf16BE
    }
    public let data: Data
    public let text: String
    public let encoding: Encoding

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw DocumentError.tooLarge }
        self.data = data
        let payload: Data
        let stringEncoding: String.Encoding
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8BOM; payload = data.dropFirst(3); stringEncoding = .utf8
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LE; payload = data.dropFirst(2); stringEncoding = .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BE; payload = data.dropFirst(2); stringEncoding = .utf16BigEndian
        } else {
            encoding = .utf8; payload = data; stringEncoding = .utf8
        }
        guard let decoded = String(data: payload, encoding: stringEncoding), !decoded.contains("\0") else {
            throw DocumentError.unsupportedEncoding
        }
        text = decoded
    }

    public func replacingText(_ value: String) throws -> FileSnapshot {
        // Retain the original CRLF convention when the source consistently uses it.
        let crlfOnly = text.contains("\r\n") && !text.replacingOccurrences(of: "\r\n", with: "").contains("\n")
        let output = crlfOnly ? value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n") : value
        let bytes: Data
        switch encoding {
        case .utf8: bytes = Data(output.utf8)
        case .utf8BOM: bytes = Data([0xEF, 0xBB, 0xBF]) + Data(output.utf8)
        case .utf16LE: bytes = Data([0xFF, 0xFE]) + output.data(using: .utf16LittleEndian)!
        case .utf16BE: bytes = Data([0xFE, 0xFF]) + output.data(using: .utf16BigEndian)!
        }
        return try FileSnapshot(data: bytes)
    }
}

public enum DocumentKind: String, Sendable {
    case markdown, text, json, xml

    public init(url: URL?) {
        switch url?.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": self = .markdown
        case "json": self = .json
        case "xml", "svg", "plist": self = .xml
        default: self = .text
        }
    }
}
