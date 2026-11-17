import AppKit

/// A small floating panel with sliders for the light parameters.
/// It does not take the keyboard focus, so typing continues on the page.
final class LightPanel: NSPanel {
    static let shared = LightPanel()

    private var sliders: [NSSlider] = []
    private var valueLabels: [NSTextField] = []

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 10),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Light"
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        buildContent()
    }

    private func buildContent() {
        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        let settings = LightSettings.current
        for (i, p) in LightSettings.parameters.enumerated() {
            let label = NSTextField(labelWithString: p.title)
            let slider = NSSlider(value: settings[keyPath: p.key], minValue: p.range.lowerBound, maxValue: p.range.upperBound,
                                  target: self, action: #selector(changed(_:)))
            slider.tag = i
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let value = NSTextField(labelWithString: p.format(settings[keyPath: p.key]))
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 56).isActive = true
            grid.addRow(with: [label, slider, value])
            sliders.append(slider)
            valueLabels.append(value)
        }
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetAll))
        grid.addRow(with: [NSGridCell.emptyContentView, NSGridCell.emptyContentView, reset])
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        contentView = content
        setContentSize(content.fittingSize)
    }

    @objc private func changed(_ sender: NSSlider) {
        let p = LightSettings.parameters[sender.tag]
        var s = LightSettings.current
        s[keyPath: p.key] = sender.doubleValue
        valueLabels[sender.tag].stringValue = p.format(sender.doubleValue)
        LightSettings.current = s
    }

    @objc private func resetAll() {
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
        if let screen = NSScreen.screens.first {
            let f = screen.visibleFrame
            setFrameTopLeftPoint(NSPoint(x: f.maxX - frame.width - 24, y: f.maxY - 24))
        }
        orderFrontRegardless()
    }
}
