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

    public init(id: String = UUID().uuidString, date: Date = Date(), destination: HistoryDestination, text: String,
                shots: [Shot] = [], clips: [Clip] = [], submitted: Bool, failure: String? = nil) {
        self.id = id
        self.date = date
        self.destination = destination
        self.text = text
        self.shots = shots
        self.clips = clips
        self.submitted = submitted
        self.failure = failure
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
