import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if !STANDALONE_CHECKS
import XCTest
@testable import EasyMarkdownCore
#endif

final class PreviewImageTests: XCTestCase {
    private func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.7))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func fixture(width: Int, height: Int, type: UTType = .png, frames: Int = 1) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil)!
        let image = image(width: width, height: height)
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testLargeImagePassesThroughWithoutNativeDecoding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("大图片.png")
        let original = fixture(width: 3000, height: 1500)
        try original.write(to: file)
        let preview = try PreviewImage.load(file, within: root)
        let source = CGImageSourceCreateWithData(preview.data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 3000)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1500)
        XCTAssertEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true)
        XCTAssertEqual(preview.data, original)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testSmallAndAnimatedImagesPassThrough() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("small.png")
        let small = fixture(width: 12, height: 8)
        try small.write(to: file)
        XCTAssertEqual(try PreviewImage.load(file, within: root).data, small)
        let gif = root.appendingPathComponent("animated.gif")
        let animation = fixture(width: 2100, height: 2, type: .gif, frames: 2)
        try animation.write(to: gif)
        XCTAssertEqual(try PreviewImage.load(gif, within: root).data, animation)
    }

    func testDirectoryTraversalAndSymlinkEscapesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let allowed = root.appendingPathComponent("allowed")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.png")
        try fixture(width: 2, height: 2).write(to: outside)
        let link = allowed.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try PreviewImage.load(outside, within: allowed))
        XCTAssertThrowsError(try PreviewImage.load(link, within: allowed))
    }
}
