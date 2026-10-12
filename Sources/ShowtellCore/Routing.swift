import Foundation

/// A spoken destination at the start or end of a message: "For the showtell session, …",
/// "… this should go to showtell", "At the cursor: …". A name in the middle never routes.
public enum Routing {
    public enum Target: Equatable, Sendable {
        case cursor
        /// A session, by the `id` of its `Candidate`.
        case session(String)
    }

    /// A session that can be named, with the names it answers to (folder, title).
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let names: [String]
        public init(id: String, names: [String]) {
            self.id = id
            self.names = names
        }
    }

    public struct Route: Equatable, Sendable {
        public let target: Target
        /// The words that named it, as they appear in the text.
        public let phrase: String
        /// The message without them.
        public let remaining: String
    }

    public enum Result: Equatable, Sendable {
        case none
        case route(Route)
        /// A routing phrase whose name matches no session, or several.
        case unclear(String)
    }

    /// Phrases before the name. A weak one ("for the") also needs "session" after the name, so
    /// "For the record, …" stays text.
    static let startTriggers: [(words: [String], strong: Bool)] = [
        (["send", "this", "to"], true), (["send", "it", "to"], true), (["send", "to"], true),
        (["this", "is", "for"], true), (["for", "the"], false), (["for"], false), ([], false),
    ]
    static let endTriggers: [(words: [String], strong: Bool)] = [
        (["this", "should", "go", "to"], true), (["it", "should", "go", "to"], true),
        (["this", "goes", "to"], true), (["send", "this", "to"], true), (["send", "it", "to"], true),
        (["this", "is", "for"], true), (["for", "the"], false),
    ]
    static let cursorStarts: [[String]] = [
        ["paste", "at", "the", "cursor"], ["insert", "at", "the", "cursor"], ["at", "the", "cursor"],
        ["to", "the", "cursor"], ["send", "to", "the", "cursor"],
    ]
    static let cursorEnds: [[String]] = [
        ["at", "the", "cursor"], ["to", "the", "cursor"], ["into", "the", "cursor"],
    ]
    /// Words that may lead into an end phrase and go with it: "…, so this should go to X".
    static let endLeads: Set<String> = ["and", "so", "please", "then", "also"]
    static let threshold = 0.75

    struct Token {
        let word: String  // lower case, letters and digits only
        let range: Range<String.Index>
        var isMarker: Bool
    }

    public static func find(in text: String, candidates: [Candidate]) -> Result {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return .none }
        let start = findAtStart(tokens, text: text, candidates: candidates)
        if case .route = start { return start }
        let end = findAtEnd(tokens, text: text, candidates: candidates)
        if case .route = end { return end }
        if case .unclear = start { return start }
        return end
    }

    // MARK: Start

    static func findAtStart(_ t: [Token], text: String, candidates: [Candidate]) -> Result {
        let words = t.map(\.word)
        for phrase in cursorStarts where words.starts(with: phrase) && t.count > phrase.count {
            return .route(cut(text, t, 0..<phrase.count, target: .cursor, atStart: true))
        }
        var unclear: Result = .none
        for trigger in startTriggers where words.starts(with: trigger.words) {
            var from = trigger.words.count
            if !trigger.words.isEmpty, trigger.words.last != "the", from < words.count, words[from] == "the" { from += 1 }
            var best: (score: Double, ids: [String], end: Int)?
            for length in 1...3 where from + length <= t.count {
                let nameTokens = t[from..<from + length]
                if nameTokens.contains(where: \.isMarker) { break }
                var end = from + length
                let session = end < t.count && words[end] == "session"
                if session { end += 1 }
                guard trigger.strong || session, end < t.count else { continue }
                let name = nameTokens.map(\.word).joined(separator: " ")
                let (score, ids) = match(name, candidates)
                if score >= threshold, score > (best?.score ?? 0) { best = (score, ids, end) }
                if score < threshold, case .none = unclear {
                    unclear = .unclear("No session called “\(name)”")
                }
            }
            if let best {
                guard best.ids.count == 1 else { return .unclear("“\(span(text, t, from..<best.end))” matches several sessions") }
                return .route(cut(text, t, 0..<best.end, target: .session(best.ids[0]), atStart: true))
            }
        }
        return unclear
    }

    // MARK: End

    static func findAtEnd(_ t: [Token], text: String, candidates: [Candidate]) -> Result {
        let words = t.map(\.word)
        for phrase in cursorEnds where words.count > phrase.count && Array(words.suffix(phrase.count)) == phrase {
            var from = t.count - phrase.count
            // "paste this at the cursor", "put it at the cursor"
            if from >= 2, ["paste", "put", "insert", "send"].contains(words[from - 2]), ["this", "it"].contains(words[from - 1]) {
                from -= 2
            } else if from >= 3, words[from - 3...from - 1] == ["this", "should", "go"] {
                from -= 3
            } else if from >= 1, ["paste", "put", "insert"].contains(words[from - 1]) {
                from -= 1
            } else if from >= 2, words[from - 2...from - 1] == ["this", "goes"] {
                from -= 2
            }
            if from > 0 { return .route(cut(text, t, leadIn(words, from)..<t.count, target: .cursor, atStart: false)) }
        }
        var unclear: Result = .none
        let tailEnd = words.last == "session" ? t.count - 1 : t.count
        let session = tailEnd < t.count
        for length in 1...3 where tailEnd - length > 0 {
            let nameStart = tailEnd - length
            if t[nameStart..<tailEnd].contains(where: \.isMarker) { break }
            for trigger in endTriggers where trigger.strong || session {
                // "… should go to the beta session": an optional "the" before the name.
                let the = trigger.words.last != "the" && nameStart > 0 && words[nameStart - 1] == "the" ? 1 : 0
                let n = trigger.words.count + the
                guard nameStart - n > 0, Array(words[nameStart - n..<nameStart - the]) == trigger.words else { continue }
                let name = t[nameStart..<tailEnd].map(\.word).joined(separator: " ")
                let (score, ids) = match(name, candidates)
                guard score >= threshold else {
                    if case .none = unclear { unclear = .unclear("No session called “\(name)”") }
                    continue
                }
                guard ids.count == 1 else { return .unclear("“\(name)” matches several sessions") }
                return .route(cut(text, t, leadIn(words, nameStart - n)..<t.count, target: .session(ids[0]), atStart: false))
            }
        }
        return unclear
    }

    static func leadIn(_ words: [String], _ from: Int) -> Int {
        var i = from
        while i > 1, endLeads.contains(words[i - 1]) { i -= 1 }
        return i
    }

    // MARK: Names

    /// The best score for `spoken` and the sessions that share it.
    static func match(_ spoken: String, _ candidates: [Candidate]) -> (Double, [String]) {
        var scores: [(String, Double)] = []
        for c in candidates {
            let s = c.names.map { similarity(spoken, $0) }.max() ?? 0
            scores.append((c.id, s))
        }
        guard let top = scores.map(\.1).max(), top > 0 else { return (0, []) }
        return (top, scores.filter { $0.1 >= top - 0.02 }.map(\.0))
    }

    /// 1 for the same name; close for a near spelling or the same sound ("chotel" ~ "showtell").
    public static func similarity(_ spoken: String, _ name: String) -> Double {
        let a = squash(spoken), b = squash(name)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let spelling = 1 - Double(distance(a, b)) / Double(max(a.count, b.count))
        let ka = soundKey(a), kb = soundKey(b)
        let sound = ka.count >= 2 && ka == kb ? 0.85 : 0
        return max(spelling, sound)
    }

    static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// A rough sound skeleton: the first letter, then consonants, with look-alike sounds merged.
    static func soundKey(_ s: String) -> String {
        var t = s
        for (from, to) in [("ph", "f"), ("ch", "s"), ("sh", "s"), ("ck", "k"), ("c", "k"), ("z", "s"), ("w", ""), ("h", "")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        var out = ""
        for (i, ch) in t.enumerated() {
            if i > 0, "aeiouy".contains(ch) { continue }
            if out.last == ch { continue }
            out.append(ch)
        }
        return out
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let keep = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = keep
            }
        }
        return row[b.count]
    }

    // MARK: Text

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            let raw = String(text[i..<j])
            let isMarker = raw.contains("[") || raw.contains("]") || raw.contains("📷")
            tokens.append(Token(word: squash(raw), range: i..<j, isMarker: isMarker))
            i = j
        }
        return tokens.filter { !$0.word.isEmpty || $0.isMarker }
    }

    static func span(_ text: String, _ t: [Token], _ r: Range<Int>) -> String {
        String(text[t[r.lowerBound].range.lowerBound..<t[r.upperBound - 1].range.upperBound])
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// The message without the tokens in `r`, tidied at the cut.
    static func cut(_ text: String, _ t: [Token], _ r: Range<Int>, target: Target, atStart: Bool) -> Route {
        let phrase = span(text, t, r)
        let cutChars: CharacterSet = .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-—–"))
        if atStart {
            var rest = String(text[t[r.upperBound - 1].range.upperBound...])
            let lead = cutChars.union(CharacterSet(charactersIn: "."))
            rest = String(rest.drop { $0.unicodeScalars.allSatisfy(lead.contains) })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = rest.first, first.isLowercase { rest = first.uppercased() + rest.dropFirst() }
            return Route(target: target, phrase: phrase, remaining: rest)
        }
        var rest = String(text[..<t[r.lowerBound].range.lowerBound]).trimmingCharacters(in: cutChars)
        let ending = text.trimmingCharacters(in: .whitespacesAndNewlines).last
        if let ending, ".?!".contains(ending), let last = rest.last, !".?!".contains(last) { rest.append(ending) }
        return Route(target: target, phrase: phrase, remaining: rest)
    }
}
