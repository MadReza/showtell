import Foundation

/// A Claude Code (or other) agent running in a herdr pane, as `agent.list` reports it.
public struct HerdrAgent: Decodable, Equatable, Sendable {
    public struct Session: Decodable, Equatable, Sendable {
        public let kind: String?
        public let value: String?
    }

    public let paneID: String
    public let terminalID: String
    public let workspaceID: String?
    public let agent: String?
    public let status: AgentStatus
    public let session: Session?
    public let cwd: String?
    public let foregroundCwd: String?
    public let title: String?
    public let focused: Bool?

    public var sessionID: String? { session?.value }
    public var isClaude: Bool { agent == "claude" }

    /// Short label for menus: the terminal title, else the folder name.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        let dir = foregroundCwd ?? cwd ?? paneID
        return URL(fileURLWithPath: dir).lastPathComponent
    }

    public var folderName: String {
        URL(fileURLWithPath: foregroundCwd ?? cwd ?? "").lastPathComponent
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", terminalID = "terminal_id", workspaceID = "workspace_id"
        case agent, status = "agent_status", session = "agent_session", cwd
        case foregroundCwd = "foreground_cwd", title = "terminal_title_stripped", focused
    }

    public init(
        paneID: String, terminalID: String, workspaceID: String? = nil, agent: String? = "claude",
        status: AgentStatus, sessionID: String?, cwd: String? = nil, title: String? = nil
    ) {
        self.paneID = paneID
        self.terminalID = terminalID
        self.workspaceID = workspaceID
        self.agent = agent
        self.status = status
        self.session = Session(kind: "id", value: sessionID)
        self.cwd = cwd
        self.foregroundCwd = cwd
        self.title = title
        self.focused = false
    }
}

public enum AgentStatus: String, Decodable, Sendable {
    case idle, working, blocked, done, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }

    /// The agent can take input without it landing in a dialog.
    public var acceptsInput: Bool { self != .blocked }
}

public struct HerdrError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let message: String
    public var description: String { "herdr \(code): \(message)" }
}

/// What Showtell needs from herdr. A protocol so the outbox can be tested without a socket.
public protocol HerdrTransport: Sendable {
    func listAgents() async throws -> [HerdrAgent]
    /// Bracketed paste of `text` into the pane (no Enter).
    func paste(_ text: String, pane: String) async throws
    func pressEnter(pane: String) async throws
    /// The visible screen, with colour escapes where the terminal can give them (see `PromptInput`).
    func readScreen(pane: String) async throws -> String
    /// Sends `rounds` rounds of Ctrl+E, Ctrl+K, Ctrl+U, Backspace. Each round empties one screen line
    /// of Claude Code's input, wherever the cursor is, and does nothing to an empty one. These keys only
    /// edit the input: unlike Ctrl+C, Ctrl+D or Esc they can't interrupt, exit or open a menu.
    func sendClearKeys(pane: String, rounds: Int) async throws
    /// Presses the keys in order.
    func sendKeys(_ keys: [PromptKey], pane: String) async throws
    /// Types `text` as keystrokes, without paste markers, so Claude Code doesn't fold it into
    /// `[Pasted text #n]`. A line break goes as LF (Ctrl+J): a new line in Claude Code's input, not Enter.
    /// Big pieces still arrive at once and read as a paste: send a short piece at a time.
    func typeText(_ text: String, pane: String) async throws
    /// Whether `typeText` can type a line break into this pane.
    func typesLineBreaks(pane: String) -> Bool
}

/// One round of `sendClearKeys`, as herdr key names.
public let clearKeysRound = ["ctrl+e", "ctrl+k", "ctrl+u", "backspace"]

/// Keys Showtell presses in Claude Code's prompt besides the clearing rounds. Raw values are herdr's names.
public enum PromptKey: String, Sendable {
    /// Stashes a non-empty prompt (Claude Code 2.1); it comes back after the next message is sent.
    case stash = "ctrl+s"
    /// Down a row in the input. On the last row it does nothing, unless you are going through history.
    case down
    /// Up a row; in a dialog, the option above.
    case up
    /// To the end of the row.
    case end = "ctrl+e"

    var tmux: String {
        switch self {
        case .stash: return "C-s"
        case .down: return "Down"
        case .up: return "Up"
        case .end: return "C-e"
        }
    }

    /// As an AppleScript expression for iTerm2's `write text`.
    var iterm: String {
        switch self {
        case .stash: return "(character id 19)"
        case .down: return "(character id 27) & \"[B\""
        case .up: return "(character id 27) & \"[A\""
        case .end: return "(character id 5)"
        }
    }
}

