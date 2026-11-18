// Renders an abstract evening landscape for the website screenshots, so they show no real desktop picture.
// Run: swift scripts/make-wallpaper.swift out.png
import AppKit

let w = 2880, h = 1800
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSGraphicsContext.current!.cgContext
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func col(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

// Sky: deep blue at the top, a warm band low over the hills.
let sky = CGGradient(colorsSpace: cs, colors: [col(0.98, 0.72, 0.52), col(0.85, 0.52, 0.55), col(0.38, 0.3, 0.55), col(0.12, 0.13, 0.3)] as CFArray,
                     locations: [0, 0.25, 0.6, 1])!
c.drawLinearGradient(sky, start: CGPoint(x: 0, y: 1150), end: CGPoint(x: 0, y: CGFloat(h)), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Layers of soft hills, darker and bluer toward the front.
let layers: [(base: Double, amp: Double, freq: Double, phase: Double, color: CGColor)] = [
    (1150, 90, 1.3, 0.4, col(0.55, 0.38, 0.55)),
    (980, 120, 1.9, 2.1, col(0.42, 0.29, 0.5)),
    (780, 150, 1.1, 4.0, col(0.3, 0.22, 0.44)),
    (560, 170, 1.6, 1.2, col(0.2, 0.16, 0.36)),
    (320, 140, 2.3, 3.3, col(0.12, 0.1, 0.26)),
]
for l in layers {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    for x in stride(from: 0, through: w, by: 8) {
        let t = Double(x) / Double(w) * .pi * 2
        let y = l.base + l.amp * (sin(t * l.freq + l.phase) * 0.7 + sin(t * l.freq * 2.3 + l.phase * 1.7) * 0.3)
        path.addLine(to: CGPoint(x: Double(x), y: y))
    }
    path.addLine(to: CGPoint(x: w, y: 0))
    path.closeSubpath()
    c.addPath(path)
    c.setFillColor(l.color)
    c.fillPath()
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
