import Foundation

/// Builds the message while you talk: live transcript, screenshot markers placed at the
/// word you were saying, and any edits you make in the overlay.
///
/// The recogniser lags about 2 s and may rewrite recent words, so placement is
/// recomputed on every update until you edit. A screenshot goes after the words the
/// transcript held one lag after the shot (or after the words timed before it, when the
/// recogniser reports word timings). Your edits freeze everything shown at that moment;
/// newer speech continues after it.
public struct Composer: Sendable {
    public struct Shot: Sendable {
        public let number: Int
        public let url: URL
        /// Seconds since recording started.
        public let time: Double
        /// Words already transcribed when the shot was taken: a lower bound for its place.
        let wordsAtShot: Int
        var frozen = false
    }

    public private(set) var shots: [Shot] = []
    /// How far the transcript trails the audio (Parakeet Unified streaming: 2.08 s).
    public var lag: Double
    private var engineText = ""
    private var wordEnds: [Double] = []
    /// (seconds of audio, words in the transcript) at each update.
    private var history: [(time: Double, words: Int)] = []
    private var frozenText = ""
    /// Recogniser words that were on screen when you edited; later speech starts after them.
    private var frozenEngine: [String] = []
    private var nextNumber = 1

    public init(lag: Double = 2.1) {
        self.lag = lag
    }

    public var shotURLs: [Int: URL] {
        Dictionary(uniqueKeysWithValues: shots.map { ($0.number, $0.url) })
    }

    public var isEmpty: Bool { render().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Latest full transcript from the recogniser, the audio time it covers, and any newly timed words.
    public mutating func updateTranscript(_ text: String, newWordEndTimes: [Double] = [], at time: Double? = nil) {
        engineText = text
        wordEnds += newWordEndTimes
        if let time { history.append((time, engineWords.count)) }
    }

    /// Mark the transcript final: every shot whose lag window is still open goes by the final text.
    public mutating func finish(at time: Double) {
        history.append((max(time, (history.last?.time ?? 0)) + lag + 1, engineWords.count))
    }

    /// Records a screenshot taken `time` seconds into the recording. Returns its marker number.
    @discardableResult
    public mutating func addShot(_ url: URL, at time: Double) -> Int {
        let number = nextNumber
        nextNumber += 1
        shots.append(Shot(number: number, url: url, time: time, wordsAtShot: engineWords.count))
        return number
    }

    /// The user changed the overlay text. What they see becomes fixed.
    public mutating func userEdited(_ text: String) {
        frozenText = text
        frozenEngine = engineWords
        for i in shots.indices { shots[i].frozen = true }
    }

    /// The text to show and to send, with `[📷 n]` markers.
    public func render() -> String {
        let words = engineWords
        let liveStart = Composer.resumeIndex(frozen: frozenEngine, current: words)
        let live = Array(words.dropFirst(liveStart))
        var slots: [Int: [Int]] = [:]  // word index in `live` -> shot numbers placed before it
        for shot in shots where !shot.frozen {
            let timed = wordEnds.filter { $0 <= shot.time }.count
            let caughtUp = history.first(where: { $0.time >= shot.time + lag })?.words ?? 0
            let index = max(timed, shot.wordsAtShot, caughtUp) - liveStart
            slots[min(max(index, 0), live.count), default: []].append(shot.number)
        }
        var tokens: [String] = []
        for i in 0...live.count {
            tokens += (slots[i] ?? []).map(ShotMarker.token)
            if i < live.count { tokens.append(live[i]) }
        }
        let liveText = tokens.joined(separator: " ")
        if frozenText.isEmpty { return liveText }
        if liveText.isEmpty { return frozenText }
        let sep = frozenText.last?.isWhitespace == true ? "" : " "
        return frozenText + sep + liveText
    }

    public func pieces() -> [Piece] {
        ShotMarker.pieces(from: render(), shots: shotURLs)
    }

    /// Where speech after an edit begins in the current transcript. The recogniser may have
    /// rewritten words since ("to day" → "today"), so the frozen words' last few are looked up
    /// near their old position instead of trusting the old word count.
    static func resumeIndex(frozen: [String], current: [String]) -> Int {
        guard !frozen.isEmpty else { return 0 }
        func norm(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
        let f = frozen.map(norm), c = current.map(norm)
        for k in stride(from: min(3, f.count), through: 1, by: -1) {
            let anchor = Array(f.suffix(k))
            // Search ends near the old position first, then anywhere.
            let candidates = (0...max(0, c.count - k)).sorted { abs($0 + k - f.count) < abs($1 + k - f.count) }
            for start in candidates where start + k <= c.count && Array(c[start..<start + k]) == anchor {
                if abs(start + k - f.count) <= 4 { return start + k }
            }
        }
        return min(frozen.count, current.count)
    }

    private var engineWords: [String] {
        engineText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
