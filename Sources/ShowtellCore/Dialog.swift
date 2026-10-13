import Foundation

/// A message whose words went as the answer to a session's question instead of into its prompt.
public struct AnsweredQuestion: Codable, Equatable, Sendable {
    public var question: String
    /// The message had pictures, which a dialog can't take: only its words went.
    public var picturesLeftOut: Bool
    /// The dialog stayed open for its other questions (or to review and submit them), left to you.
    public var moreLeft: Bool

    public init(question: String, picturesLeftOut: Bool, moreLeft: Bool) {
        self.question = question
        self.picturesLeftOut = picturesLeftOut
        self.moreLeft = moreLeft
    }
}

/// A dialog Claude Code shows in place of its prompt (herdr status `blocked`), read from the pane's screen.
///
/// Verified against Claude Code 2.1.296 (12 Oct 2026, scratch session in herdr):
/// - A question (AskUserQuestion) sits under a rule: a header (` ☐ Fruit`), or for several questions or a
///   multi-select a tab row (`←  ☐ Colours  ☐ Size  ✔ Submit  →`), then the question and numbered options.
///   The last answer option is `Type something.` (`[ ] Type something` in a multi-select); a rule and
///   `Chat about this` follow. The footer reads `Enter to select · ↑/↓ to navigate · Esc to cancel`.
/// - `❯` marks the focused option. On the free-text option the placeholder turns dim, and what you type
///   replaces it (and wraps onto indented lines when long).
/// - One choice: a number key picks that option and moves on; on the free-text option it only moves there.
///   Enter on the free-text option, with text in it, sends it.
/// - Multi-select: number keys and Enter tick boxes and leave the focus where it is; typing in the
///   free-text option ticks it; the row after it (`Next`, or `Submit` for the last question) moves on.
/// - With tabs, an answer moves to the next question, and the last to `Review your answers`, where
///   `1. Submit answers` sends them all.
/// - A permission prompt asks `Do you want to proceed?` (or another `Do you want to …`), and its footer
///   reads `Esc to cancel · Tab to amend`.
public struct Dialog: Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        /// Claude asks you something (AskUserQuestion).
        case question
        /// Claude asks to run a tool, edit a file, or similar.
        case permission
        /// Something else: a trust prompt, a menu.
        case other
    }

    public struct Option: Equatable, Sendable {
        public var number: Int
        /// As shown, without the checkbox.
        public var label: String
        public var focused: Bool
        /// A multi-select option, with a box to tick.
        public var checkbox: Bool
        /// Its line on the screen.
        var line: Int
    }

    public var kind: Kind
    /// The line just above the options: the question asked.
    public var question: String
    public var options: [Option]
    /// The questions' tabs, when it asks several or allows several choices (the Submit tab left out).
    public var tabs: [String]
    /// The row with `❯` when it isn't an option: `Next` or `Submit` in a multi-select.
    public var focusedRow: String?

    public var multiSelect: Bool { options.contains { $0.checkbox } }
    public var focused: Option? { options.first { $0.focused } }

    /// The option you type your own answer in, if this is a question that has one.
    public var freeText: Option? {
        guard kind == .question else { return nil }
        return options.first { Self.freeTextLabels.contains($0.label.trimmingCharacters(in: .whitespaces)) }
    }

    /// Showtell can type an answer: a question with a place to type it.
    public var canAnswer: Bool { freeText != nil }

    static let freeTextLabels: Set<String> = ["Type something.", "Type something"]
    static let actionRows: Set<String> = ["Next", "Submit"]

    /// The dialog on the screen, or nil when it shows Claude Code's prompt or no numbered options.
    public static func read(_ screen: String) -> Dialog? {
        guard PromptInput.read(screen) == nil else { return nil }
        // Dim text kept: the focused free-text option's placeholder is dim.
        let lines = screen.components(separatedBy: "\n").map { PromptInput.visibleText($0, keepingDim: true) }

        // The options, counted up from the bottom: the highest number first, down to 1.
        var options: [Option] = []
        for i in lines.indices.reversed() {
            guard let option = option(lines[i], line: i) else { continue }
            if let last = options.last, option.number != last.number - 1 { continue }
            options.append(option)
            if option.number == 1 { break }
        }
        guard let first = options.last, first.number == 1 else { return nil }
        options.reverse()

        // The dialog starts under the last rule above its first option.
        let top = lines[..<first.line].lastIndex(where: PromptInput.isRule) ?? -1
        let head = lines[(top + 1)..<first.line].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let question = head.last ?? ""
        let tabRow = head.first { $0.hasPrefix("←") }
        let tabs = tabRow.map(Self.tabs) ?? []
        let marked = head.contains { $0.hasPrefix("☐") || $0.hasPrefix("☒") } || tabRow != nil
        let footer = lines[options.last!.line...].last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""

        let kind: Kind
        if footer.contains("Tab to amend") || question.hasPrefix("Do you want") || question.hasPrefix("Would you like to proceed") {
            kind = .permission
        } else if marked || footer.contains("Enter to select") {
            kind = .question
        } else {
            kind = .other
        }

        var focusedRow: String?
        if !options.contains(where: \.focused),
           let row = lines[first.line...].first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }) {
            focusedRow = row.trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return Dialog(kind: kind, question: question, options: options, tabs: tabs, focusedRow: focusedRow)
    }

    /// `❯ 3. [✔] Purple`, `  2. Banana` → an option.
    static func option(_ line: String, line index: Int) -> Option? {
        var s = Substring(line).drop { PromptInput.isSpace($0) }
        var focused = false
        if s.first == "❯" {
            focused = true
            s = s.dropFirst().drop { PromptInput.isSpace($0) }
        }
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        s = s.dropFirst(digits.count)
        guard s.hasPrefix(". ") else { return nil }
        s = s.dropFirst(2)
        var checkbox = false
        if s.count >= 4, s.first == "[", s.dropFirst(2).first == "]" {
            checkbox = true
            s = s.dropFirst(3).drop { PromptInput.isSpace($0) }
        }
        let label = String(s).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return Option(number: number, label: label, focused: focused, checkbox: checkbox, line: index)
    }

    /// `←  ☒ Colours  ☐ Size  ✔ Submit  →` → ["Colours", "Size"].
    static func tabs(_ row: String) -> [String] {
        row.components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("☐") || $0.hasPrefix("☒") }
            .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
    }

    /// Whether the screen shows `text` (spacing aside, as a long answer wraps): all of it, or its end.
    public static func shows(_ text: String, on screen: String) -> Bool {
        let plain = screen.components(separatedBy: "\n").map { PromptInput.visibleText($0, keepingDim: true) }
            .joined().filter { !$0.isWhitespace }
        let wanted = String(text.filter { !$0.isWhitespace }.suffix(40))
        return !wanted.isEmpty && plain.contains(wanted)
    }
}
