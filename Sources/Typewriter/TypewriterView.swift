import AppKit
import QuartzCore
import CoreText

protocol TypewriterViewDelegate: AnyObject {
    func typewriterViewDidCommit(_ view: TypewriterView)
    func typewriterViewDidDiscard(_ view: TypewriterView)
    func typewriterViewDidChange(_ view: TypewriterView)
}

/// Sizes and positions, all derived from the screen size.
struct Metrics {
    let size: CGSize
    let columns: Int
    let font: CTFont
    let charWidth: CGFloat
    let lineHeight: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let left: CGFloat
    let barCenterY: CGFloat
    let barHeight: CGFloat = 3
    let carriageWidth: CGFloat
    let carriageHeight: CGFloat
    let stemHeight: CGFloat
    let lampHeadWidth: CGFloat
    let lampHeadHeight: CGFloat = 3
    let lampTopY: CGFloat
    let typingY: CGFloat
    let baseline: CGFloat
    let linePadding: CGFloat = 24

    init(size: CGSize, columns: Int = 72) {
        self.size = size
        self.columns = columns
        let targetWidth = min(size.width * 0.46, 860)
        let probe = CTFontCreateWithName("Courier" as CFString, 100, nil)
        let advance = Metrics.advance(of: probe) / 100
        let fontSize = (targetWidth / CGFloat(columns) / advance).rounded(.down)
        font = CTFontCreateWithName("Courier" as CFString, fontSize, nil)
        charWidth = Metrics.advance(of: font)
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        lineHeight = (fontSize * 1.6).rounded()
        left = ((size.width - CGFloat(columns) * charWidth) / 2).rounded()
        barCenterY = (size.height * 0.14).rounded()
        carriageHeight = max(18, (fontSize * 1.45).rounded())
        carriageWidth = (carriageHeight * 3.9).rounded()
        stemHeight = max(5, (fontSize * 0.4).rounded())
        lampHeadWidth = (charWidth * 1.6).rounded()
        lampTopY = barCenterY + carriageHeight / 2 + stemHeight + lampHeadHeight
        baseline = (lineHeight * 0.32).rounded()
        // The current line sits right above the lamp.
        let baselineY = lampTopY + (descent * 0.8).rounded() + 2
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

    func carriageX(col: Int) -> CGFloat {
        left + CGFloat(min(col, columns)) * charWidth + charWidth / 2
    }
}

enum Palette {
    static let paper = CGColor(srgbRed: 0.85, green: 0.85, blue: 0.885, alpha: 1)
    static let ink = (r: CGFloat(0.2), g: CGFloat(0.195), b: CGFloat(0.19))
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

        // Correction tape traces: a slightly brighter patch with a faint ghost of the old letter.
        for g in ghosts {
            let x = x0 + CGFloat(g.col) * m.charWidth
            let rect = CGRect(x: x - 0.5, y: y0 - m.descent * 0.7, width: m.charWidth + 1, height: m.ascent * 0.95 + m.descent * 0.7)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.55))
            ctx.fill(rect)
            draw(g.char, style: g.style, x: x, y: y0, inkScale: 0.07, blur: 1.4, in: ctx)
        }
        for g in glyphs where !g.char.isWhitespace {
            draw(g.char, style: g.style, x: x0 + CGFloat(g.col) * m.charWidth, y: y0, inkScale: 1, blur: 0, in: ctx)
        }
    }

    private func draw(_ c: Character, style s: StrikeStyle, x: CGFloat, y: CGFloat, inkScale: CGFloat, blur: CGFloat, in ctx: CGContext) {
        let alpha = s.ink * inkScale
        let color = CGColor(srgbRed: Palette.ink.r, green: Palette.ink.g, blue: Palette.ink.b, alpha: alpha)
        ctx.saveGState()
        ctx.translateBy(x: x + s.dx, y: y + s.dy)
        ctx.rotate(by: s.rotation)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(0.12)
        ctx.setTextDrawingMode(.fill)
        if blur > 0 {
            ctx.setShadow(offset: .zero, blur: blur, color: CGColor(srgbRed: Palette.ink.r, green: Palette.ink.g, blue: Palette.ink.b, alpha: alpha * 0.7))
        }
        ctx.textPosition = .zero
        CTLineDraw(ctLine(for: c), ctx)
        ctx.restoreGState()
    }
}

