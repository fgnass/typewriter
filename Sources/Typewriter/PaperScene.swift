import AppKit
import QuartzCore
import CoreText
import CoreImage

/// Sizes and positions, all derived from the screen size.
struct Metrics {
    let size: CGSize
    let columns: Int
    let font: CTFont
    let charWidth: CGFloat
    let lineHeight: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let capHeight: CGFloat
    let left: CGFloat
    let rodY: CGFloat
    let rodHeight: CGFloat = 6
    let carriageWidth: CGFloat
    let carriageHeight: CGFloat
    /// Baseline of the current line, in screen coordinates.
    let baselineY: CGFloat
    /// Top of the T-shaped lamp, where the light comes from.
    let lampY: CGFloat
    /// Bottom of the current line layer.
    let typingY: CGFloat
    /// Baseline inside a line layer.
    let baseline: CGFloat
    let linePadding: CGFloat = 24

    static let fontName = "Courier New" as CFString

    init(size: CGSize, columns: Int = 72) {
        self.size = size
        self.columns = columns
        let targetWidth = min(size.width * 0.62, 1150)
        let probe = CTFontCreateWithName(Metrics.fontName, 100, nil)
        let advance = Metrics.advance(of: probe) / 100
        let fontSize = (targetWidth / CGFloat(columns) / advance).rounded(.down)
        font = CTFontCreateWithName(Metrics.fontName, fontSize, nil)
        charWidth = Metrics.advance(of: font)
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        capHeight = CTFontGetCapHeight(font)
        lineHeight = (fontSize * 1.6).rounded()
        left = ((size.width - CGFloat(columns) * charWidth) / 2).rounded()
        rodY = (size.height * 0.14).rounded()
        carriageWidth = (charWidth * 7.4).rounded()
        carriageHeight = (charWidth * 1.55).rounded()
        baselineY = rodY + carriageHeight / 2 + 3
        lampY = baselineY + capHeight.rounded()
        baseline = (lineHeight * 0.32).rounded()
        typingY = baselineY - baseline
    }

    private static func advance(of font: CTFont) -> CGFloat {
        var ch: UniChar = 0x4D // "M"
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &adv, 1)
        return adv.width
    }

    /// Center of the character cell at this column.
    func printX(col: Int) -> CGFloat {
        left + CGFloat(min(col, columns)) * charWidth + charWidth / 2
    }
}

enum Palette {
    /// The paper itself. The lighting layer gives it its final color.
    static let paperAlbedo: CGFloat = 1.0
    static let ink: CGFloat = 0.24
    /// Paper color outside the light.
    static let ambient: (r: Double, g: Double, b: Double) = (0.77, 0.78, 0.84)
    /// Paper color in the full light of the lamp.
    static let lamp: (r: Double, g: Double, b: Double) = (0.985, 0.958, 0.885)
    static var paperBackground: CGColor {
        CGColor(srgbRed: paperAlbedo * ambient.r, green: paperAlbedo * ambient.g, blue: paperAlbedo * ambient.b, alpha: 1)
    }
}

/// Draws the glyphs (and correction traces) of one line of paper.
final class LineLayer: CALayer {
    var metrics: Metrics!
    var glyphs: [PlacedGlyph] = []
    var ghosts: [Ghost] = []
    var signature = 0

    private static var lineCache: [Character: CTLine] = [:]
    private static var cachedFont: CTFont?

    override func action(forKey event: String) -> CAAction? { NSNull() }

    private func ctLine(for c: Character) -> CTLine {
        if LineLayer.cachedFont !== metrics.font {
            LineLayer.lineCache.removeAll()
            LineLayer.cachedFont = metrics.font
        }
        if let l = LineLayer.lineCache[c] { return l }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): metrics.font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: String(c), attributes: attrs))
        LineLayer.lineCache[c] = l
        return l
    }

    override func draw(in ctx: CGContext) {
        guard let m = metrics else { return }
        ctx.textMatrix = .identity
        let x0 = m.linePadding
        let y0 = m.baseline

        // Correction tape: the cover is a bit whiter than the paper, with a faint ghost of the old letter.
        for g in ghosts {
            let x = x0 + CGFloat(g.col) * m.charWidth
            let rect = CGRect(x: x - 0.5, y: y0 - m.descent * 0.7, width: m.charWidth + 1, height: m.ascent * 0.95 + m.descent * 0.7)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
            ctx.fill(rect)
            draw(g.char, x: x, y: y0, alpha: 0.07, in: ctx)
        }
        for g in glyphs where !g.char.isWhitespace {
            draw(g.char, x: x0 + CGFloat(g.col) * m.charWidth, y: y0, alpha: 1, in: ctx)
        }
    }

    private func draw(_ c: Character, x: CGFloat, y: CGFloat, alpha: CGFloat, in ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: Palette.ink, alpha: alpha))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(ctLine(for: c), ctx)
    }
}

