import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import ImageIO

/// Positions in the carriage images (1774 × 887 px, origin top left). All carriage layers share this canvas.
enum CarriageGeometry {
    /// The body is made taller than in the original images: a flat slice of its front is stretched.
    static let bodyExtension: CGFloat = 100
    /// Rows of the original image: the slice between them is stretched by `bodyExtension`.
    static let stretchTop: CGFloat = 615
    static let stretchBottom: CGFloat = 672
    static let canvas = CGSize(width: 1774, height: 887 + bodyExtension)
    /// The straight part of the fin, which covers the cell of the next character.
    static let finLeft: CGFloat = 1223
    static let finRight: CGFloat = 1356
    static let finCenter: CGFloat = 1290
    static let finTop: CGFloat = 190
    /// The long body.
    static let bodyLeft: CGFloat = 178
    static let bodyRight: CGFloat = 1595
    static let bodyTop: CGFloat = 492
    static let bodyBottom: CGFloat = 706 + bodyExtension
    /// The lamp strip along the top edge of the body.
    static let lampStart = CGPoint(x: 226, y: 503)
    static let lampEnd = CGPoint(x: 1134, y: 500)
    static let status = CGPoint(x: 1300, y: 578)
    /// The lamp strip runs on behind the fin; this is its visible part on the foot right of the fin.
    static let rightLampStart: CGFloat = 1358
    static let rightLampEnd: CGFloat = 1545
}

/// Rows of the rail band (origin top left). The band is built from the carriage material, so rail and carriage
/// look exactly the same: the lip from the top edge of the carriage, the face from its front. Only the dark
/// groove and the fine highlight below it come from the rail image.
enum RailGeometry {
    static let top: CGFloat = 0
    static let grooveTop: CGFloat = 60
    static let grooveBottom: CGFloat = 78
    static let bottom: CGFloat = 201

    /// Source rows in the original carriage image (1774 × 887).
    static let lipSourceRows = 492..<552        // top edge with its polished chamfer, on the foot
    static let lipSourceColumns = 1385..<1540
    static let faceSourceRows = 560..<680       // plain front of the body
    static let faceSourceColumns = 300..<1100
    /// Source rows in the rail image: the dark groove and the highlight right below it.
    static let grooveSourceRows = 337..<355
    static let highlightSourceRows = 355..<358
}

/// One hardware color. All colors share the same images; they are tinted from the rose gold originals.
struct HardwareVariant {
    let id: String
    let title: String
    let carriage: CGImage
    let rail: CGImage
    let lamp: CGImage
    let status: CGImage
    let grilleHole: CGImage
}

enum Hardware {
    /// MacBook colors first, then MacBook Neo colors. nil means the original rose gold.
    static let ids: [(id: String, title: String, color: (r: Double, g: Double, b: Double)?)] = [
        ("silver", "Silver", (0.86, 0.865, 0.875)),
        ("space-gray", "Space Gray", (0.47, 0.475, 0.49)),
        ("space-black", "Space Black", (0.2, 0.2, 0.21)),
        ("gold", "Gold", nil),
        ("starlight", "Starlight", (0.89, 0.86, 0.8)),
        ("midnight", "Midnight", (0.19, 0.22, 0.27)),
        ("sky-blue", "Sky Blue", (0.77, 0.83, 0.87)),
        ("blush", "Blush", (0.9, 0.72, 0.75)),
        ("indigo", "Indigo", (0.33, 0.35, 0.56)),
        ("citrus", "Citrus", (0.86, 0.86, 0.56)),
    ]

    private static let directory = Bundle.main.resourceURL?.appendingPathComponent("Fin")
    private static var cache: [String: HardwareVariant] = [:]