/// Talks to herdr's newline-delimited JSON socket, one request per connection.
public struct HerdrClient: HerdrTransport {
    public let socketPath: String
    public var timeout: TimeInterval = 3

    public static var defaultSocketPath: String {
        if let env = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"], !env.isEmpty { return env }
        return NSString(string: "~/.config/herdr/herdr.sock").expandingTildeInPath
    }

    public init(socketPath: String = HerdrClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    public func listAgents() async throws -> [HerdrAgent] {
        struct Result: Decodable { let agents: [HerdrAgent] }
        let data = try await call("agent.list", params: [:])
        return try JSONDecoder().decode(Result.self, from: data).agents
    }

    /// Synchronous variant for menus, which must be built on the spot. herdr answers in milliseconds.
    public func listAgentsNow() throws -> [HerdrAgent] {
        struct Result: Decodable { let agents: [HerdrAgent] }
        let request: [String: Any] = ["id": "showtell-menu", "method": "agent.list", "params": [String: Any]()]
        let line = try JSONSerialization.data(withJSONObject: request) + Data([0x0a])
        let reply = try UnixSocket.exchange(path: socketPath, payload: line, timeout: 1)
        struct Envelope: Decodable { let result: Result?; let error: [String: String]? }
        let env = try JSONDecoder().decode(Envelope.self, from: reply)
        if let e = env.error { throw HerdrError(code: e["code"] ?? "error", message: e["message"] ?? "") }
        return env.result?.agents ?? []
    }

    public func paste(_ text: String, pane: String) async throws {
        // herdr wraps text-only send_input in ESC[200~ … ESC[201~ when the app enabled
        // bracketed paste. A stray end marker inside would end the paste early.
        let safe = text.replacingOccurrences(of: "\u{1b}[201~", with: "")
        _ = try await call("pane.send_input", params: ["pane_id": pane, "text": safe])
    }

    public func pressEnter(pane: String) async throws {
        _ = try await call("pane.send_keys", params: ["pane_id": pane, "keys": ["enter"]])
    }

    public func sendClearKeys(pane: String, rounds: Int) async throws {
        let keys = Array(Array(repeating: clearKeysRound, count: rounds).joined())
        _ = try await call("pane.send_keys", params: ["pane_id": pane, "keys": keys])
    }

    public func sendKeys(_ keys: [PromptKey], pane: String) async throws {
        _ = try await call("pane.send_keys", params: ["pane_id": pane, "keys": keys.map(\.rawValue)])
    }

    public func typeText(_ text: String, pane: String) async throws {
        _ = try await call("pane.send_text", params: ["pane_id": pane, "text": text])
    }

    public func typesLineBreaks(pane: String) -> Bool { true }

    public func readScreen(pane: String) async throws -> String {
        struct Read: Decodable { let text: String }
        struct Result: Decodable { let read: Read }
        let data = try await call(
            "pane.read", params: ["pane_id": pane, "source": "visible", "format": "ansi", "strip_ansi": false])
        return try JSONDecoder().decode(Result.self, from: data).read.text
    }

    /// Sends one request and returns the raw JSON of its `result`.
    public func call(_ method: String, params: [String: Any]) async throws -> Data {
        let request: [String: Any] = ["id": "showtell-\(UUID().uuidString)", "method": method, "params": params]
        let line = try JSONSerialization.data(withJSONObject: request) + Data([0x0a])
        let path = socketPath
        let timeout = timeout
        let reply = try await Task.detached { try UnixSocket.exchange(path: path, payload: line, timeout: timeout) }.value
        guard let obj = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw HerdrError(code: "bad_reply", message: String(decoding: reply, as: UTF8.self))
        }
        if let err = obj["error"] as? [String: Any] {
            throw HerdrError(code: err["code"] as? String ?? "error", message: err["message"] as? String ?? "")
        }
        return try JSONSerialization.data(withJSONObject: obj["result"] ?? [:])
    }
}

/// Minimal blocking AF_UNIX request/response: write one line, read one line.
enum UnixSocket {
    static func exchange(path: String, payload: Data, timeout: TimeInterval) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError(code: "socket", message: String(cString: strerror(errno))) }
        defer { close(fd) }
        var one: Int32 = 1  // a herdr that went away must not kill us with SIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { throw HerdrError(code: "socket", message: "path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            throw HerdrError(code: "not_running", message: "can't reach herdr at \(path): \(String(cString: strerror(errno)))")
        }

        try payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                guard n > 0 else { throw HerdrError(code: "write", message: String(cString: strerror(errno))) }
                sent += n
            }
        }

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while reply.last != 0x0a {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { reply.append(chunk, count: n) } else if n == 0 { break } else {
                throw HerdrError(code: "timeout", message: "no reply from herdr")
            }
        }
        return reply
    }
}
