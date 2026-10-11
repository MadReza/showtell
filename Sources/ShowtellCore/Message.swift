import Foundation

/// One part of a message: narration or a screenshot file.
public enum Piece: Equatable, Sendable {
    case text(String)
    case image(URL)
}

/// A screenshot inside editable text is a marker like `[📷 3]`.
/// Users can move or delete markers in the overlay; whatever is left decides the order.
public enum ShotMarker {
    public static func token(_ number: Int) -> String { "[📷 \(number)]" }

    static let regex = try! NSRegularExpression(pattern: #"\[📷 (\d+)\]"#)

    /// Splits edited text into pieces. Markers whose number has no file are dropped.
    public static func pieces(from text: String, shots: [Int: URL]) -> [Piece] {
        var pieces: [Piece] = []
        let ns = text as NSString
        var cursor = 0
        func addText(_ s: String) {
            guard !s.isEmpty else { return }
            if case .text(let prev)? = pieces.last {
                pieces[pieces.count - 1] = .text(prev + s)
            } else {
                pieces.append(.text(s))
            }
        }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            addText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
            let number = Int(ns.substring(with: match.range(at: 1))) ?? -1
            if let url = shots[number] { pieces.append(.image(url)) }
        }
        addText(ns.substring(from: cursor))
        return tidy(pieces)
    }

    /// Collapses runs of whitespace and trims the ends, keeping one space next to images
    /// so Claude Code's chips read naturally ("look [Image #1] here").
    static func tidy(_ pieces: [Piece]) -> [Piece] {
        var out: [Piece] = []
        for (i, piece) in pieces.enumerated() {
            guard case .text(let raw) = piece else { out.append(piece); continue }
            var s = raw.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            if i == 0 { s = String(s.drop(while: { $0.isWhitespace })) }
            if i == pieces.count - 1 { s = String(s.reversed().drop(while: { $0.isWhitespace }).reversed()) }
            if !s.isEmpty { out.append(.text(s)) }
        }
        return out
    }
}
