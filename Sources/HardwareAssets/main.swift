import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Carriage

// Makes the hardware images for all colors from the rose gold originals.
//   hardware-assets <originals directory> <output directory>
// Output: <id>/carriage.png, <id>/rail.png and <id>/grille-hole.png for each color, and lamp.png and status.png, which are the same
// for all colors.

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: hardware-assets <originals directory> <output directory>\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("hardware-assets: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func load(_ name: String) -> CGImage {
    guard let image = Assets.image(input.appendingPathComponent(name)) else { fail("cannot read \(name)") }
    return image
}

func write(_ image: CGImage?, _ path: String) {
    let url = output.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let image, let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot make \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(path)") }
}

let carriage = load("carriage-base.png"), rail = load("rail.png"), hole = load("grille-hole.png")
write(Assets.prepare(load("lamp-overlay.png")), "lamp.png")
write(Assets.prepare(load("status-overlay.png")), "status.png")
for entry in HardwareColors.all {
    // Rose gold: the carriage image is a little more yellow than the rose gold housing, so it is tinted to that hue.
    let color = entry.color ?? HardwareColors.railRoseGold
    guard let tintedCarriage = Assets.tint(carriage, to: color), let tintedRail = Assets.tint(rail, to: color),
          let tintedHole = Assets.tint(hole, to: color)
    else { fail("cannot tint \(entry.id)") }
    // The groove and its highlight come from the rail image, the rest of the rail band from the carriage.
    write(Assets.makeRail(from: tintedCarriage, groove: tintedRail), "\(entry.id)/rail.png")
    write(tintedHole, "\(entry.id)/grille-hole.png")
    let prepared = Assets.prepare(Assets.removeStatusDot(tintedCarriage) ?? tintedCarriage)
    write(Assets.addRightLampSlot(prepared) ?? prepared, "\(entry.id)/carriage.png")
}

