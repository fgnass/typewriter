import AppKit
import ApplicationServices

enum FocusState {
    /// `element` is the focused text field, nil only in the video mode.
    case editable(appName: String, element: AXUIElement?)
    /// The app does not tell which element has the focus, or it is web content, but its Paste command is on.
    /// A paste can work: the text is pasted and also stays on the clipboard.
    case maybeEditable(appName: String)
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

        let name = app.localizedName ?? "app"
        // Without a clear answer from the element, the Paste command of the app decides. Each app turns it on
        // and off by itself, so this needs no knowledge of the app.
        func fallback() -> FocusState {
            app.activationPolicy == .regular && pasteEnabled(axApp) != false ? .maybeEditable(appName: name) : .notEditable
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let focused = value, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return fallback()
        }
        let element = focused as! AXUIElement

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        if textRoles.contains(role) { return .editable(appName: name, element: element) }

        // Web content and custom views: an element with a settable text selection accepts text.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success, settable.boolValue {
            return .editable(appName: name, element: element)
        }
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            var rangeValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success {
                return .editable(appName: name, element: element)
            }
        }
        return fallback()
    }

    /// True if the Paste command (⌘V) in the menu bar of the app is on, nil if the app has no such command.
    static func pasteEnabled(_ axApp: AXUIElement) -> Bool? {
        func children(_ e: AXUIElement) -> [AXUIElement] {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
            return v as? [AXUIElement] ?? []
        }
        func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        guard let bar = attr(axApp, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        // Menu bar → menu titles → menus → items. The Paste item is the one with ⌘V and no other modifier.
        for title in children(bar as! AXUIElement) {
            for menu in children(title) {
                for item in children(menu) where (attr(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "V"
                    && (attr(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0 {
                    return attr(item, kAXEnabledAttribute) as? Bool
                }
            }
        }
        return nil
    }

    /// True if the app is in front again and the same text field as before has the focus.
    /// Another field or window of the same app does not count.
    static func canPaste(into app: NSRunningApplication?, element: AXUIElement) -> Bool {
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        guard case .editable(_, let focused?) = focusState(of: app) else { return false }
        return CFEqual(focused, element)
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Pastes the text with a synthetic ⌘V and then restores the previous clipboard.
    /// With `keep` the text stays on the clipboard, for a paste that may not work.
    static func paste(_ text: String, keep: Bool = false) {
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

        if keep { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pb.changeCount == ourChange else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}
