import Foundation
import UniformTypeIdentifiers
import ImageIO

public struct PreviewImage: Sendable {
    public let data: Data
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let estimatedDecodedBytes: Int
    public static let maximumPixels = 32_000_000
    public static let maximumFrames = 300
    /// Let WebKit decode at its required display resolution. A native thumbnail
    /// pipeline was measured and rejected because it increased app-side memory.
    public static func load(_ file: URL, within root: URL, maximumBytes: Int = 128 * 1024 * 1024) throws -> PreviewImage {
        let target = file.standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard target.path.hasPrefix(folder), let type = UTType(filenameExtension: target.pathExtension),
              type.conforms(to: .image) else { throw CocoaError(.fileReadNoPermission) }
        let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: target, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        // SVG stays vector data. Inspect raster metadata without allocating
        // native pixel buffers; WebKit remains the only image decoder.
        return try inspect(data, mimeType: type.preferredMIMEType ?? "application/octet-stream")
    }

    public static func inspect(_ data: Data, mimeType: String) throws -> PreviewImage {
        guard data.count <= 128 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        if mimeType.lowercased().split(separator: ";").first == "image/svg+xml" {
            // Vector complexity is not represented by raster dimensions. Bound
            // its source and reserve a conservative charge without rasterizing.
            guard data.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            return PreviewImage(data: data, mimeType: "image/svg+xml", width: 0, height: 0,
                                estimatedDecodedBytes: 16 * 1024 * 1024)
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard count <= maximumFrames else { throw CocoaError(.fileReadTooLarge) }
        var width = 0, height = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                  let frameWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                  let frameHeight = properties[kCGImagePropertyPixelHeight] as? Int,
                  frameWidth > 0, frameHeight > 0 else { throw CocoaError(.fileReadCorruptFile) }
            width = max(width, frameWidth)
            height = max(height, frameHeight)
            // Division avoids overflow for malicious dimension headers. Charge
            // all frames at the largest canvas size, including GIF subframes.
            guard width <= maximumPixels / count / height else { throw CocoaError(.fileReadTooLarge) }
        }
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        return PreviewImage(data: data, mimeType: type?.preferredMIMEType ?? mimeType,
            width: width, height: height, estimatedDecodedBytes: width * height * count * 4)
    }
}
