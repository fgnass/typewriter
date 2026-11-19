import AppKit
import SwiftUI

/// The state behind the settings form. Every change is applied at once.
final class SettingsModel: ObservableObject {
    var sounds: SoundEngine? {
        didSet { reload() }
    }

    @Published var hardwareID = Hardware.currentID {
        didSet { if Hardware.currentID != hardwareID { Hardware.currentID = hardwareID } }
    }
    @Published var roomLight = RoomLight.temperature {
        didSet { if RoomLight.temperature != roomLight { RoomLight.temperature = roomLight } }
    }
    @Published var roomLightAutomatic = RoomLight.automatic {
        didSet { if RoomLight.automatic != roomLightAutomatic { RoomLight.automatic = roomLightAutomatic } }
    }
    @Published var hardwareBrightness = RoomLight.brightness {
        didSet { if RoomLight.brightness != hardwareBrightness { RoomLight.brightness = hardwareBrightness } }
    }
    @Published var hardwareTint = RoomLight.tint {
        didSet { if RoomLight.tint != hardwareTint { RoomLight.tint = hardwareTint } }
    }
    @Published var roomLightStrength = RoomLight.strength {
        didSet { if RoomLight.strength != roomLightStrength { RoomLight.strength = roomLightStrength } }
    }
    /// The raw values of the sensor and the display, to compare a manual setting with the automatic one.
    @Published private(set) var sensorText = ""
    @Published var style = SoundEngine.Style.thermal {
        didSet {
            guard let sounds, sounds.style != style else { return }
            sounds.style = style
            sounds.play(.key)
        }
    }
    @Published var light = LightSettings.current {
        didSet { if light != LightSettings.current { LightSettings.current = light } }
    }
    @Published var focus = FocusMode.enabled {
        didSet {
            if FocusMode.enabled != focus { FocusMode.enabled = focus }
            if focus && shortcutInstalled == false { FocusMode.install() }
        }
    }
    /// Nil until checked.
    @Published var shortcutInstalled: Bool?

    @Published var pageStyle = PageStyle.current {
        didSet { if PageStyle.current != pageStyle { PageStyle.current = pageStyle } }
    }
    @Published var shortcut = Shortcut.current {
        didSet { if Shortcut.current != shortcut { Shortcut.current = shortcut } }
    }
    @Published private(set) var recording = false
    private var monitor: Any?
    private weak var previousKeyWindow: NSWindow?