/// All layers of the typewriter page: paper, text, lighting, rod and carriage.
final class PaperScene {
    let metrics: Metrics
    let root = CALayer()
    let textContainer = CALayer()
    let markedLayer = CATextLayer()
    let hintLayer = CATextLayer()
    let noticeLayer = CATextLayer()

    private let paper = CALayer()
    private let light = CALayer()
    private let rod = CAGradientLayer()
    private let carriage = CALayer()
    private let scale: CGFloat
    private var lineLayers: [Int: LineLayer] = [:]
    private var lastCaretLine = 0

    init(metrics m: Metrics, scale: CGFloat) {
        metrics = m
        self.scale = scale
        let b = CGRect(origin: .zero, size: m.size)
        root.frame = b
        root.backgroundColor = Palette.paperBackground

        paper.frame = b
        paper.contents = Self.makePaperImage(width: Int(m.size.width), height: Int(m.size.height))
        paper.contentsGravity = .resize
        paper.magnificationFilter = .nearest
        root.addSublayer(paper)

        textContainer.anchorPoint = .zero
        textContainer.bounds = .zero
        textContainer.position = CGPoint(x: m.left - m.linePadding, y: m.typingY)
        root.addSublayer(textContainer)

        markedLayer.font = m.font
        markedLayer.fontSize = CTFontGetSize(m.font)
        markedLayer.foregroundColor = CGColor(gray: Palette.ink, alpha: 0.4)
        markedLayer.contentsScale = scale
        markedLayer.anchorPoint = .zero
        markedLayer.bounds = CGRect(x: 0, y: 0, width: m.charWidth * 4, height: m.lineHeight)
        root.addSublayer(markedLayer)

        // The light falls on paper and ink alike, so it multiplies everything below it.
        light.contents = Self.makeLightImage(metrics: m)
        light.contentsGravity = .resize
        light.magnificationFilter = .linear
        light.anchorPoint = CGPoint(x: 0.5, y: 0)
        light.bounds = CGRect(x: 0, y: 0, width: m.size.width * 2, height: m.size.height)
        light.position = CGPoint(x: m.printX(col: 0), y: 0)
        light.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
        root.addSublayer(light)

        // A chrome rod.
        // Chrome: dark lower edge, a bright reflection of the paper above the middle, a sharp highlight line.
        rod.colors = [0.16, 0.26, 0.4, 0.3, 0.55, 0.82, 0.5, 0.28].map { CGColor(gray: $0, alpha: 1) }
        rod.locations = [0, 0.18, 0.38, 0.5, 0.62, 0.74, 0.86, 1]
        rod.startPoint = CGPoint(x: 0.5, y: 0)
        rod.endPoint = CGPoint(x: 0.5, y: 1)
        rod.frame = CGRect(x: 0, y: m.rodY - m.rodHeight / 2, width: m.size.width, height: m.rodHeight)
        rod.shadowColor = CGColor(gray: 0, alpha: 1)
        rod.shadowOpacity = 0.22
        rod.shadowRadius = 1.5
        rod.shadowOffset = CGSize(width: 0, height: -1.5)
        root.addSublayer(rod)

        setupCarriage()

        for t in [hintLayer, noticeLayer] {
            t.font = CTFontCreateWithName(Metrics.fontName, 13, nil)
            t.fontSize = 13
            t.foregroundColor = CGColor(gray: 0.2, alpha: 0.45)
            t.contentsScale = scale
            t.alignmentMode = .center
            root.addSublayer(t)
        }
        hintLayer.frame = CGRect(x: 0, y: m.rodY / 2 - 9, width: m.size.width, height: 18)
        noticeLayer.frame = CGRect(x: 0, y: m.size.height - 60, width: m.size.width, height: 18)
        noticeLayer.opacity = 0
    }