    /// The chosen color, or the color of this Mac when the user has not chosen one.
    static var currentID: String {
        get {
            let id = UserDefaults.standard.string(forKey: "hardware") ?? detectedID ?? "gold"
            return ids.contains { $0.id == id } ? id : "gold"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "hardware")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static let didChange = Notification.Name("HardwareDidChange")

    /// The housing color of this Mac, as macOS knows it for the device picture in "About This Mac":
    /// the model and the enclosure color number map to a device type such as
    /// "com.apple.macbookair-late-2020-gold", whose name contains the color.
    static let detectedID: String? = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let model = String(cString: buf)
        typealias MGCopyAnswer = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?
        guard !model.isEmpty,
              let lib = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW),
              let sym = dlsym(lib, "MGCopyAnswer"),
              let answer = unsafeBitCast(sym, to: MGCopyAnswer.self)("DeviceEnclosureColor" as CFString)?.takeRetainedValue()
        else { return nil }
        let color = "\(answer)"
        guard let type = UTType(tag: "\(model)@ECOLOR=\(color)", tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)
        else { return nil }
        let names = ([type.identifier] + type.supertypes.map(\.identifier)).joined(separator: " ").lowercased()
        // Longer names first, so "sky-blue" is not taken for "blue" and "space-gray" not for "gray".
        let keywords: [(String, String)] = [
            ("space-black", "space-black"), ("space-gray", "space-gray"), ("space-grey", "space-gray"),
            ("sky-blue", "sky-blue"), ("midnight", "midnight"), ("starlight", "starlight"),
            ("rose-gold", "gold"), ("gold", "gold"), ("silver", "silver"),
            ("blush", "blush"), ("pink", "blush"), ("indigo", "indigo"), ("citrus", "citrus"), ("yellow", "citrus"),
        ]
        return keywords.first { names.contains($0.0) }?.1
    }()

    /// The color for a preview circle.
    static func swatchColor(_ id: String) -> NSColor {
        let c = ids.first { $0.id == id }?.color ?? roseGold
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    static var current: HardwareVariant? { variant(currentID) }

    static func cycle(_ step: Int) {
        let i = ids.firstIndex { $0.id == currentID } ?? 0
        currentID = ids[(i + step + ids.count) % ids.count].id
    }

    static func variant(_ id: String) -> HardwareVariant? {
        if let v = cache[id] { return v }
        guard let entry = ids.first(where: { $0.id == id }), let dir = directory,
              let carriage = image(dir.appendingPathComponent("carriage-base.png")),
              let rail = image(dir.appendingPathComponent("rail.png")),
              let lamp = image(dir.appendingPathComponent("lamp-overlay.png")),
              let status = image(dir.appendingPathComponent("status-overlay.png")),
              let hole = image(dir.appendingPathComponent("grille-hole.png")) else { return nil }
        // Rose gold: the carriage image is a little more yellow than the rose gold housing, so it is tinted to that hue.
        let tintedCarriage = tint(carriage, to: entry.color ?? railRoseGold) ?? carriage
        let railBand = makeRail(from: tintedCarriage, groove: rail) ?? rail
        let v = HardwareVariant(id: id, title: entry.title,
                                carriage: extend(tintedCarriage) ?? tintedCarriage,
                                rail: railBand,
                                lamp: extend(lamp) ?? lamp, status: extend(status) ?? status, grilleHole: hole)
        cache[id] = v
        return v
    }

    static let paper: CGImage? = directory.flatMap { image($0.appendingPathComponent("paper.png")) }

    /// Mean color of the rose gold metal, the reference for tinting.
    private static let roseGold = (r: 0.86, g: 0.72, b: 0.64)
    /// Mean color of the rose gold rail, measured on its lip and face.
    private static let railRoseGold = (r: 0.875, g: 0.678, b: 0.632)

    /// Recolors the rose gold metal to another hardware color and keeps the shading:
    /// darker pixels scale the target color down, brighter pixels blend it toward white.
    /// Very dark parts (groove, holes) and neutral parts stay nearly unchanged.
    private static func tint(_ image: CGImage, to c: (r: Double, g: Double, b: Double)) -> CGImage? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func lum(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        let refL = lum(roseGold.r, roseGold.g, roseGold.b)
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0 else { continue }
            let r = Double(px[i]) / 255 / a, g = Double(px[i + 1]) / 255 / a, b = Double(px[i + 2]) / 255 / a
            // Only metal is tinted; dark or grey parts keep more of their own color.
            let sat = max(r, g, b) - min(r, g, b)
            let metal = min(1, sat / 0.12)
            let l = lum(r, g, b) / refL
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
    private static func makeRail(from carriage: CGImage, groove railImage: CGImage) -> CGImage? {
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

    private struct Pixels {
        let data: [UInt8]
        let width: Int
    }

    private static func pixels(_ image: CGImage) -> Pixels? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(data: px, width: w)
    }

    private static func makeImage(_ px: inout [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    /// Makes the body taller: the rows above the slice stay, the slice is stretched, the rows below move down.
    private static func extend(_ image: CGImage) -> CGImage? {
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

    private static func multiply(_ image: CGImage, by f: (CGFloat, CGFloat, CGFloat)) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(image, in: r)
        ctx.setBlendMode(.multiply)
        ctx.setFillColor(CGColor(srgbRed: f.0, green: f.1, blue: f.2, alpha: 1))
        ctx.clip(to: r, mask: image)
        ctx.fill(r)
        return ctx.makeImage()
    }

    private static func image(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
