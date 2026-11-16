import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sounds = SoundEngine()
    private lazy var overlay = OverlayController(sounds: sounds)
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let recentMenu = NSMenu()
    private let colorMenu = NSMenu()
    private let partMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌘^ : keycode 10 is the key left of "1" on ISO keyboards (German "^").
        hotKey = HotKey(keyCode: UInt32(kVK_ISO_Section), modifiers: UInt32(cmdKey)) { [weak self] in
            self?.overlay.toggle()
        }
        setupMenu()
        if !Inserter.isTrusted { Inserter.requestTrust() }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.overlay.show() }
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Typewriter")
        let menu = NSMenu()
        menu.delegate = self
        let open = NSMenuItem(title: "Open Typewriter", action: #selector(openTypewriter), keyEquivalent: "^")
        open.keyEquivalentModifierMask = .command
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let sound = NSMenuItem(title: "Sounds", action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self
        sound.tag = 1
        menu.addItem(sound)
        if sounds.hasHum {
            let hum = NSMenuItem(title: "Motor Hum", action: #selector(toggleHum), keyEquivalent: "")
            hum.target = self
            hum.tag = 3
            hum.indentationLevel = 1
            menu.addItem(hum)
        }
        let colorItem = NSMenuItem(title: "Hardware Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        let partItem = NSMenuItem(title: "Colored Part", action: nil, keyEquivalent: "")
        partItem.submenu = partMenu
        menu.addItem(partItem)
        let recent = NSMenuItem(title: "Recent Pages", action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        menu.addItem(recent)
        let folder = NSMenuItem(title: "Show History Folder", action: #selector(showHistory), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 1)?.state = sounds.enabled ? .on : .off
        menu.item(withTag: 3)?.state = sounds.humEnabled ? .on : .off
        if Inserter.isTrusted, let ax = menu.item(withTag: 2) { menu.removeItem(ax) }
        colorMenu.removeAllItems()
        for (i, c) in HardwareColor.all.enumerated() {
            if i == 7 { colorMenu.addItem(.separator()) } // MacBook colors first, then iMac colors.
            let item = NSMenuItem(title: c.name, action: #selector(selectColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = c == Appearance.color ? .on : .off
            item.image = swatch(c)
            colorMenu.addItem(item)
        }
        partMenu.removeAllItems()
        for (i, p) in ColoredPart.allCases.enumerated() {
            let item = NSMenuItem(title: p.title, action: #selector(selectPart(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = p == Appearance.part ? .on : .off
            partMenu.addItem(item)
        }
        recentMenu.removeAllItems()
        let pages = History.recent()
        if pages.isEmpty {
            recentMenu.addItem(NSMenuItem(title: "No pages yet", action: nil, keyEquivalent: ""))
        }
        for page in pages {
            let item = NSMenuItem(title: page.preview, action: #selector(copyPage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = page.url
            item.toolTip = "Copy to clipboard"
            recentMenu.addItem(item)
        }
    }

    @objc private func openTypewriter() { overlay.show() }
    @objc private func selectColor(_ sender: NSMenuItem) { Appearance.color = HardwareColor.all[sender.tag] }
    @objc private func selectPart(_ sender: NSMenuItem) { Appearance.part = ColoredPart.allCases[sender.tag] }

    private func swatch(_ c: HardwareColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            let path = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
            path.fill()
            NSColor(white: 0, alpha: 0.25).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }
    @objc private func toggleSound() { sounds.enabled.toggle() }
    @objc private func toggleHum() { sounds.humEnabled.toggle() }
    @objc private func showHistory() { NSWorkspace.shared.open(History.directory) }
    @objc private func requestAccess() { Inserter.requestTrust() }

    @objc private func copyPage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        Inserter.copyToClipboard(text)
        HUD.show("Copied to clipboard")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
