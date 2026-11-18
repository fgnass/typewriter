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
    /// Points per pixel of the rail image. The rail is drawn larger than the carriage image scale.
    let railScale: CGFloat
    /// Height of the rail band at the bottom of the screen, and of its three parts.
    let bandHeight: CGFloat
    let lipHeight: CGFloat
    let grooveHeight: CGFloat
    let faceHeight: CGFloat
    /// Top of the dark guide groove in the rail.
    let grooveTopY: CGFloat
    /// The carriage image, relative to the print point (fin center, top of the body).
    let carriageFrame: CGRect
    let carriageBottomY: CGFloat
    let carriageWidth: CGFloat
    /// Center of the long body relative to the print point.
    let carriageCenterOffset: CGFloat
    /// Height of the print point: the top edge of the long body. The lamp strip sits here.
    let printY: CGFloat
    /// Center of the lamp strip relative to the print point.
    let lampOffsetX: CGFloat
    /// Half length of the lamp strip.
    let lampHalfLength: CGFloat
    let xHeight: CGFloat

    let baselineY: CGFloat
    /// Bottom of the current line layer.
    let typingY: CGFloat
    /// Baseline inside a line layer.
    let baseline: CGFloat
    let linePadding: CGFloat = 24

    /// Drafting* Mono (SIL Open Font License), bundled in Resources/Fonts.
    static let fontName: CFString = {
        if let url = Bundle.main.url(forResource: "DraftingMono-Regular", withExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return "DraftingMono-Regular" as CFString
    }()

    init(size: CGSize, columns: Int = 72) {
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

        typealias C = CarriageGeometry
        typealias R = RailGeometry
        xHeight = CTFontGetXHeight(font)
        // The fin covers exactly one character cell; everything else follows from that scale.
        assetScale = (charWidth + 2) / (C.finRight - C.finLeft)
        let s = assetScale
        // The carriage stands in front of the rail: its lower edge reaches down to the bottom of the groove,
        // and the top of the rail lip meets the body a little above its middle.
        // Proportions measured from the approved design, relative to the body height: the rail lip is
        // 0.45, the dark groove 0.19 and the face below it 0.75 body heights. The body reaches 72 % down
        // into the groove.
        // The rail proportions refer to the original body height; the body itself is taller now and
        // reaches down over the groove onto the face of the rail.
        let originalBodyHeight = (C.bodyBottom - C.bodyExtension - C.bodyTop) * s
        let bodyHeight = (C.bodyBottom - C.bodyTop) * s
        lipHeight = (originalBodyHeight * 0.55).rounded()
        grooveHeight = (originalBodyHeight * 0.3).rounded()
        faceHeight = (originalBodyHeight * 0.85).rounded()
        railScale = lipHeight / (R.grooveTop - R.top)
        bandHeight = lipHeight + grooveHeight + faceHeight
        grooveTopY = faceHeight + grooveHeight
        carriageBottomY = faceHeight + grooveHeight * 0.28 - C.bodyExtension * s + C.raise * s
        printY = carriageBottomY + bodyHeight
        carriageFrame = CGRect(x: -C.finCenter * s, y: -(C.canvas.height - C.bodyTop) * s,
                               width: C.canvas.width * s, height: C.canvas.height * s)
        carriageWidth = (C.bodyRight - C.bodyLeft) * s
        carriageCenterOffset = ((C.bodyLeft + C.bodyRight) / 2 - C.finCenter) * s
        // One continuous lamp strip along the whole body; the fin stands in front of it.
        lampOffsetX = ((C.lampStart.x + C.rightLampEnd) / 2 - C.finCenter) * s
        lampHalfLength = (C.rightLampEnd - C.lampStart.x) / 2 * s
        // The current line sits as low as possible: the fin covers its cell up to the top of an "Ä",
        // and the descenders keep some air above the body.
        let finTopY = printY + (C.bodyTop - C.finTop) * s
        let tallest = Metrics.top(of: "\u{C4}", in: font)
        baselineY = max(finTopY - tallest - 1.5, printY + descent + 2).rounded()
        baseline = (lineHeight * 0.32).rounded()
        typingY = baselineY - baseline
    }

    /// Height of a glyph above the baseline.
    private static func top(of character: String, in font: CTFont) -> CGFloat {
        var ch = Array(character.utf16)
        var glyph = [CGGlyph](repeating: 0, count: ch.count)
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, ch.count)
        return CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyph, nil, 1).maxY
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
    /// The fin is 2 pt wider than a cell, so the carriage sits 1.5 pt further right: the fin then starts
    /// half a point behind the last written character and never covers it.
    func printX(caretCol: Int) -> CGFloat {
        cellX(col: caretCol) + charWidth / 2 + 1.5
    }
}

