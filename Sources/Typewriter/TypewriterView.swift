import AppKit
import QuartzCore

protocol TypewriterViewDelegate: AnyObject {
    func typewriterViewDidCommit(_ view: TypewriterView)
    func typewriterViewDidDiscard(_ view: TypewriterView)
    func typewriterViewDidChange(_ view: TypewriterView)
}

/// Takes the keyboard input and shows it on the paper scene.
final class TypewriterView: NSView, NSTextInputClient {
    weak var delegate: TypewriterViewDelegate?
    let model: TextModel
    let metrics: Metrics
    let sounds: SoundEngine
    private let scene: PaperScene

    private var marked: String = ""
    private var bellRungOnLine = -1
    private var escArmedUntil: Date?

    init(frame: CGRect, model: TextModel, metrics: Metrics, sounds: SoundEngine, scale: CGFloat, hint: String) {
        self.model = model
        self.metrics = metrics
        self.sounds = sounds
        scene = PaperScene(metrics: metrics, scale: scale)
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = Palette.paperBackground
        layer?.addSublayer(scene.root)
        scene.setHint(hint)
        scene.update(layout: model.layout, ghosts: model.ghosts, animated: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.5)
            self?.scene.hintLayer.opacity = 0.35
            CATransaction.commit()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private func refresh() {
        scene.update(layout: model.layout, ghosts: model.ghosts, animated: true)
    }

    private func showNotice(_ text: String, duration: TimeInterval = 2) {
        let notice = scene.noticeLayer
        notice.string = text
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        notice.opacity = 1
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard (notice.string as? String) == text else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            notice.opacity = 0
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
        refresh()
        delegate?.typewriterViewDidChange(self)
    }

    private func backspace() {
        if model.deleteBackward() {
            sounds.play(.backspace)
            refresh()
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
        switch event.keyCode {
        case 36, 76: delegate?.typewriterViewDidCommit(self)
        // ⌘← / ⌘→ cycle the hardware color, ⌘↑ / ⌘↓ cycle the colored part.
        case 123: changeAppearance { Appearance.cycleColor(-1) }
        case 124: changeAppearance { Appearance.cycleColor(1) }
        case 125: changeAppearance { Appearance.cyclePart(1) }
        case 126: changeAppearance { Appearance.cyclePart(-1) }
        default: break
        }
        return true // Swallow all other command shortcuts.
    }

    private func changeAppearance(_ change: () -> Void) {
        change()
        scene.applyAppearance()
        showNotice("\(Appearance.color.name) · \(Appearance.part.title)", duration: 1.5)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            _ = performKeyEquivalent(with: event)
            return
        }
        if event.keyCode == 53, !hasMarkedText() { // Escape
            handleEscape()
            return
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
        scene.markedLayer.string = s
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
        let x = m.printX(col: model.layout.caretCol) - m.charWidth / 2
        let r = NSRect(x: x, y: m.typingY, width: m.charWidth, height: m.lineHeight)
        return window?.convertToScreen(convert(r, to: nil)) ?? r
    }
}
