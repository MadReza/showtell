import Foundation

/// Builds the message while you talk: live transcript, screenshot and copied-text markers
/// placed at the word you were saying, and any edits you make in the overlay.
///
/// The recogniser lags about 2 s and may rewrite recent words, so placement is
/// recomputed on every update until you edit. A screenshot (or a copy) goes after the words that
/// started before it, once the recogniser has timed speech past the shot (always by the
/// end). Until then it sits after the words the transcript held one lag after the shot,
/// as a guess. Your edits freeze everything shown at that moment; newer speech continues
/// after it.
public struct Composer: Sendable {
    /// A screenshot or text copied while talking. Each kind is numbered on its own: `[📷 1]`, `[📋 1]`.
    public struct Shot: Sendable {
        public enum Content: Sendable, Equatable {
            case screenshot(URL)
            case copiedText(String)
        }
        public let number: Int
        public let content: Content
        /// Seconds since recording started.
        public let time: Double
        /// Words already transcribed when the shot was taken: a lower bound for its place.
        let wordsAtShot: Int
        var frozen = false

        var token: String {
            switch content {
            case .screenshot: return ShotMarker.token(number)
            case .copiedText: return ShotMarker.clipToken(number)
            }
        }
    }

    public private(set) var shots: [Shot] = []
    /// How far the transcript trails the audio (Parakeet Unified streaming: 2.08 s).
    public var lag: Double
    private var engineText = ""
    private var wordStarts: [Double] = []
    private var finished = false
    /// (seconds of audio, words in the transcript) at each update.
    private var history: [(time: Double, words: Int)] = []
    private var frozenText = ""
    /// Recogniser words that were on screen when you edited; later speech starts after them.
    private var frozenEngine: [String] = []
    private var nextShot = 1
    private var nextClip = 1

    public init(lag: Double = 2.1) {
        self.lag = lag
    }

    public var shotURLs: [Int: URL] {
        var urls: [Int: URL] = [:]
        for shot in shots { if case .screenshot(let url) = shot.content { urls[shot.number] = url } }
        return urls
    }

    public var clipTexts: [Int: String] {
        var texts: [Int: String] = [:]
        for shot in shots { if case .copiedText(let text) = shot.content { texts[shot.number] = text } }
        return texts
    }

    /// The number the next screenshot will get.
    public var nextShotNumber: Int { nextShot }

    public var isEmpty: Bool { render().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Latest full transcript from the recogniser, the audio time it covers, and any newly timed words.
    public mutating func updateTranscript(_ text: String, newWordStartTimes: [Double] = [], at time: Double? = nil) {
        engineText = text
        wordStarts += newWordStartTimes
        if let time { history.append((time, engineWords.count)) }
    }

    /// Mark the transcript final: every shot whose lag window is still open goes by the final text.
    public mutating func finish(at time: Double) {
        history.append((max(time, (history.last?.time ?? 0)) + lag + 1, engineWords.count))
        finished = true
    }

    /// Listening restarts with a new recogniser (another language) whose transcript and clock start
    /// from zero: everything heard so far, with its markers placed, stays as it is, like an edit.
    public mutating func restartTranscript(at time: Double, lag: Double? = nil) {
        finish(at: time)
        frozenText = render()
        for i in shots.indices { shots[i].frozen = true }
        engineText = ""
        wordStarts = []
        history = []
        frozenEngine = []
        finished = false
        if let lag { self.lag = lag }
    }

    /// Records a screenshot taken `time` seconds into the recording. Returns its marker number.
    @discardableResult
    public mutating func addShot(_ url: URL, at time: Double) -> Int {
        let number = nextShot
        nextShot += 1
        shots.append(Shot(number: number, content: .screenshot(url), time: time, wordsAtShot: engineWords.count))
        return number
    }

    /// Records text copied `time` seconds into the recording, placed like a screenshot. Returns its marker number.
    @discardableResult
    public mutating func addClip(_ text: String, at time: Double) -> Int {
        let number = nextClip
        nextClip += 1
        shots.append(Shot(number: number, content: .copiedText(text), time: time, wordsAtShot: engineWords.count))
        return number
    }

    /// The user changed the overlay text. What they see becomes fixed.
    public mutating func userEdited(_ text: String) {
        frozenText = text
        frozenEngine = engineWords
        for i in shots.indices { shots[i].frozen = true }
    }

    /// The text to show and to send, with `[📷 n]` and `[📋 n]` markers.
    public func render() -> String {
        let words = engineWords
        let liveStart = Composer.resumeIndex(frozen: frozenEngine, current: words)
        let live = Array(words.dropFirst(liveStart))
        var slots: [Int: [String]] = [:]  // word index in `live` -> markers placed before it
        for shot in shots where !shot.frozen {
            let index: Int
            if !wordStarts.isEmpty, finished || wordStarts.last! >= shot.time {
                index = wordStarts.filter { $0 < shot.time }.count - liveStart
            } else {
                let caughtUp = history.first(where: { $0.time >= shot.time + lag })?.words ?? 0
                index = max(shot.wordsAtShot, caughtUp) - liveStart
            }
            slots[min(max(index, 0), live.count), default: []].append(shot.token)
        }
        var tokens: [String] = []
        for i in 0...live.count {
            tokens += slots[i] ?? []
            if i < live.count { tokens.append(live[i]) }
        }
        let liveText = tokens.joined(separator: " ")
        if frozenText.isEmpty { return liveText }
        if liveText.isEmpty { return frozenText }
        let sep = frozenText.last?.isWhitespace == true ? "" : " "
        return frozenText + sep + liveText
    }

    public func pieces() -> [Piece] {
        ShotMarker.pieces(from: render(), shots: shotURLs, clips: clipTexts)
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
