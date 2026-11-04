import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib
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

    func testOversizedRasterHeadersAreRejectedWithoutDecoding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("oversized.png")
        // Encode a real 36 MP, 1-bit PNG without a 144 MB RGBA pixel buffer.
        // Some ImageIO decoders only expose dimensions after validating IDAT.
        let raw = Data(repeating: 0, count: (1 + 6000 / 8) * 6000)
        var compressed = Data(count: Int(compressBound(uLong(raw.count))))
        var length = uLongf(compressed.count)
        let status = raw.withUnsafeBytes { input in
            compressed.withUnsafeMutableBytes { output in
                compress2(output.bindMemory(to: Bytef.self).baseAddress, &length,
                    input.bindMemory(to: Bytef.self).baseAddress, uLong(raw.count), Z_BEST_SPEED)
            }
        }
        XCTAssertEqual(status, Z_OK)
        compressed.count = Int(length)
        func bigEndian(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ((3 - $0) * 8)) }
        }
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        func chunk(_ kind: String, _ payload: Data) {
            var body = Data(kind.utf8)
            body.append(payload)
            let crc = body.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(body.count)) }
            data.append(contentsOf: bigEndian(UInt32(payload.count)))
            data.append(body)
            data.append(contentsOf: bigEndian(UInt32(crc)))
        }
        chunk("IHDR", Data(bigEndian(6000) + bigEndian(6000) + [1, 0, 0, 0, 0]))
        chunk("IDAT", compressed)
        chunk("IEND", Data())
        try data.write(to: file)
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 6000)
        do {
            _ = try PreviewImage.load(file, within: root)
            XCTFail("Oversized image passed its pixel budget")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadTooLarge.rawValue) }
    }

    func testAnimationBudgetAndSVGPassThrough() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.gif")
        try fixture(width: 2, height: 2, type: .gif, frames: PreviewImage.maximumFrames + 1).write(to: file)
        XCTAssertThrowsError(try PreviewImage.load(file, within: root))
        try fixture(width: 400, height: 400, type: .gif, frames: 201).write(to: file)
        XCTAssertThrowsError(try PreviewImage.load(file, within: root))
        let svg = root.appendingPathComponent("vector.svg")
        let vector = Data("<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='blue'/></svg>".utf8)
        try vector.write(to: svg)
        XCTAssertEqual(try PreviewImage.load(svg, within: root).data, vector)
    }
}
