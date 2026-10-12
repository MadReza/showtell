import Foundation

/// Claude Code sessions outside herdr: in tmux panes and plain iTerm2 tabs.
///
/// Each running session writes `~/.claude/sessions/<pid>.json` (session id, cwd, name, status).
/// The process's terminal (`ps -o tty`) is matched against tmux's panes and iTerm2's sessions.
/// Delivery follows the same rules as herdr: each piece as its own bracketed paste, then Enter.
public struct TerminalSessions: HerdrTransport {
    public var sessionsDir: String
    public static let tmuxPrefix = "tmux:"
    public static let itermPrefix = "iterm:"

    public init(sessionsDir: String = NSString(string: "~/.claude/sessions").expandingTildeInPath) {
        self.sessionsDir = sessionsDir
    }

    public static func handles(pane: String) -> Bool {
        pane.hasPrefix(tmuxPrefix) || pane.hasPrefix(itermPrefix)
    }

    public func listAgents() async throws -> [HerdrAgent] { listNow() }

    /// Runs a few short commands; fine for building a menu.
    public func listNow() -> [HerdrAgent] {
        let files = Self.sessionFiles(in: sessionsDir)
        guard !files.isEmpty else { return [] }
        let ttys = Self.ttys(of: files.map(\.pid))
        let tmux = Self.tmuxPanes()
        let iterm = Self.itermSessions()
        return files.compactMap { f -> HerdrAgent? in
            guard let tty = ttys[f.pid] else { return nil }
            let pane: String, place: String
            if let p = tmux[tty] {
                pane = Self.tmuxPrefix + p
                place = "tmux"
            } else if let s = iterm[tty] {
                pane = Self.itermPrefix + s
                place = "iTerm2"
            } else {
                return nil  // herdr or a terminal we can't reach
            }
            let name = f.name ?? URL(fileURLWithPath: f.cwd ?? "").lastPathComponent
            return HerdrAgent(paneID: pane, terminalID: "tty:" + tty, status: f.status, sessionID: f.sessionID,
                              cwd: f.cwd, title: "\(name) · \(place)")
        }
    }

    public func paste(_ text: String, pane: String) async throws {
        let safe = text.replacingOccurrences(of: "\u{1b}[201~", with: "")
        if let p = Self.strip(pane, Self.tmuxPrefix) {
            try Self.run(Self.tmuxPath, ["set-buffer", "-b", "showtell", "--", safe])
            try Self.run(Self.tmuxPath, ["paste-buffer", "-p", "-d", "-b", "showtell", "-t", p])
        } else if let s = Self.strip(pane, Self.itermPrefix) {
            try Self.iterm(s, write: "(character id 27) & \"[200~\" & txt & (character id 27) & \"[201~\"", text: safe)
        } else {
            throw HerdrError(code: "unknown_pane", message: pane)
        }
    }

    public func pressEnter(pane: String) async throws {
        if let p = Self.strip(pane, Self.tmuxPrefix) {
            try Self.run(Self.tmuxPath, ["send-keys", "-t", p, "Enter"])
        } else if let s = Self.strip(pane, Self.itermPrefix) {
            try Self.iterm(s, write: "(character id 13)", text: "")
        }
    }

    public func sendClearKeys(pane: String, rounds: Int) async throws {
        guard rounds > 0 else { return }
        if let p = Self.strip(pane, Self.tmuxPrefix) {
            let round = ["C-e", "C-k", "C-u", "BSpace"]
            try Self.run(Self.tmuxPath, ["send-keys", "-t", p] + Array(Array(repeating: round, count: rounds).joined()))
        } else if let s = Self.strip(pane, Self.itermPrefix) {
            // Typed, not pasted: Ctrl+E, Ctrl+K, Ctrl+U, Backspace (DEL).
            let round = [5, 11, 21, 127].map { "(character id \($0))" }.joined(separator: " & ")
            try Self.iterm(s, write: Array(repeating: round, count: rounds).joined(separator: " & "), text: "")
        } else {
            throw HerdrError(code: "unknown_pane", message: pane)
        }
    }

    /// tmux gives colours (`-e`); iTerm2's AppleScript only plain text.
    public func readScreen(pane: String) async throws -> String {
        if let p = Self.strip(pane, Self.tmuxPrefix) {
            return try Self.run(Self.tmuxPath, ["capture-pane", "-p", "-e", "-t", p])
        } else if let s = Self.strip(pane, Self.itermPrefix) {
            return try Self.itermContents(s)
        }
        return ""
    }

    // MARK: Discovery

    struct SessionFile {
        let pid: Int32
        let sessionID: String?
        let cwd: String?
        let name: String?
        let status: AgentStatus
    }

