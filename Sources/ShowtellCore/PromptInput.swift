import Foundation

/// What is typed in Claude Code's prompt, read from the pane's screen.
///
/// The input box is the line starting with `❯` (or `!` in bash mode) and the lines after it, between
/// two horizontal rules. An empty box shows a dim placeholder (`Try "fix lint errors"`), and Claude
/// Code shows dim suggestions after typed text: both are left out. Without colours (an iTerm2
/// screen) a lone `Try "…"` line counts as the placeholder.
///
/// Claude Code wraps the input at the rule's width less 4 columns: between words, dropping the
/// space, or inside a word too long for a line. A line that ends where the next line's first word
/// wouldn't have fit is taken as wrapped and joined back; a typed line break that happens to fall
/// there is joined too.
///
/// A draft taller than the box shows only the rows around the cursor, with `❯` on the top one and
/// nothing to say more are hidden. Claude Code's prompt stash (Ctrl+S) shows `› stashed` above the box.
public enum PromptInput {
    /// The rows of the input box as shown, without the prompt sign or the indent.
    public struct Box: Equatable, Sendable {
        public var rows: [String]
        /// `!` in bash mode.
        public var marker: String
        /// Columns a row can hold before it wraps.
        public var width: Int
        var hasColours: Bool

        /// The typed text the rows show (empty when the box is empty).
        public var text: String { PromptInput.text(rows, marker: marker, width: width, hasColours: hasColours) }
    }

    /// The typed text (empty when the box is empty), or nil when the screen shows no input box.
    public static func parse(_ screen: String) -> String? {
        read(screen)?.text
    }

    /// The input box, or nil when the screen shows none.
    public static func read(_ screen: String) -> Box? {
        let lines = screen.components(separatedBy: "\n").map { visibleText($0) }
        guard let box = box(lines) else { return nil }
        var marker = ""
        var rows: [String] = []
        for (i, line) in lines[box].enumerated() {
            var s = Substring(line)
            if i == 0 {
                let m = s.first!
                if m == "!" { marker = "!" }
                s = s.dropFirst()
                if let c = s.first, isSpace(c) { s = s.dropFirst() }
            } else {
                var n = 0
                while n < 2, let c = s.first, isSpace(c) { s = s.dropFirst(); n += 1 }
            }
            rows.append(String(s).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        return Box(rows: rows, marker: marker, width: lines[box.lowerBound - 1].count - 4,
                   hasColours: screen.contains("\u{1b}["))
    }

    /// Whether Claude Code holds a stashed prompt: `› stashed` just above the box.
    public static func hasStash(_ screen: String) -> Bool {
        let lines = screen.components(separatedBy: "\n").map { visibleText($0) }
        guard let box = box(lines) else { return false }
        return lines[max(0, box.lowerBound - 3)..<(box.lowerBound - 1)].contains { $0.contains("› stashed") }
    }

    static func text(_ rows: [String], marker: String, width: Int, hasColours: Bool) -> String {
        var typed = rows
        while typed.last?.isEmpty == true { typed.removeLast() }
        let text = unwrap(typed, width: width)
        if !hasColours, typed.count == 1, isPlaceholder(text) { return marker }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? marker : marker + text
    }

    /// Joins screen rows into the typed text. A full row whose last word runs on into the next row's
    /// first was a word too long for a row; a row the next word didn't fit on gets back the space the
    /// wrap took; any other row ends in a line break.
    static func unwrap(_ rows: [String], width: Int) -> String {
        var text = ""
        for (i, row) in rows.enumerated() {
            text += row
            guard i + 1 < rows.count else { break }
            let next = rows[i + 1].prefix { !isSpace($0) }
            let last = row.reversed().prefix { !isSpace($0) }
            if width > 0, row.count >= width, last.count + next.count > width {
                continue
            } else if width > 0, !row.isEmpty, !next.isEmpty, row.count + 1 + next.count > width {
                text += " "
            } else {
                text += "\n"
            }
        }
        return text
    }

    /// How many lines the box spans, for deciding how many clearing rounds to send.
    public static func lineCount(_ screen: String) -> Int {
        box(screen.components(separatedBy: "\n").map { visibleText($0) })?.count ?? 1
    }

    /// The lines of the lowest input box: from its prompt line up to the closing rule.
    static func box(_ lines: [String]) -> Range<Int>? {
        guard let start = lines.indices.last(where: { $0 > 0 && isPromptLine(lines[$0]) && isRule(lines[$0 - 1]) }),
              let end = lines[(start + 1)...].firstIndex(where: isRule) else { return nil }
        return start..<end
    }

    static func isPromptLine(_ line: String) -> Bool {
        line.hasPrefix("❯") || line == "!" || (line.first == "!" && line.dropFirst().first.map(isSpace) == true)
    }

    /// Claude Code puts a no-break space after the prompt sign.
    static func isSpace(_ c: Character) -> Bool { c == " " || c == "\u{a0}" }

    /// A horizontal rule: mostly `─`.
    static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 10, t.hasPrefix("──") else { return false }
        return t.filter { $0 == "─" }.count * 2 >= t.count
    }

    static func isPlaceholder(_ text: String) -> Bool {
        (text.hasPrefix("Try \"") && text.hasSuffix("\"")) || text == "Press up to edit queued messages"
    }

    /// The line without escape sequences, carriage returns or dim (SGR 2) text (unless `keepingDim`).
    static func visibleText(_ line: String, keepingDim: Bool = false) -> String {
        var out = ""
        var dim = false
        var it = line.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c == "\r" { continue }
            guard c == "\u{1b}" else {
                if !dim || keepingDim { out.unicodeScalars.append(c) }
                continue
            }
            guard let kind = it.next() else { break }
            guard kind == "[" else { continue }  // other escapes: skip the next character
            var params = ""
            while let p = it.next() {
                if (0x40...0x7e).contains(p.value) {
                    if p == "m" { dim = sgr(params, dim: dim) }
                    break
                }
                params.unicodeScalars.append(p)
            }
        }
        return out
    }

    /// Applies one SGR sequence to the dim state.
    static func sgr(_ params: String, dim: Bool) -> Bool {
        var dim = dim
        let codes = params.isEmpty ? ["0"] : params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < codes.count {
            switch codes[i] {
            case "", "0", "22": dim = false
            case "2": dim = true
            case "38", "48", "58":
                // Colour arguments: 5;n or 2;r;g;b.
                if i + 1 < codes.count { i += codes[i + 1] == "5" ? 2 : codes[i + 1] == "2" ? 4 : 1 }
            default: break
            }
            i += 1
        }
        return dim
    }
}
