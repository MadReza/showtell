import Foundation

/// A model that tidies a dictated message: punctuation, filler words, numbers, obvious
/// mis-hearings. It keeps your wording; it is not a rewrite.
public struct CleanupModel: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// Apple Intelligence's on-device model (macOS 26): nothing to download.
        case apple
        /// A GGUF file run by llama.cpp inside Showtell, downloaded once.
        case download(url: URL, file: String, bytes: Int64)
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let summary: String
    public let pros: String
    public let cons: String

    public static let apple = CleanupModel(
        id: "apple", name: "Apple Intelligence", kind: .apple,
        summary: "Apple's on-device model, built into macOS 26.",
        pros: "Nothing to download and no extra memory; fast (under a second).",
        cons: "Needs Apple Intelligence switched on in System Settings, macOS 26 and a supported language.")

    public static let qwenSmall = CleanupModel(
        id: "qwen2.5-1.5b", name: "Qwen 2.5 1.5B (small)",
        kind: .download(
            url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
            file: "qwen2.5-1.5b-instruct-q4_k_m.gguf", bytes: 1_117_320_736),
        summary: "A small open model (Apache 2.0) that runs inside Showtell.",
        pros: "Quickest download (1.1 GB) and the fastest replies; works without Apple Intelligence.",
        cons: "Rewords more freely than the others: it sometimes shortens a sentence or drops a phrase.")

    public static let qwen4B = CleanupModel(
        id: "qwen3-4b", name: "Qwen 3 4B Instruct",
        kind: .download(
            url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
            file: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", bytes: 2_497_281_120),
        summary: "A stronger open model (Apache 2.0) that runs inside Showtell.",
        pros: "Keeps closest to your words while fixing the most; works without Apple Intelligence.",
        cons: "2.5 GB download and about 3 GB of memory while loaded; a second or two per message.")

    public static let all: [CleanupModel] = [.apple, .qwenSmall, .qwen4B]

    public static func named(_ id: String?) -> CleanupModel? { all.first { $0.id == id } }

    public var downloadBytes: Int64? {
        if case .download(_, _, let bytes) = kind { return bytes }
        return nil
    }
}

/// The instructions and the safety checks around a clean-up.
public enum Cleanup {
    public static func instructions(terms: [String], language: DictationLanguage = .english) -> String {
        var s = """
        You tidy up text that someone dictated to a coding assistant. Return the same message with:
        - punctuation, capital letters and sentence breaks fixed;
        - filler words (um, uh, like, you know, so at the start) and false starts removed;
        - numbers, versions, times and units written as digits (four zero four → 404, version two point one → version 2.1);
        - words the speech recogniser clearly misheard corrected when the meaning is obvious.
        Keep the speaker's own words, order, tone and meaning. Do not summarise, shorten, explain, answer, or add anything.
        Markers like [Screenshot 1] stand for pictures and [Copied 1] for copied text: keep every one exactly as written, in the same place in the sentence.
        If the text is a question or a request, it stays a question or a request for someone else; never reply to it.
        Output only the tidied text, with no quotes and no preamble.

        Example. Dictated: so um can you open the profile page [Screenshot 1] and uh the save button does nothing on version three point one you know
        Tidied: Can you open the profile page [Screenshot 1]? The save button does nothing on version 3.1.
        """
        if language.isFrench {
            s += "\nThis message is in French. Keep it in French and never translate it into English; the example above only shows the kind of changes. "
                + "French filler words include euh, ben, bon, genre, tsé, là at the end of a phrase. Use French punctuation and number conventions."
        }
        let words = terms.filter { !$0.isEmpty }
        if !words.isEmpty {
            s += "\nThese names are spelled exactly like this: " + words.joined(separator: ", ") + "."
        }
        return s
    }

    /// The cleaned text if it is safe to use, nil to keep the original: every screenshot marker must
    /// survive in the same order, your terms must stay, and the length must stay about the same.
    public static func accept(original: String, cleaned raw: String, terms: [String]) -> String? {
        var cleaned = fromModelText(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        for preamble in ["Here is the tidied text:", "Here's the tidied text:", "Tidied text:", "Here is the text:",
                         "Voici le texte corrigé :", "Voici le texte corrigé:", "Texte corrigé :", "Texte corrigé:"] {
            if cleaned.lowercased().hasPrefix(preamble.lowercased()) {
                cleaned = String(cleaned.dropFirst(preamble.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if cleaned.count >= 2, let f = cleaned.first, let l = cleaned.last,
           (f == "\"" && l == "\"") || (f == "“" && l == "”"), !original.hasPrefix(String(f)) {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        guard !cleaned.isEmpty else { return nil }
        guard markers(in: cleaned) == markers(in: original) else { return nil }
        for term in terms where !term.isEmpty {
            if original.range(of: term, options: .caseInsensitive) != nil,
               cleaned.range(of: term, options: .caseInsensitive) == nil { return nil }
        }
        let before = wordCount(original), after = wordCount(cleaned)
        if before >= 4, Double(after) < Double(before) * 0.5 || Double(after) > Double(before) * 1.5 + 3 { return nil }
        return cleaned
    }

    /// Models keep a plain `[Screenshot 1]` more reliably than `[📷 1]`, so they see that form
    /// (and `[Copied 1]` for `[📋 1]`).
    public static func modelText(_ text: String) -> String {
        replace(replace(text, #"\[📷 (\d+)\]"#, "[Screenshot $1]"), #"\[📋 (\d+)\]"#, "[Copied $1]")
    }

    public static func fromModelText(_ text: String) -> String {
        replace(replace(text, #"\[Screenshot (\d+)\]"#, "[📷 $1]"), #"\[Copied (\d+)\]"#, "[📋 $1]")
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    static func markers(in text: String) -> [String] {
        let ns = text as NSString
        return ShotMarker.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// Text and screenshot markers, in order: "a [📷 1] b" → ["a", "[📷 1]", "b"].
    public static func split(_ text: String) -> [String] {
        let ns = text as NSString
        var parts: [String] = []
        var cursor = 0
        for match in ShotMarker.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                .trimmingCharacters(in: .whitespaces)
            if !before.isEmpty { parts.append(before) }
            parts.append(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        let rest = ns.substring(from: cursor).trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { parts.append(rest) }
        return parts
    }

    public static func isMarker(_ part: String) -> Bool {
        ShotMarker.regex.firstMatch(in: part, range: NSRange(location: 0, length: (part as NSString).length)) != nil
            && split(part).count == 1
    }

    /// Puts tidied parts back together. A part that continues a sentence across a screenshot starts
    /// in lower case ("thing [📷 1] it doesn't"), unless it starts with "I" or a name.
    public static func join(_ parts: [String]) -> String {
        var out = ""
        var lastText = ""
        for part in parts {
            var piece = part
            if !isMarker(part) {
                let endsSentence = lastText.isEmpty || ".?!:".contains(lastText.last ?? ".")
                if !endsSentence, let first = piece.first, first.isUppercase {
                    let word = piece.prefix(while: { !$0.isWhitespace && !$0.isPunctuation })
                    let second = word.dropFirst().first
                    if word != "I", !word.hasPrefix("I'"), second.map({ $0.isLowercase }) ?? true {
                        piece = first.lowercased() + piece.dropFirst()
                    }
                }
                lastText = piece
            }
            out += out.isEmpty ? piece : " " + piece
        }
        return out
    }

    public static func wordCount(_ text: String) -> Int {
        let stripped = ShotMarker.regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
        return stripped.split(whereSeparator: { $0.isWhitespace }).count
    }
}
