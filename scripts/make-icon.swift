// Renders Resources/AppIcon.icns from Resources/Icon/source.png (a square crop of the
// real page: the carriage on the rail and the light cone).
// Run: swift scripts/make-icon.swift [preview.png]
// The source is a 1150 × 1150 crop of a full-screen screenshot of the page.
import AppKit
import CoreImage

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let source: NSImage = {
    // More contrast, so the light cone still reads at Dock size.
    let ci = CIImage(contentsOf: root.appendingPathComponent("Resources/Icon/source.png"))!
    let f = CIFilter(name: "CIColorControls")!
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(1.45, forKey: kCIInputContrastKey)
    f.setValue(1.0, forKey: kCIInputSaturationKey)
    f.setValue(-0.04, forKey: kCIInputBrightnessKey)
    let rep = NSCIImageRep(ciImage: f.outputImage!.cropped(to: ci.extent))
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
}()
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

/// One icon on the macOS grid: an 824 pt tile in a 1024 pt canvas with a soft drop shadow.
func render(_ size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    c.interpolationQuality = .high
    c.scaleBy(x: s, y: s)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.3))
    c.addPath(path)
    c.setFillColor(CGColor(gray: 0.8, alpha: 1))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(path)
    c.clip()
    source.draw(in: tile)
    // Dusk from above: the far end of the page falls off into shade.
    let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [CGColor(srgbRed: 0.33, green: 0.3, blue: 0.45, alpha: 0.55),
                                    CGColor(srgbRed: 0.33, green: 0.3, blue: 0.45, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    c.setBlendMode(.multiply)
    c.drawLinearGradient(shade, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY + 330), options: [])
    c.setBlendMode(.normal)
    // A faint inner edge, so the light tile stands out on a light Dock.
    c.addPath(path)
    c.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
    c.setLineWidth(4)
    c.strokePath()
    c.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print("Wrote \(out.path)")

if CommandLine.arguments.count > 1 {
    try render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
