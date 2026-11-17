import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sounds = SoundEngine()
    private lazy var overlay = OverlayController(sounds: sounds)
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let recentMenu = NSMenu()
    private let colorMenu = NSMenu()
    private let styleMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌘^ : keycode 10 is the key left of "1" on ISO keyboards (German "^").
        hotKey = HotKey(keyCode: UInt32(kVK_ISO_Section), modifiers: UInt32(cmdKey)) { [weak self] in
            self?.overlay.toggle()
        }
        if let dir = ProcessInfo.processInfo.environment["TYPEWRITER_EXPORT_SOUNDS"] {
            sounds.export(to: URL(fileURLWithPath: dir))
            exit(0)
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
        let styleItem = NSMenuItem(title: "Sound Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        styleItem.indentationLevel = 1
        menu.addItem(styleItem)
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
        let lightItem = NSMenuItem(title: "Light Settings…", action: #selector(showLight), keyEquivalent: ",")
        lightItem.target = self
        menu.addItem(lightItem)
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
        styleMenu.removeAllItems()
        for (i, st) in SoundEngine.Style.allCases.enumerated() {
            let item = NSMenuItem(title: st.title, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = st == sounds.style ? .on : .off
            styleMenu.addItem(item)
        }
        colorMenu.removeAllItems()
        for (i, c) in Hardware.ids.enumerated() {
            if i == 7 { colorMenu.addItem(.separator()) } // MacBook colors first, then MacBook Neo colors.
            let item = NSMenuItem(title: c.title, action: #selector(selectColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = c.id == Hardware.currentID ? .on : .off
            colorMenu.addItem(item)
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
    @objc private func selectColor(_ sender: NSMenuItem) { Hardware.currentID = Hardware.ids[sender.tag].id }
    @objc private func showLight() { LightPanel.shared.toggle() }
    @objc private func selectStyle(_ sender: NSMenuItem) { sounds.style = SoundEngine.Style.allCases[sender.tag] }
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
