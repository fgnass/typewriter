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
    /// True during the fade-out. A new page opens only after it, so the old close cannot activate the wrong app.
    private var closing = false
    /// Counts the pages. A paste that is still waiting is cancelled when a new page opens.
    private var session = 0
    /// The last page, for "Copy Last Page" in the menu. Only in memory.
    private(set) var lastPage: String?

    init(sounds: SoundEngine) {
        self.sounds = sounds
    }

    var isShowing: Bool { window != nil }

    func toggle() {
        if let view { typewriterViewDidCommit(view) } else { show() }
    }

    func show() {
        guard window == nil, !closing, let screen = NSScreen.screens.first else { return }
        session += 1
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        focus = Inserter.focusState(of: previousApp)
        // Debug aid for the website video: the mock-up's text field counts as editable at once.
        if let name = ProcessInfo.processInfo.environment["TYPEWRITER_APPNAME"] { focus = .editable(appName: name, element: nil) }

        let hint = Self.hint(for: focus)

        let frame = screen.frame
        let w = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.isOpaque = true
        w.backgroundColor = NSColor(cgColor: Palette.paperBackground)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.hasShadow = false
        w.setFrame(frame, display: false)

        RoomLight.measure(on: screen, notify: false)
        guard let variant = Hardware.current else {
            HUD.show("Hardware assets are missing")
            return
        }
        let model = TextModel(columns: 72, text: "")
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
        if let script = ProcessInfo.processInfo.environment["TYPEWRITER_SCRIPT"] {
            // Debug aid for the website video: types the script like a person and sends it.
            v.play(script: script.replacingOccurrences(of: "\\n", with: "\n"))
        }
        FocusMode.begin()
        switch focus {
        case .notEditable, .maybeEditable: if previousApp != nil { watchFocus(session: session) }
        default: break
        }
    }

    private static func hint(for focus: FocusState) -> String {
        switch focus {
        case .editable(let name, _), .maybeEditable(let name): return "⌘↩ insert into \(name)    esc discard    ⌘, light"
        case .notEditable: return "⌘↩ copy to clipboard    esc discard"
        case .unknown: return "⌘↩ copy to clipboard (allow Accessibility to insert directly)    esc discard"
        }
    }

    /// Chrome builds its accessibility tree only when a client asks for it, and drops it again after a pause.
    /// The first question then gets the web area instead of the text field. So ask again for a few seconds
    /// while the page is open, and switch to insert mode when the text field shows up.
    private func watchFocus(session: Int, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard session == self.session, self.window != nil, !self.closing else { return }
            if case .editable = self.focus { return }
            let state = Inserter.focusState(of: self.previousApp)
            if case .editable = state {
                self.focus = state
                self.view?.hint = Self.hint(for: state)
            } else if attempt < 20 {
                self.watchFocus(session: session, attempt: attempt + 1)
            }
        }
    }

    private func close(then: @escaping () -> Void) {
        guard let w = window else { return }
        window = nil
        view = nil
        closing = true
        let target = previousApp
        sounds.stopHum()
        FocusMode.end()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            w.animator().alphaValue = 0
        }, completionHandler: {
            w.orderOut(nil)
            w.close()
            if let app = target {
                app.activate()
            } else if let stage = Stage.shared {
                stage.focus()
            } else {
                NSApp.hide(nil)
            }
            self.closing = false
            then()
        })
    }

    /// The app quits (for example for an update) while a page is open: its text goes to the clipboard.
    func rescueOpenPage() {
        guard let view else { return }
        view.finishComposition()
        let text = view.model.text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Inserter.copyToClipboard(text) }
    }

    // MARK: TypewriterViewDelegate

    func typewriterViewDidCommit(_ view: TypewriterView) {
        view.finishComposition()
        let text = view.model.text
        remember(text)
        let focus = self.focus
        let target = previousApp
        sounds.play(.key, volume: 0.6) // A short, light click instead of a long carriage return.
        close {
            guard !text.isEmpty else { return }
            switch focus {
            case .editable(_, let element):
                if let stage = Stage.shared {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { stage.insert(text) }
                } else if let element {
                    self.paste(text, into: target, element: element, session: self.session)
                } else {
                    Inserter.copyToClipboard(text)
                    HUD.show("Copied to clipboard")
                }
            case .maybeEditable:
                if Stage.shared == nil {
                    self.pasteWhenInFront(text, into: target, session: self.session)
                } else {
                    Inserter.copyToClipboard(text)
                    HUD.show("Copied to clipboard")
                }
            case .notEditable, .unknown:
                Inserter.copyToClipboard(text)
                HUD.show("Copied to clipboard")
            }
        }
    }

    /// Pastes when the target app is in front again and the same text field has the focus. If that does not
    /// happen within about a second (the user switched to another app or field), the text goes to the clipboard.
    /// A new page cancels the wait; the text then goes to the clipboard at once.
    private func paste(_ text: String, into target: NSRunningApplication?, element: AXUIElement, session: Int, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.2 : 0.1)) {
            if session != self.session {
                Inserter.copyToClipboard(text)
            } else if Inserter.canPaste(into: target, element: element) {
                Inserter.paste(text)
            } else if attempt < 8 {
                self.paste(text, into: target, element: element, session: session, attempt: attempt + 1)
            } else {
                Inserter.copyToClipboard(text)
                HUD.show("The text field lost the focus. Copied to clipboard.")
            }
        }
    }

    /// For an app that does not tell where its focus is: pastes as soon as the app is in front again.
    /// The text also stays on the clipboard, because it is not sure that the paste lands in a text field.
    private func pasteWhenInFront(_ text: String, into target: NSRunningApplication?, session: Int, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.2 : 0.1)) {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if session == self.session, let target, front == target.processIdentifier {
                Inserter.paste(text, keep: true)
            } else if session == self.session, attempt < 8 {
                self.pasteWhenInFront(text, into: target, session: session, attempt: attempt + 1)
            } else {
                Inserter.copyToClipboard(text)
                HUD.show("Copied to clipboard")
            }
        }
    }

    func typewriterViewDidDiscard(_ view: TypewriterView) {
        view.finishComposition()
        let text = view.model.text
        remember(text)
        close {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HUD.show("Page put away. Copy Last Page is in the menu.")
            }
        }
    }

    func typewriterViewDidChange(_ view: TypewriterView) {}

    /// Only the last page is kept, and only in memory: Typewriter saves no files with the text.
    private func remember(_ text: String) {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastPage = text }
    }
}

/// A short message in the lower part of the screen.
enum HUD {
    private static var current: NSWindow?

    static func show(_ text: String) {
        current?.orderOut(nil)
        guard let screen = NSScreen.screens.first else { return }
        let label = NSTextField(labelWithString: text)
        label.font = NSFont(name: Metrics.fontName as String, size: 15) ?? .systemFont(ofSize: 15)
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
