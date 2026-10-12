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
            setOwnString(plainText(pieces), on: pb)
            return false
        }
        let saved = snapshot(pb)
        try? await Task.sleep(nanoseconds: 150_000_000)  // let the bar give the keyboard back
        for (i, piece) in pieces.enumerated() {
            switch piece {
            case .text(let text):
                // Pieces are trimmed; keep a space between text and the screenshots around it.
                let before = i > 0 ? " " : ""
                let after = i < pieces.count - 1 ? " " : ""
                setOwnString(before + text + after, on: pb)
            case .copied(let text):
                setOwnString(text, on: pb)
            case .image(let url):
                guard let png = try? Data(contentsOf: url) else { continue }
                pb.declareTypes([.png, .tiff, ClipboardWatcher.ownType], owner: nil)
                pb.setData(png, forType: .png)
                if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
                pb.setData(Data(), forType: ClipboardWatcher.ownType)
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

    /// Marked as ours, so a recording that is listening doesn't take it for a copy.
    private static func setOwnString(_ text: String, on pb: NSPasteboard) {
        pb.declareTypes([.string, ClipboardWatcher.ownType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: ClipboardWatcher.ownType)
    }

    private static func plainText(_ pieces: [Piece]) -> String {
        pieces.compactMap { piece -> String? in
            switch piece {
            case .text(let t), .copied(let t): return t
            case .image: return nil
            }
        }.joined(separator: " ")
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
    }

    private static func restore(_ items: [[(NSPasteboard.PasteboardType, Data)]], to pb: NSPasteboard) {
        pb.clearContents()
        let restored = items.enumerated().map { i, pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            if i == 0 { item.setData(Data(), forType: ClipboardWatcher.ownType) }  // not a new copy
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }
}
