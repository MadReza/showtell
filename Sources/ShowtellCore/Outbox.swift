import Foundation

/// The session the user opened. Pinned by Claude session id; the pane id is refreshed
/// whenever herdr reports the session somewhere else (pane moved, workspace changed).
public struct PinnedTarget: Codable, Equatable, Sendable {
    public var sessionID: String
    public var terminalID: String
    public var paneID: String
    public var name: String
    public var cwd: String?

    public init(agent: HerdrAgent) {
        sessionID = agent.sessionID ?? ""
        terminalID = agent.terminalID
        paneID = agent.paneID
        name = agent.displayName
        cwd = agent.foregroundCwd ?? agent.cwd
    }

    /// Finds this target in a fresh agent list: same Claude session first, then same terminal.
    public func locate(in agents: [HerdrAgent]) -> HerdrAgent? {
        if !sessionID.isEmpty, let a = agents.first(where: { $0.sessionID == sessionID }) { return a }
        return agents.first(where: { $0.terminalID == terminalID && $0.isClaude })
    }
}

public enum DeliveryEvent: Equatable, Sendable {
    case waitingForApproval(String)
    case sending(String)
    case delivered(String)
    case failed(String)
}

public enum DeliveryError: Error, Equatable, CustomStringConvertible {
    case targetGone(String)
    case stillBlocked(String)

    public var description: String {
        switch self {
        case .targetGone(let n): return "\(n) is no longer running in herdr"
        case .stillBlocked(let n): return "\(n) kept a dialog open; message not sent"
        }
    }
}

/// Delivers messages to the pinned session one at a time, in order.
///
/// Rules verified against Claude Code 2.1.296:
/// - every screenshot path is its own bracketed paste, then a pause until its chip appears;
/// - a message sent while Claude works is queued by Claude Code with its images;
/// - nothing is pasted while the agent shows a dialog (herdr status `blocked`).
public actor Outbox {
    public struct Timing: Sendable {
        public var afterText: Double = 0.15
        public var afterImage: Double = 0.8
        public var beforeEnter: Double = 0.35
        public var blockedPoll: Double = 0.5
        public var blockedTimeout: Double = 600
        public init() {}
    }

    private let transport: HerdrTransport
    private let timing: Timing
    private let sleep: @Sendable (Double) async -> Void
    private var tail: Task<Void, Never>?
    public var onEvent: (@Sendable (DeliveryEvent) -> Void)?

    public init(
        transport: HerdrTransport,
        timing: Timing = Timing(),
        sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.transport = transport
        self.timing = timing
        self.sleep = sleep
    }

    public func setEventHandler(_ handler: @escaping @Sendable (DeliveryEvent) -> Void) {
        onEvent = handler
    }

    /// Queues a message behind any message still being delivered. Returns once it is delivered.
    @discardableResult
    public func enqueue(_ pieces: [Piece], to target: PinnedTarget, submit: Bool) async -> Result<PinnedTarget, Error> {
        let previous = tail
        let task = Task<Result<PinnedTarget, Error>, Never> {
            await previous?.value
            do {
                return .success(try await self.deliver(pieces, to: target, submit: submit))
            } catch {
                self.emit(.failed(String(describing: error)))
                return .failure(error)
            }
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func emit(_ event: DeliveryEvent) { onEvent?(event) }

    /// Returns the target as found (its pane id may have changed).
    func deliver(_ pieces: [Piece], to target: PinnedTarget, submit: Bool) async throws -> PinnedTarget {
        guard !pieces.isEmpty else { return target }
        var current = try await waitUntilReady(target)
        emit(.sending(current.name))

        for piece in pieces {
            switch piece {
            case .text(let s):
                try await transport.paste(s, pane: current.paneID)
                await sleep(timing.afterText)
            case .image(let url):
                try await transport.paste(url.path, pane: current.paneID)
                await sleep(timing.afterImage)
            }
        }
        if submit {
            await sleep(timing.beforeEnter)
            // A dialog may have opened while we pasted; Enter would answer it.
            current = try await waitUntilReady(current)
            try await transport.pressEnter(pane: current.paneID)
        }
        emit(.delivered(current.name))
        return current
    }

    private func waitUntilReady(_ target: PinnedTarget) async throws -> PinnedTarget {
        var waited = 0.0
        while true {
            let agents = try await transport.listAgents()
            guard let agent = target.locate(in: agents) else { throw DeliveryError.targetGone(target.name) }
            var updated = target
            updated.paneID = agent.paneID
            updated.terminalID = agent.terminalID
            if agent.status.acceptsInput { return updated }
            if waited == 0 { emit(.waitingForApproval(target.name)) }
            if waited >= timing.blockedTimeout { throw DeliveryError.stillBlocked(target.name) }
            await sleep(timing.blockedPoll)
            waited += timing.blockedPoll
        }
    }
}
