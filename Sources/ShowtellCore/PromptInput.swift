import Foundation

/// What is typed in Claude Code's prompt, read from the pane's screen.
///
/// The input box is the line starting with `❯` (or `!` in bash mode) and the lines after it, between
/// two horizontal rules. An empty box shows a dim placeholder (`Try "fix lint errors"`), and Claude
/// Code shows dim suggestions after typed text: both are left out. Without colours (an iTerm2
/// screen) a lone `Try "…"` line counts as the placeholder.
///
/// Wrapped lines come back as separate lines: the screen can't tell them from typed newlines.
public enum PromptInput {
    /// The typed text (empty when the box is empty), or nil when the screen shows no input box.
    public static func parse(_ screen: String) -> String? {
        let hasColours = screen.contains("\u{1b}[")
        let lines = screen.components(separatedBy: "\n").map(visibleText)
        guard let box = box(lines) else { return nil }

        var marker = ""
        var typed: [String] = []
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
            typed.append(String(s).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        while typed.last?.isEmpty == true { typed.removeLast() }
        let text = typed.joined(separator: "\n")
        if !hasColours, typed.count == 1, isPlaceholder(text) { return marker }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? marker : marker + text
    }

    /// How many lines the box spans, for deciding how many clearing rounds to send.
    public static func lineCount(_ screen: String) -> Int {
        box(screen.components(separatedBy: "\n").map(visibleText))?.count ?? 1
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
        text.hasPrefix("Try \"") && text.hasSuffix("\"")
    }

    /// The line without escape sequences, carriage returns or dim (SGR 2) text.
    static func visibleText(_ line: String) -> String {
        var out = ""
        var dim = false
        var it = line.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c == "\r" { continue }
            guard c == "\u{1b}" else {
                if !dim { out.unicodeScalars.append(c) }
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