final class TypewriterView: NSView, NSTextInputClient {
    weak var delegate: TypewriterViewDelegate?
    let model: TextModel
    let metrics: Metrics
    let sounds: SoundEngine

    private let root = CALayer()
    private let paper = CALayer()
    private let lowerPaper = CAGradientLayer()
    private let spotlight = CALayer()
    private let lightClip = CALayer()
    private let vignette = CAGradientLayer()
    private let textContainer = CALayer()
    private let bar = CAGradientLayer()
    private let carriage = CALayer()
    private let markedLayer = CATextLayer()
    private let hintLayer = CATextLayer()
    private let noticeLayer = CATextLayer()
    private var lineLayers: [Int: LineLayer] = [:]

    private var marked: String = ""
    private var lastCaretLine = 0
    private var bellRungOnLine = -1
    private var escArmedUntil: Date?
    private let scale: CGFloat

    init(frame: CGRect, model: TextModel, metrics: Metrics, sounds: SoundEngine, scale: CGFloat, hint: String) {
        self.model = model
        self.metrics = metrics
        self.sounds = sounds
        self.scale = scale
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        setupLayers(hint: hint)
        lastCaretLine = model.layout.caretLine
        refresh(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: Layers

    private func setupLayers(hint: String) {
        guard let host = layer else { return }
        let m = metrics
        let b = CGRect(origin: .zero, size: m.size)
        host.backgroundColor = Palette.paper
        root.frame = b
        host.addSublayer(root)

        paper.frame = b
        paper.backgroundColor = Palette.paper
        if let noise = Self.makeNoiseImage(width: Int(m.size.width), height: Int(m.size.height)) {
            paper.contents = noise
            paper.contentsGravity = .resize
            paper.magnificationFilter = .nearest
        }
        root.addSublayer(paper)

        vignette.type = .radial
        vignette.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(srgbRed: 0.12, green: 0.1, blue: 0.2, alpha: 0.14)]
        vignette.locations = [0, 0.5, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.3)
        vignette.endPoint = CGPoint(x: 1.2, y: 1.2)
        vignette.frame = b
        root.addSublayer(vignette)

        // The light only falls on the paper above the bar.
        lightClip.frame = CGRect(x: 0, y: m.barCenterY, width: m.size.width, height: m.size.height - m.barCenterY)
        lightClip.masksToBounds = true
        root.addSublayer(lightClip)

        let coneSize = CGSize(width: m.size.width * 1.4, height: lightClip.bounds.height)
        let apexHeight = m.lampTopY - m.barCenterY
        spotlight.contents = Self.makeConeImage(size: coneSize, apexHeight: apexHeight, screenHeight: m.size.height)
        spotlight.contentsGravity = .resize
        spotlight.magnificationFilter = .linear
        spotlight.anchorPoint = CGPoint(x: 0.5, y: 0)
        spotlight.bounds = CGRect(origin: .zero, size: coneSize)
        spotlight.position = CGPoint(x: m.carriageX(col: 0), y: 0)
        lightClip.addSublayer(spotlight)

        // The paper below the bar is outside the light, but brighter.
        lowerPaper.frame = CGRect(x: 0, y: 0, width: m.size.width, height: m.barCenterY)
        lowerPaper.colors = [CGColor(srgbRed: 0.84, green: 0.845, blue: 0.875, alpha: 1),
                             CGColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)]
        lowerPaper.startPoint = CGPoint(x: 0.5, y: 0)
        lowerPaper.endPoint = CGPoint(x: 0.5, y: 1)
        root.addSublayer(lowerPaper)

        textContainer.anchorPoint = .zero
        textContainer.bounds = .zero
        textContainer.position = CGPoint(x: m.left - m.linePadding, y: m.typingY)
        root.addSublayer(textContainer)

        markedLayer.font = metrics.font
        markedLayer.fontSize = CTFontGetSize(metrics.font)
        markedLayer.foregroundColor = CGColor(gray: 0.1, alpha: 0.35)
        markedLayer.contentsScale = scale
        markedLayer.anchorPoint = .zero
        markedLayer.bounds = CGRect(x: 0, y: 0, width: m.charWidth * 4, height: m.lineHeight)
        root.addSublayer(markedLayer)

        // A thin metal rod.
        bar.colors = [
            CGColor(srgbRed: 0.20, green: 0.205, blue: 0.22, alpha: 1),
            CGColor(srgbRed: 0.55, green: 0.56, blue: 0.59, alpha: 1),
            CGColor(srgbRed: 0.30, green: 0.31, blue: 0.33, alpha: 1),
        ]
        bar.startPoint = CGPoint(x: 0.5, y: 0)
        bar.endPoint = CGPoint(x: 0.5, y: 1)
        bar.frame = CGRect(x: 0, y: m.barCenterY - m.barHeight / 2, width: m.size.width, height: m.barHeight)
        bar.shadowColor = CGColor(gray: 0, alpha: 1)
        bar.shadowOpacity = 0.25
        bar.shadowRadius = 1.5
        bar.shadowOffset = CGSize(width: 0, height: -1.5)
        root.addSublayer(bar)

        setupCarriage()

        for t in [hintLayer, noticeLayer] {
            t.font = CTFontCreateWithName("Courier" as CFString, 13, nil)
            t.fontSize = 13
            t.foregroundColor = CGColor(gray: 0.15, alpha: 0.45)
            t.contentsScale = scale
            t.alignmentMode = .center
            root.addSublayer(t)
        }
        hintLayer.string = hint
        hintLayer.frame = CGRect(x: 0, y: m.barCenterY / 2 - 9, width: m.size.width, height: 18)
        noticeLayer.frame = CGRect(x: 0, y: m.size.height - 60, width: m.size.width, height: 18)
        noticeLayer.opacity = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.5)
            self?.hintLayer.opacity = 0.35
            CATransaction.commit()
        }
    }

    /// A glossy white capsule on the rod. A slim stem carries the lamp, which sits right below the print position.
    private func setupCarriage() {
        let m = metrics
        let w = m.carriageWidth, h = m.carriageHeight
        carriage.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        carriage.position = CGPoint(x: m.carriageX(col: 0), y: m.barCenterY)
        carriage.masksToBounds = false

        // Warm reflection of the lamp on the polished rod.
        let rodGlow = CAGradientLayer()
        rodGlow.type = .radial
        rodGlow.colors = [CGColor(srgbRed: 1, green: 0.88, blue: 0.62, alpha: 0.75),
                          CGColor(srgbRed: 1, green: 0.9, blue: 0.7, alpha: 0.25),
                          CGColor(srgbRed: 1, green: 0.9, blue: 0.7, alpha: 0)]
        rodGlow.locations = [0, 0.35, 1]
        rodGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        rodGlow.endPoint = CGPoint(x: 1, y: 1)
        let gw = w * 5
        rodGlow.frame = CGRect(x: w / 2 - gw / 2, y: h / 2 - m.barHeight / 2, width: gw, height: m.barHeight)
        carriage.addSublayer(rodGlow)

        // Stem from the carriage up to the lamp.
        let stemWidth: CGFloat = 2
        let stem = CAGradientLayer()
        stem.colors = [CGColor(gray: 0.32, alpha: 1), CGColor(gray: 0.78, alpha: 1), CGColor(gray: 0.4, alpha: 1)]
        stem.startPoint = CGPoint(x: 0, y: 0.5)
        stem.endPoint = CGPoint(x: 1, y: 0.5)
        stem.frame = CGRect(x: w / 2 - stemWidth / 2, y: h - 1, width: stemWidth, height: m.stemHeight + 1)
        carriage.addSublayer(stem)

        // Lamp head: graphite with a glowing filament on top.
        let head = CAGradientLayer()
        head.colors = [CGColor(gray: 0.12, alpha: 1), CGColor(gray: 0.3, alpha: 1), CGColor(gray: 0.2, alpha: 1)]
        head.startPoint = CGPoint(x: 0.5, y: 0)
        head.endPoint = CGPoint(x: 0.5, y: 1)
        head.cornerRadius = m.lampHeadHeight / 2
        head.frame = CGRect(x: w / 2 - m.lampHeadWidth / 2, y: h + m.stemHeight, width: m.lampHeadWidth, height: m.lampHeadHeight)
        carriage.addSublayer(head)
        let filament = CAGradientLayer()
        filament.colors = [CGColor(srgbRed: 1, green: 0.78, blue: 0.45, alpha: 0.2),
                           CGColor(srgbRed: 1, green: 0.97, blue: 0.88, alpha: 1),
                           CGColor(srgbRed: 1, green: 0.78, blue: 0.45, alpha: 0.2)]
        filament.startPoint = CGPoint(x: 0, y: 0.5)
        filament.endPoint = CGPoint(x: 1, y: 0.5)
        filament.cornerRadius = 0.5
        filament.frame = CGRect(x: w / 2 - m.lampHeadWidth * 0.42, y: h + m.stemHeight + m.lampHeadHeight - 1.2,
                                width: m.lampHeadWidth * 0.84, height: 1.2)
        carriage.addSublayer(filament)

        // Bloom around the glowing filament.
        let bloom = CAGradientLayer()
        bloom.type = .radial
        bloom.colors = [CGColor(srgbRed: 1, green: 0.95, blue: 0.82, alpha: 0.95),
                        CGColor(srgbRed: 1, green: 0.85, blue: 0.6, alpha: 0.35),
                        CGColor(srgbRed: 1, green: 0.85, blue: 0.6, alpha: 0)]
        bloom.locations = [0, 0.3, 1]
        bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloom.endPoint = CGPoint(x: 1, y: 1)
        let bw = m.lampHeadWidth * 2.6, bh = m.lampHeadWidth * 1.3
        bloom.frame = CGRect(x: w / 2 - bw / 2, y: h + m.stemHeight + m.lampHeadHeight - bh / 2, width: bw, height: bh)
        carriage.insertSublayer(bloom, below: head)

        let body = CarriageBodyLayer()
        body.frame = carriage.bounds.insetBy(dx: -5, dy: -5)
        body.contentsScale = scale
        body.setNeedsDisplay()
        carriage.addSublayer(body)

        root.addSublayer(carriage)
    }

    /// Light of an incandescent lamp on the paper: a soft beam, bright and almost white close to the lamp,
    /// warm further away, plus the bloom around the bulb. Dithered against banding.
    private static func makeConeImage(size: CGSize, apexHeight: CGFloat, screenHeight: CGFloat) -> CGImage? {
        let step: CGFloat = 2 // points per pixel; the layer scales it up smoothly
        let w = Int(size.width / step), h = Int(size.height / step)
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var rng = SplitMix64(seed: 7)
        let cx = Double(w) / 2
        let z0 = 22.0       // the lamp is a bit in front of the paper
        let r0 = 60.0
        let k = 13.0 * pow(Double(screenHeight) / 900, 1.5)
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = max(0, min(1, (x - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
        func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        for row in 0..<h {
            let y = Double(h - 1 - row) * Double(step) - Double(apexHeight)
            for col in 0..<w {
                let dx = (Double(col) - cx) * Double(step)
                let d = (dx * dx + y * y).squareRoot()
                // Beam: angle from straight up.
                let angle = atan2(abs(dx), max(y, 0.0001))
                let beam = y <= 0 ? 0 : (1 - smooth(0.36, 0.8, angle)) + 0.1 * (1 - smooth(0.7, 1.3, angle))
                let r = (d * d + z0 * z0).squareRoot()
                let e = beam * k / pow(r / r0, 1.5)
                let lit = 1 - exp(-e)
                let bloom = min(1, 0.95 * exp(-d / 9) + 0.4 * exp(-d / 38))
                let a = min(0.985, 1 - (1 - lit) * (1 - bloom))
                // Overexposed white near the lamp, warm yellow in the middle.
                let hot = pow(lit, 5)
                var red = 1.0
                var green = mix(0.885, 0.985, hot)
                var blue = mix(0.64, 0.94, hot)
                let bw = bloom / max(a, 0.0001)
                green = mix(green, 0.93, min(1, bw) * 0.4)
                blue = mix(blue, 0.78, min(1, bw) * 0.4)
                red *= a; green *= a; blue *= a
                let i = (row * w + col) * 4
                func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v * 255 + (rng.nextUnit() - 0.5) * 1.6))) }
                px[i] = q(red)
                px[i + 1] = q(green)
                px[i + 2] = q(blue)
                px[i + 3] = max(px[i], max(px[i + 1], max(px[i + 2], q(a))))
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    private static func makeNoiseImage(width w: Int, height h: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var rng = SplitMix64(seed: 42)
        let base: (Double, Double, Double) = (0.85, 0.85, 0.885)
        for i in 0..<(w * h) {
            let n = (rng.nextUnit() - 0.5) * 0.018
            px[i * 4] = UInt8(max(0, min(255, (base.0 + n) * 255)))
            px[i * 4 + 1] = UInt8(max(0, min(255, (base.1 + n) * 255)))
            px[i * 4 + 2] = UInt8(max(0, min(255, (base.2 + n) * 255)))
            px[i * 4 + 3] = 255
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    // MARK: Rendering

    func refresh(animated: Bool) {
        let m = metrics
        let layout = model.layout
        let caretLine = layout.caretLine
        let visibleLines = Int((m.size.height - m.typingY) / m.lineHeight) + 2
        let firstVisible = max(0, caretLine - visibleLines)
        let maxGhostLine = model.ghosts.map(\.line).max() ?? -1
        let lastLine = max(caretLine, maxGhostLine)

        var ghostsByLine: [Int: [Ghost]] = [:]
        for g in model.ghosts where g.line >= firstVisible { ghostsByLine[g.line, default: []].append(g) }

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
        let x = m.carriageX(col: layout.caretCol)
        let containerY = m.typingY + CGFloat(caretLine) * m.lineHeight

        // The lamp sits in the carriage, so the light moves together with it.
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
        spotlight.position = CGPoint(x: x, y: spotlight.position.y)
        textContainer.position = CGPoint(x: textContainer.position.x, y: containerY)
        markedLayer.position = CGPoint(x: x - m.charWidth / 2, y: m.typingY + m.baseline - m.descent - 2)
        CATransaction.commit()

        lastCaretLine = caretLine
    }

    private func showNotice(_ text: String, duration: TimeInterval = 2) {
        noticeLayer.string = text
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        noticeLayer.opacity = 1
        CATransaction.commit()
        let token = text
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, (self.noticeLayer.string as? String) == token else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            self.noticeLayer.opacity = 0
            CATransaction.commit()
        }
    }

    // MARK: Editing

    private func type(_ s: String) {
        let clean = s.replacingOccurrences(of: "\t", with: "    ")
            .replacingOccurrences(of: "\r", with: "\n")
            .filter { $0 == "\n" || !$0.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) } }
        guard !clean.isEmpty else { return }
        let before = model.layout
        model.insert(clean)
        let after = model.layout
        if clean.last == "\n" {
            sounds.play(.carriageReturn)
        } else if after.caretLine != before.caretLine {
            sounds.play(clean.last == " " ? .space : .key)
            sounds.play(.carriageReturn, volume: 0.6)
        } else {
            sounds.play(clean.last == " " ? .space : .key)
        }
        let bellCol = model.columns - 8
        if after.caretCol >= bellCol, before.caretCol < bellCol || before.caretLine != after.caretLine, bellRungOnLine != after.caretLine {
            bellRungOnLine = after.caretLine
            sounds.play(.bell)
        }
        refresh(animated: true)
        delegate?.typewriterViewDidChange(self)
    }

    private func backspace() {
        if model.deleteBackward() {
            sounds.play(.backspace)
            refresh(animated: true)
            delegate?.typewriterViewDidChange(self)
        } else {
            NSSound.beep()
        }
    }

    // MARK: Keys

    private func isReturn(_ e: NSEvent) -> Bool { e.keyCode == 36 || e.keyCode == 76 }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        if isReturn(event) {
            delegate?.typewriterViewDidCommit(self)
        }
        return true // Swallow all other command shortcuts.
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if isReturn(event) { delegate?.typewriterViewDidCommit(self) }
            return
        }
        if event.keyCode == 53 { // Escape
            if !hasMarkedText() {
                handleEscape()
                return
            }
        }
        escArmedUntil = nil
        if inputContext?.handleEvent(event) != true {
            interpretKeyEvents([event])
        }
    }

    private func handleEscape() {
        if model.isEmpty {
            delegate?.typewriterViewDidDiscard(self)
            return
        }
        if let until = escArmedUntil, until > Date() {
            delegate?.typewriterViewDidDiscard(self)
            return
        }
        escArmedUntil = Date().addingTimeInterval(2.5)
        showNotice("Press esc again to discard this page", duration: 2.5)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            type("\n")
        case #selector(insertTab(_:)):
            type("\t")
        case #selector(deleteBackward(_:)):
            backspace()
        case #selector(cancelOperation(_:)):
            handleEscape()
        default:
            break // Typewriters have no arrow keys.
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        setMarked("")
        type(s)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        setMarked(s)
    }

    private func setMarked(_ s: String) {
        marked = s
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markedLayer.string = s
        CATransaction.commit()
    }

    func unmarkText() { setMarked("") }
    func selectedRange() -> NSRange { NSRange(location: model.text.utf16.count, length: 0) }
    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: model.text.utf16.count, length: marked.utf16.count)
    }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let m = metrics
        let x = m.carriageX(col: model.layout.caretCol) - m.charWidth / 2
        let r = NSRect(x: x, y: m.typingY, width: m.charWidth, height: m.lineHeight)
        return window?.convertToScreen(convert(r, to: nil)) ?? r
    }
}


