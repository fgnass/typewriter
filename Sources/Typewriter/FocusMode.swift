import AppKit

/// Turns on Do Not Disturb while the page is open, and off again when it closes.
///
/// macOS has no public API for Focus. The private one rejects apps without an Apple entitlement.
/// So Typewriter uses a shortcut in the Shortcuts app, which it creates once ("Add Shortcut…" in
/// the settings) and then runs with the `shortcuts` command line tool:
///   with input:    if no Focus is active, turn on Do Not Disturb
///   without input: turn off Do Not Disturb
///   output:      the Focus that was active before, empty if there was none
/// Typewriter turns Do Not Disturb off again only when it turned it on itself.
enum FocusMode {
    static let shortcutName = "Typewriter Focus"
    static let didChange = Notification.Name("FocusModeDidChange")

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "focusEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "focusEnabled")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Runs the shortcut calls one after another, never on the main thread.
    private static let queue = DispatchQueue(label: "typewriter.focus")
    /// True while Do Not Disturb is on because of us. Only used on `queue`.
    private static var turnedOn = false

    /// The page opens.
    static func begin() {
        guard enabled else { return }
        queue.async {
            guard !turnedOn, let before = run(on: true) else { return }
            turnedOn = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The page closes. `wait` blocks until it is done, for the quit of the app.
    static func end(wait: Bool = false) {
        let work = {
            guard turnedOn else { return }
            // Keep the state when it fails, so the next close tries again.
            if run(on: false) != nil {
                turnedOn = false
            } else {
                DispatchQueue.main.async { HUD.show("Could not turn off Do Not Disturb") }
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    // MARK: - The shortcut

    /// Calls back on the main thread.
    static func checkInstalled(_ done: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let names = shortcuts(["list"]).output ?? ""
            let found = names.split(separator: "\n").contains { $0 == shortcutName }
            DispatchQueue.main.async { done(found) }
        }
    }

    /// Writes the shortcut, signs it for this Mac and opens it in Shortcuts, which asks to add it.
    static func install() {
        DispatchQueue.global().async {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TypewriterShortcut", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let raw = dir.appendingPathComponent("unsigned.shortcut")
            let signed = dir.appendingPathComponent("\(shortcutName).shortcut")
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: workflow(), format: .binary, options: 0)
                try data.write(to: raw)
            } catch {
                DispatchQueue.main.async { HUD.show("Could not write the shortcut") }
                return
            }
            let result = shortcuts(["sign", "--mode", "people-who-know-me", "--input", raw.path, "--output", signed.path])
            DispatchQueue.main.async {
                guard result.status == 0, FileManager.default.fileExists(atPath: signed.path) else {
                    HUD.show("Could not sign the shortcut")
                    return
                }
                NSWorkspace.shared.open(signed)
            }
        }
    }

    /// Runs the shortcut and returns its output, or nil if it failed. Any input means "on":
    /// a text comparison in a generated shortcut does not survive the import.
    private static func run(on: Bool) -> String? {
        let dir = FileManager.default.temporaryDirectory
        let input = dir.appendingPathComponent("typewriter-focus-on.txt")
        let output = dir.appendingPathComponent("typewriter-focus-out.txt")
        try? FileManager.default.removeItem(at: output)
        var arguments = ["run", shortcutName, "--output-path", output.path, "--output-type", "public.plain-text"]
        if on {
            try? "on".write(to: input, atomically: true, encoding: .utf8)
            arguments += ["--input-path", input.path]
        }
        let result = shortcuts(arguments, timeout: 5)
        guard result.status == 0 else { return nil }
        return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    }

    /// Runs the `shortcuts` tool. After `timeout` seconds it is stopped, so a shortcut that waits for
    /// input (or a Shortcuts app that hangs) cannot block the app or its quit.
    private static func shortcuts(_ arguments: [String], timeout: TimeInterval = 20) -> (status: Int32, output: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, nil) }
        let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        defer { stop.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8))
    }

    /// The shortcut as a Shortcuts workflow property list.
    private static func workflow() -> [String: Any] {
        let current = UUID().uuidString, outer = UUID().uuidString, inner = UUID().uuidString
        let focusOutput: [String: Any] = ["Type": "ActionOutput", "OutputUUID": current, "OutputName": "Current Focus"]
        func variable(_ value: [String: Any]) -> [String: Any] {
            ["Type": "Variable", "Variable": ["Value": value, "WFSerializationType": "WFTextTokenAttachment"]]
        }
        func action(_ id: String, _ parameters: [String: Any] = [:]) -> [String: Any] {
            ["WFWorkflowActionIdentifier": "is.workflow.actions." + id, "WFWorkflowActionParameters": parameters]
        }
        let doNotDisturb = ["Identifier": "com.apple.donotdisturb.mode.default", "DisplayString": "Do Not Disturb"]
        let actions: [[String: Any]] = [
            action("dnd.getfocus", ["UUID": current]),
            // If there is any input
            action("conditional", ["GroupingIdentifier": outer, "WFControlFlowMode": 0, "WFCondition": 100,
                                   "WFInput": variable(["Type": "ExtensionInput"])]),
            //   If no Focus is active: turn on Do Not Disturb until turned off
            action("conditional", ["GroupingIdentifier": inner, "WFControlFlowMode": 0, "WFCondition": 101,
                                   "WFInput": variable(focusOutput)]),
            action("dnd.set", ["Enabled": 1, "FocusModes": doNotDisturb, "AssertionType": "Turned Off"]),
            action("conditional", ["GroupingIdentifier": inner, "WFControlFlowMode": 2]),
            // Otherwise: turn off Do Not Disturb
            action("conditional", ["GroupingIdentifier": outer, "WFControlFlowMode": 1]),
            action("dnd.set", ["Enabled": 0, "FocusModes": doNotDisturb]),
            action("conditional", ["GroupingIdentifier": outer, "WFControlFlowMode": 2]),
            // Output the Focus that was active before.
            action("output", ["WFOutput": ["Value": ["string": "\u{FFFC}", "attachmentsByRange": ["{0, 1}": focusOutput]],
                                           "WFSerializationType": "WFTextTokenString"]]),
        ]
        return [
            "WFWorkflowActions": actions,
            "WFWorkflowClientVersion": "2607.0.2",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4_292_093_695, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFGenericFileContentItem"],
            "WFWorkflowOutputContentItemClasses": ["WFStringContentItem"],
            "WFWorkflowHasShortcutInputVariables": true,
            "WFWorkflowTypes": [Any](),
            "WFQuickActionSurfaces": [Any](),
        ]
    }
}
