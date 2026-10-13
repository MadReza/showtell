import Foundation

/// Where a message went.
public enum HistoryDestination: Codable, Equatable, Sendable {
    case cursor
    case session(PinnedTarget)

    public var label: String {
        switch self {
        case .cursor: return "Cursor"
        case .session(let target): return target.name
        }
    }
}

/// What became of text that was already typed in the session's prompt when a message was pasted.
public enum DraftOutcome: String, Codable, Equatable, Sendable {
    /// Stashed with Ctrl+S; Claude Code put it back when the message was sent.
    case restoredFromStash
    /// Cleared, then typed back after the message was sent.
    case retyped
    /// Stashed, and the message was left unsent: Claude Code puts it back once you send it.
    case leftStashed
    case notRestored
}

/// One message Showtell sent: the text as the bar showed it (with `[📷 n]` and `[📋 n]` markers),
/// its screenshots (file names in shots/) and its copied text.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public struct Shot: Codable, Equatable, Sendable {
        public var number: Int
        /// A file name in shots/.
        public var file: String
        public init(number: Int, file: String) {
            self.number = number
            self.file = file
        }
    }

    public struct Clip: Codable, Equatable, Sendable {
        public var number: Int
        public var text: String
        public init(number: Int, text: String) {
            self.number = number
            self.text = text
        }
    }

    public var id: String
    public var date: Date
    public var destination: HistoryDestination
    public var text: String
    public var shots: [Shot]
    public var clips: [Clip]
    /// Enter was pressed after pasting.
    public var submitted: Bool
    /// Why it could not be delivered, if it couldn't.
    public var failure: String?
    /// Text that was already in the session's prompt and was cleared before pasting.
    public var clearedDraft: String?
    /// How the cleared text went back into the prompt, or that it didn't.
    public var draftOutcome: DraftOutcome?
    /// Why the cleared text was not put back, if it wasn't.
    public var draftNotRestored: String?
    /// The session showed a dialog and you cancelled the message: it wasn't sent.
    public var cancelled: Bool?
    /// Its words went as the answer to the session's question, not into the prompt.
    public var answered: AnsweredQuestion?

    /// How the text got from your voice to what was sent, to see where words went missing.
    /// Older entries have none of it.
    /// The recogniser's transcript when listening stopped, before anything changed it.
    public var rawTranscript: String?
    /// The text after your edits in the bar, when they changed the words.
    public var editedText: String?
    /// The text after your replacements, when they changed the words.
    public var replacedText: String?
    /// What the tidy-up returned, if it ran and its text was kept.
    public var tidiedText: String?
    /// The tidy-up model's name, or "Off" when the text wasn't tidied.
    public var tidyModel: String?

    public static let tidyOff = "Off"

    public init(id: String = UUID().uuidString, date: Date = Date(), destination: HistoryDestination, text: String,
                shots: [Shot] = [], clips: [Clip] = [], submitted: Bool, failure: String? = nil,
                clearedDraft: String? = nil) {
        self.id = id
        self.date = date
        self.destination = destination
        self.text = text
        self.shots = shots
        self.clips = clips
        self.submitted = submitted
        self.failure = failure
        self.clearedDraft = clearedDraft
    }

    /// A message as sent, keeping only the screenshots and copied text whose marker is still in it.
    public static func sent(id: String, destination: HistoryDestination, text: String, shots: [Int: URL],
                            clips: [Int: String], submitted: Bool) -> HistoryEntry {
        let ns = text as NSString
        var shotNumbers = Set<Int>(), clipNumbers = Set<Int>()
        for match in ShotMarker.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let n = Int(ns.substring(with: match.range(at: 2))) else { continue }
            if ns.substring(with: match.range(at: 1)) == "📋" { clipNumbers.insert(n) } else { shotNumbers.insert(n) }
        }
        return HistoryEntry(
            id: id, destination: destination, text: text,
            shots: shots.filter { shotNumbers.contains($0.key) }.sorted { $0.key < $1.key }
                .map { Shot(number: $0.key, file: $0.value.lastPathComponent) },
            clips: clips.filter { clipNumbers.contains($0.key) }.sorted { $0.key < $1.key }
                .map { Clip(number: $0.key, text: $0.value) },
            submitted: submitted)
    }

    /// Keeps each step from voice to message; a step that left the words as they were is not kept.
    /// `tidyModel` nil means the tidy-up didn't run (or its text was put back).
    public mutating func setStages(raw: String?, edited: String, replaced: String, tidied: String?, tidyModel: String?) {
        rawTranscript = raw
        editedText = raw.map { WordDiff.sameWords($0, edited) } == true ? nil : edited
        replacedText = WordDiff.sameWords(edited, replaced) ? nil : replaced
        tidiedText = tidyModel == nil ? nil : tidied
        self.tidyModel = tidiedText == nil ? Self.tidyOff : tidyModel
    }

    /// Whether the steps from voice to message were kept (not for older entries).
    public var hasStages: Bool { rawTranscript != nil || tidyModel != nil }

    /// The text the tidy-up was given: after your edits and replacements.
    public var tidyInput: String? {
        guard tidiedText != nil else { return nil }
        return replacedText ?? editedText ?? rawTranscript
    }

    /// The share of words (fillers left out) the tidy-up dropped, if it ran.
    public var tidyRemovedFraction: Double? {
        guard let input = tidyInput, let tidied = tidiedText else { return nil }
        return WordDiff.removedFraction(input, tidied)
    }

    /// The tidy-up dropped enough words to look at.
    public var tidyDroppedWords: Bool { (tidyRemovedFraction ?? 0) > 0.1 }

    /// Words from what was heard to what was sent.
    public var changes: [WordDiff.Part]? {
        rawTranscript.map { WordDiff.diff($0, text) }
    }

    /// The text on one line, for the list.
    public var preview: String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The message again, as pieces to deliver. Screenshots whose file is gone are left out.
    public func pieces(shotsIn folder: URL) -> [Piece] {
        let fm = FileManager.default
        var urls: [Int: URL] = [:]
        for shot in shots {
            let url = folder.appendingPathComponent(shot.file)
            if fm.fileExists(atPath: url.path) { urls[shot.number] = url }
        }
        let texts = Dictionary(clips.map { ($0.number, $0.text) }, uniquingKeysWith: { a, _ in a })
        return ShotMarker.pieces(from: text, shots: urls, clips: texts)
    }
}