/// What is around the text: a full screen of paper, or the desktop picture with a strip of paper
/// that comes out of the carriage and grows with the text.
enum PageStyle: String, CaseIterable {
    case paper, desktop

    static let didChange = Notification.Name("PageStyleDidChange")

    static var current: PageStyle {
        get { PageStyle(rawValue: UserDefaults.standard.string(forKey: "pageStyle") ?? "") ?? .paper }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "pageStyle")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    var title: String {
        switch self {
        case .paper: return "Paper"
        case .desktop: return "Desktop"
        }
    }
}

enum Palette {
    static let ink: CGFloat = 0.14
    static var paperBackground: CGColor { CGColor(srgbRed: 0.745, green: 0.715, blue: 0.79, alpha: 1) }
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
    private let style = PageStyle.current
    /// Desktop style: the desktop picture, the visible part of the paper and its shadow.
    /// The desktop lies over the full page and its light, with a hole in the shape of the paper strip.
    /// So the lamp lights only the paper, and the paper looks exactly as in the paper style.
    private let desktop = CALayer()
    private let wallpaper = CALayer()
    private let paperShadow = CALayer()
    /// The part of the hole mask above the paper; it moves with the top edge.
    private let holeTop = CALayer()
    /// The top edge of the sheet: a fine bright rim and a soft shade below it.
    private let paperEdge = CAGradientLayer()
    /// Layers whose top-left corner follows the top edge of the paper.
    private var paperTopLayers: [CALayer] { [holeTop, paperShadow, paperEdge] }
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
    private let lampLayer = CALayer()
    private let statusLayer = CALayer()
    /// A green light over the status dot while Caps Lock is on.
    private let capsLayer = CALayer()
    private var lampStrip: CALayer?
    private var lampEdges: [CAGradientLayer] = []
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
        if style == .desktop { setupDesktop() }
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
        // A quick coarse light first, so the page opens at once; the fine version follows in the background.
        light.contents = Self.makeLightImage(metrics: m, settings: lightSettings, step: 3)
        light.contentsGravity = .resize
        light.anchorPoint = CGPoint(x: 0.5, y: 0)
        light.bounds = CGRect(x: 0, y: 0, width: m.size.width * 2, height: m.size.height - m.bandHeight)
        light.position = CGPoint(x: m.printX(caretCol: 0), y: m.bandHeight)
        if style == .desktop { root.addSublayer(paperEdge) }
        light.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
        root.addSublayer(light)
        if style == .desktop { root.addSublayer(desktop) }

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
        if style == .desktop {
            hintLayer.foregroundColor = CGColor(gray: 1, alpha: 0.55)
            noticeLayer.foregroundColor = CGColor(gray: 1, alpha: 0.55)
        }
        hintLayer.frame = CGRect(x: 0, y: m.size.height - 40, width: m.size.width, height: 18)
        noticeLayer.frame = CGRect(x: 0, y: m.size.height - 64, width: m.size.width, height: 18)
        noticeLayer.opacity = 0

