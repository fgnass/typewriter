import Foundation
import CoreGraphics
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
}

/// Rows of the rail image (origin top left): polished lip, dark recessed groove, then the face,
/// which starts with a fine highlight right below the groove.
enum RailGeometry {
    static let top: CGFloat = 309
    static let grooveTop: CGFloat = 337
    static let grooveBottom: CGFloat = 355
    static let bottom: CGFloat = 413
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

    static var currentID: String {
        get {
            let id = UserDefaults.standard.string(forKey: "hardware") ?? "gold"
            return ids.contains { $0.id == id } ? id : "gold"
        }
        set { UserDefaults.standard.set(newValue, forKey: "hardware") }
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
        let railBand = rail.cropping(to: CGRect(x: 0, y: RailGeometry.top, width: CGFloat(rail.width),
                                                height: RailGeometry.bottom - RailGeometry.top)) ?? rail
        let tintedCarriage = entry.color.map { tint(carriage, to: $0) ?? carriage } ?? carriage
        let tintedRail = entry.color.map { tint(railBand, to: $0) ?? railBand } ?? railBand
        // The front of the carriage faces the viewer and is a little darker than the rail.
        let shaded = multiply(tintedCarriage, by: (0.92, 0.88, 0.9)) ?? tintedCarriage
        let v = HardwareVariant(id: id, title: entry.title,
                                carriage: extend(shaded) ?? shaded,
                                rail: tintedRail,
                                lamp: extend(lamp) ?? lamp, status: extend(status) ?? status, grilleHole: hole)
        cache[id] = v
        return v
    }

    static let paper: CGImage? = directory.flatMap { image($0.appendingPathComponent("paper.png")) }

    /// Mean color of the rose gold metal, the reference for tinting.
    private static let roseGold = (r: 0.86, g: 0.72, b: 0.64)

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
