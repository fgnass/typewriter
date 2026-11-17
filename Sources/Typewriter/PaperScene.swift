import AppKit
import QuartzCore
import CoreText
import CoreImage

/// Sizes and positions, derived from the screen size and the registration data of the hardware variant.
/// All values are in points, y goes up.
struct Metrics {
    let size: CGSize
    let columns: Int
    let font: CTFont
    let charWidth: CGFloat
    let lineHeight: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let left: CGFloat

    /// Points per pixel of the hardware images.
    let assetScale: CGFloat
    /// Height of the housing band at the bottom.
    let bandHeight: CGFloat
    /// Top of the dark guide groove in the band.
    let grooveTopY: CGFloat
    /// Bottom of the visible carriage body, where it stands on the guide.
    let carriageBottomY: CGFloat
    /// Size of the whole carriage image.
    let carriageSize: CGSize
    /// The print point inside the carriage image, from its bottom left corner.
    let printOffset: CGPoint
    /// Height of the print point: the top of the ceramic insert. The light starts here.
    let printY: CGFloat
    let ceramicWidth: CGFloat
    let visibleCarriageWidth: CGFloat
    /// Center of the visible carriage body relative to the print point.
    let carriageCenterOffset: CGFloat

    let baselineY: CGFloat
    /// Bottom of the current line layer.
    let typingY: CGFloat
    /// Baseline inside a line layer.
    let baseline: CGFloat
    let linePadding: CGFloat = 24

    static let fontName = "Courier New" as CFString

    init(size: CGSize, variant v: HardwareVariant, columns: Int = 72) {
        self.size = size
        self.columns = columns
        let targetWidth = min(size.width * 0.6, 1100)
        let probe = CTFontCreateWithName(Metrics.fontName, 100, nil)
        let advance = Metrics.advance(of: probe) / 100
        let fontSize = (targetWidth / CGFloat(columns) / advance).rounded(.down)
        font = CTFontCreateWithName(Metrics.fontName, fontSize, nil)
        charWidth = Metrics.advance(of: font)
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        lineHeight = (fontSize * 1.6).rounded()
        left = ((size.width - CGFloat(columns) * charWidth) / 2).rounded()

        let c = v.carriageReg, r = v.railReg
        visibleCarriageWidth = min(180, max(140, size.width * 0.115))
        assetScale = visibleCarriageWidth / CGFloat((c.right - c.left) * c.width)
        bandHeight = min(85, max(65, (size.height * 0.085).rounded()))
        grooveTopY = bandHeight * (1 - CGFloat((r.grooveTop - r.top) / (r.bottom - r.top)))
        carriageBottomY = bandHeight - 1
        carriageSize = CGSize(width: CGFloat(c.width) * assetScale, height: CGFloat(c.height) * assetScale)
        printOffset = CGPoint(x: CGFloat(c.printX) * carriageSize.width, y: CGFloat(1 - c.printY) * carriageSize.height)
        let bottomOffset = CGFloat(1 - c.bottom) * carriageSize.height
        printY = carriageBottomY + (printOffset.y - bottomOffset)
        ceramicWidth = CGFloat(c.ceramicRight - c.ceramicLeft) * carriageSize.width
        carriageCenterOffset = CGFloat((c.left + c.right) / 2 - c.printX) * carriageSize.width

        // Descenders must not touch the ceramic.
        baselineY = (printY + descent + 3).rounded()
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

    /// Left edge of the character cell at this column.
    func cellX(col: Int) -> CGFloat {
        left + CGFloat(min(col, columns)) * charWidth
    }

    /// The print point is where the next character will appear: the center of the caret cell.
    func printX(caretCol: Int) -> CGFloat {
        cellX(col: caretCol) + charWidth / 2
    }
}

enum Palette {
    static let ink: CGFloat = 0.14
    static var paperBackground: CGColor { CGColor(srgbRed: 0.77, green: 0.78, blue: 0.84, alpha: 1) }
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
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.995, blue: 0.985, alpha: 0.85))
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

/// All layers of the typewriter page, from back to front:
/// paper, text, light (multiplied onto paper and ink), housing band, and the moving head
/// (contact shadow, carriage with ambient shadow, warm reflexes).
final class PaperScene {
    let metrics: Metrics
    let variant: HardwareVariant
    let root = CALayer()
    let textContainer = CALayer()
    let markedLayer = CATextLayer()
    let hintLayer = CATextLayer()
    let noticeLayer = CATextLayer()

