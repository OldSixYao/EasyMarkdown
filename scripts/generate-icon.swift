import AppKit

// A reproducible vector drawing, rendered at each macOS icon resolution.
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func drawIcon() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = color(0x15294F, alpha: 0.24)
    tileShadow.shadowOffset = NSSize(width: 0, height: -14)
    tileShadow.shadowBlurRadius = 20
    tileShadow.set()
    color(0x3155A5).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x29458E), color(0x557CD5)])!.draw(in: tile, angle: 80)

    let rim = NSBezierPath(roundedRect: NSRect(x: 65, y: 65, width: 894, height: 894), xRadius: 201, yRadius: 201)
    color(0xFFFFFF, alpha: 0.22).setStroke(); rim.lineWidth = 2; rim.stroke()

    // A single folded sheet; generous negative space keeps the small icon readable.
    let page = NSBezierPath()
    page.move(to: NSPoint(x: 318, y: 214))
    page.curve(to: NSPoint(x: 274, y: 258), controlPoint1: NSPoint(x: 294, y: 214), controlPoint2: NSPoint(x: 274, y: 234))
    page.line(to: NSPoint(x: 274, y: 766))
    page.curve(to: NSPoint(x: 318, y: 810), controlPoint1: NSPoint(x: 274, y: 790), controlPoint2: NSPoint(x: 294, y: 810))
    page.line(to: NSPoint(x: 622, y: 810))
    page.line(to: NSPoint(x: 750, y: 682))
    page.line(to: NSPoint(x: 750, y: 258))
    page.curve(to: NSPoint(x: 706, y: 214), controlPoint1: NSPoint(x: 750, y: 234), controlPoint2: NSPoint(x: 730, y: 214))
    page.close()
    NSGraphicsContext.saveGraphicsState()
    let pageShadow = NSShadow()
    pageShadow.shadowColor = color(0x0C245D, alpha: 0.35)
    pageShadow.shadowOffset = NSSize(width: 0, height: -14)
    pageShadow.shadowBlurRadius = 22
    pageShadow.set()
    color(0xFCFDFF).setFill(); page.fill()
    NSGraphicsContext.restoreGraphicsState()

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 622, y: 810))
    fold.line(to: NSPoint(x: 622, y: 716))
    fold.curve(to: NSPoint(x: 656, y: 682), controlPoint1: NSPoint(x: 622, y: 693), controlPoint2: NSPoint(x: 633, y: 682))
    fold.line(to: NSPoint(x: 750, y: 682)); fold.close()
    color(0xD5E2FC).setFill(); fold.fill()

    // A hand-drawn Markdown M and down arrow, with rounded stroke ends.
    let mark = NSBezierPath()
    mark.move(to: NSPoint(x: 354, y: 426))
    mark.line(to: NSPoint(x: 354, y: 558))
    mark.line(to: NSPoint(x: 420, y: 487))
    mark.line(to: NSPoint(x: 486, y: 558))
    mark.line(to: NSPoint(x: 486, y: 426))
    mark.lineWidth = 30; mark.lineCapStyle = .round; mark.lineJoinStyle = .round
    color(0x3458A4).setStroke(); mark.stroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 624, y: 558)); arrow.line(to: NSPoint(x: 624, y: 431))
    arrow.move(to: NSPoint(x: 578, y: 475)); arrow.line(to: NSPoint(x: 624, y: 429)); arrow.line(to: NSPoint(x: 670, y: 475))
    arrow.lineWidth = 28; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    color(0x3458A4).setStroke(); arrow.stroke()

    let line = NSBezierPath(roundedRect: NSRect(x: 354, y: 320, width: 316, height: 16), xRadius: 8, yRadius: 8)
    color(0xB9CAE9).setFill(); line.fill()
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to: assets.appendingPathComponent("AppIcon.png"))
try render(256).write(to: assets.appendingPathComponent("AppIcon-preview.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated Assets/AppIcon.png and Assets/AppIcon.icns")