    static func sessionFiles(in dir: String) -> [SessionFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = FileManager.default.contents(atPath: dir + "/" + name),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  kill(pid, 0) == 0 || errno == EPERM else { return nil }
            return SessionFile(pid: pid, sessionID: obj["sessionId"] as? String, cwd: obj["cwd"] as? String,
                               name: obj["name"] as? String, status: status(obj["status"] as? String))
        }
    }

    /// Claude Code writes idle, busy, or waiting (a dialog or question is open).
    static func status(_ raw: String?) -> AgentStatus {
        switch raw {
        case "idle": return .idle
        case "busy": return .working
        case "waiting": return .blocked
        default: return .unknown
        }
    }

    /// pid → "/dev/ttys012"
    static func ttys(of pids: [Int32]) -> [Int32: String] {
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = try? run("/bin/ps", ["-o", "pid=,tty=", "-p", list]) else { return [:] }
        var map: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]), parts[1] != "??" else { continue }
            map[pid] = "/dev/" + parts[1]
        }
        return map
    }

    static var tmuxPath: String {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "tmux"
    }

    /// tty → "%3"
    static func tmuxPanes() -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: tmuxPath),
              let out = try? run(tmuxPath, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"]) else { return [:] }
        return pairs(out)
    }

    /// tty → iTerm2 session id. Asks iTerm2 only when it is running.
    static func itermSessions() -> [String: String] {
        guard (try? run("/usr/bin/pgrep", ["-x", "iTerm2"])) != nil else { return [:] }
        let script = """
        set out to ""
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set out to out & (tty of s) & " " & (id of s) & linefeed
                    end repeat
                end repeat
            end repeat
        end tell
        return out
        """
        guard let out = try? run("/usr/bin/osascript", ["-e", script]) else { return [:] }
        return pairs(out)
    }

    static func iterm(_ session: String, write expression: String, text: String) throws {
        let script = """
        on run argv
            set sid to item 1 of argv
            set txt to item 2 of argv
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (id of s) is sid then
                                tell s to write text (\(expression)) newline no
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            error "iTerm2 session not found"
        end run
        """
        try run("/usr/bin/osascript", ["-e", script, session, text])
    }

    /// The session's visible text.
    static func itermContents(_ session: String) throws -> String {
        let script = """
        on run argv
            set sid to item 1 of argv
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (id of s) is sid then return contents of s
                        end repeat
                    end repeat
                end repeat
            end tell
            error "iTerm2 session not found"
        end run
        """
        return try run("/usr/bin/osascript", ["-e", script, session])
    }

    // MARK: Helpers

    static func pairs(_ out: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { map[String(parts[0])] = String(parts[1]) }
        }
        return map
    }

    static func strip(_ pane: String, _ prefix: String) -> String? {
        pane.hasPrefix(prefix) ? String(pane.dropFirst(prefix.count)) : nil
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrError(code: "\(URL(fileURLWithPath: path).lastPathComponent)_failed", message: message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Every reachable Claude Code session: herdr panes, then tmux panes and iTerm2 tabs not
/// already seen in herdr. Pastes go to whichever runs the pane.
public struct AllSessions: HerdrTransport {
    public let herdr: HerdrClient
    public let terminals: TerminalSessions

    public init(herdr: HerdrClient = HerdrClient(), terminals: TerminalSessions = TerminalSessions()) {
        self.herdr = herdr
        self.terminals = terminals
    }

    public func listAgents() async throws -> [HerdrAgent] {
        let fromHerdr = try? await herdr.listAgents()
        return Self.merge(fromHerdr ?? [], terminals.listNow())
    }

    public func listAgentsNow() -> [HerdrAgent] {
        Self.merge((try? herdr.listAgentsNow()) ?? [], terminals.listNow())
    }

    public static func merge(_ herdr: [HerdrAgent], _ others: [HerdrAgent]) -> [HerdrAgent] {
        let seen = Set(herdr.compactMap(\.sessionID))
        return herdr + others.filter { $0.sessionID.map { !seen.contains($0) } ?? true }
    }

    public func paste(_ text: String, pane: String) async throws {
        if TerminalSessions.handles(pane: pane) {
            try await terminals.paste(text, pane: pane)
        } else {
            try await herdr.paste(text, pane: pane)
        }
    }

    public func pressEnter(pane: String) async throws {
        if TerminalSessions.handles(pane: pane) {
            try await terminals.pressEnter(pane: pane)
        } else {
            try await herdr.pressEnter(pane: pane)
        }
    }

    public func readScreen(pane: String) async throws -> String {
        TerminalSessions.handles(pane: pane)
            ? try await terminals.readScreen(pane: pane) : try await herdr.readScreen(pane: pane)
    }

    public func sendClearKeys(pane: String, rounds: Int) async throws {
        if TerminalSessions.handles(pane: pane) {
            try await terminals.sendClearKeys(pane: pane, rounds: rounds)
        } else {
            try await herdr.sendClearKeys(pane: pane, rounds: rounds)
        }
    }
}
