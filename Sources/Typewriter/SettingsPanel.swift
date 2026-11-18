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
            guard let self, self.hardwareID != Hardware.currentID else { return }
            self.hardwareID = Hardware.currentID
        }
    }

    func reload() {
        hardwareID = Hardware.currentID
        light = LightSettings.current
        focus = FocusMode.enabled
        shortcut = Shortcut.current
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

            Section("Hardware") {
                LabeledContent {
                    HStack(spacing: 8) {
                        ForEach(Hardware.ids, id: \.id) { entry in
                            Swatch(color: Color(nsColor: Hardware.swatchColor(entry.id)),
                                   selected: model.hardwareID == entry.id)
                                .onTapGesture { model.hardwareID = entry.id }
                                .help(entry.title)
                        }
                    }
                } label: {
                    Text(Hardware.ids.first { $0.id == model.hardwareID }?.title ?? "")
                }
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
        // The panel never takes the focus, so system switches would always look inactive (grey).
        .toggleStyle(AlwaysActiveSwitch())
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
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
