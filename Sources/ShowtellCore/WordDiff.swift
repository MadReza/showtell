import Foundation

/// A word-by-word comparison of two versions of a message, to see what the recogniser heard
/// against what was sent: which words went and which came in.
///
/// Words match ignoring case and punctuation ("Today," matches "today"), so the tidy-up's
/// capitals and commas don't show as changes. `[📷 n]` and `[📋 n]` markers are left out.
public enum WordDiff {
    public enum Part: Equatable, Sendable {
        /// In both; shown as the newer text has it.
        case same(String)
        case removed(String)
        case added(String)
    }

    /// Words heard but carrying no meaning: the tidy-up is asked to drop them, so dropping them
    /// doesn't count as losing words.
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "erm", "er", "ah", "hmm", "mm", "mhm"]

    /// The words of a message, markers left out.
    public static func words(_ text: String) -> [String] {
        let stripped = ShotMarker.regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
        return stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// What a word is compared by: lower case, letters and digits only.
    static func key(_ word: String) -> String {
        let k = word.lowercased().filter { $0.isLetter || $0.isNumber }
        return k.isEmpty ? word : k
    }

    /// The same words, ignoring case, punctuation, spacing and markers.
    public static func sameWords(_ a: String, _ b: String) -> Bool {
        words(a).map(key) == words(b).map(key)
    }

    /// From `old` to `new`: each removal comes before the additions that replace it.
    public static func diff(_ old: String, _ new: String) -> [Part] {
        let a = words(old), b = words(new)
        let ka = a.map(key), kb = b.map(key)
        // Longest common subsequence, filled from the end so the walk below goes forwards.
        let n = a.count, m = b.count
        var lcs = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = ka[i] == kb[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var parts: [Part] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, ka[i] == kb[j] {
                parts.append(.same(b[j]))
                i += 1
                j += 1
            } else if i < n, j == m || lcs[i + 1][j] >= lcs[i][j + 1] {
                parts.append(.removed(a[i]))
                i += 1
            } else {
                parts.append(.added(b[j]))
                j += 1
            }
        }
        return parts
    }

    /// The share of `old`'s words (fillers left out) that `new` no longer has: 0 to 1.
    public static func removedFraction(_ old: String, _ new: String) -> Double {
        let total = words(old).filter { !fillers.contains(key($0)) }.count
        guard total > 0 else { return 0 }
        let removed = diff(old, new).filter {
            if case .removed(let w) = $0 { return !fillers.contains(key(w)) }
            return false
        }.count
        return Double(removed) / Double(total)
    }
}