    private let paper = CALayer()
    private let light = CALayer()
    private let band = CALayer()
    private let head = CALayer()
    private let carriage = CALayer()
    private let ceramicGlow = CAGradientLayer()
    private let railGlow = CAGradientLayer()
    private let scale: CGFloat
    private var lineLayers: [Int: LineLayer] = [:]
    private var lastCaretLine = 0
    private var lightSettings = LightSettings.current
    private var lightGeneration = 0

    init(metrics m: Metrics, variant: HardwareVariant, scale: CGFloat) {
        metrics = m
        self.variant = variant
        self.scale = scale
        let b = CGRect(origin: .zero, size: m.size)
        root.frame = b
        root.backgroundColor = Palette.paperBackground

        paper.frame = b
        paper.contents = Self.makePaperImage(size: m.size, scale: scale)
        paper.contentsGravity = .resize
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
        // It never brightens, so the ink keeps its contrast.
        light.contents = Self.makeLightImage(metrics: m, settings: lightSettings)
        light.contentsGravity = .resize
        light.anchorPoint = CGPoint(x: 0.5, y: 0)
        light.bounds = CGRect(x: 0, y: 0, width: m.size.width * 2, height: m.size.height - m.bandHeight)
        light.position = CGPoint(x: m.printX(caretCol: 0), y: m.bandHeight)
        light.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
        root.addSublayer(light)

        band.frame = CGRect(x: 0, y: 0, width: m.size.width, height: m.bandHeight)
        band.contents = Self.makeBandImage(variant: variant, metrics: m, scale: scale)
        band.contentsGravity = .resize
        root.addSublayer(band)

        setupHead()

        for t in [hintLayer, noticeLayer] {
            t.font = CTFontCreateWithName(Metrics.fontName, 13, nil)
            t.fontSize = 13
            t.foregroundColor = CGColor(gray: 0.25, alpha: 0.5)
            t.contentsScale = scale
            t.alignmentMode = .center
            root.addSublayer(t)
        }
        hintLayer.frame = CGRect(x: 0, y: m.size.height - 40, width: m.size.width, height: 18)
        noticeLayer.frame = CGRect(x: 0, y: m.size.height - 64, width: m.size.width, height: 18)
        noticeLayer.opacity = 0

        applyLightTint()
    }

    /// The head group. Its origin is the print point, so carriage, shadows, reflexes and the light share one position.
    private func setupHead() {
        let m = metrics
        head.bounds = .zero
        head.position = CGPoint(x: m.printX(caretCol: 0), y: m.printY)
        let carriageFrame = CGRect(x: -m.printOffset.x, y: -m.printOffset.y,
                                   width: m.carriageSize.width, height: m.carriageSize.height)
        let bottom = m.carriageBottomY - m.printY

        // Contact shadow on the guide: narrow, dark and soft.
        let contact = CAGradientLayer()
        contact.type = .radial
        contact.colors = [CGColor(gray: 0, alpha: 0.45), CGColor(gray: 0, alpha: 0.18), CGColor(gray: 0, alpha: 0)]
        contact.locations = [0, 0.6, 1]
        contact.startPoint = CGPoint(x: 0.5, y: 0.5)
        contact.endPoint = CGPoint(x: 1, y: 1)
        contact.bounds = CGRect(x: 0, y: 0, width: m.visibleCarriageWidth * 1.04, height: 5)
        contact.position = CGPoint(x: m.carriageCenterOffset, y: bottom - 0.5)
        head.addSublayer(contact)

        // Faint warm reflex on the guide close to the head.
        railGlow.type = .radial
        railGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        railGlow.endPoint = CGPoint(x: 1, y: 1)
        railGlow.bounds = CGRect(x: 0, y: 0, width: m.visibleCarriageWidth * 1.5, height: 4)
        railGlow.position = CGPoint(x: 0, y: m.grooveTopY - m.printY + 1)
        railGlow.compositingFilter = CIFilter(name: "CIScreenBlendMode")
        head.addSublayer(railGlow)

        // Carriage with a soft ambient shadow, derived from its own contour.
        carriage.contents = variant.carriage
        carriage.contentsGravity = .resize
        carriage.frame = carriageFrame
        carriage.shadowColor = CGColor(gray: 0, alpha: 1)
        carriage.shadowOpacity = 0.14
        carriage.shadowRadius = 4
        carriage.shadowOffset = CGSize(width: 0, height: -2)
        head.addSublayer(carriage)

        // Warm light on the ceramic and the inner edges of the notch, masked to the carriage.
        let glowHost = CALayer()
        glowHost.frame = carriageFrame
        let mask = CALayer()
        mask.contents = variant.carriage
        mask.contentsGravity = .resize
        mask.frame = glowHost.bounds
        glowHost.mask = mask
        ceramicGlow.type = .radial
        ceramicGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        ceramicGlow.endPoint = CGPoint(x: 1, y: 1)
        ceramicGlow.bounds = CGRect(x: 0, y: 0, width: m.ceramicWidth * 1.9, height: m.ceramicWidth * 0.9)
        ceramicGlow.position = CGPoint(x: m.printOffset.x, y: m.printOffset.y + 1)
        glowHost.addSublayer(ceramicGlow)
        glowHost.compositingFilter = CIFilter(name: "CIScreenBlendMode")
        head.addSublayer(glowHost)

        root.addSublayer(head)
    }

