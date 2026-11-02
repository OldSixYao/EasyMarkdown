import Foundation
import UniformTypeIdentifiers

public struct PreviewImage: Sendable {
    public let data: Data
    public let mimeType: String
    /// Let WebKit decode at its required display resolution. A native thumbnail
    /// pipeline was measured and rejected because it increased app-side memory.
    public static func load(_ file: URL, within root: URL) throws -> PreviewImage {
        let target = file.standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard target.path.hasPrefix(folder), let type = UTType(filenameExtension: target.pathExtension),
              type.conforms(to: .image) else { throw CocoaError(.fileReadNoPermission) }
        let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: target, options: .mappedIfSafe)
        return PreviewImage(data: data, mimeType: type.preferredMIMEType ?? "application/octet-stream")
    }
}
