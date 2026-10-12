import AppKit
import ShowtellCore

/// Watches the clipboard for new images (what ⌘⌃⇧4 and friends put there) and copied text.
/// Showtell's own writes carry `ClipboardChange.ownType` and are skipped.
final class ClipboardWatcher {
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    var onImage: ((Data) -> Void)?
    var onText: ((String) -> Void)?

    static var ownType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(ClipboardChange.ownType) }

    func start() {
        lastChange = NSPasteboard.general.changeCount
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let types = (pb.types ?? []).map(\.rawValue)
        switch ClipboardChange.classify(types: types, string: pb.string(forType: .string)) {
        case .ignore:
            break
        case .screenshot:
            if let png = Self.pngData(from: pb) { onImage?(png) }
        case .text(let text):
            onText?(text)
        }
    }

    static func pngData(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Notices the native copy-to-clipboard screenshot shortcuts (⌘⌃⇧3/4) so the bar can step out
/// of the way before macOS captures the screen; it comes back when the image reaches the
/// clipboard. Needs the Accessibility permission; without it the bar still never appears in
/// shots because it is excluded from capture.
final class ScreenshotKeyMonitor {
    private var monitors: [Any] = []
    var onScreenshotKeys: (() -> Void)?
    var onEscape: (() -> Void)?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func askForPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        stop()
        let handler: (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains([.command, .shift, .control]), [20, 21].contains(event.keyCode) {  // 3, 4
                self?.onScreenshotKeys?()
            } else if event.keyCode == 53 {
                self?.onEscape?()
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) {
            monitors.append(l)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}
