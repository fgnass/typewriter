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
    let barY: CGFloat
    let barHeight: CGFloat
    let typingY: CGFloat
    let baseline: CGFloat
    let linePadding: CGFloat = 24

    init(size: CGSize, columns: Int = 72) {
        self.size = size
        self.columns = columns
        // Courier has a fixed advance of 0.6 em.
        let targetWidth = min(size.width * 0.56, 1000)
        let probe = CTFontCreateWithName("Courier" as CFString, 100, nil)
        let advance = Metrics.advance(of: probe) / 100
        let fontSize = (targetWidth / CGFloat(columns) / advance).rounded(.down)
        font = CTFontCreateWithName("Courier" as CFString, fontSize, nil)
        charWidth = Metrics.advance(of: font)
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        lineHeight = (fontSize * 1.6).rounded()
        left = ((size.width - CGFloat(columns) * charWidth) / 2).rounded()
        barY = (size.height * 0.14).rounded()
        barHeight = 9
        typingY = barY + barHeight + 4
        baseline = (lineHeight * 0.32).rounded()
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
    static let paper = CGColor(srgbRed: 0.86, green: 0.865, blue: 0.895, alpha: 1)
    static let ink = (r: CGFloat(0.10), g: CGFloat(0.095), b: CGFloat(0.09))
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
            draw(g.char, style: g.style, x: x0 + CGFloat(g.col) * m.charWidth, y: y0, inkScale: 1, blur: 0.9, in: ctx)
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
        ctx.setTextDrawingMode(.fillStroke)
        ctx.setShadow(offset: .zero, blur: blur, color: CGColor(srgbRed: Palette.ink.r, green: Palette.ink.g, blue: Palette.ink.b, alpha: alpha * 0.7))
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
    private let spotlight = CAGradientLayer()
    private let hotspot = CAGradientLayer()
    private let lightClip = CALayer()
    private let vignette = CAGradientLayer()
    private let textContainer = CALayer()
    private let bar = CAGradientLayer()
    private let barShadow = CAGradientLayer()
    private let carriage = CAGradientLayer()
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

        // The light only falls on the paper above the bar.
        lightClip.frame = CGRect(x: 0, y: m.barY + m.barHeight, width: m.size.width, height: m.size.height)
        lightClip.masksToBounds = true
        root.addSublayer(lightClip)

        spotlight.type = .radial
        spotlight.colors = [
            CGColor(srgbRed: 1.0, green: 0.95, blue: 0.83, alpha: 1),
            CGColor(srgbRed: 1.0, green: 0.96, blue: 0.88, alpha: 0.8),
            CGColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 0.35),
            CGColor(srgbRed: 0.98, green: 0.97, blue: 0.96, alpha: 0),
        ]
        spotlight.locations = [0, 0.3, 0.65, 1]
        spotlight.startPoint = CGPoint(x: 0.5, y: 0.5)
        spotlight.endPoint = CGPoint(x: 1, y: 1)
        spotlight.bounds = CGRect(x: 0, y: 0, width: m.size.width * 0.7, height: m.size.height * 1.7)
        lightClip.addSublayer(spotlight)

        hotspot.type = .radial
        hotspot.colors = [
            CGColor(srgbRed: 1.0, green: 0.9, blue: 0.7, alpha: 0.75),
            CGColor(srgbRed: 1.0, green: 0.93, blue: 0.8, alpha: 0.3),
            CGColor(srgbRed: 1.0, green: 0.95, blue: 0.85, alpha: 0),
        ]
        hotspot.startPoint = CGPoint(x: 0.5, y: 0.5)
        hotspot.endPoint = CGPoint(x: 1, y: 1)
        hotspot.bounds = CGRect(x: 0, y: 0, width: m.size.width * 0.3, height: m.size.height * 0.6)
        lightClip.addSublayer(hotspot)

        vignette.type = .radial
        vignette.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(srgbRed: 0.1, green: 0.1, blue: 0.2, alpha: 0.12)]
        vignette.locations = [0, 0.55, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.35)
        vignette.endPoint = CGPoint(x: 1.15, y: 1.15)
        vignette.frame = b
        root.addSublayer(vignette)

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

        // A soft shadow on the paper just above the bar.
        barShadow.colors = [CGColor(gray: 0, alpha: 0.22), CGColor(gray: 0, alpha: 0)]
        barShadow.startPoint = CGPoint(x: 0.5, y: 0)
        barShadow.endPoint = CGPoint(x: 0.5, y: 1)
        barShadow.frame = CGRect(x: 0, y: m.barY + m.barHeight, width: m.size.width, height: 5)
        root.addSublayer(barShadow)

        bar.colors = [
            CGColor(srgbRed: 0.16, green: 0.165, blue: 0.175, alpha: 1),
            CGColor(srgbRed: 0.33, green: 0.34, blue: 0.36, alpha: 1),
            CGColor(srgbRed: 0.62, green: 0.63, blue: 0.66, alpha: 1),
            CGColor(srgbRed: 0.28, green: 0.29, blue: 0.31, alpha: 1),
        ]
        bar.locations = [0, 0.35, 0.7, 1]
        bar.startPoint = CGPoint(x: 0.5, y: 0)
        bar.endPoint = CGPoint(x: 0.5, y: 1)
        bar.frame = CGRect(x: 0, y: m.barY, width: m.size.width, height: m.barHeight)
        root.addSublayer(bar)

        carriage.colors = [
            CGColor(srgbRed: 0.72, green: 0.73, blue: 0.75, alpha: 1),
            CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
            CGColor(srgbRed: 0.80, green: 0.81, blue: 0.83, alpha: 1),
        ]
        carriage.startPoint = CGPoint(x: 0.5, y: 0)
        carriage.endPoint = CGPoint(x: 0.5, y: 1)
        carriage.cornerRadius = 2
        carriage.bounds = CGRect(x: 0, y: 0, width: max(26, m.charWidth * 2.4), height: m.barHeight - 1)
        carriage.position = CGPoint(x: m.carriageX(col: 0), y: m.barY + m.barHeight / 2 + 1)
        carriage.shadowColor = CGColor(gray: 0, alpha: 1)
        carriage.shadowOpacity = 0.35
        carriage.shadowRadius = 2
        carriage.shadowOffset = CGSize(width: 0, height: -1)
        root.addSublayer(carriage)

        for t in [hintLayer, noticeLayer] {
            t.font = CTFontCreateWithName("Courier" as CFString, 13, nil)
            t.fontSize = 13
            t.foregroundColor = CGColor(gray: 0.15, alpha: 0.45)
            t.contentsScale = scale
            t.alignmentMode = .center
            root.addSublayer(t)
        }
        hintLayer.string = hint
        hintLayer.frame = CGRect(x: 0, y: m.barY / 2 - 9, width: m.size.width, height: 18)
        noticeLayer.frame = CGRect(x: 0, y: m.size.height - 60, width: m.size.width, height: 18)
        noticeLayer.opacity = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.5)
            self?.hintLayer.opacity = 0.35
            CATransaction.commit()
        }
    }

    private static func makeNoiseImage(width w: Int, height h: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var rng = SplitMix64(seed: 42)
        let base: (Double, Double, Double) = (0.86, 0.865, 0.895)
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

        CATransaction.begin()
        if !animated {
            CATransaction.setDisableActions(true)
        } else if lineChanged {
            CATransaction.setAnimationDuration(0.38)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1))
        } else {
            CATransaction.setAnimationDuration(0.05)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        carriage.position = CGPoint(x: x, y: carriage.position.y)
        textContainer.position = CGPoint(x: textContainer.position.x, y: containerY)
        markedLayer.position = CGPoint(x: x - m.charWidth / 2, y: m.typingY + m.baseline - m.descent - 2)
        CATransaction.commit()

        // The light follows with a little lag.
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(lineChanged ? 0.6 : 0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        let lightBaseY: CGFloat = 0 // bottom of lightClip
        spotlight.position = CGPoint(x: x, y: lightBaseY)
        hotspot.position = CGPoint(x: x, y: lightBaseY)
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
