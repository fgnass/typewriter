import AppKit

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows the typewriter page and sends the text to its target when done.
final class OverlayController: TypewriterViewDelegate {
    let sounds: SoundEngine
    private var window: OverlayWindow?
    private var view: TypewriterView?
    private var previousApp: NSRunningApplication?
    private var focus: FocusState = .notEditable
    private var draftWork: DispatchWorkItem?

    init(sounds: SoundEngine) {
        self.sounds = sounds
    }

    var isShowing: Bool { window != nil }

    func toggle() {
        if let view { typewriterViewDidCommit(view) } else { show() }
    }

    func show() {
        guard window == nil, let screen = NSScreen.screens.first else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        focus = Inserter.focusState(of: previousApp)

        let hint: String
        switch focus {
        case .editable(let name): hint = "⌘↩ insert into \(name)    esc discard"
        case .notEditable: hint = "⌘↩ copy to clipboard    esc discard"
        case .unknown: hint = "⌘↩ copy to clipboard (allow Accessibility to insert directly)    esc discard"
        }

        let frame = screen.frame
        let w = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.isOpaque = true
        w.backgroundColor = NSColor(cgColor: Palette.paperBackground)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.hasShadow = false
        w.setFrame(frame, display: false)

        let metrics = Metrics(size: frame.size)
        let model = TextModel(columns: metrics.columns, text: History.loadDraft() ?? "")
        if let demo = ProcessInfo.processInfo.environment["TYPEWRITER_DEMO"] {
            // Debug aid: prefilled text with one correction, to check the look.
            model.insert(demo + " typo")
            for _ in 0..<4 { model.deleteBackward() }
            model.insert("fixed")
        }
        let v = TypewriterView(frame: CGRect(origin: .zero, size: frame.size), model: model, metrics: metrics,
                               sounds: sounds, scale: screen.backingScaleFactor, hint: hint)
        v.delegate = self
        w.contentView = v
        window = w
        view = v

        sounds.start()
        w.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        NSCursor.setHiddenUntilMouseMoves(true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 1
        }
        sounds.play(.feed)
    }

    private func close(then: @escaping () -> Void) {
        guard let w = window else { return }
        window = nil
        view = nil
        draftWork?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            w.animator().alphaValue = 0
        }, completionHandler: {
            w.orderOut(nil)
            w.close()
            if let app = self.previousApp {
                app.activate()
            } else {
                NSApp.hide(nil)
            }
            then()
        })
    }

    // MARK: TypewriterViewDelegate

    func typewriterViewDidCommit(_ view: TypewriterView) {
        let text = view.model.text
        History.save(text)
        History.clearDraft()
        let focus = self.focus
        sounds.play(.carriageReturn)
        close {
            guard !text.isEmpty else { return }
            switch focus {
            case .editable:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Inserter.paste(text) }
            case .notEditable, .unknown:
                Inserter.copyToClipboard(text)
                HUD.show("Copied to clipboard")
            }
        }
    }

    func typewriterViewDidDiscard(_ view: TypewriterView) {
        History.save(view.model.text)
        History.clearDraft()
        close {}
    }

    func typewriterViewDidChange(_ view: TypewriterView) {
        draftWork?.cancel()
        let text = view.model.text
        let work = DispatchWorkItem { History.saveDraft(text) }
        draftWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

/// A short message in the lower part of the screen.
enum HUD {
    private static var current: NSWindow?

    static func show(_ text: String) {
        current?.orderOut(nil)
        guard let screen = NSScreen.screens.first else { return }
        let label = NSTextField(labelWithString: text)
        label.font = NSFont(name: "Courier", size: 15) ?? .systemFont(ofSize: 15)
        label.textColor = .white
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 40, height: label.frame.height + 22)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + screen.frame.height * 0.14,
                           width: size.width, height: size.height)
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .statusBar
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSView(frame: CGRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        bg.layer?.cornerRadius = 10
        label.frame.origin = CGPoint(x: 20, y: 11)
        bg.addSubview(label)
        w.contentView = bg
        w.orderFrontRegardless()
        current = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; w.animator().alphaValue = 0 },
                                                 completionHandler: { w.orderOut(nil) })
        }
    }
}
