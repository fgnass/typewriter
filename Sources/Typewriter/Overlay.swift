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
        History.log("show: trusted=\(Inserter.isTrusted) target=\(previousApp?.bundleIdentifier ?? "none") focus=\(focus)")

        let hint: String
        switch focus {
        case .editable(let name): hint = "⌘↩ insert into \(name)    esc discard    ⌘, light"
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

        guard let variant = Hardware.current else {
            HUD.show("Hardware assets are missing")
            return
        }
        let model = TextModel(columns: 72, text: History.loadDraft() ?? "")
        if let demo = ProcessInfo.processInfo.environment["TYPEWRITER_DEMO"] {
            // Debug aid: prefilled text to check the look. A "~" is typed and removed again with the correction tape.
            for part in demo.split(separator: "~", omittingEmptySubsequences: false).enumerated() {
                if part.offset > 0 { model.insert("x"); model.deleteBackward() }
                model.insert(String(part.element))
            }
        }
        let v = TypewriterView(frame: CGRect(origin: .zero, size: frame.size), model: model, variant: variant,
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
        sounds.startHum()
    }

    private func close(then: @escaping () -> Void) {
        guard let w = window else { return }
        window = nil
        view = nil
        draftWork?.cancel()
        sounds.stopHum()
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
        sounds.play(.key, volume: 0.6) // A short, light click instead of a long carriage return.
        close {
            guard !text.isEmpty else { return }
            switch focus {
            case .editable:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    History.log("paste: frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
                    Inserter.paste(text)
                }
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
