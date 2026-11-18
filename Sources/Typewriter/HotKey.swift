import Carbon

/// A global hotkey via the Carbon API. It needs no special permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    /// Nil if the system does not accept the shortcut, for example because another app uses it.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        HotKey.installHandlerOnce()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x5459_5057), id: id) // "TYPW"
        guard RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
        HotKey.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let h = HotKey.handlers[hkID.id] {
                DispatchQueue.main.async { h() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
