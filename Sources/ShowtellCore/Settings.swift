import Foundation

/// User settings, stored as JSON in ~/Library/Application Support/Showtell/settings.json.
public struct Settings: Codable, Equatable, Sendable {
    /// Carbon virtual key code and modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000).
    public var hotKeyCode: UInt32 = 49  // space
    public var hotKeyModifiers: UInt32 = 0x1000 | 0x800  // ⌃⌥
    /// Second press sends with Enter. Off: the message is pasted and you press Enter yourself.
    public var submitOnSecondPress = true
    /// Hide the bar while a native ⌘⇧3/4/5 screenshot is being taken.
    public var hideDuringScreenshots = true
    public var pinned: PinnedTarget?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        hotKeyCode = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyCode) ?? d.hotKeyCode
        hotKeyModifiers = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyModifiers) ?? d.hotKeyModifiers
        submitOnSecondPress = try c.decodeIfPresent(Bool.self, forKey: .submitOnSecondPress) ?? d.submitOnSecondPress
        hideDuringScreenshots = try c.decodeIfPresent(Bool.self, forKey: .hideDuringScreenshots) ?? d.hideDuringScreenshots
        pinned = try c.decodeIfPresent(PinnedTarget.self, forKey: .pinned)
    }
}

/// Where Showtell keeps its files.
public struct Storage: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Showtell", isDirectory: true)
    }

    public var settingsURL: URL { root.appendingPathComponent("settings.json") }
    /// Your own terms, simple list format (`term: alias, alias`).
    public var vocabularyURL: URL { root.appendingPathComponent("vocabulary.txt") }
    /// `wrong => right` lines applied to the finished text.
    public var replacementsURL: URL { root.appendingPathComponent("replacements.txt") }
    public var shotsURL: URL { root.appendingPathComponent("shots", isDirectory: true) }

    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: shotsURL, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: vocabularyURL.path) {
            try "# One term per line. Optional aliases: herdr: herder, her dr\nClaude Code\nherdr: herder\nShowtell: show tell\n"
                .write(to: vocabularyURL, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: replacementsURL.path) {
            try "# wrong => right, applied to the finished text\nclawed code => Claude Code\n"
                .write(to: replacementsURL, atomically: true, encoding: .utf8)
        }
    }

    public func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(_ settings: Settings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) { try? data.write(to: settingsURL, options: .atomic) }
    }

    /// A new numbered file for a screenshot in this recording.
    public func newShotURL(recording: String, number: Int) -> URL {
        shotsURL.appendingPathComponent("\(recording)-\(String(format: "%02d", number)).png")
    }

    /// All terms for a session in `cwd`: your list plus the repo's `.github/dictation.md`.
    public func vocabulary(forRepoAt cwd: String?) -> [VocabularyTerm] {
        var terms: [VocabularyTerm] = []
        if let text = try? String(contentsOf: vocabularyURL, encoding: .utf8) {
            terms += Vocabulary.simpleListTerms(text)
        }
        if let cwd, let root = Storage.gitRoot(from: cwd),
           let md = try? String(contentsOf: root.appendingPathComponent(".github/dictation.md"), encoding: .utf8) {
            terms += Vocabulary.dictationFileTerms(md)
        }
        return terms
    }

    public func replacementRules() -> [(String, String)] {
        guard let text = try? String(contentsOf: replacementsURL, encoding: .utf8) else { return [] }
        return Vocabulary.replacements(text)
    }

    static func gitRoot(from path: String) -> URL? {
        var dir = URL(fileURLWithPath: path)
        let fm = FileManager.default
        while dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}
