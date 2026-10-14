import Foundation

/// A keyboard shortcut: a key with modifiers (⌃⌥Space), or one modifier tapped on its own (left ⌥).
public struct Shortcut: Codable, Equatable, Sendable {
    /// Carbon virtual key code; nil for a modifier tap.
    public var keyCode: UInt32?
    /// Carbon modifier mask: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
    public var modifiers: UInt32
    /// How the key is shown ("Space", "K"), captured when it was recorded.
    public var keyName: String?
    /// For a modifier tap: leftOption, rightOption, leftControl, rightControl, leftCommand,
    /// rightCommand, leftShift or rightShift.
    public var tap: String?

    public static func chord(_ keyCode: UInt32, _ modifiers: UInt32, _ keyName: String) -> Shortcut {
        Shortcut(keyCode: keyCode, modifiers: modifiers, keyName: keyName, tap: nil)
    }

    public static func tap(_ name: String) -> Shortcut {
        Shortcut(keyCode: nil, modifiers: 0, keyName: nil, tap: name)
    }

    public static let tapNames: [String: String] = [
        "leftOption": "Left ⌥", "rightOption": "Right ⌥", "leftControl": "Left ⌃", "rightControl": "Right ⌃",
        "leftCommand": "Left ⌘", "rightCommand": "Right ⌘", "leftShift": "Left ⇧", "rightShift": "Right ⇧",
    ]

    /// "⌃⌥Space", or "Left ⌥ tap".
    public var label: String {
        if let tap { return (Self.tapNames[tap] ?? tap) + " tap" }
        return Self.describe(modifiers: modifiers) + (keyName ?? keyCode.map { "key \($0)" } ?? "")
    }

    public static func describe(modifiers: UInt32) -> String {
        var s = ""
        if modifiers & 0x1000 != 0 { s += "⌃" }
        if modifiers & 0x800 != 0 { s += "⌥" }
        if modifiers & 0x200 != 0 { s += "⇧" }
        if modifiers & 0x100 != 0 { s += "⌘" }
        return s
    }
}

/// User settings, stored as JSON in ~/Library/Application Support/Showtell/settings.json and
/// edited in the Settings window.
public struct Settings: Codable, Equatable, Sendable {
    /// Starts a recording, and sends it on the second press.
    public var startShortcut = Shortcut.tap("leftOption")
    /// Throws the recording away. Active only while recording.
    public var cancelShortcut = Shortcut.chord(51, 0x1000 | 0x800, "⌫")
    /// Second press sends with Enter. Off: the message is pasted and you press Enter yourself.
    public var submitOnSecondPress = true
    /// Hide the bar while a native ⌘⌃⇧3/4 (copy to clipboard) screenshot is being taken.
    public var hideDuringScreenshots = true
    public var pinned: PinnedTarget?
    /// Insert into whatever app has the cursor instead of the open session.
    public var insertAtCursor = false
    /// Which model tidies the text (a `CleanupModel` id); nil means no clean-up.
    public var cleanupModel: String?
    /// Tidy every message when you send it. Off: only when you press the clean-up shortcut.
    public var cleanupOnSend = false
    /// While recording: stop listening and tidy the text for review; press again for the original.
    public var cleanupShortcut = Shortcut.chord(8, 0x1000 | 0x800, "C")
    /// While recording: switch between sending (Enter) and just pasting. Changes the default too.
    public var sendToggleShortcut = Shortcut.chord(1, 0x1000 | 0x800, "S")
    /// While recording: send this message to the next or previous session in the list.
    public var nextTargetShortcut = Shortcut.chord(125, 0x1000 | 0x800, "↓")
    public var previousTargetShortcut = Shortcut.chord(126, 0x1000 | 0x800, "↑")
    /// "For the showtell session, …" or "… send this to showtell" sends that message there.
    public var spokenRouting = true
    /// A spoken destination becomes the open session for the next messages too (off: that message only).
    public var spokenRouteSticks = true
    /// While recording: screenshots copied to the clipboard (⌘⌃⇧4) land in the message.
    public var captureScreenshots = true
    /// While recording: text you copy (⌘C, react-grab, …) lands in the message.
    public var captureCopiedText = true
    /// While recording: switch either capture on or off. Changes the default too.
    public var screenshotsToggleShortcut = Shortcut.chord(34, 0x1000 | 0x800, "I")
    public var copiedTextToggleShortcut = Shortcut.chord(17, 0x1000 | 0x800, "T")
    /// The language you dictate in; stays for the next messages.
    public var language = DictationLanguage.english
    /// While recording: switch to the next or previous language.
    public var nextLanguageShortcut = Shortcut.chord(124, 0x1000 | 0x800, "→")
    public var previousLanguageShortcut = Shortcut.chord(123, 0x1000 | 0x800, "←")

    public init() {}

