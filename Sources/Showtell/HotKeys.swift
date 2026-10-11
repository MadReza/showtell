import AppKit
import Carbon.HIToolbox
import ShowtellCore

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
}

/// A tap of one modifier key on its own (for example the left Option key): press and release
/// within `maxHold`, with no other key, modifier or click in between. Holding the key for
/// Option-click or ⌥-shortcuts never fires. Seeing keys outside Showtell needs Accessibility.
final class ModifierTap {
    static let keyCodes: [String: UInt16] = [
        "leftOption": 58, "rightOption": 61, "leftControl": 59, "rightControl": 62,
        "leftCommand": 55, "rightCommand": 54, "leftShift": 56, "rightShift": 60,
    ]

    private let keyCode: UInt16
    private let maxHold: TimeInterval
    private var monitors: [Any] = []
    private var pressedAt: Date?
    var onTap: (() -> Void)?

    init?(name: String, maxHold: TimeInterval = 0.4) {
        guard let code = Self.keyCodes[name] else { return nil }
        keyCode = code
        self.maxHold = maxHold
    }

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] in self?.flagsChanged($0) }
        let other: (NSEvent) -> Void = { [weak self] _ in self?.pressedAt = nil }
        let spoilers: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: spoilers, handler: other) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: spoilers, handler: { other($0); return $0 }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        pressedAt = nil
    }

    private func flagsChanged(_ event: NSEvent) {
        guard event.keyCode == keyCode else {
            pressedAt = nil  // another modifier joined in
            return
        }
        let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        if pressedAt == nil, Self.isDown(keyCode, event.modifierFlags), held == [.option] || held == [.control] || held == [.command] || held == [.shift] {
            pressedAt = Date()
        } else if let start = pressedAt, !Self.isDown(keyCode, event.modifierFlags) {
            pressedAt = nil
            if Date().timeIntervalSince(start) <= maxHold { onTap?() }
        } else {
            pressedAt = nil
        }
    }

    /// Whether this exact key (left or right) is down, from the device-dependent flag bits.
    static func isDown(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        let bits: [UInt16: UInt] = [58: 0x20, 61: 0x40, 59: 0x01, 62: 0x2000, 55: 0x08, 54: 0x10, 56: 0x02, 60: 0x04]
        return flags.rawValue & (bits[code] ?? 0) != 0
    }
}

/// Listens for one `Shortcut`: Carbon for a key chord, `ModifierTap` for a lone modifier.
final class ShortcutBinding {
    private let hotKeys: HotKeys
    private var id: UInt32?
    private var tap: ModifierTap?
    /// False when another app already owns the chord.
    let ok: Bool

    init(_ shortcut: Shortcut, hotKeys: HotKeys, handler: @escaping () -> Void) {
        self.hotKeys = hotKeys
        if let name = shortcut.tap {
            tap = ModifierTap(name: name)
            tap?.onTap = handler
            tap?.start()
            ok = tap != nil
        } else if let code = shortcut.keyCode {
            id = hotKeys.register(keyCode: code, modifiers: shortcut.modifiers, handler: handler)
            ok = id != nil
        } else {
            ok = false
        }
    }

    /// Key monitors added before Accessibility was granted may stay deaf; add them again.
    func refresh() { tap?.start() }

    func stop() {
        hotKeys.unregister(id)
        id = nil
        tap?.stop()
        tap = nil
    }
}