    /// A small white glossy carriage with a dark T-shaped lamp at the print position.
    private func setupCarriage() {
        let m = metrics
        let w = m.carriageWidth, h = m.carriageHeight
        let pad: CGFloat = 5
        carriage.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        carriage.anchorPoint = CGPoint(x: Self.carriageAnchorX, y: 0.5)
        carriage.position = CGPoint(x: m.printX(col: 0), y: m.rodY)

        let body = CarriageBodyLayer()
        body.frame = carriage.bounds.insetBy(dx: -pad, dy: -pad)
        body.pad = pad
        body.contentsScale = scale
        body.setNeedsDisplay()
        carriage.addSublayer(body)

        // The lamp: a slim dark T standing on the carriage.
        let color = CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
        let stroke: CGFloat = 1.5
        let x = w * Self.carriageAnchorX
        let top = m.lampY - (m.rodY - h / 2)
        let stem = CALayer()
        stem.backgroundColor = color
        stem.frame = CGRect(x: x - stroke / 2, y: h - 1, width: stroke, height: top - h + 1)
        carriage.addSublayer(stem)
        let bar = CALayer()
        bar.backgroundColor = color
        let barWidth = (m.charWidth * 0.95).rounded()
        bar.frame = CGRect(x: x - barWidth / 2, y: top - stroke, width: barWidth, height: stroke)
        carriage.addSublayer(bar)

        root.addSublayer(carriage)
    }

    /// The lamp, and with it the print position, is in the middle of the carriage.
    private static let carriageAnchorX: CGFloat = 0.5

    func setHint(_ text: String) { hintLayer.string = text }

    // MARK: Updates

    func update(layout: Layout, ghosts allGhosts: [Ghost], animated: Bool) {
        let m = metrics
        let caretLine = layout.caretLine
        let visibleLines = Int((m.size.height - m.typingY) / m.lineHeight) + 2
        let firstVisible = max(0, caretLine - visibleLines)
        let lastLine = max(caretLine, allGhosts.map(\.line).max() ?? -1)

        var ghostsByLine: [Int: [Ghost]] = [:]
        for g in allGhosts where g.line >= firstVisible { ghostsByLine[g.line, default: []].append(g) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in lineLayers where i < firstVisible || i > lastLine {
            l.removeFromSuperlayer()
            lineLayers[i] = nil
        }
        for i in firstVisible...lastLine {
            let glyphs = i < layout.lines.count ? layout.lines[i] : []
            let ghosts = ghostsByLine[i] ?? []
            var h = Hasher()
            h.combine(glyphs)
            h.combine(ghosts)
            let sig = h.finalize()
            let l: LineLayer
            if let existing = lineLayers[i] {
                l = existing
            } else {
                l = LineLayer()
                l.metrics = m
                l.contentsScale = scale
                l.anchorPoint = .zero
                l.bounds = CGRect(x: 0, y: 0, width: CGFloat(m.columns + 2) * m.charWidth + m.linePadding * 2, height: m.lineHeight)
                l.signature = ~sig
                textContainer.addSublayer(l)
                lineLayers[i] = l
            }
            l.position = CGPoint(x: 0, y: -CGFloat(i) * m.lineHeight)
            if l.signature != sig {
                l.glyphs = glyphs
                l.ghosts = ghosts
                l.signature = sig
                l.setNeedsDisplay()
            }
        }
        CATransaction.commit()

        let lineChanged = caretLine != lastCaretLine
        let x = m.printX(col: layout.caretCol)

        // The lamp sits on the carriage, so the light moves together with it.
        CATransaction.begin()
        if !animated {
            CATransaction.setDisableActions(true)
        } else if lineChanged {
            CATransaction.setAnimationDuration(0.38)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1))
        } else {
            CATransaction.setAnimationDuration(0.06)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        carriage.position = CGPoint(x: x, y: carriage.position.y)
        light.position = CGPoint(x: x, y: light.position.y)
        textContainer.position = CGPoint(x: textContainer.position.x, y: m.typingY + CGFloat(caretLine) * m.lineHeight)
        markedLayer.position = CGPoint(x: x - m.charWidth / 2, y: m.typingY)
        CATransaction.commit()

        lastCaretLine = caretLine
    }

    // MARK: Images

    private static func makePaperImage(width w: Int, height h: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var rng = SplitMix64(seed: 42)
        let base = Double(Palette.paperAlbedo) - 0.008
        for i in 0..<(w * h) {
            let v = UInt8(max(0, min(255, (base + (rng.nextUnit() - 0.5) * 0.012) * 255)))
            px[i * 4] = v
            px[i * 4 + 1] = v
            px[i * 4 + 2] = v
            px[i * 4 + 3] = 255
        }
        return makeImage(&px, w, h)
    }

