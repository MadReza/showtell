import Foundation

/// Builds the message while you talk: live transcript, screenshot markers placed at the
/// word you were saying, and any edits you make in the overlay.
///
/// The recogniser lags about 2 s and may rewrite recent words, so placement is
/// recomputed on every update from word timings, until you edit. Your edits freeze
/// everything shown at that moment; newer speech continues after it.
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
    private var engineText = ""
    private var wordEnds: [Double] = []
    private var frozenText = ""
    private var frozenEngineWords = 0
    private var nextNumber = 1

    public init() {}

    public var shotURLs: [Int: URL] {
        Dictionary(uniqueKeysWithValues: shots.map { ($0.number, $0.url) })
    }

    public var isEmpty: Bool { render().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Latest full transcript from the recogniser plus any newly timed words.
    public mutating func updateTranscript(_ text: String, newWordEndTimes: [Double] = []) {
        engineText = text
        wordEnds += newWordEndTimes
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
        frozenEngineWords = engineWords.count
        for i in shots.indices { shots[i].frozen = true }
    }

    /// The text to show and to send, with `[📷 n]` markers.
    public func render() -> String {
        let live = Array(engineWords.dropFirst(frozenEngineWords))
        var slots: [Int: [Int]] = [:]  // word index in `live` -> shot numbers placed before it
        for shot in shots where !shot.frozen {
            let timed = wordEnds.filter { $0 <= shot.time }.count
            let index = max(timed, shot.wordsAtShot) - frozenEngineWords
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

    private var engineWords: [String] {
        engineText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
