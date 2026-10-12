import Darwin
import Foundation

/// Names a message's screenshots after it is settled, so they read well in Finder:
/// `2026-10-12 14.03 showtell 📷2 — the header is cut off here.png`, flat in shots/.
/// The destination is the session's name, `cursor`, or `unsent`; the words are the ones said
/// just before the picture's marker.
public enum ShotNames {
    /// The destination word for a message that was cancelled or never delivered.
    public static let unsent = "unsent"
    /// Longest name, without the extension and a ` (2)` suffix.
    public static let maxLength = 120
    /// How many words before the marker go in the name.
    public static let wordCount = 6

    /// The name without extension: date, time, destination, picture number, then the words.
    public static func name(date: Date, destination: String, number: Int, words: String?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        var head = "\(f.string(from: date)) \(sanitize(destination)) 📷\(number)"
        if head.count > maxLength { head = String(head.prefix(maxLength)) }
        guard let words else { return head }
        let tail = sanitize(words)
        guard !tail.isEmpty else { return head }
        let room = maxLength - head.count - 3
        guard room > 1 else { return head }
        let cut = tail.count > room ? String(tail.prefix(room - 1)).trimmingCharacters(in: .whitespaces) + "…" : tail
        return "\(head) — \(cut)"
    }

    /// Safe in a file name: no `/` or `:`, no line breaks or control characters, one space
    /// between words, no leading dot.
    public static func sanitize(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" {
                out.append("-")
            } else if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                out.append(" ")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        let collapsed = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.drop(while: { $0 == "." }))
    }

    /// About `count` words said just before marker `[📷 number]` in `text`, other markers left
    /// out. Nil when the marker isn't there or nothing was said before it.
    public static func words(before number: Int, in text: String, count: Int = wordCount) -> String? {
        let ns = text as NSString
        let matches = ShotMarker.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let marker = matches.first(where: {
            ns.substring(with: $0.range(at: 1)) == "📷" && Int(ns.substring(with: $0.range(at: 2))) == number
        }) else { return nil }
        let before = ns.substring(to: marker.range.location)
        let plain = ShotMarker.regex.stringByReplacingMatches(
            in: before, range: NSRange(location: 0, length: (before as NSString).length), withTemplate: " ")
        let picked = plain.split(whereSeparator: { $0.isWhitespace }).suffix(count).joined(separator: " ")
        let trimmed = picked.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces).subtracting(["?", "!"]))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `base.ext`, or `base (2).ext`, `base (3).ext`… the first one not taken.
    public static func unique(_ base: String, ext: String, taken: (String) -> Bool) -> String {
        let dot = ext.isEmpty ? "" : "." + ext
        var candidate = base + dot
        var n = 2
        while taken(candidate) {
            candidate = "\(base) (\(n))\(dot)"
            n += 1
        }
        return candidate
    }

    /// The Finder comment: where the message went and all of its text, so Spotlight finds the
    /// picture by anything you said.
    public static func comment(destination: String, delivered: Bool, text: String) -> String {
        let head = delivered ? "Showtell → \(destination)"
            : destination == unsent ? "Showtell, unsent" : "Showtell, unsent (for \(destination))"
        return head + "\n\n" + text
    }

    /// Renames this message's pictures in their folder and sets their Finder comment. The name
    /// says `destination` if the message was delivered, else `unsent`; pictures whose marker is no
    /// longer in the text are unsent too. Returns the URL of each picture from now on (one that
    /// couldn't be renamed keeps its name; a missing one is left out).
    @discardableResult
    public static func rename(_ shots: [Int: URL], text: String, destination: String, delivered: Bool,
                              date: Date) -> [Int: URL] {
        let fm = FileManager.default
        var renamed: [Int: URL] = [:]
        for (number, url) in shots.sorted(by: { $0.key < $1.key }) {
            guard fm.fileExists(atPath: url.path) else { continue }
            let words = words(before: number, in: text)
            let inText = text.contains(ShotMarker.token(number))
            let base = name(date: date, destination: delivered && inText ? destination : unsent, number: number, words: words)
            let folder = url.deletingLastPathComponent()
            let ext = url.pathExtension
            let current = url.lastPathComponent
            let file = unique(base, ext: ext) { candidate in
                candidate != current && fm.fileExists(atPath: folder.appendingPathComponent(candidate).path)
            }
            var target = folder.appendingPathComponent(file)
            if file != current {
                do { try fm.moveItem(at: url, to: target) } catch { target = url }
            }
            setFinderComment(comment(destination: destination, delivered: delivered && inText, text: text), on: target)
            renamed[number] = target
        }
        return renamed
    }

    static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    /// Sets the Spotlight comment (the attribute Finder's Get Info shows and `mdls` reads).
    @discardableResult
    public static func setFinderComment(_ text: String, on url: URL) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0)
        else { return false }
        return data.withUnsafeBytes { bytes in
            setxattr(url.path, commentAttribute, bytes.baseAddress, bytes.count, 0, 0) == 0
        }
    }

    /// The comment set by `setFinderComment`, if any.
    public static func finderComment(of url: URL) -> String? {
        let size = getxattr(url.path, commentAttribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, commentAttribute, $0.baseAddress, size, 0, 0) }
        guard read == size else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? String
    }
}