    /// The lighting of the page, twice as wide as the screen and centered on the lamp.
    /// Values are measured from the reference: a very wide beam (the sides are only about 15° above
    /// the rod), full strength right at the carriage, and a smooth falloff with the distance to the lamp
    /// that reaches over the whole page. Outside the beam the paper gets only the cool ambient light,
    /// which leaves flat shadow wedges left and right of the carriage.
    private static func makeLightImage(metrics m: Metrics) -> CGImage? {
        let step = 2.0
        let W = Double(m.size.width), H = Double(m.size.height)
        let w = Int(W * 2 / step), h = Int(H / step)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var rng = SplitMix64(seed: 7)
        let floorY = Double(m.rodY + m.rodHeight / 2)
        let amb = Palette.ambient
        let peak = Palette.lamp
        let half = 75.0 * .pi / 180
        // The virtual apex lies below the carriage, so the beam is as wide as the carriage where it leaves it.
        let apexY = Double(m.rodY + m.carriageHeight / 2) - Double(m.carriageWidth / 2) / tan(half)
        let soft = 0.1
        let reach = 0.7 * H
        func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
            let t = max(0, min(1, (x - e0) / (e1 - e0)))
            return t * t * (3 - 2 * t)
        }
        func mix(_ p: Double, _ q: Double, _ t: Double) -> Double { p + (q - p) * t }
        for row in 0..<h {
            let y = (Double(h - 1 - row) + 0.5) * step
            let v = y - apexY
            for col in 0..<w {
                let u = (Double(col) + 0.5) * step - W
                var lit = 0.0
                if y >= floorY {
                    let d = (u * u + v * v).squareRoot()
                    let angle = atan2(abs(u), v)
                    // The edge gets softer with distance, like a real penumbra.
                    let s = soft * min(1, 0.25 + d / (0.5 * H))
                    let beam = 1 - smooth(half - s, half + s, angle)
                    let falloff = exp(-(d / reach) * (d / reach))
                    lit = beam * falloff
                }
                let i = (row * w + col) * 4
                func q(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x * 255 + (rng.nextUnit() - 0.5) * 1.5))) }
                px[i] = q(mix(amb.r, peak.r, lit))
                px[i + 1] = q(mix(amb.g, peak.g, lit))
                px[i + 2] = q(mix(amb.b, peak.b, lit))
                px[i + 3] = 255
            }
        }
        return makeImage(&px, w, h)
    }

    private static func makeImage(_ px: inout [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }
}

/// The carriage body: an opaque white pill with a soft gloss and two small dots.
final class CarriageBodyLayer: CALayer {
    var pad: CGFloat = 5

    override func action(forKey event: String) -> CAAction? { NSNull() }

    override func draw(in ctx: CGContext) {
        let b = bounds.insetBy(dx: pad, dy: pad)
        let r = b.height / 2
        let path = CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
            CGGradient(colorsSpace: cs, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
        }

        // Contact shadow on the paper.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // White lacquer, slightly shaded at the bottom.
        ctx.drawLinearGradient(gradient([
            (0, CGColor(gray: 0.86, alpha: 1)),
            (0.35, CGColor(gray: 0.95, alpha: 1)),
            (0.7, CGColor(gray: 0.99, alpha: 1)),
            (1, CGColor(gray: 1, alpha: 1)),
        ]), start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.maxY), options: [])
        // Soft gloss on the upper half.
        let gloss = CGRect(x: b.minX + r * 0.6, y: b.midY + 0.5, width: b.width - r * 1.2, height: b.height / 2 - 1.5)
        ctx.addPath(CGPath(roundedRect: gloss, cornerWidth: gloss.height / 2, cornerHeight: gloss.height / 2, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(gradient([
            (0, CGColor(gray: 1, alpha: 0)),
            (1, CGColor(gray: 1, alpha: 0.9)),
        ]), start: CGPoint(x: 0, y: gloss.minY), end: CGPoint(x: 0, y: gloss.maxY), options: [])
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.22))
        ctx.setLineWidth(0.5)
        ctx.strokePath()

        // Two small dots.
        let d = max(2.5, (b.height * 0.18).rounded())
        let cy = b.midY - 0.5
        for (fx, gray) in [(0.36, 0.72), (0.47, 0.22)] as [(CGFloat, CGFloat)] {
            let dot = CGRect(x: b.minX + b.width * fx - d / 2, y: cy - d / 2, width: d, height: d)
            ctx.addEllipse(in: dot)
            ctx.setFillColor(CGColor(gray: gray, alpha: 1))
            ctx.fillPath()
        }
    }
}