/// Every message sent, newest first, in history.json next to shots/.
public struct HistoryStore: Sendable {
    public let url: URL
    public let shotsURL: URL

    public init(storage: Storage) {
        url = storage.root.appendingPathComponent("history.json")
        shotsURL = storage.shotsURL
    }

    public func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([HistoryEntry].self, from: data)) ?? []
    }

    func save(_ entries: [HistoryEntry]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(entries).write(to: url, options: .atomic)
    }

    /// Adds a sent message at the top.
    public func record(_ entry: HistoryEntry) throws {
        try save([entry] + load().filter { $0.id != entry.id })
    }

    /// Notes that a message could not be delivered.
    public func markFailed(_ id: String, _ reason: String) throws {
        var entries = load()
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].failure = reason
        try save(entries)
    }

    /// Notes that a message held for a dialog was cancelled.
    public func markCancelled(_ id: String) throws {
        var entries = load()
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].cancelled = true
        try save(entries)
    }

    /// Notes that a message went as the answer to the session's question.
    public func setAnswered(_ id: String, _ answered: AnsweredQuestion) throws {
        var entries = load()
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].answered = answered
        try save(entries)
    }

    /// Keeps the text that was cleared from the prompt before this message was pasted.
    public func setClearedDraft(_ id: String, _ draft: String) throws {
        var entries = load()
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].clearedDraft = draft
        try save(entries)
    }

    /// Notes how the cleared text went back into the prompt, or why it didn't.
    public func setDraftOutcome(_ id: String, _ outcome: DraftOutcome, reason: String? = nil) throws {
        var entries = load()
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].draftOutcome = outcome
        entries[i].draftNotRestored = outcome == .notRestored ? reason : nil
        try save(entries)
    }

    /// Points every entry that uses a renamed picture at its new name (old name → new name).
    public func renameShots(_ renames: [String: String]) throws {
        guard !renames.isEmpty else { return }
        var entries = load()
        var changed = false
        for i in entries.indices {
            for j in entries[i].shots.indices {
                if let new = renames[entries[i].shots[j].file] {
                    entries[i].shots[j].file = new
                    changed = true
                }
            }
        }
        if changed { try save(entries) }
    }

    /// Removes these entries and their screenshots, unless another entry still uses a picture.
    /// Returns how many picture files were deleted.
    @discardableResult
    public func delete(_ ids: Set<String>) throws -> Int {
        let entries = load()
        let kept = entries.filter { !ids.contains($0.id) }
        let stillUsed = Set(kept.flatMap { $0.shots.map(\.file) })
        let orphans = Set(entries.filter { ids.contains($0.id) }.flatMap { $0.shots.map(\.file) }).subtracting(stillUsed)
        try save(kept)
        return orphans.reduce(0) { n, file in
            (try? FileManager.default.removeItem(at: shotsURL.appendingPathComponent(file))) != nil ? n + 1 : n
        }
    }

    /// Removes every entry and the screenshots they used.
    @discardableResult
    public func clear() throws -> Int {
        try delete(Set(load().map(\.id)))
    }

    /// The pictures in shots/: how many, and how many bytes.
    public func shotsUsage() -> (files: Int, bytes: Int64) {
        pictures().reduce((0, Int64(0))) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (sum.0 + 1, sum.1 + Int64(size))
        }
    }

    /// Deletes every picture in shots/ except `keeping` (a recording still in progress).
    /// History entries keep their text; their pictures show as removed. Returns how many were deleted.
    @discardableResult
    public func clearShots(keeping: Set<String> = []) -> Int {
        pictures().filter { !keeping.contains($0.lastPathComponent) }.reduce(0) { n, url in
            (try? FileManager.default.removeItem(at: url)) != nil ? n + 1 : n
        }
    }

    public func shotURL(_ shot: HistoryEntry.Shot) -> URL { shotsURL.appendingPathComponent(shot.file) }

    private func pictures() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: shotsURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return files.filter { ["png", "tiff", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
    }
}
