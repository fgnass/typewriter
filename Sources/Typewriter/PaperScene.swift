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

    /// Height of the housing band at the bottom.
    let bandHeight: CGFloat
    /// Top of the dark guide groove in the band.
    let grooveTopY: CGFloat
    /// The metal block of the carriage.
    let carriageWidth: CGFloat
    let carriageHeight: CGFloat
    let carriageBottomY: CGFloat
    let carriageTopY: CGFloat
    /// The white thermal element that sticks out of the block and covers the cell of the next character.
    let elementWidth: CGFloat
    let elementBottomY: CGFloat
    let elementTopY: CGFloat
    /// Where the lamp light starts: the top of the block, at the element.
    let printY: CGFloat
    let xHeight: CGFloat

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

        let r = v.railReg
        xHeight = CTFontGetXHeight(font)
        let capHeight = CTFontGetCapHeight(font)
        bandHeight = min(85, max(65, (size.height * 0.085).rounded()))
        grooveTopY = bandHeight * (1 - CGFloat((r.grooveTop - r.top) / (r.bottom - r.top)))
        carriageWidth = (charWidth * 7).rounded()
        carriageHeight = (charWidth * 1.6).rounded()
        carriageBottomY = bandHeight - 1
        carriageTopY = carriageBottomY + carriageHeight
        printY = carriageTopY
        // The current line sits right above the block; descenders keep a small gap.
        baselineY = (carriageTopY + descent + 3).rounded()
        baseline = (lineHeight * 0.32).rounded()
        typingY = baselineY - baseline
        // The element covers the whole cell of the next character, from the block up to above the capitals.
        elementWidth = (charWidth + 3).rounded()
        elementBottomY = carriageTopY - 4
        elementTopY = (baselineY + max(capHeight, ascent * 0.8) + 3).rounded()
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
    /// Columns that are not drawn here, because a glyph layer is animating them.
    var hiddenCols: Set<Int> = []

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
        for g in glyphs where !g.char.isWhitespace && !hiddenCols.contains(g.col) {
            draw(g.char, x: x0 + CGFloat(g.col) * m.charWidth, y: y0, alpha: 1, in: ctx)
        }
    }

    private func draw(_ c: Character, x: CGFloat, y: CGFloat, alpha: CGFloat, in ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: Palette.ink, alpha: alpha))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(ctLine(for: c), ctx)
    }
}

/// Prototype of the white ceramic thermal element: a slim upright tab with a rounded top.
final class ThermalElementLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { NSNull() }

    override func draw(in ctx: CGContext) {
        let b = bounds
        let r = min(b.width * 0.35, 4)
        let path = CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // Matte ceramic: slightly darker at the bottom where it enters the block, soft roundness at the sides.
        let vertical = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 0.86, green: 0.85, blue: 0.83, alpha: 1),
            CGColor(srgbRed: 0.96, green: 0.955, blue: 0.94, alpha: 1),
            CGColor(srgbRed: 0.985, green: 0.98, blue: 0.97, alpha: 1),
        ] as CFArray, locations: [0, 0.3, 1])!
        ctx.drawLinearGradient(vertical, start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.maxY), options: [])
        let sides = CGGradient(colorsSpace: cs, colors: [
            CGColor(gray: 0, alpha: 0.12), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.16),
        ] as CFArray, locations: [0, 0.3, 0.7, 1])!
        ctx.drawLinearGradient(sides, start: CGPoint(x: b.minX, y: 0), end: CGPoint(x: b.maxX, y: 0), options: [])
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0.55, alpha: 0.35))
        ctx.setLineWidth(0.5)
        ctx.strokePath()
    }
}

/// Prototype of the metal carriage block: anodized aluminum with a soft vertical shading and polished chamfers.
final class MetalBlockLayer: CALayer {
    var color: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.8, 0.8, 0.8)

    override func action(forKey event: String) -> CAAction? { NSNull() }

    override func draw(in ctx: CGContext) {
        let b = bounds.insetBy(dx: 0.5, dy: 0.5)
        let r: CGFloat = 3
        let path = CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func c(_ f: CGFloat) -> CGColor { CGColor(srgbRed: min(1, color.r * f), green: min(1, color.g * f), blue: min(1, color.b * f), alpha: 1) }
        func lifted(_ t: CGFloat) -> CGColor {
            CGColor(srgbRed: color.r + (1 - color.r) * t, green: color.g + (1 - color.g) * t, blue: color.b + (1 - color.b) * t, alpha: 1)
        }
        ctx.addPath(path)
        ctx.clip()
        let g = CGGradient(colorsSpace: cs, colors: [c(0.78), c(0.92), c(1.02), lifted(0.15)] as CFArray, locations: [0, 0.35, 0.75, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.maxY), options: [])
        // Polished chamfer along the top edge, darker one along the bottom.
        ctx.setFillColor(lifted(0.6))
        ctx.fill(CGRect(x: b.minX, y: b.maxY - 1.2, width: b.width, height: 1.2))
        ctx.setFillColor(c(0.6))
        ctx.fill(CGRect(x: b.minX, y: b.minY, width: b.width, height: 0.8))
    }
}

