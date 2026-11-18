import AppKit
import ApplicationServices

enum FocusState {
    case editable(appName: String)
    case notEditable
    case unknown // No Accessibility permission.
}

enum Inserter {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Checks if the focused UI element of the app accepts text.
    static func focusState(of app: NSRunningApplication?) -> FocusState {
        guard isTrusted else { return .unknown }
        guard let app else { return .notEditable }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Electron apps expose their accessibility tree only on request.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let focused = value, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .notEditable
        }
        let element = focused as! AXUIElement
        let name = app.localizedName ?? "app"

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        if textRoles.contains(role) { return .editable(appName: name) }

        // Web content and custom views: an element with a settable text selection accepts text.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success, settable.boolValue {
            return .editable(appName: name)
        }
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            var rangeValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success {
                return .editable(appName: name)
            }
        }
        return .notEditable
    }

    /// True if the app is in front again and its focused element still accepts text.
    static func canPaste(into app: NSRunningApplication?) -> Bool {
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        if case .editable = focusState(of: app) { return true }
        return false
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Pastes the text with a synthetic ⌘V and then restores the previous clipboard.
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pb.changeCount == ourChange else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}