    enum CodingKeys: String, CodingKey {
        case startShortcut, cancelShortcut, submitOnSecondPress, hideDuringScreenshots, pinned, insertAtCursor
        case cleanupModel, cleanupOnSend, cleanupShortcut
        case sendToggleShortcut, nextTargetShortcut, previousTargetShortcut, spokenRouting, spokenRouteSticks
        case captureScreenshots, captureCopiedText, screenshotsToggleShortcut, copiedTextToggleShortcut
        case language, nextLanguageShortcut, previousLanguageShortcut
        case hotKeyCode, hotKeyModifiers, tapKey  // before the Settings window (v0.1)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        if let s = try c.decodeIfPresent(Shortcut.self, forKey: .startShortcut) {
            startShortcut = s
        } else if let tap = try c.decodeIfPresent(String.self, forKey: .tapKey), tap != "off" {
            startShortcut = .tap(tap)
        } else if let code = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyCode) {
            let mods = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyModifiers) ?? 0x1000 | 0x800
            startShortcut = .chord(code, mods, code == 49 ? "Space" : "key \(code)")
        }
        cancelShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .cancelShortcut) ?? d.cancelShortcut
        submitOnSecondPress = try c.decodeIfPresent(Bool.self, forKey: .submitOnSecondPress) ?? d.submitOnSecondPress
        hideDuringScreenshots = try c.decodeIfPresent(Bool.self, forKey: .hideDuringScreenshots) ?? d.hideDuringScreenshots
        pinned = try c.decodeIfPresent(PinnedTarget.self, forKey: .pinned)
        insertAtCursor = try c.decodeIfPresent(Bool.self, forKey: .insertAtCursor) ?? false
        cleanupModel = try c.decodeIfPresent(String.self, forKey: .cleanupModel)
        cleanupOnSend = try c.decodeIfPresent(Bool.self, forKey: .cleanupOnSend) ?? d.cleanupOnSend
        cleanupShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .cleanupShortcut) ?? d.cleanupShortcut
        sendToggleShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .sendToggleShortcut) ?? d.sendToggleShortcut
        nextTargetShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .nextTargetShortcut) ?? d.nextTargetShortcut
        previousTargetShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .previousTargetShortcut) ?? d.previousTargetShortcut
        spokenRouting = try c.decodeIfPresent(Bool.self, forKey: .spokenRouting) ?? d.spokenRouting
        spokenRouteSticks = try c.decodeIfPresent(Bool.self, forKey: .spokenRouteSticks) ?? d.spokenRouteSticks
        captureScreenshots = try c.decodeIfPresent(Bool.self, forKey: .captureScreenshots) ?? d.captureScreenshots
        captureCopiedText = try c.decodeIfPresent(Bool.self, forKey: .captureCopiedText) ?? d.captureCopiedText
        screenshotsToggleShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .screenshotsToggleShortcut) ?? d.screenshotsToggleShortcut
        copiedTextToggleShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .copiedTextToggleShortcut) ?? d.copiedTextToggleShortcut
        // A language this build doesn't know (from a newer one) falls back to English.
        language = try c.decodeIfPresent(String.self, forKey: .language).flatMap(DictationLanguage.init(rawValue:)) ?? d.language
        nextLanguageShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .nextLanguageShortcut) ?? d.nextLanguageShortcut
        previousLanguageShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .previousLanguageShortcut) ?? d.previousLanguageShortcut
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startShortcut, forKey: .startShortcut)
        try c.encode(cancelShortcut, forKey: .cancelShortcut)
        try c.encode(submitOnSecondPress, forKey: .submitOnSecondPress)
        try c.encode(hideDuringScreenshots, forKey: .hideDuringScreenshots)
        try c.encodeIfPresent(pinned, forKey: .pinned)
        try c.encode(insertAtCursor, forKey: .insertAtCursor)
        try c.encodeIfPresent(cleanupModel, forKey: .cleanupModel)
        try c.encode(cleanupOnSend, forKey: .cleanupOnSend)
        try c.encode(cleanupShortcut, forKey: .cleanupShortcut)
        try c.encode(sendToggleShortcut, forKey: .sendToggleShortcut)
        try c.encode(nextTargetShortcut, forKey: .nextTargetShortcut)
        try c.encode(previousTargetShortcut, forKey: .previousTargetShortcut)
        try c.encode(spokenRouting, forKey: .spokenRouting)
        try c.encode(spokenRouteSticks, forKey: .spokenRouteSticks)
        try c.encode(captureScreenshots, forKey: .captureScreenshots)
        try c.encode(captureCopiedText, forKey: .captureCopiedText)
        try c.encode(screenshotsToggleShortcut, forKey: .screenshotsToggleShortcut)
        try c.encode(copiedTextToggleShortcut, forKey: .copiedTextToggleShortcut)
        try c.encode(language, forKey: .language)
        try c.encode(nextLanguageShortcut, forKey: .nextLanguageShortcut)
        try c.encode(previousLanguageShortcut, forKey: .previousLanguageShortcut)
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
    /// Downloaded clean-up models.
    public var modelsURL: URL { root.appendingPathComponent("models", isDirectory: true) }

    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: shotsURL, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: vocabularyURL.path) {
            try "# One term per line, written the way it should appear.\n# Aliases (herdr: herder) force the term onto similar-sounding words; use them sparingly.\nClaude Code\nherdr\nShowtell\n"
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