enum Assets {
    /// Recolors the rose gold metal to another hardware color and keeps the shading:
    /// darker pixels scale the target color down, brighter pixels blend it toward white.
    /// Very dark parts (groove, holes) and neutral parts stay nearly unchanged.
    static func tint(_ image: CGImage, to c: HardwareColors.RGB) -> CGImage? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func lum(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        let refL = lum(HardwareColors.roseGold.r, HardwareColors.roseGold.g, HardwareColors.roseGold.b)
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0 else { continue }
            let r = Double(px[i]) / 255 / a, g = Double(px[i + 1]) / 255 / a, b = Double(px[i + 2]) / 255 / a
            // Only metal is tinted; dark or grey parts keep more of their own color.
            // Highlights are nearly white but still warm, so bright pixels count as metal too.
            let sat = max(r, g, b) - min(r, g, b)
            let l = lum(r, g, b) / refL
            let metal = min(1, max(sat / 0.12, (l - 0.85) / 0.15))
            func tone(_ t: Double) -> Double { l <= 1 ? t * l : t + (1 - t) * min(1, (l - 1) * 1.6) }
            let out = (r + (tone(c.r) - r) * metal, g + (tone(c.g) - g) * metal, b + (tone(c.b) - b) * metal)
            px[i] = UInt8(max(0, min(255, out.0 * a * 255)))
            px[i + 1] = UInt8(max(0, min(255, out.1 * a * 255)))
            px[i + 2] = UInt8(max(0, min(255, out.2 * a * 255)))
        }
        return ctx.makeImage()
    }

    /// Builds the rail band from the carriage material. Each part uses the mean color of its source rows,
    /// so horizontal light falloff in the source does not repeat; the fine grain of the metal comes back as a
    /// mirrored texture taken from the front of the carriage.
    static func makeRail(from carriage: CGImage, groove railImage: CGImage) -> CGImage? {
        typealias R = RailGeometry
        guard let c = pixels(carriage), let r = pixels(railImage) else { return nil }
        let width = 1200, height = Int(R.bottom)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        // Mean color (premultiplied RGBA) of one row segment.
        func rowMean(_ p: Pixels, _ y: Int, _ cols: Range<Int>) -> [Double] {
            var sum = [0.0, 0, 0, 0]
            for x in cols { for k in 0..<4 { sum[k] += Double(p.data[(y * p.width + x) * 4 + k]) } }
            return sum.map { $0 / Double(cols.count) }
        }
        // Grain: pixel brightness relative to its row mean, from the plain front of the carriage.
        let gx = R.faceSourceColumns, gy = R.faceSourceRows
        var grain = [Double](repeating: 1, count: gx.count * gy.count)
        for (j, y) in gy.enumerated() {
            let mean = rowMean(c, y, gx)
            let m = (mean[0] + mean[1] + mean[2]) / 3
            for (i, x) in gx.enumerated() {
                let o = (y * c.width + x) * 4
                let v = (Double(c.data[o]) + Double(c.data[o + 1]) + Double(c.data[o + 2])) / 3
                grain[j * gx.count + i] = m > 0 ? v / m : 1
            }
        }
        func grainAt(_ x: Int, _ y: Int) -> Double {
            let w = gx.count, h = gy.count
            let px = (x / w) % 2 == 0 ? x % w : w - 1 - x % w
            let py = (y / h) % 2 == 0 ? y % h : h - 1 - y % h
            return grain[py * w + px]
        }
        func fill(_ y: Int, with mean: [Double], grainy: Bool) {
            for x in 0..<width {
                let f = grainy ? grainAt(x, y) : 1
                let o = (y * width + x) * 4
                for k in 0..<3 { out[o + k] = UInt8(max(0, min(mean[3], mean[k] * f))) }
                out[o + 3] = UInt8(mean[3])
            }
        }
        // Lip: rows from the top edge of the carriage.
        for (i, y) in R.lipSourceRows.enumerated() where i < Int(R.grooveTop) {
            fill(i, with: rowMean(c, y, R.lipSourceColumns), grainy: true)
        }
        // Groove and the highlight below it, from the rail image.
        let railCols = 100..<min(r.width - 100, 1900)
        for (i, y) in R.grooveSourceRows.enumerated() {
            fill(Int(R.grooveTop) + i, with: rowMean(r, y, railCols), grainy: false)
        }
        let faceStart = Int(R.grooveBottom)
        for (i, y) in R.highlightSourceRows.enumerated() {
            fill(faceStart + i, with: rowMean(r, y, railCols), grainy: false)
        }
        // Face: the plain front of the carriage, its rows stretched over the face height.
        let faceRows = height - faceStart - R.highlightSourceRows.count
        for i in 0..<faceRows {
            let src = R.faceSourceRows.lowerBound + i * R.faceSourceRows.count / faceRows
            fill(faceStart + R.highlightSourceRows.count + i, with: rowMean(c, src, R.faceSourceColumns), grainy: true)
        }
        return makeImage(&out, width, height)
    }

    struct Pixels {
        let data: [UInt8]
        let width: Int
    }

    static func pixels(_ image: CGImage) -> Pixels? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(data: px, width: w)
    }

    static func makeImage(_ px: inout [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    /// Brings an original full-canvas image to the shape in use: shorter fin, taller body.
    static func prepare(_ image: CGImage) -> CGImage {
        let short = shortenFin(image) ?? image
        let shifted = shiftFin(short) ?? short
        return extend(shifted) ?? shifted
    }

    /// The carriage image has the status dot painted in below the fin. The scene draws the dot elsewhere,
    /// so here it is covered with the plain front from a little further left.
    /// The original image has the slot of the lamp strip only left of the fin. The strip also shows right of
    /// the fin, so the slot is copied there: the tip from the left end, then a piece from the middle, then
    /// the tip again, mirrored. At both ends and at the top and bottom of the band it is blended in.
    static func addRightLampSlot(_ image: CGImage) -> CGImage? {
        typealias C = CarriageGeometry
        guard let p = pixels(image) else { return nil }
        var out = p.data
        let w = p.width
        let rows = C.lampSlotRows, x0 = Int(C.rightLampStart), x1 = Int(C.rightLampEnd)
        // `plain` is the plain metal just left of the tip; the blend at the ends starts from there.
        let plain = Int(C.lampStart.x) - 6, blend = 14, cap = 40, middle = 400
        // Source column and weight for a distance from the nearer end of the slot.
        func source(_ d: Int) -> (Int, Double)? {
            if d < blend { return (plain, Double(d) / Double(blend)) }
            if d - blend < cap { return (plain + d - blend, 1) }
            return nil
        }
        for y in rows {
            let edge = min(y - rows.lowerBound, rows.upperBound - 1 - y)
            let wy = min(1, Double(edge + 1) / 3)
            for x in x0..<x1 {
                let (src, wx) = source(x - x0) ?? source(x1 - 1 - x) ?? (middle + x - x0, 1)
                let f = wx * wy
                let o = (y * w + x) * 4, so = (y * w + src) * 4
                for k in 0..<4 { out[o + k] = UInt8(Double(p.data[o + k]) + (Double(p.data[so + k]) - Double(p.data[o + k])) * f) }
            }
        }
        return makeImage(&out, w, image.height)
    }

    static func removeStatusDot(_ image: CGImage) -> CGImage? {
        let x = 1300, y = 578, r = 16, from = x - 60
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let patch = image.cropping(to: CGRect(x: from - r, y: y - r, width: 2 * r, height: 2 * r)) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Core Graphics counts y from the bottom.
        ctx.draw(patch, in: CGRect(x: x - r, y: h - y - r, width: 2 * r, height: 2 * r))
        return ctx.makeImage()
    }

    /// Moves the fin `finShift` columns to the left; the carriage keeps its length.
    static func shiftFin(_ image: CGImage) -> CGImage? {
        typealias C = CarriageGeometry
        let d = Int(C.finShift)
        guard d > 0 else { return image }
        let w = image.width, h = image.height
        let a = Int(C.shiftStart), f0 = Int(C.footStretch.lowerBound), f1 = Int(C.footStretch.upperBound)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        func put(_ from: Range<Int>, to x: Int, width: Int) {
            guard let part = image.cropping(to: CGRect(x: from.lowerBound, y: 0, width: from.count, height: h)) else { return }
            ctx.draw(part, in: CGRect(x: x, y: 0, width: width, height: h))
        }
        put(0..<a, to: 0, width: a)                              // left end and grille area
        put((a + d)..<f0, to: a, width: f0 - a - d)              // the fin and its rounding, moved left
        put(f0..<f1, to: f0 - d, width: f1 - f0 + d)             // plain foot, stretched
        put(f1..<w, to: f1, width: w - f1)                       // right end
        return ctx.makeImage()
    }

    /// Takes `finCut` rows out of the straight part of the fin; the rows above it move down.
    static func shortenFin(_ image: CGImage) -> CGImage? {
        typealias C = CarriageGeometry
        let w = image.width, h = image.height
        let cut = Int(C.finCut), row = Int(C.finCutRow)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let upper = image.cropping(to: CGRect(x: 0, y: 0, width: w, height: row)),
              let lower = image.cropping(to: CGRect(x: 0, y: row + cut, width: w, height: h - row - cut)) else { return nil }
        // Core Graphics counts y from the bottom.
        ctx.draw(lower, in: CGRect(x: 0, y: 0, width: w, height: h - row - cut))
        ctx.draw(upper, in: CGRect(x: 0, y: h - row - cut, width: w, height: row))
        return ctx.makeImage()
    }

    /// Makes the body taller: the rows above the slice stay, the slice is stretched, the rows below move down.
    static func extend(_ image: CGImage) -> CGImage? {
        typealias C = CarriageGeometry
        let w = image.width, h = image.height
        let ext = Int(C.bodyExtension), top = Int(C.stretchTop), bottom = Int(C.stretchBottom)
        let H = h + ext
        guard let ctx = CGContext(data: nil, width: w, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let upper = image.cropping(to: CGRect(x: 0, y: 0, width: w, height: top)),
              let middle = image.cropping(to: CGRect(x: 0, y: top, width: w, height: bottom - top)),
              let lower = image.cropping(to: CGRect(x: 0, y: bottom, width: w, height: h - bottom)) else { return nil }
        ctx.interpolationQuality = .high
        // Core Graphics counts y from the bottom.
        ctx.draw(lower, in: CGRect(x: 0, y: 0, width: w, height: h - bottom))
        ctx.draw(middle, in: CGRect(x: 0, y: h - bottom, width: w, height: bottom - top + ext))
        ctx.draw(upper, in: CGRect(x: 0, y: H - top, width: w, height: top))
        return ctx.makeImage()
    }

    static func image(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
