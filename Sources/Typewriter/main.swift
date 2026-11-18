import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sounds = SoundEngine()
    private lazy var overlay = OverlayController(sounds: sounds)
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var openItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerHotKey()
        NotificationCenter.default.addObserver(forName: Shortcut.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKey()
            self?.updateOpenItem()
        }
        // While the settings record a new shortcut, the old one must not fire.
        NotificationCenter.default.addObserver(forName: Shortcut.recordingDidChange, object: nil, queue: .main) { [weak self] n in
            if n.object as? Bool == true { self?.hotKey = nil } else { self?.registerHotKey() }
        }
        if let dir = ProcessInfo.processInfo.environment["TYPEWRITER_EXPORT_SOUNDS"] {
            sounds.export(to: URL(fileURLWithPath: dir))
            exit(0)
        }
        SettingsPanel.shared.sounds = sounds
        setupMenu()
        if !Inserter.isTrusted { Inserter.requestTrust() }
        if let path = ProcessInfo.processInfo.environment["TYPEWRITER_STAGE"], let stage = Stage(path: path) {
            Stage.shared = stage
            stage.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.overlay.show() }
        } else if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.overlay.show() }
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Open Typewriter", action: #selector(openTypewriter), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        openItem = open
        updateOpenItem()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let last = NSMenuItem(title: "Copy Last Page", action: #selector(copyLastPage), keyEquivalent: "")
        last.target = self
        last.tag = 1
        menu.addItem(last)
        if !Inserter.isTrusted {
            let ax = NSMenuItem(title: "Allow Accessibility…", action: #selector(requestAccess), keyEquivalent: "")
            ax.target = self
            ax.tag = 2
            menu.addItem(ax)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func registerHotKey() {
        let s = Shortcut.current
        hotKey = nil
        hotKey = HotKey(keyCode: s.keyCode, modifiers: s.carbonModifiers) { [weak self] in
            self?.overlay.toggle()
        }
    }

    /// The menu shows the shortcut, but it only works globally: the menu item itself does not react to it.
    private func updateOpenItem() {
        let s = Shortcut.current
        openItem?.keyEquivalent = s.menuKeyEquivalent ?? ""
        openItem?.keyEquivalentModifierMask = s.modifiers
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if Inserter.isTrusted, let ax = menu.item(withTag: 2) { menu.removeItem(ax) }
        menu.item(withTag: 1)?.isEnabled = overlay.lastPage != nil
    }

    /// The T of the page font as a template image, so the menu bar tints it.
    private static func menuBarIcon() -> NSImage {
        let font = NSFont(name: Metrics.fontName as String, size: 19) ?? .systemFont(ofSize: 17, weight: .semibold)
        let text = NSAttributedString(string: "T", attributes: [.font: font, .foregroundColor: NSColor.black])
        let glyph = text.size()
        let size = NSSize(width: ceil(glyph.width) + 2, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            text.draw(at: NSPoint(x: (size.width - glyph.width) / 2, y: (size.height - glyph.height) / 2 + 0.5))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Typewriter"
        return image
    }

    func applicationWillTerminate(_ notification: Notification) {
        FocusMode.end(wait: true)
    }

    @objc private func openTypewriter() { overlay.show() }
    @objc private func showSettings() { SettingsPanel.shared.toggle() }
    @objc private func requestAccess() { Inserter.requestTrust() }

    @objc private func copyLastPage() {
        guard let text = overlay.lastPage else { return }
        Inserter.copyToClipboard(text)
        HUD.show("Copied to clipboard")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