        applyLightTint()
        renderLight(lightSettings)
    }

    // MARK: Desktop style

    /// Margin of the paper strip left and right of the text, and above the first line.
    private var paperSideMargin: CGFloat { metrics.charWidth * 6 }
    private var paperTopMargin: CGFloat { metrics.lineHeight * 1.2 }

    private func setupDesktop() {
        let m = metrics
        let b = CGRect(origin: .zero, size: m.size)
        // The picture is far away: the lamp does not reach it, only the cool evening light.
        desktop.frame = b
        desktop.backgroundColor = CGColor(gray: 0, alpha: 1)
        wallpaper.frame = b
        wallpaper.contentsGravity = .resizeAspectFill
        wallpaper.masksToBounds = true
        wallpaper.opacity = 0.62
        desktop.addSublayer(wallpaper)
        let dusk = CALayer()
        dusk.frame = b
        dusk.backgroundColor = Palette.paperBackground
        dusk.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
        desktop.addSublayer(dusk)
        let size = m.size, scale = self.scale
        DispatchQueue.global(qos: .userInitiated).async {
            let image = Self.makeWallpaperImage(size: size, scale: scale)
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.wallpaper.contents = image
                CATransaction.commit()
            }
        }

        // The hole: everything except the strip. Left and right parts are fixed, the top part moves.
        let stripX = m.left - paperSideMargin
        let stripWidth = CGFloat(m.columns) * m.charWidth + paperSideMargin * 2
        let top = paperTop(caretLine: 0)
        let hole = CALayer()
        hole.frame = b
        let left = CALayer(), right = CALayer()
        left.frame = CGRect(x: 0, y: 0, width: stripX, height: m.size.height)
        right.frame = CGRect(x: stripX + stripWidth, y: 0, width: m.size.width - stripX - stripWidth, height: m.size.height)
        holeTop.anchorPoint = .zero
        holeTop.bounds = CGRect(x: 0, y: 0, width: stripWidth, height: m.size.height)
        holeTop.position = CGPoint(x: stripX, y: top)
        for l in [left, right, holeTop] {
            l.backgroundColor = CGColor(gray: 0, alpha: 1)
            hole.addSublayer(l)
        }
        desktop.mask = hole

        // The shadow of the sheet falls on the desktop; the strip reaches far below the screen.
        let strip = CGRect(x: 0, y: 0, width: stripWidth, height: m.size.height * 2)
        paperShadow.anchorPoint = CGPoint(x: 0, y: 1)
        paperShadow.bounds = strip
        paperShadow.position = CGPoint(x: stripX, y: top)
        paperShadow.shadowPath = CGPath(rect: strip, transform: nil)
        paperShadow.shadowColor = CGColor(gray: 0, alpha: 1)
        paperShadow.shadowOpacity = 0.5
        paperShadow.shadowRadius = 18
        paperShadow.shadowOffset = CGSize(width: 0, height: -4)
        desktop.addSublayer(paperShadow)

        // Only the top 10 pt of the paper: a bright rim, then a faint shade.
        paperEdge.anchorPoint = CGPoint(x: 0, y: 1)
        paperEdge.bounds = CGRect(x: 0, y: 0, width: stripWidth, height: 10)
        paperEdge.position = CGPoint(x: stripX, y: top)
        paperEdge.colors = [CGColor(gray: 1, alpha: 0.45), CGColor(gray: 1, alpha: 0), CGColor(gray: 0, alpha: 0.05), CGColor(gray: 0, alpha: 0)]
        paperEdge.locations = [0, 0.12, 0.3, 1]
        paperEdge.startPoint = CGPoint(x: 0.5, y: 1)
        paperEdge.endPoint = CGPoint(x: 0.5, y: 0)
    }

    /// Top edge of the paper strip: some air above the first line.
    private func paperTop(caretLine: Int) -> CGFloat {
        metrics.typingY + CGFloat(caretLine + 1) * metrics.lineHeight + paperTopMargin
    }

    /// The desktop picture of the main screen, filled to the screen size and a little less colorful.
    /// Dynamic pictures and the moving aerials give their still image here.
    private static func makeWallpaperImage(size: CGSize, scale: CGFloat) -> CGImage? {
        guard let screen = NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * scale),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let ci = CIImage(cgImage: image)
        guard let f = CIFilter(name: "CIColorControls") else { return image }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(0.7, forKey: kCIInputSaturationKey)
        guard let out = f.outputImage else { return image }
        return CIContext().createCGImage(out, from: ci.extent) ?? image
    }

    /// Renders the light in full resolution in the background and shows it when it is ready.
    private func renderLight(_ settings: LightSettings) {
        lightGeneration += 1
        let generation = lightGeneration
        let m = metrics
        DispatchQueue.global(qos: .userInitiated).async {
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

    /// The head group. Its origin is the print point (center of the fin, top of the body),
    /// so carriage, overlays, shadows and the light share one position.
    private func setupHead() {
        let m = metrics
        head.bounds = .zero
        head.position = CGPoint(x: m.printX(caretCol: 0), y: m.printY)
        let bottom = m.carriageBottomY - m.printY

        // Contact shadow on the rail: narrow, dark and soft.
        let contact = CAGradientLayer()
        contact.type = .radial
        contact.colors = [CGColor(gray: 0, alpha: 0.55), CGColor(gray: 0, alpha: 0.22), CGColor(gray: 0, alpha: 0)]
        contact.locations = [0, 0.6, 1]
        contact.startPoint = CGPoint(x: 0.5, y: 0.5)
        contact.endPoint = CGPoint(x: 1, y: 1)
        contact.bounds = CGRect(x: 0, y: 0, width: m.carriageWidth * 1.06, height: 8)
        contact.position = CGPoint(x: m.carriageCenterOffset, y: bottom - 0.5)
        head.addSublayer(contact)

        func layer(_ image: CGImage) -> CALayer {
            let l = CALayer()
            l.contents = image
            l.contentsGravity = .resize
            l.frame = m.carriageFrame
            return l
        }

        // The carriage with a soft ambient shadow from its own contour.
        let body = layer(variant.carriage)
        body.shadowColor = CGColor(gray: 0, alpha: 1)
        // The room light comes from the upper left, so the shadow falls to the lower right.
        body.shadowOpacity = 0.38
        body.shadowRadius = 5
        body.shadowOffset = CGSize(width: 2.5, height: -2.5)
        head.addSublayer(body)
        head.addSublayer(makeGrille())

        // Light layers: the lamp strip follows the brightness, the status light flashes when a character is made.
        lampLayer.contents = variant.lamp
        lampLayer.contentsGravity = .resize
        lampLayer.frame = m.carriageFrame
        // A soft bloom around the strip, so the lamp reads as bright light and not as a thin line.
        lampLayer.shadowColor = CGColor(srgbRed: 1, green: 0.82, blue: 0.55, alpha: 1)
        lampLayer.shadowOpacity = 1
        lampLayer.shadowRadius = 5
        lampLayer.shadowOffset = CGSize(width: 0, height: 1.5)
        head.addSublayer(lampLayer)
        // The glowing edge of the lamp strip along the top of the body.
        let strip = CAGradientLayer()
        let warmWhite = CGColor(srgbRed: 1, green: 0.98, blue: 0.94, alpha: 1)
        strip.colors = [CGColor(srgbRed: 1, green: 0.95, blue: 0.84, alpha: 0), warmWhite, warmWhite,
                        CGColor(srgbRed: 1, green: 0.95, blue: 0.84, alpha: 0)]
        strip.locations = [0, 0.04, 0.96, 1]
        strip.startPoint = CGPoint(x: 0, y: 0.5)
        strip.endPoint = CGPoint(x: 1, y: 0.5)
        let s = m.assetScale
        strip.frame = CGRect(x: CarriageGeometry.lampStart.x * s,
                             y: (CarriageGeometry.canvas.height - CarriageGeometry.bodyTop) * s - 1.6,
                             width: (CarriageGeometry.lampEnd.x - CarriageGeometry.lampStart.x) * s, height: 1.8)
        strip.shadowColor = CGColor(srgbRed: 1, green: 0.8, blue: 0.55, alpha: 1)
        strip.shadowOpacity = 1
        strip.shadowRadius = 4
        strip.shadowOffset = CGSize(width: 0, height: 3)
        lampLayer.addSublayer(strip)
        lampStrip = strip
        // The visible part of the strip right of the fin (the fin hides the part behind it).
        let rightStrip = CAGradientLayer()
        rightStrip.colors = strip.colors
        rightStrip.locations = [0, 0.08, 0.92, 1]
        rightStrip.startPoint = strip.startPoint
        rightStrip.endPoint = strip.endPoint
        rightStrip.frame = CGRect(x: CarriageGeometry.rightLampStart * s, y: strip.frame.minY,
                                  width: (CarriageGeometry.rightLampEnd - CarriageGeometry.rightLampStart) * s,
                                  height: strip.frame.height)
        rightStrip.shadowColor = strip.shadowColor
        rightStrip.shadowOpacity = strip.shadowOpacity
        rightStrip.shadowRadius = strip.shadowRadius
        rightStrip.shadowOffset = strip.shadowOffset
        lampLayer.addSublayer(rightStrip)
        lampEdges = [strip, rightStrip]
        statusLayer.contents = variant.status
        statusLayer.contentsGravity = .resize
        statusLayer.frame = m.carriageFrame
        statusLayer.opacity = 1
        statusLayer.shadowColor = CGColor(srgbRed: 1, green: 0.97, blue: 0.9, alpha: 1)
        statusLayer.shadowOpacity = 0.9
        statusLayer.shadowRadius = 2.5
        statusLayer.shadowOffset = .zero

        // Caps Lock: the status dot glows green.
        let sp = CarriageGeometry.status
        let d: CGFloat = 2.6
        capsLayer.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        capsLayer.cornerRadius = d / 2
        capsLayer.position = CGPoint(x: m.carriageFrame.minX + sp.x * m.assetScale,
                                     y: m.carriageFrame.minY + (CarriageGeometry.canvas.height - sp.y) * m.assetScale)
        capsLayer.backgroundColor = CGColor(srgbRed: 0.45, green: 1, blue: 0.45, alpha: 1)
        capsLayer.shadowColor = CGColor(srgbRed: 0.3, green: 1, blue: 0.35, alpha: 1)
        capsLayer.shadowOpacity = 1
        capsLayer.shadowRadius = 3
        capsLayer.shadowOffset = .zero
        capsLayer.isHidden = true
        head.addSublayer(statusLayer)
        head.addSublayer(capsLayer)

        root.addSublayer(head)
    }

    /// A fine speaker grille in the left part of the body, made from the single hole image.
    private func makeGrille() -> CALayer {
        let m = metrics
        typealias C = CarriageGeometry
        let s = m.assetScale
        // Everything in whole device pixels, so every hole looks exactly the same.
        let pitchPx = max(4, (3.2 * scale).rounded())
        let holePx = max(2, (1.3 * scale).rounded())
        let tilePx = (holePx / 0.62).rounded() // the hole image has a rim around the hole
        let rows = 5
        let left = (C.bodyLeft + (C.bodyRight - C.bodyLeft) * 0.09) * s
        let right = (C.bodyLeft + (C.bodyRight - C.bodyLeft) * 0.38) * s
        let cols = Int((right - left) * scale / pitchPx)
        let w = Int(CGFloat(cols - 1) * pitchPx + tilePx), h = Int(CGFloat(rows - 1) * pitchPx + tilePx)
        let layer = CALayer()
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return layer }
        ctx.interpolationQuality = .high
        for row in 0..<rows {
            for col in 0..<cols {
                ctx.draw(variant.grilleHole, in: CGRect(x: CGFloat(col) * pitchPx, y: CGFloat(row) * pitchPx,
                                                        width: tilePx, height: tilePx))
            }
        }
        layer.contents = ctx.makeImage()
        layer.contentsScale = scale
        // The layer lives in the head group (origin at the print point). Place it on whole device pixels.
        let midY = (C.canvas.height - (C.bodyTop + C.bodyBottom) / 2) * s
        let size = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        let x = ((m.carriageFrame.minX + left) * scale).rounded() / scale
        let y = ((m.carriageFrame.minY + midY - size.height / 2) * scale).rounded() / scale
        layer.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        return layer
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
        let m = metrics
        typealias R = RailGeometry
        func bandY(_ v: CGFloat) -> CGFloat { m.bandHeight - (v - R.top) * m.railScale }
        let lipY = bandY((R.top + R.grooveTop) / 2)
        let lipHeight = max(2, bandY(R.top) - bandY(R.grooveTop))
        let grooveBottomY = bandY(R.grooveBottom)
        let w = m.carriageWidth
        bandLight.bounds = .zero
        bandLight.position = CGPoint(x: m.printX(caretCol: 0), y: 0)

        radial(bandSpill, width: w * 4.5, height: m.bandHeight * 1.8)
        bandSpill.position = CGPoint(x: 0, y: m.bandHeight)
        radial(lipHighlight, width: w * 6, height: lipHeight * 1.5)
        lipHighlight.position = CGPoint(x: 0, y: lipY)
        radial(grooveHighlight, width: w * 4.5, height: 2.5)
        grooveHighlight.position = CGPoint(x: 0, y: grooveBottomY + 0.5)
        // The rail stays matte like in the approved design; only a faint warm spill remains near the carriage.
        lipHighlight.isHidden = true
        grooveHighlight.isHidden = true
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
        renderLight(settings)
    }

    func setCapsLock(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsLayer.isHidden = !on
        CATransaction.commit()
    }

    /// The status light flashes when a character is made.
    func flashStatus() {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 0.25, 1, 1]
        a.keyTimes = [0, 0.15, 0.5, 1]
        a.duration = 0.5
        statusLayer.add(a, forKey: "flash")
    }

    /// The reflexes use the light color and fade out with the brightness.
    private func applyLightTint() {
        let c = lightSettings.color
        let k = min(1, lightSettings.brightness)
        lampLayer.opacity = Float(min(1, lightSettings.brightness))
        // The glowing lamp edge has the color of the light: nearly white in its core, its glow in the light color.
        let core = CGColor(srgbRed: 1, green: 1 - (1 - c.g) * 0.3, blue: 1 - (1 - c.b) * 0.3, alpha: 1)
        let fade = CGColor(srgbRed: 1, green: 1 - (1 - c.g) * 0.3, blue: 1 - (1 - c.b) * 0.3, alpha: 0)
        for edge in lampEdges {
            edge.colors = [fade, core, core, fade]
            edge.shadowColor = CGColor(srgbRed: c.r, green: c.g * 0.92, blue: c.b * 0.8, alpha: 1)
        }
        func warm(_ a: Double) -> CGColor { CGColor(srgbRed: c.r, green: c.g * 0.92, blue: c.b * 0.75, alpha: a) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ceramicGlow.colors = [warm(0.5 * k), warm(0.12 * k), warm(0)]
        ceramicGlow.locations = [0, 0.45, 1]
        railGlow.colors = [warm(0.3 * k), warm(0)]
        bandSpill.colors = [warm(0.12 * k), warm(0.04 * k), warm(0)]
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
        if style == .desktop {
            let top = CGPoint(x: m.left - paperSideMargin, y: paperTop(caretLine: caretLine))
            for l in paperTopLayers {
                move(l, to: top, duration: instant ? 0 : (lineChanged ? 0.28 : 0), timing: timing)
            }
        }

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
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.35))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The rail band at the bottom, built from the three parts of the rail image (lip, groove, face),
    /// each scaled to its measured height and stretched to the full width.
    private static func makeBandImage(variant v: HardwareVariant, metrics m: Metrics, scale: CGFloat) -> CGImage? {
        let w = Int(m.size.width * scale), h = Int(m.bandHeight * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        typealias R = RailGeometry
        let rail = v.rail
        func slice(_ y0: CGFloat, _ y1: CGFloat) -> CGImage? {
            rail.cropping(to: CGRect(x: 0, y: y0 - R.top, width: CGFloat(rail.width), height: y1 - y0))
        }
        let W = CGFloat(w)
        let highlightRows = CGFloat(RailGeometry.highlightSourceRows.count)
        if let face = slice(R.grooveBottom + highlightRows, R.bottom) {
            ctx.draw(face, in: CGRect(x: 0, y: 0, width: W, height: m.faceHeight * scale))
        }
        // The fine highlight on the lower edge of the groove, always 1 pt high so it stays visible.
        if let highlight = slice(R.grooveBottom, R.grooveBottom + highlightRows) {
            ctx.draw(highlight, in: CGRect(x: 0, y: (m.faceHeight - 1) * scale, width: W, height: scale))
        }
        if let groove = slice(R.grooveTop, R.grooveBottom) {
            ctx.draw(groove, in: CGRect(x: 0, y: m.faceHeight * scale, width: W, height: m.grooveHeight * scale))
        }
        if let lip = slice(R.top, R.grooveTop) {
            ctx.draw(lip, in: CGRect(x: 0, y: (m.faceHeight + m.grooveHeight) * scale, width: W, height: m.lipHeight * scale))
        }
        return ctx.makeImage()
    }

    /// The lighting of the paper, twice as wide as the screen and centered on the print point.
    /// A warm ivory fan opens upward from the print point with soft side edges and a smooth distance
    /// falloff, plus a small bright area right at the print point. Outside the fan the paper gets the
    /// dimmer ambient light. Dithered against banding.
    static func makeLightImage(metrics m: Metrics, settings s: LightSettings, step: Double = 1) -> CGImage? {
        let W = Double(m.size.width)
        let paperH = Double(m.size.height - m.bandHeight)
        let w = Int(W * 2 / step), h = Int(paperH / step)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var rng = SplitMix64(seed: 7)
        let half = s.spread / 2 * .pi / 180
        // The lamp is a strip along the top edge of the body. Every point of the strip sends the same tilted
        // beam; for each paper point the strip point whose beam axis passes through it is used.
        // Below the top edge of the body there is no light.
        let depth = 0.0
        let halfStrip = Double(m.lampHalfLength)
        let apexY = Double(m.printY - m.bandHeight)
        let soft = max(0.01, s.softness * half)
        // Distance at which the light has dropped to half (inverse square law, softened near the lamp).
        let reach = max(1, s.reach * 0.3 * paperH)
        let tilt = s.tilt * .pi / 180
        let axis = (x: sin(tilt), y: cos(tilt))
        // The lamp sits in the body, left of the print point.
        let lampX = Double(m.lampOffsetX)
        // A rosy, peach-colored light, as measured in the approved design.
        // Strong light looks almost white-warm, weak light deeper and more orange.
        let hotColor = s.color(saturation: 0.3)
        let deepColor = s.color(saturation: 0.9)
        let amb = s.ambient
        // The ambient light is cool lavender, the lamp is warm.
        let ambient = (r: amb, g: amb * 0.96, b: min(1, amb * 1.06))
        func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
            let t = max(0, min(1, (x - e0) / (e1 - e0)))
            return t * t * (3 - 2 * t)
        }
        func mix(_ p: Double, _ q: Double, _ t: Double) -> Double { p + (q - p) * t }
        for row in 0..<h {
            let v = (Double(h - 1 - row) + 0.5) * step - apexY
            for col in 0..<w {
                let pu0 = (Double(col) + 0.5) * step - W
                // Beam from the strip: the strip point whose beam axis passes through this paper point,
                // clamped to the strip.
                func segmentBeam(_ center: Double, _ halfLen: Double) -> (beam: Double, d: Double) {
                    let sx = min(center + halfLen, max(center - halfLen, pu0 - v * axis.x / max(axis.y, 0.05)))
                    let u = pu0 - sx
                    let d = (u * u + v * v).squareRoot()
                    let along = u * axis.x + v * axis.y
                    guard along > 0 else { return (0, d) }
                    let across = u * axis.y - v * axis.x
                    let angle = atan2(abs(across), along)
                    // The edge gets softer with distance, like a real penumbra. It is never narrower
                    // than about 2 pt, so it never shows the pixel grid.
                    let edge = max(soft * min(1, 0.25 + d / (0.5 * paperH)), 2 / max(d, 1))
                    // Brightest on the axis, softly darker toward the edge of the beam.
                    let axisFalloff = pow(max(0, cos(min(angle / (half + edge), 1) * .pi / 2)), 0.6)
                    return ((1 - smooth(half - edge, half + edge, angle)) * axisFalloff * smooth(depth - 1.5, depth + 1.5, v), d)
                }
                let (beam, d) = segmentBeam(lampX, halfStrip)
                let falloff = 1 / (1 + (d / reach) * (d / reach))
                // Exposure: the light saturates softly instead of being cut off.
                let k = 1 - exp(-2.4 * s.brightness * beam * falloff)
                let heat = k * k
                let lc = (r: mix(deepColor.r, hotColor.r, heat), g: mix(deepColor.g, hotColor.g, heat),
                          b: mix(deepColor.b, hotColor.b, heat))
                let i = (row * w + col) * 4
                func q(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x * 255 + (rng.nextUnit() - 0.5) * 1.5))) }
                // Light only adds: no channel may get darker than in the ambient light alone.
                px[i] = q(max(ambient.r, mix(ambient.r, lc.r, k)))
                px[i + 1] = q(max(ambient.g, mix(ambient.g, lc.g, k)))
                px[i + 2] = q(max(ambient.b, mix(ambient.b, lc.b, k)))
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