    /// Waits for the next key with ⌃, ⌥ or ⌘. Esc cancels.
    func startRecording() {
        guard !recording else { return }
        recording = true
        NotificationCenter.default.post(name: Shortcut.recordingDidChange, object: true)
        previousKeyWindow = NSApp.keyWindow
        NSApp.activate(ignoringOtherApps: true)
        SettingsPanel.shared.makeKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, event.modifierFlags.intersection([.control, .option, .command]).isEmpty {
                self.stopRecording()
            } else if let s = Shortcut(event: event) {
                self.shortcut = s
                self.stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func stopRecording() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        NotificationCenter.default.post(name: Shortcut.recordingDidChange, object: false)
        previousKeyWindow?.makeKey()
    }

    func checkShortcut() {
        FocusMode.checkInstalled { [weak self] in self?.shortcutInstalled = $0 }
    }

    init() {
        NotificationCenter.default.addObserver(forName: Hardware.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.hardwareID != Hardware.currentID { self.hardwareID = Hardware.currentID }
        }
    }

    /// The page measures the room light only while it is open. The settings can be open without the page,
    /// so they measure too. The page is always on the first screen.
    func measureRoomLight() {
        RoomLight.measure(on: NSScreen.screens.first)
        let text = RoomLight.reading.map {
            "\(Int($0.lux.rounded())) lx · \(Int($0.kelvin.rounded())) K · display \(Int(($0.display * 16).rounded()))/16"
        } ?? "No sensor for this screen"
        if text != sensorText { sensorText = text }
    }

    func reload() {
        hardwareID = Hardware.currentID
        roomLight = RoomLight.temperature
        measureRoomLight()
        roomLightAutomatic = RoomLight.automatic
        hardwareBrightness = RoomLight.brightness
        hardwareTint = RoomLight.tint
        roomLightStrength = RoomLight.strength
        light = LightSettings.current
        focus = FocusMode.enabled
        shortcut = Shortcut.current
        pageStyle = PageStyle.current
        checkShortcut()
        guard let sounds else { return }
        style = sounds.style
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Open Typewriter") {
                    HStack(spacing: 8) {
                        Button(model.recording ? "Type a shortcut…" : model.shortcut.title) {
                            model.recording ? model.stopRecording() : model.startRecording()
                        }
                        .frame(minWidth: 120)
                        Menu {
                            ForEach(Shortcut.suggestions, id: \.title) { s in
                                Button(s.title) { model.stopRecording(); model.shortcut = s }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Suggestions")
                    }
                }
            }

            Section {
                Picker("Around the page", selection: $model.pageStyle) {
                    ForEach(PageStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        ForEach(Hardware.ids, id: \.id) { entry in
                            Button { model.hardwareID = entry.id } label: {
                                Swatch(color: Color(nsColor: Hardware.swatchColor(entry.id)),
                                       selected: model.hardwareID == entry.id)
                            }
                            .buttonStyle(.plain)
                            .help(entry.title)
                            .accessibilityLabel(entry.title)
                            .accessibilityAddTraits(model.hardwareID == entry.id ? .isSelected : [])
                        }
                    }
                } label: {
                    Text(Hardware.ids.first { $0.id == model.hardwareID }?.title ?? "")
                }
                Picker("Room Light", selection: $model.roomLightAutomatic) {
                    Text("Manual").tag(false)
                    Text("Automatic").tag(true)
                }
                .pickerStyle(.segmented)
                if model.roomLightAutomatic {
                    hardwareSlider("Room Light on Housing", value: $model.roomLightStrength, range: RoomLight.strengthRange,
                                   step: 0.1, text: String(format: "× %.1f", pow(2, model.roomLightStrength)))
                } else {
                    hardwareSlider("Color", value: $model.roomLight, range: RoomLight.range, step: 50,
                                   text: Self.kelvinTitle(model.roomLight))
                    hardwareSlider("Tint", value: $model.hardwareTint, range: RoomLight.tintRange, step: 1,
                                   text: "\(Int(model.hardwareTint))")
                    hardwareSlider("Brightness", value: $model.hardwareBrightness, range: RoomLight.brightnessRange, step: 0.01,
                                   text: "\(Int((model.hardwareBrightness * 100).rounded())) %")
                }
                LabeledContent("Sensor") {
                    Text(model.sensorText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Hardware")
            } footer: {
                Text("Shows the hardware as the housing of your Mac looks in the light of the room. Automatic uses the light sensor of the built-in display. The sensor looks at you and the housing lies flat, so the room light can be stronger or weaker on the housing than at the sensor. Adjust that with the slider.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Sound", selection: $model.style) {
                    ForEach(SoundEngine.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section {
                Toggle("Do Not Disturb while writing", isOn: $model.focus)
                if model.focus && model.shortcutInstalled == false {
                    LabeledContent {
                        HStack(spacing: 12) {
                            Button("Add Shortcut…") { FocusMode.install() }
                            Button("Check Again") { model.checkShortcut() }
                                .buttonStyle(.link)
                        }
                    } label: {
                        Text("Needs the shortcut \u{201C}\(FocusMode.shortcutName)\u{201D}")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Turns on Do Not Disturb while the page is open, unless a Focus is already on. Uses a shortcut in the Shortcuts app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(LightSettings.parameters.indices, id: \.self) { i in
                    let p = LightSettings.parameters[i]
                    LabeledContent(p.title) {
                        HStack(spacing: 10) {
                            Slider(value: Binding(get: { model.light[keyPath: p.key] },
                                                  set: { model.light[keyPath: p.key] = $0 }),
                                   in: p.range)
                                .controlSize(.small)
                            Text(p.format(model.light[keyPath: p.key]))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                        .frame(width: 230)
                    }
                }
            } header: {
                HStack {
                    Text("Light")
                    Spacer()
                    Button("Reset") { model.light = .defaults }
                        .buttonStyle(.link)
                        .font(.callout)
                        .disabled(model.light == .defaults)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if SettingsPanel.shared.isVisible { model.measureRoomLight() }
        }
        // The panel never takes the focus, so system switches would always look inactive (grey).
        .toggleStyle(AlwaysActiveSwitch())
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension SettingsView {
    static func kelvinTitle(_ kelvin: Double) -> String {
        kelvin >= RoomLight.neutral ? "Daylight" : "\(Int(kelvin)) K"
    }

    func hardwareSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        text: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value.wrappedValue },
                                      set: { value.wrappedValue = ($0 / step).rounded() * step }),
                       in: range)
                    .controlSize(.small)
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .frame(width: 230)
        }
    }
}

/// A switch that looks like the system switch, but always in its active colors.
struct AlwaysActiveSwitch: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Color(nsColor: .tertiaryLabelColor).opacity(0.5))
                .frame(width: 32, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .padding(1.5)
                }
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
        }
        // For VoiceOver and Full Keyboard Access: a normal switch with the same label.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A color circle like the accent color choice in System Settings.
struct Swatch: View {
    let color: Color
    let selected: Bool

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            .overlay(Circle().fill(.white).frame(width: 6, height: 6).opacity(selected ? 1 : 0)
                .shadow(color: .black.opacity(0.3), radius: 0.5))
            .frame(width: 18, height: 18)
            .padding(2)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
            .contentShape(Circle())
    }
}

/// A floating panel with the settings form. It does not take the keyboard focus,
/// so it can stay open over the page and every change is visible at once.
final class SettingsPanel: NSPanel {
    static let shared = SettingsPanel()
    let model = SettingsModel()

    var sounds: SoundEngine? {
        get { model.sounds }
        set { model.sounds = newValue }
    }

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                   styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Settings"
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SettingsView(model: model))
        contentView = host
        setContentSize(host.fittingSize)
    }

    /// A shortcut recording must not outlive the panel: the global shortcut is off while it runs.
    override func orderOut(_ sender: Any?) {
        model.stopRecording()
        super.orderOut(sender)
    }

    override func close() {
        model.stopRecording()
        super.close()
    }

    override func resignKey() {
        super.resignKey()
        model.stopRecording()
    }

    func toggle() {
        if isVisible {
            orderOut(nil)
            return
        }
        model.reload()
        if let screen = NSScreen.screens.first {
            let f = screen.visibleFrame
            setFrameTopLeftPoint(NSPoint(x: f.maxX - frame.width - 24, y: f.maxY - 24))
        }
        orderFrontRegardless()
    }
}
