import AppKit
import Carbon

/// The global shortcut that opens the page. The user can record any key with at least one of ⌃ ⌥ ⌘,
/// or pick a suggestion.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    static let didChange = Notification.Name("ShortcutDidChange")
    /// Object: true while the settings record a new shortcut.
    static let recordingDidChange = Notification.Name("ShortcutRecordingDidChange")

    /// The key left of 1: "^" on German keyboards, "`" on US keyboards. Its key code depends on the
    /// physical keyboard type: ISO keyboards send the "section" code there, ANSI keyboards the grave code.
    static var keyLeftOfOne: UInt32 {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO ? UInt32(kVK_ISO_Section) : UInt32(kVK_ANSI_Grave)
    }

    /// ⌥ Space: the same on German and US keyboards. (In text fields it usually types a non-breaking
    /// space; while Typewriter runs, the shortcut opens the page instead.)
    static var standard: Shortcut { Shortcut(keyCode: UInt32(kVK_Space), modifiers: .option) }

    /// Suggestions that macOS does not use, and that are easy to reach on German and US keyboards.
    static var suggestions: [Shortcut] {
        [standard,
         Shortcut(keyCode: keyLeftOfOne, modifiers: .control),
         Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: [.control, .option]),
         Shortcut(keyCode: UInt32(kVK_Return), modifiers: [.control, .option])]
    }

    static var current: Shortcut {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: "shortcutKey") != nil else { return standard }
            return Shortcut(keyCode: UInt32(d.integer(forKey: "shortcutKey")),
                            modifiers: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "shortcutModifiers"))))
        }
        set {
            UserDefaults.standard.set(Int(newValue.keyCode), forKey: "shortcutKey")
            UserDefaults.standard.set(Int(newValue.modifiers.rawValue), forKey: "shortcutModifiers")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// A key event as a shortcut, or nil if it has no ⌃, ⌥ or ⌘ (it would block normal typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: flags)
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.control, .option, .shift, .command])
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// For example "⌃ ^" or "⌥ Space".
    var title: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + " " + keyName
    }

    var keyName: String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            // The key codes of F1 to F20 are not in order, so they come from a table.
            if let f = Self.functionKeys[Int(keyCode)] { return f }
            return Self.character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
        }
    }

    /// The character for the menu item, or nil for keys that a menu cannot show.
    var menuKeyEquivalent: String? {
        switch Int(keyCode) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        default: return Self.character(for: keyCode)
        }
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// The character that this key types with the current keyboard layout, without modifiers.
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }
}