/// One glyph, drawn exactly like the glyphs of a line, for print and erase animations.
final class GlyphLayer: CALayer {
    var char: Character = " "
    var color = CGColor(gray: 0, alpha: 1)
    var metrics: Metrics!

    override func action(forKey event: String) -> CAAction? { event == "contents" ? NSNull() : super.action(forKey: event) }

    override func draw(in ctx: CGContext) {
        guard let m = metrics else { return }
        ctx.textMatrix = .identity
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): m.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(char), attributes: attrs))
        ctx.textPosition = CGPoint(x: 0, y: m.baseline)
        CTLineDraw(line, ctx)
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
    /// Light of the lamp on the housing band. It moves with the head and is clipped to the band.
    private let bandLight = CALayer()
    private let bandSpill = CAGradientLayer()
    private let lipHighlight = CAGradientLayer()
    private let grooveHighlight = CAGradientLayer()
    private let lampBloom = CAGradientLayer()
    /// Short heat pulse of the ceramic print head when it prints or erases.
    private let heatPulse = CAGradientLayer()
    /// Cells whose glyph is still developing or fading, per line.
    private var animatingCells: [Int: Set<Int>] = [:]
    private var lastLayout: Layout?
    private var lastGhosts: [Ghost] = []
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
        band.masksToBounds = true
        setupBandLight()
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

    /// The head group. Its origin is the print point, so block, element, shadows and the light share one position.
    private func setupHead() {
        let m = metrics
        head.bounds = .zero
        head.position = CGPoint(x: m.printX(caretCol: 0), y: m.printY)
        let bottom = m.carriageBottomY - m.printY

        // Contact shadow on the guide: narrow, dark and soft.
        let contact = CAGradientLayer()
        contact.type = .radial
        contact.colors = [CGColor(gray: 0, alpha: 0.45), CGColor(gray: 0, alpha: 0.18), CGColor(gray: 0, alpha: 0)]
        contact.locations = [0, 0.6, 1]
        contact.startPoint = CGPoint(x: 0.5, y: 0.5)
        contact.endPoint = CGPoint(x: 1, y: 1)
        contact.bounds = CGRect(x: 0, y: 0, width: m.carriageWidth * 1.04, height: 5)
        contact.position = CGPoint(x: 0, y: bottom - 0.5)
        head.addSublayer(contact)

        // The white thermal element. It stands behind the front of the block and covers the next cell.
        let element = ThermalElementLayer()
        element.contentsScale = scale
        element.frame = CGRect(x: -m.elementWidth / 2, y: m.elementBottomY - m.printY,
                               width: m.elementWidth, height: m.elementTopY - m.elementBottomY)
        element.shadowColor = CGColor(gray: 0, alpha: 1)
        element.shadowOpacity = 0.18
        element.shadowRadius = 2.5
        element.shadowOffset = CGSize(width: 1, height: -1)
        element.setNeedsDisplay()
        head.addSublayer(element)

        // The metal block, in the color of the rail.
        let block = MetalBlockLayer()
        block.color = Self.averageColor(of: variant.rail)
        block.contentsScale = scale
        block.frame = CGRect(x: -m.carriageWidth / 2, y: bottom, width: m.carriageWidth, height: m.carriageHeight)
        block.shadowColor = CGColor(gray: 0, alpha: 1)
        block.shadowOpacity = 0.16
        block.shadowRadius = 4
        block.shadowOffset = CGSize(width: 0, height: -2)
        block.setNeedsDisplay()
        head.addSublayer(block)

        root.addSublayer(head)
    }

    /// The mean color of the brushed face of the rail, used for the prototype block.
    private static func averageColor(of image: CGImage) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var px = [UInt8](repeating: 0, count: 4)
        let mid = CGRect(x: image.width / 4, y: image.height / 2, width: image.width / 2, height: 4)
        guard let crop = image.cropping(to: mid),
              let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0.8, 0.8, 0.8) }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (CGFloat(px[0]) / 255, CGFloat(px[1]) / 255, CGFloat(px[2]) / 255)
    }

    func setHint(_ text: String) { hintLayer.string = text }

    private func radial(_ l: CAGradientLayer, width: CGFloat, height: CGFloat) {
        l.type = .radial
        l.startPoint = CGPoint(x: 0.5, y: 0.5)
        l.endPoint = CGPoint(x: 1, y: 1)
        l.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        l.compositingFilter = CIFilter(name: "CIScreenBlendMode")
    }

    /// The lamp also lights its surroundings: a warm spill on the band next to the carriage,
    /// a specular highlight on the polished lip and a thin one on the lower edge of the groove.
    private func setupBandLight() {
        let m = metrics, r = variant.railReg
        func bandY(_ v: Double) -> CGFloat { m.bandHeight * (1 - CGFloat((v - r.top) / (r.bottom - r.top))) }
        let lipY = bandY((r.top + r.grooveTop) / 2)
        let lipHeight = max(2, bandY(r.top) - bandY(r.grooveTop))
        let grooveBottomY = bandY(r.grooveBottom)
        let w = m.carriageWidth
        bandLight.bounds = .zero
        bandLight.position = CGPoint(x: m.printX(caretCol: 0), y: 0)

        radial(bandSpill, width: w * 4.5, height: m.bandHeight * 1.8)
        bandSpill.position = CGPoint(x: 0, y: m.bandHeight)
        radial(lipHighlight, width: w * 6, height: lipHeight * 1.5)
        lipHighlight.position = CGPoint(x: 0, y: lipY)
        radial(grooveHighlight, width: w * 4.5, height: 2.5)
        grooveHighlight.position = CGPoint(x: 0, y: grooveBottomY + 0.5)
        for l in [bandSpill, lipHighlight, grooveHighlight] {
            // Light adds up on metal.
            l.compositingFilter = CIFilter(name: "CIAdditionCompositing")
            bandLight.addSublayer(l)
        }
        band.addSublayer(bandLight)
    }

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
        bandSpill.colors = [warm(0.55 * k), warm(0.18 * k), warm(0)]
        bandSpill.locations = [0, 0.4, 1]
        func white(_ a: Double) -> CGColor { CGColor(srgbRed: 1, green: 0.97 * c.g / max(c.r, 0.01), blue: 0.9 * c.b / max(c.r, 0.01), alpha: a) }
        lipHighlight.colors = [white(min(1, 1.1 * k)), warm(0.4 * k), warm(0)]
        lipHighlight.locations = [0, 0.35, 1]
        grooveHighlight.colors = [white(min(1, 0.95 * k)), warm(0.25 * k), warm(0)]
        lampBloom.colors = [white(0.85 * k), warm(0.35 * k), warm(0)]
        lampBloom.locations = [0, 0.3, 1]
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
        lastLayout = layout
        lastGhosts = allGhosts
        updateLines(layout: layout, ghosts: allGhosts)
        moveHead(layout: layout, animated: animated)
    }

    private func updateLines(layout: Layout, ghosts allGhosts: [Ghost]) {
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
            let hidden = animatingCells[i] ?? []
            h.combine(hidden)
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
                l.hiddenCols = hidden
                l.ghosts = ghosts
                l.signature = sig
                l.setNeedsDisplay()
            }
        }
        markedLayer.position = CGPoint(x: m.cellX(col: layout.caretCol), y: m.typingY)
        CATransaction.commit()
    }

    private func moveHead(layout: Layout, animated: Bool) {
        let m = metrics
        let caretLine = layout.caretLine
        let lineChanged = caretLine != lastCaretLine
        let x = m.printX(caretCol: layout.caretCol)
        let instant = !animated || reduceMotion
        // A short, softly caught glide while typing; a quick return to the line start on a new line.
        let duration: CFTimeInterval = instant ? 0 : (lineChanged ? 0.32 : 0.09)
        let timing = lineChanged ? CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1) : CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        move(head, to: CGPoint(x: x, y: m.printY), duration: duration, timing: timing)
        move(bandLight, to: CGPoint(x: x, y: 0), duration: duration, timing: timing)
        move(light, to: CGPoint(x: x, y: m.bandHeight), duration: duration, timing: timing)
        move(textContainer, to: CGPoint(x: m.left - m.linePadding, y: m.typingY + CGFloat(caretLine) * m.lineHeight),
             duration: instant ? 0 : (lineChanged ? 0.28 : 0), timing: timing)

        lastCaretLine = caretLine
    }

    // MARK: Thermal printing

    /// The ceramic head heats up for a moment.
    private func pulseHeat(strength: Float) {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, strength, strength * 0.35, 0]
        a.keyTimes = [0, 0.15, 0.45, 1]
        a.duration = 0.26
        heatPulse.add(a, forKey: "pulse")
    }

    private func glyphLayer(_ c: Character, color: CGColor) -> GlyphLayer {
        let m = metrics
        let l = GlyphLayer()
        l.char = c
        l.color = color
        l.metrics = m
        l.contentsScale = scale
        l.frame = CGRect(x: 0, y: 0, width: m.charWidth * 1.5, height: m.lineHeight)
        l.setNeedsDisplay()
        return l
    }

    /// The new glyph develops like thermal paper: a soft warm brown first, then sharp and dark.
    func printGlyph(_ c: Character, line: Int, col: Int) {
        guard !c.isWhitespace else { return }
        pulseHeat(strength: 0.9)
        guard !reduceMotion else { return }
        animateCell(line: line, col: col, duration: 0.2) { host in
            let warm = self.glyphLayer(c, color: CGColor(srgbRed: 0.5, green: 0.32, blue: 0.2, alpha: 1))
            let ink = self.glyphLayer(c, color: CGColor(gray: Palette.ink, alpha: 1))
            host.addSublayer(warm)
            host.addSublayer(ink)
            let w = CAKeyframeAnimation(keyPath: "opacity")
            w.values = [0, 0.75, 0]
            w.keyTimes = [0, 0.35, 1]
            w.duration = 0.2
            warm.add(w, forKey: "develop")
            warm.opacity = 0
            let i = CABasicAnimation(keyPath: "opacity")
            i.fromValue = 0
            i.toValue = 1
            i.beginTime = CACurrentMediaTime() + 0.03
            i.duration = 0.17
            i.fillMode = .backwards
            i.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ink.add(i, forKey: "develop")
        }
    }

    /// A deleted glyph fades out while the head heats up again.
    func eraseGlyph(_ c: Character, line: Int, col: Int) {
        guard !c.isWhitespace else { return }
        pulseHeat(strength: 0.6)
        guard !reduceMotion else { return }
        animateCell(line: line, col: col, duration: 0.16, keepHidden: false) { host in
            let ink = self.glyphLayer(c, color: CGColor(gray: Palette.ink, alpha: 1))
            host.addSublayer(ink)
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0
            a.duration = 0.16
            ink.add(a, forKey: "erase")
            ink.opacity = 0
        }
    }

    /// Runs an animation in one character cell. While it runs, the line layer does not draw that cell.
    private func animateCell(line: Int, col: Int, duration: CFTimeInterval, keepHidden: Bool = true, _ build: (CALayer) -> Void) {
        guard let lineLayer = lineLayers[line] else { return }
        let m = metrics
        let host = CALayer()
        host.anchorPoint = .zero
        host.bounds = CGRect(x: 0, y: 0, width: m.charWidth * 1.5, height: m.lineHeight)
        host.position = CGPoint(x: m.linePadding + CGFloat(col) * m.charWidth, y: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineLayer.addSublayer(host)
        build(host)
        CATransaction.commit()
        if keepHidden {
            animatingCells[line, default: []].insert(col)
            refreshLines()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if keepHidden {
                self.animatingCells[line]?.remove(col)
                self.refreshLines()
            }
            host.removeFromSuperlayer()
            CATransaction.commit()
        }
    }

    private func refreshLines() {
        guard let layout = lastLayout else { return }
        updateLines(layout: layout, ghosts: lastGhosts)
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
        let cw = Double(m.charWidth)
        let poolY = Double(m.baselineY + m.xHeight / 2 - m.printY)
        let poolW = cw * 1.6, poolH = Double(m.lineHeight) * 0.9
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
                // A focused pool of light on the freshly printed character, one cell left of the element.
                let pu = u + cw, pv = v - poolY
                let pool = 0.55 * exp(-(pu * pu) / (2 * poolW * poolW) - (pv * pv) / (2 * poolH * poolH))
                let k = min(1, s.brightness * (beam * falloff + pool))
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
