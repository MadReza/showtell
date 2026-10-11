import AppKit
import Carbon.HIToolbox

/// Global shortcuts through Carbon's RegisterEventHotKey: no Accessibility or
/// Input Monitoring permission needed.
final class HotKeys {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, me, &eventHandler)
    }

    /// Returns an id for `unregister`, or nil when another app owns the shortcut.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x5354_4C4C), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt32?) {
        guard let id, let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
        handlers[id] = nil
    }

    /// "⌃⌥Space" for menus and hints.
    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        let names: [UInt32: String] = [49: "Space", 36: "Return", 53: "Esc", 48: "Tab", 51: "⌫"]
        return describe(modifiers: modifiers) + (names[keyCode] ?? "key \(keyCode)")
    }

    static func describe(modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }
}
