import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sounds = SoundEngine()
    private lazy var overlay = OverlayController(sounds: sounds)
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let recentMenu = NSMenu()

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
        if Inserter.isTrusted, let ax = menu.item(withTag: 2) { menu.removeItem(ax) }
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
    @objc private func toggleSound() { sounds.enabled.toggle() }
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
