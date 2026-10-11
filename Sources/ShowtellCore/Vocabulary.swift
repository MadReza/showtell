import Foundation

/// A word the recogniser should prefer, with spellings it tends to mishear it as.
public struct VocabularyTerm: Equatable, Sendable {
    public var text: String
    public var aliases: [String]
    public init(_ text: String, aliases: [String] = []) {
        self.text = text
        self.aliases = aliases
    }
}

public enum Vocabulary {
    /// Terms from a repository's `.github/dictation.md` (the file VS Code and localvoxtral read):
    /// inline code spans, and each list item's first words up to a dash or colon.
    /// Headings, paragraphs and fenced blocks are ignored.
    public static func dictationFileTerms(_ markdown: String) -> [VocabularyTerm] {
        var terms: [String] = []
        var inFence = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence || line.hasPrefix("#") { continue }
            terms += codeSpans(line)
            guard let item = listItemBody(line) else { continue }
            if item.hasPrefix("`") { continue }  // already taken as a code span
            var head = item
            for sep in [" — ", " – ", " - ", ":"] {
                if let r = head.range(of: sep) { head = String(head[..<r.lowerBound]) }
            }
            head = head.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, head.split(separator: " ").count <= 4 { terms.append(head) }
        }
        return unique(terms).map { VocabularyTerm($0) }
    }

    /// Simple list format, the same FluidAudio reads: one term per line, optional
    /// `term: alias, alias`. Lines starting with `#` are comments.
    public static func simpleListTerms(_ text: String) -> [VocabularyTerm] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard let colon = line.firstIndex(of: ":") else { return VocabularyTerm(line) }
            let term = line[..<colon].trimmingCharacters(in: .whitespaces)
            let aliases = line[line.index(after: colon)...].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return term.isEmpty ? nil : VocabularyTerm(term, aliases: aliases)
        }
    }

    /// Writes terms in the simple list format, merging aliases of duplicates.
    public static func simpleListText(_ terms: [VocabularyTerm]) -> String {
        var order: [String] = []
        var merged: [String: VocabularyTerm] = [:]
        for t in terms {
            let key = t.text.lowercased()
            if var existing = merged[key] {
                existing.aliases = unique(existing.aliases + t.aliases)
                merged[key] = existing
            } else {
                order.append(key)
                merged[key] = t
            }
        }
        return order.compactMap { merged[$0] }.map { t in
            t.aliases.isEmpty ? t.text : "\(t.text): \(t.aliases.joined(separator: ", "))"
        }.joined(separator: "\n") + "\n"
    }

    /// `wrong => right` lines, applied to the finished text, longest first, whole words, any case.
    public static func replacements(_ text: String) -> [(String, String)] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let r = line.range(of: "=>") else { return nil }
            let from = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let to = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return from.isEmpty ? nil : (from, to)
        }.sorted { $0.0.count > $1.0.count }
    }

    public static func applyReplacements(_ text: String, _ rules: [(String, String)]) -> String {
        rules.reduce(text) { s, rule in
            let pattern = "(?<![\\w])" + NSRegularExpression.escapedPattern(for: rule.0) + "(?![\\w])"
            return s.replacingOccurrences(
                of: pattern, with: NSRegularExpression.escapedTemplate(for: rule.1),
                options: [.regularExpression, .caseInsensitive])
        }
    }

    static func codeSpans(_ line: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "`([^`]+)`")
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func listItemBody(_ line: String) -> String? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return String(line.dropFirst(bullet.count))
        }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
            return line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }
}