/// The glossy carriage body, drawn with Core Graphics for fine highlights.
final class CarriageBodyLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { NSNull() }

    override func draw(in ctx: CGContext) {
        let b = bounds.insetBy(dx: 5, dy: 5)
        let r = b.height / 2
        let path = CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
            CGGradient(colorsSpace: cs, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
        }

        // Soft contact shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // Base: white lacquer, a bit darker at the bottom.
        ctx.drawLinearGradient(gradient([
            (0, CGColor(srgbRed: 0.78, green: 0.785, blue: 0.80, alpha: 1)),
            (0.3, CGColor(srgbRed: 0.9, green: 0.905, blue: 0.915, alpha: 1)),
            (0.62, CGColor(srgbRed: 0.975, green: 0.975, blue: 0.98, alpha: 1)),
            (1, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
        ]), start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.maxY), options: [])
        // Reflection of the dark rod across the body.
        ctx.drawLinearGradient(gradient([
            (0, CGColor(gray: 0.2, alpha: 0)),
            (0.5, CGColor(gray: 0.2, alpha: 0.09)),
            (1, CGColor(gray: 0.2, alpha: 0)),
        ]), start: CGPoint(x: 0, y: b.midY - b.height * 0.22), end: CGPoint(x: 0, y: b.midY + b.height * 0.02), options: [])
        // Warm light from the lamp on the top.
        ctx.drawRadialGradient(gradient([
            (0, CGColor(srgbRed: 1, green: 0.9, blue: 0.7, alpha: 0.6)),
            (1, CGColor(srgbRed: 1, green: 0.9, blue: 0.7, alpha: 0)),
        ]), startCenter: CGPoint(x: b.midX, y: b.maxY), startRadius: 0,
           endCenter: CGPoint(x: b.midX, y: b.maxY), endRadius: b.width * 0.35, options: [])
        // Gloss on the upper half.
        let gloss = CGRect(x: b.minX + r * 0.5, y: b.midY + 0.5, width: b.width - r, height: b.height / 2 - 1.2)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: gloss, cornerWidth: gloss.height / 2, cornerHeight: gloss.height / 2, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(gradient([
            (0, CGColor(gray: 1, alpha: 0.0)),
            (1, CGColor(gray: 1, alpha: 0.95)),
        ]), start: CGPoint(x: 0, y: gloss.minY), end: CGPoint(x: 0, y: gloss.maxY), options: [])
        ctx.restoreGState()
        // Bottom rim light.
        ctx.addPath(CGPath(roundedRect: b.insetBy(dx: 0.75, dy: 0.75), cornerWidth: r - 0.75, cornerHeight: r - 0.75, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
        ctx.setLineWidth(0.75)
        ctx.strokePath()
        ctx.restoreGState()

        // Fine outline.
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0.45, alpha: 0.35))
        ctx.setLineWidth(0.5)
        ctx.strokePath()

        // Small indicator dot, left of center.
        let d = max(3, b.height * 0.2)
        let dot = CGRect(x: b.midX - b.width * 0.16 - d / 2, y: b.midY - d / 2 - 0.5, width: d, height: d)
        ctx.addEllipse(in: dot)
        ctx.setFillColor(CGColor(gray: 0.22, alpha: 1))
        ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: dot.minX + d * 0.25, y: dot.minY + d * 0.5, width: d * 0.3, height: d * 0.3))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.45))
        ctx.fillPath()
    }
}
