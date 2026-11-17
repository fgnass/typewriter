import AppKit

/// A floating settings panel: hardware color, sound and light. It does not take the keyboard focus,
/// so it can stay open over the page and every change is visible at once.
final class SettingsPanel: NSPanel {
    static let shared = SettingsPanel()

    /// Set by the app delegate.
    var sounds: SoundEngine? {
        didSet { syncSound() }
    }

    private var swatches: [SwatchButton] = []
    private var sliders: [NSSlider] = []
    private var valueLabels: [NSTextField] = []
    private let soundCheckbox = NSButton(checkboxWithTitle: "Sounds", target: nil, action: nil)
    private let humCheckbox = NSButton(checkboxWithTitle: "Motor hum", target: nil, action: nil)
    private let stylePopup = NSPopUpButton()
    private let printPopup = NSPopUpButton()
    private let colorName = NSTextField(labelWithString: "")

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 10),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Settings"
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        buildContent()
        NotificationCenter.default.addObserver(forName: Hardware.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.syncHardware()
        }
    }

    // MARK: Layout

    private func header(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func buildContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 20)

        // Hardware color: a row of color circles.
        stack.addArrangedSubview(header("HARDWARE"))
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        for (i, entry) in Hardware.ids.enumerated() {
            let b = SwatchButton(color: Hardware.swatchColor(entry.id), title: entry.title)
            b.tag = i
            b.target = self
            b.action = #selector(selectColor(_:))
            swatches.append(b)
            row.addArrangedSubview(b)
        }
        stack.addArrangedSubview(row)
        colorName.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        colorName.textColor = .secondaryLabelColor
        stack.addArrangedSubview(colorName)
        stack.setCustomSpacing(16, after: colorName)

        // Sound.
        stack.addArrangedSubview(header("SOUND"))
        soundCheckbox.target = self
        soundCheckbox.action = #selector(toggleSound)
        stack.addArrangedSubview(soundCheckbox)
        let soundGrid = NSGridView()
        soundGrid.rowSpacing = 6
        soundGrid.columnSpacing = 10
        stylePopup.addItems(withTitles: SoundEngine.Style.allCases.map(\.title))
        stylePopup.target = self
        stylePopup.action = #selector(selectStyle)
        printPopup.addItems(withTitles: ThermalSynth.PrintSound.allCases.map(\.title))
        printPopup.target = self
        printPopup.action = #selector(selectPrintSound)
        soundGrid.addRow(with: [NSTextField(labelWithString: "Style"), stylePopup])
        soundGrid.addRow(with: [NSTextField(labelWithString: "Print sound"), printPopup])
        stack.addArrangedSubview(soundGrid)
        humCheckbox.target = self
        humCheckbox.action = #selector(toggleHum)
        stack.addArrangedSubview(humCheckbox)
        stack.setCustomSpacing(16, after: humCheckbox)

        // Light.
        stack.addArrangedSubview(header("LIGHT"))
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        let settings = LightSettings.current
        for (i, p) in LightSettings.parameters.enumerated() {
            let label = NSTextField(labelWithString: p.title)
            let slider = NSSlider(value: settings[keyPath: p.key], minValue: p.range.lowerBound, maxValue: p.range.upperBound,
                                  target: self, action: #selector(changed(_:)))
            slider.tag = i
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let value = NSTextField(labelWithString: p.format(settings[keyPath: p.key]))
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 64).isActive = true
            grid.addRow(with: [label, slider, value])
            sliders.append(slider)
            valueLabels.append(value)
        }
        let reset = NSButton(title: "Reset Light", target: self, action: #selector(resetLight))
        grid.addRow(with: [NSGridCell.emptyContentView, reset, NSGridCell.emptyContentView])
        stack.addArrangedSubview(grid)

        contentView = stack
        setContentSize(stack.fittingSize)
        syncHardware()
        syncSound()
    }

    // MARK: Sync

    private func syncHardware() {
        let id = Hardware.currentID
        for (i, s) in swatches.enumerated() { s.isSelected = Hardware.ids[i].id == id }
        colorName.stringValue = Hardware.ids.first { $0.id == id }?.title ?? ""
    }

    private func syncSound() {
        guard let sounds else { return }
        soundCheckbox.state = sounds.enabled ? .on : .off
        stylePopup.selectItem(at: SoundEngine.Style.allCases.firstIndex(of: sounds.style) ?? 0)
        printPopup.selectItem(at: ThermalSynth.PrintSound.allCases.firstIndex(of: .current) ?? 0)
        printPopup.isEnabled = sounds.enabled && sounds.style == .thermal
        stylePopup.isEnabled = sounds.enabled
        humCheckbox.state = sounds.humEnabled ? .on : .off
        humCheckbox.isEnabled = sounds.enabled && sounds.hasHum
    }

    // MARK: Actions

    @objc private func selectColor(_ sender: SwatchButton) {
        Hardware.currentID = Hardware.ids[sender.tag].id
    }

    @objc private func toggleSound() {
        sounds?.enabled = soundCheckbox.state == .on
        syncSound()
    }

    @objc private func selectStyle() {
        sounds?.style = SoundEngine.Style.allCases[stylePopup.indexOfSelectedItem]
        sounds?.play(.key)
        syncSound()
    }

    @objc private func selectPrintSound() {
        ThermalSynth.PrintSound.current = ThermalSynth.PrintSound.allCases[printPopup.indexOfSelectedItem]
        sounds?.reload()
        sounds?.play(.key)
    }

    @objc private func toggleHum() {
        sounds?.humEnabled = humCheckbox.state == .on
    }

    @objc private func changed(_ sender: NSSlider) {
        let p = LightSettings.parameters[sender.tag]
        var s = LightSettings.current
        s[keyPath: p.key] = sender.doubleValue
        valueLabels[sender.tag].stringValue = p.format(sender.doubleValue)
        LightSettings.current = s
    }

    @objc private func resetLight() {
        LightSettings.current = .defaults
        for (i, p) in LightSettings.parameters.enumerated() {
            sliders[i].doubleValue = LightSettings.defaults[keyPath: p.key]
            valueLabels[i].stringValue = p.format(sliders[i].doubleValue)
        }
    }

    func toggle() {
        if isVisible {
            orderOut(nil)
            return
        }
        syncHardware()
        syncSound()
        if let screen = NSScreen.screens.first {
            let f = screen.visibleFrame
            setFrameTopLeftPoint(NSPoint(x: f.maxX - frame.width - 24, y: f.maxY - 24))
        }
        orderFrontRegardless()
    }
}

/// A round color swatch. The selected one gets a ring.
final class SwatchButton: NSControl {
    private let color: NSColor
    var isSelected = false { didSet { needsDisplay = true } }

    init(color: NSColor, title: String) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        toolTip = title
        setAccessibilityLabel(title)
        setAccessibilityRole(.button)
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        if isSelected {
            let ring = NSBezierPath(ovalIn: b.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
        let dot = NSBezierPath(ovalIn: b.insetBy(dx: 4.5, dy: 4.5))
        color.setFill()
        dot.fill()
        NSColor(white: 0, alpha: 0.2).setStroke()
        dot.lineWidth = 0.5
        dot.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}
