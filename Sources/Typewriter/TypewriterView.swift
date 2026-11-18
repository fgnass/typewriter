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
    private(set) var metrics: Metrics
    let sounds: SoundEngine
    private var scene: PaperScene
    private let scale: CGFloat
    private var hint: String
    private var lightObserver: NSObjectProtocol?
    private var hardwareObserver: NSObjectProtocol?
    private var styleObserver: NSObjectProtocol?

    private var marked: String = ""
    private var bellRungOnLine = -1

    init(frame: CGRect, model: TextModel, variant: HardwareVariant, sounds: SoundEngine, scale: CGFloat, hint: String) {
        self.model = model
        self.sounds = sounds
        self.scale = scale
        self.hint = hint
        metrics = Metrics(size: frame.size)
        scene = PaperScene(metrics: metrics, variant: variant, scale: scale)
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = Palette.paperBackground
        layer?.addSublayer(scene.root)
        scene.setHint(hint)
        scene.update(layout: model.layout, ghosts: model.ghosts, animated: false)
        scene.setCapsLock(NSEvent.modifierFlags.contains(.capsLock))
        lightObserver = NotificationCenter.default.addObserver(forName: LightSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.scene.updateLight(LightSettings.current)
        }
        hardwareObserver = NotificationCenter.default.addObserver(forName: Hardware.didChange, object: nil, queue: .main) { [weak self] _ in
            if let v = Hardware.current { self?.reloadScene(variant: v) }
        }
        styleObserver = NotificationCenter.default.addObserver(forName: PageStyle.didChange, object: nil, queue: .main) { [weak self] _ in
            if let v = Hardware.current { self?.reloadScene(variant: v) }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.5)
            self?.scene.hintLayer.opacity = 0.35
            CATransaction.commit()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let lightObserver { NotificationCenter.default.removeObserver(lightObserver) }
        if let hardwareObserver { NotificationCenter.default.removeObserver(hardwareObserver) }
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
    }

    /// Builds the scene again for another hardware variant. The text stays.
    private func reloadScene(variant: HardwareVariant) {
        let old = scene
        metrics = Metrics(size: bounds.size)
        scene = PaperScene(metrics: metrics, variant: variant, scale: scale)
        scene.setHint(hint)
        scene.hintLayer.opacity = old.hintLayer.opacity
        scene.update(layout: model.layout, ghosts: model.ghosts, animated: false)
        scene.setCapsLock(NSEvent.modifierFlags.contains(.capsLock))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.replaceSublayer(old.root, with: scene.root)
        CATransaction.commit()
    }

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
        if clean.contains(where: { !$0.isWhitespace }) { scene.flashStatus() }
        delegate?.typewriterViewDidChange(self)
    }

    /// Types a script like a person, then sends the page. "⌫" in the script is a backspace.
    /// Only a debug aid for the website video (TYPEWRITER_SCRIPT).
    /// macOS bundles the timers of a background app to save energy, which made 2–3 keys land at once.
    /// So each key is scheduled by a strict timer after the one before, and App Nap is off meanwhile.
    func play(script: String, start: TimeInterval = 1.2) {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Typing a script for a video")
        var keys = Array(script)
        var previous: Character = " "
        let log = ProcessInfo.processInfo.environment["TYPEWRITER_TIMING"] != nil
        func gap(before c: Character) -> TimeInterval {
            // Faster inside words, a short stop after punctuation and before a new line.
            var g = Double.random(in: 0.11...0.21)
            if previous == " " { g += Double.random(in: 0.04...0.18) }
            if ".,!?".contains(previous) { g += 0.35 }
            if c == "\n" { g += 0.3 }
            if previous == "\n" { g += 0.55 } // wait for the carriage to return
            return g
        }
        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            timer.schedule(deadline: .now() + delay, leeway: .milliseconds(1))
            timer.setEventHandler { timer.cancel(); work() }
            timer.resume()
        }
        func next() {
            guard !keys.isEmpty else {
                schedule(after: 1.4) { [weak self] in
                    ProcessInfo.processInfo.endActivity(activity)
                    guard let self else { return }
                    self.delegate?.typewriterViewDidCommit(self)
                }
                return
            }
            let c = keys.removeFirst()
            let delay = gap(before: c)
            previous = c
            let planned = CACurrentMediaTime() + delay
            schedule(after: delay) { [weak self] in
                guard let self else { return }
                if log {
                    FileHandle.standardError.write(String(format: "%@ late %.0f ms\n", String(c), (CACurrentMediaTime() - planned) * 1000).data(using: .utf8)!)
                }
                if c == "⌫" { self.backspace() } else { self.type(String(c)) }
                next()
            }
        }
        schedule(after: start) { next() }
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
        // ⌘← / ⌘→ cycle the hardware color.
        case 123: changeHardware(-1)
        case 124: changeHardware(1)
        default:
            // ⌘, shows the settings. The panel does not take the keyboard focus.
            if event.charactersIgnoringModifiers == "," { SettingsPanel.shared.toggle() }
        }
        return true // Swallow all other command shortcuts.
    }

    private func changeHardware(_ step: Int) {
        Hardware.cycle(step) // The scene follows through the change notification.
        if let v = Hardware.current { showNotice(v.title, duration: 1.5) }
    }

    override func flagsChanged(with event: NSEvent) {
        scene.setCapsLock(event.modifierFlags.contains(.capsLock))
        super.flagsChanged(with: event)
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
        if inputContext?.handleEvent(event) != true {
            interpretKeyEvents([event])
        }
    }

    /// One press closes the page. Nothing is lost: the page stays available as Copy Last Page.
    private func handleEscape() {
        delegate?.typewriterViewDidDiscard(self)
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

    /// The input method accepts the marked text as it is.
    func unmarkText() {
        let s = marked
        setMarked("")
        if !s.isEmpty { type(s) }
    }

    /// Takes over a composition that is still open (input methods, dead keys), so the page has all visible text.
    func finishComposition() {
        guard hasMarkedText() else { return }
        unmarkText()
        inputContext?.discardMarkedText()
    }
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
        // Without marked text (dead keys, input methods) nothing needs this position. macOS would place its
        // Caps Lock indicator here, over the carriage, so it gets a position outside of all screens instead.
        // The carriage shows Caps Lock with its own green light.
        guard hasMarkedText() else { return NSRect(x: -100_000, y: -100_000, width: 0, height: 0) }
        let m = metrics
        let x = m.cellX(col: model.layout.caretCol)
        let r = NSRect(x: x, y: m.typingY, width: m.charWidth, height: m.lineHeight)
        return window?.convertToScreen(convert(r, to: nil)) ?? r
    }
}