    func setHint(_ text: String) { hintLayer.string = text }

    // MARK: Light

    func updateLight(_ settings: LightSettings) {
        guard settings != lightSettings else { return }
        lightSettings = settings
        applyLightTint()
        lightGeneration += 1
        let generation = lightGeneration
        let m = metrics
        DispatchQueue.global(qos: .userInteractive).async {
            let image = Self.makeLightImage(metrics: m, settings: settings)
            DispatchQueue.main.async {
                guard generation == self.lightGeneration else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.light.contents = image
                CATransaction.commit()
            }
        }
    }

    /// The reflexes use the light color and fade out with the brightness.
    private func applyLightTint() {
        let c = lightSettings.color
        let k = min(1, lightSettings.brightness)
        func warm(_ a: Double) -> CGColor { CGColor(srgbRed: c.r, green: c.g * 0.92, blue: c.b * 0.75, alpha: a) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ceramicGlow.colors = [warm(0.5 * k), warm(0.12 * k), warm(0)]
        ceramicGlow.locations = [0, 0.45, 1]
        railGlow.colors = [warm(0.3 * k), warm(0)]
        CATransaction.commit()
    }

    // MARK: Updates

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Moves a layer to a new position. The animation starts from where the layer is on screen right now,
    /// so fast typing never builds up a queue of animations.
    private func move(_ layer: CALayer, to target: CGPoint, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        let from = layer.presentation()?.position ?? layer.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = target
        CATransaction.commit()
        guard duration > 0, from != target else {
            layer.removeAnimation(forKey: "move")
            return
        }
        let a = CABasicAnimation(keyPath: "position")
        a.fromValue = NSValue(point: from)
        a.toValue = NSValue(point: target)
        a.duration = duration
        a.timingFunction = timing
        layer.add(a, forKey: "move")
    }

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
        markedLayer.position = CGPoint(x: m.cellX(col: layout.caretCol), y: m.typingY)
        CATransaction.commit()

        let lineChanged = caretLine != lastCaretLine
        let x = m.printX(caretCol: layout.caretCol)
        let instant = !animated || reduceMotion
        // A short, softly caught glide while typing; a quick return to the line start on a new line.
        let duration: CFTimeInterval = instant ? 0 : (lineChanged ? 0.32 : 0.09)
        let timing = lineChanged ? CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1) : CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        move(head, to: CGPoint(x: x, y: m.printY), duration: duration, timing: timing)
        move(light, to: CGPoint(x: x, y: m.bandHeight), duration: duration, timing: timing)
        move(textContainer, to: CGPoint(x: m.left - m.linePadding, y: m.typingY + CGFloat(caretLine) * m.lineHeight),
             duration: instant ? 0 : (lineChanged ? 0.28 : 0), timing: timing)

