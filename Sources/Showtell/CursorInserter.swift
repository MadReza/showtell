import AppKit
import ShowtellCore

/// Pastes a message into whatever app has the keyboard cursor: each piece goes through the
/// clipboard and a synthesized ⌘V, in order, and your clipboard is put back afterwards.
/// Pressing keys for another app needs the Accessibility permission.
@MainActor
enum CursorInserter {
    /// Returns false when it could not paste; the whole text is then left on the clipboard.
    static func insert(_ pieces: [Piece]) async -> Bool {
        let pb = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            pb.clearContents()
            pb.setString(plainText(pieces), forType: .string)
            return false
        }
        let saved = snapshot(pb)
        try? await Task.sleep(nanoseconds: 150_000_000)  // let the bar give the keyboard back
        for (i, piece) in pieces.enumerated() {
            pb.clearContents()
            switch piece {
            case .text(let text):
                // Pieces are trimmed; keep a space between text and the screenshots around it.
                let before = i > 0 ? " " : ""
                let after = i < pieces.count - 1 ? " " : ""
                pb.setString(before + text + after, forType: .string)
            case .image(let url):
                guard let png = try? Data(contentsOf: url) else { continue }
                pb.declareTypes([.png, .tiff], owner: nil)
                pb.setData(png, forType: .png)
                if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
            pressCommandV()
            // Apps read the clipboard after the key arrives; images take longer.
            let wait: UInt64 = if case .image = piece { 600_000_000 } else { 250_000_000 }
            try? await Task.sleep(nanoseconds: wait)
        }
        restore(saved, to: pb)
        return true
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)  // V
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func plainText(_ pieces: [Piece]) -> String {
        pieces.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: " ")
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
    }

    private static func restore(_ items: [[(NSPasteboard.PasteboardType, Data)]], to pb: NSPasteboard) {
        pb.clearContents()
        let restored = items.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }
}