        lastCaretLine = caretLine
    }

    // MARK: Images

    /// The paper texture, mirrored at its edges so it can cover any screen without visible seams.
    private static func makePaperImage(size: CGSize, scale: CGFloat) -> CGImage? {
        guard let tile = Hardware.paper else { return nil }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let tw = tile.width, th = tile.height
        for ty in stride(from: 0, to: h, by: th) {
            for tx in stride(from: 0, to: w, by: tw) {
                ctx.saveGState()
                let flipX = (tx / tw) % 2 == 1, flipY = (ty / th) % 2 == 1
                ctx.translateBy(x: CGFloat(tx + (flipX ? tw : 0)), y: CGFloat(ty + (flipY ? th : 0)))
                ctx.scaleBy(x: flipX ? -1 : 1, y: flipY ? -1 : 1)
                ctx.draw(tile, in: CGRect(x: 0, y: 0, width: tw, height: th))
                ctx.restoreGState()
            }
        }
        // Keep only the fiber structure: a neutral white sheet, so the cool ambient light and the warm lamp
        // give the paper its color.
        ctx.setBlendMode(.saturation)
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setBlendMode(.normal)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.7))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The housing band: the whole rail band of the asset (lip, dark groove, brushed surface),
    /// scaled evenly to the band height so it keeps the look of the asset, and stretched to the full width.
    /// The surface is brushed horizontally, so the horizontal stretch does not show.
    private static func makeBandImage(variant v: HardwareVariant, metrics m: Metrics, scale: CGFloat) -> CGImage? {
        let r = v.railReg
        let rail = v.rail
        let w = Int(m.size.width * scale), h = Int(m.bandHeight * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let top = Int((r.top * r.height).rounded()), bottom = Int((r.bottom * r.height).rounded())
        // Skip the transparent crop margin at both ends.
        guard let band = rail.cropping(to: CGRect(x: 8, y: top, width: rail.width - 16, height: bottom - top + 1)) else { return nil }
        ctx.draw(band, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The lighting of the paper, twice as wide as the screen and centered on the print point.
    /// A warm ivory fan opens upward from the print point with soft side edges and a smooth distance
    /// falloff, plus a small bright area right at the print point. Outside the fan the paper gets the
    /// dimmer ambient light. Dithered against banding.
    static func makeLightImage(metrics m: Metrics, settings s: LightSettings) -> CGImage? {
        let step = 1.0
        let W = Double(m.size.width)
        let paperH = Double(m.size.height - m.bandHeight)
        let w = Int(W * 2 / step), h = Int(paperH / step)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var rng = SplitMix64(seed: 7)
        let apexY = Double(m.printY - m.bandHeight)
        let half = s.spread / 2 * .pi / 180
        let soft = max(0.01, s.softness * half)
        let reach = max(1, s.reach * paperH)
        let lc = s.color
        let amb = s.ambient
        // The ambient light is cool lavender, the lamp is warm.
        let ambient = (r: amb * 0.987, g: amb, b: min(1, amb * 1.077))
        func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
            let t = max(0, min(1, (x - e0) / (e1 - e0)))
            return t * t * (3 - 2 * t)
        }
        func mix(_ p: Double, _ q: Double, _ t: Double) -> Double { p + (q - p) * t }
        for row in 0..<h {
            let v = (Double(h - 1 - row) + 0.5) * step - apexY
            for col in 0..<w {
                let u = (Double(col) + 0.5) * step - W
                let d = (u * u + v * v).squareRoot()
                var beam = 0.0
                if v > 0 {
                    let angle = atan2(abs(u), v)
                    // The edge gets softer with distance, like a real penumbra. It is never narrower
                    // than about 2 pt, so it never shows the pixel grid.
                    let edge = max(soft * min(1, 0.25 + d / (0.5 * paperH)), 2 / max(d, 1))
                    beam = 1 - smooth(half - edge, half + edge, angle)
                }
                let falloff = exp(-(d / reach) * (d / reach))
                let hot = 0.35 * exp(-d / 16) * smooth(-8, 2, v)
                let k = min(1, s.brightness * (beam * falloff + hot))
                let i = (row * w + col) * 4
                func q(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x * 255 + (rng.nextUnit() - 0.5) * 1.5))) }
                px[i] = q(mix(ambient.r, lc.r, k))
                px[i + 1] = q(mix(ambient.g, lc.g, k))
                px[i + 2] = q(mix(ambient.b, lc.b, k))
                px[i + 3] = 255
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        return px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
