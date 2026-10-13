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
    /// A dialog opened after the message was pasted; Enter waits for it to close.
    case waitingForApproval(String)
    /// A message is held: its session shows a dialog. Sent again whenever what can be done changes.
    case held(Hold)
    /// The message with this id is no longer held: the dialog closed, or you chose what to do.
    case released(String)
    case sending(String)
    case delivered(String)
    case failed(String)
}

/// A message held back because its session shows a dialog, and what you can do about it.
public struct Hold: Equatable, Sendable {
    public var messageID: String
    public var name: String
    public var kind: Dialog.Kind
    /// The dialog is a question with a place to type, and the message has words to type there.
    public var canAnswer: Bool
    /// The message has pictures, which can't go into a dialog.
    public var hasPictures: Bool
    /// You chose to send it once the dialog closes.
    public var sendAfter: Bool

    public init(messageID: String, name: String, kind: Dialog.Kind, canAnswer: Bool, hasPictures: Bool, sendAfter: Bool) {
        self.messageID = messageID
        self.name = name
        self.kind = kind
        self.canAnswer = canAnswer
        self.hasPictures = hasPictures
        self.sendAfter = sendAfter
    }

    /// "Held: showtell is asking a question".
    public var title: String {
        switch kind {
        case .question: return "Held: \(name) is asking a question"
        case .permission: return "Held: \(name) is waiting on a permission prompt"
        case .other: return "Held: \(name) is showing a dialog"
        }
    }
}

/// What to do with a held message.
public enum HoldChoice: Sendable {
    /// Type its words as the answer to the question on screen.
    case answer
    /// Paste it once the dialog closes, however long that takes.
    case sendAfter
    /// Drop it.
    case cancel
}

/// How a message was delivered.
public struct Delivered: Equatable, Sendable {
    /// The target as found (its pane id may have changed).
    public var target: PinnedTarget
    /// Set when its words went as the answer to a question instead of into the prompt.
    public var answered: AnsweredQuestion?
}

public enum DeliveryError: Error, Equatable, CustomStringConvertible {
    case targetGone(String)
    case stillBlocked(String)
    /// An earlier message stopped halfway; pasting this one would land on its leftovers.
    case earlierMessageFailed
    /// The prompt held text that wouldn't clear; pasting would have joined it to the message.
    case promptNotCleared(String)
    /// A draft taller than the box was being cleared, and its first rows never came into view.
    case draftNotRead(String)
    /// You cancelled it while it was held.
    case cancelled(String)
    /// Typing it as the answer to the session's question stopped, and why.
    case notAnswered(String, String)

    public var description: String {
        switch self {
        case .targetGone(let n): return "\(n) is no longer running in herdr"
        case .stillBlocked(let n): return "\(n) kept a dialog open; message not sent"
        case .promptNotCleared(let n): return "\(n)'s prompt already had text that couldn't be cleared"
        case .draftNotRead(let n): return "\(n)'s prompt had text whose start couldn't be read; message not sent"
        case .earlierMessageFailed: return "an earlier message failed partway, so this one was held back"
        case .cancelled(let n): return "cancelled while \(n) showed a dialog"
        case .notAnswered(let n, let why): return "not typed as the answer to \(n)'s question: \(why)"
        }
    }
}

/// What became of text that was already typed in the session's prompt.
public enum DraftEvent: Equatable, Sendable {
    /// It was read off the screen (as far as the box shows it) and taken out of the prompt.
    case cleared(String)
    /// How it went back, or that it didn't (with why).
    case outcome(DraftOutcome, reason: String? = nil)
}

/// Whether and how a cleared draft is typed back into the prompt after the message is sent.
/// (A stashed draft needs none of this: Claude Code puts it back itself.)
public enum DraftRestore {
    /// Why the draft is not typed back, or nil when it is.
    public static func reasonToKeep(_ draft: String, submitted: Bool, typesLineBreaks: Bool) -> String? {
        if !submitted { return "the message was left in the prompt unsent" }
        // Claude Code shows a long paste or a picture as a chip; typing the chip's label isn't the paste.
        if draft.range(of: #"\[(Pasted text|Image) #\d+"#, options: .regularExpression) != nil {
            return "it held a pasted block or a picture, which can't be typed back"
        }
        if draft.contains("\n"), !typesLineBreaks { return "it has several lines, and this terminal can't type a line break" }
        return nil
    }

    /// The draft cut into pieces of at most `size` characters, typed one at a time.
    public static func pieces(_ draft: String, size: Int) -> [String] {
        var out: [String] = []
        var rest = Substring(draft)
        while !rest.isEmpty {
            out.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return out
    }

    /// Whether the prompt shows the draft typed back: all of it, or for a draft taller than the box,
    /// its last rows. Spacing aside: a typed line break that falls where a row would wrap reads back as a space.
    public static func shows(_ shown: String, _ draft: String) -> Bool {
        let shown = shown.filter { !$0.isWhitespace }
        return !shown.isEmpty && draft.filter { !$0.isWhitespace }.hasSuffix(shown)
    }
}

/// How the text in the prompt was taken out of it before pasting.
enum TakenDraft {
    /// Stashed with Ctrl+S: Claude Code puts it back after the next submit.
    case stashed(String)
    /// Cleared: typed back by Showtell. `heldStash`: Claude Code held a stash of yours, which it puts
    /// in the prompt when the message is sent; it is stashed again before the draft is typed back.
    case cleared(String, heldStash: Bool)
}

/// Delivers messages to the pinned session one at a time, in order.
///
/// Rules verified against Claude Code 2.1.296:
/// - every screenshot path is its own bracketed paste, then a pause until its chip appears;
/// - a message sent while Claude works is queued by Claude Code with its images;
/// - nothing is pasted while the agent shows a dialog (herdr status `blocked`): the message is held, and
///   `held` events say so, until you choose (`decide`): send it after, cancel it, or type its words as the
///   answer to the question on screen;
/// - text already in the prompt is taken out first, or it would be sent along with the message: stashed
///   with Ctrl+S, which Claude Code undoes after the submit; or, when Claude Code already holds a stash
///   (it keeps one), cleared, and typed back once the message is sent and the prompt is empty.
public actor Outbox {
    public struct Timing: Sendable {
        public var afterClear: Double = 0.3
        public var clearAttempts = 3
        /// Checks, `afterClear` apart, that the prompt emptied (or the stash came back) after Enter.
        public var emptyChecks = 10
        /// Box-fulls of a tall draft read while clearing it, before giving up on finding its start.
        public var revealLimit = 30
        /// Typed pieces: bigger ones, or ones sent without a pause, are taken for a paste.
        public var typedPiece = 100
        public var afterTypedPiece: Double = 0.05
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
    private var lastTicket = 0
    /// Messages queued up to this ticket are dropped: one before them failed after pasting part of itself.
    private var haltThrough = 0
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
    /// `id` names it in `held` events and to `decide`.
    /// `onDraft` hears about text that was in the prompt: just before it is cleared, then whether it was put back.
    @discardableResult
    public func enqueue(
        _ pieces: [Piece], to target: PinnedTarget, submit: Bool, id: String = UUID().uuidString,
        onDraft: (@Sendable (DraftEvent) -> Void)? = nil
    ) async -> Result<Delivered, Error> {
        let previous = tail
        lastTicket += 1
        let ticket = lastTicket
        let task = Task<Result<Delivered, Error>, Never> {
            await previous?.value
            if ticket <= self.haltThrough { return .failure(DeliveryError.earlierMessageFailed) }
            do {
                return .success(try await self.deliver(pieces, to: target, submit: submit, id: id, onDraft: onDraft))
            } catch {
                if self.pastedSomething { self.haltThrough = self.lastTicket }
                self.emit(.failed(String(describing: error)))
                return .failure(error)
            }
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// What to do with the held message `id`. Ignored once it is no longer held.
    public func decide(_ id: String, _ choice: HoldChoice) {
        guard heldIDs.contains(id) else { return }
        choices[id] = choice
    }

    private func emit(_ event: DeliveryEvent) { onEvent?(event) }
    private var pastedSomething = false
    private var heldIDs: Set<String> = []
    private var choices: [String: HoldChoice] = [:]

    func deliver(
        _ pieces: [Piece], to target: PinnedTarget, submit: Bool, id: String = UUID().uuidString,
        onDraft: (@Sendable (DraftEvent) -> Void)? = nil
    ) async throws -> Delivered {
        guard !pieces.isEmpty else { return Delivered(target: target) }
        pastedSomething = false
        var current: PinnedTarget
        switch try await waitUntilReady(target, holding: id, pieces: pieces) {
        case .ready(let found): current = found
        case .answer(let found): return try await answer(pieces, in: found)
        }
        emit(.sending(current.name))
        let taken = try await takeDraft(current, onDraft: onDraft)

        for piece in pieces {
            switch piece {
            case .text(let s), .copied(let s):
                try await transport.paste(s, pane: current.paneID)
                pastedSomething = true
                await sleep(timing.afterText)
            case .image(let url):
                try await transport.paste(url.path, pane: current.paneID)
                pastedSomething = true
                await sleep(timing.afterImage)
            }
        }
        if submit {
            await sleep(timing.beforeEnter)
            // A dialog may have opened while we pasted; Enter would answer it.
            if case .ready(let found) = try await waitUntilReady(current) { current = found }
            try await transport.pressEnter(pane: current.paneID)
        }
        emit(.delivered(current.name))
        switch taken {
        case nil:
            break
        case .stashed:
            if !submit {
                onDraft?(.outcome(.leftStashed))
            } else if let failed = await stashCameBack(current) {
                onDraft?(.outcome(.notRestored, reason: failed))
            } else {
                onDraft?(.outcome(.restoredFromStash))
            }
        case .cleared(let draft, let heldStash):
            if let reason = DraftRestore.reasonToKeep(
                draft, submitted: submit, typesLineBreaks: transport.typesLineBreaks(pane: current.paneID)) {
                onDraft?(.outcome(.notRestored, reason: reason))
            } else {
                do {
                    let failed = try await typeBack(draft, into: current, heldStash: heldStash)
                    onDraft?(failed.map { .outcome(.notRestored, reason: $0) } ?? .outcome(.retyped))
                } catch {
                    onDraft?(.outcome(.notRestored, reason: "\(error)"))
                }
            }
        }
        return Delivered(target: current)
    }

    /// Takes text out of the prompt, and checks on screen that the prompt is empty: stashes it, or clears
    /// it when Claude Code already holds a stash (a second one would replace it) or Ctrl+S didn't stash.
    /// A screen without an input box (unreadable, or not Claude Code's layout) is left alone.
    private func takeDraft(_ target: PinnedTarget, onDraft: (@Sendable (DraftEvent) -> Void)?) async throws -> TakenDraft? {
        guard var screen = try? await transport.readScreen(pane: target.paneID),
              let draft = PromptInput.parse(screen), !draft.isEmpty else { return nil }
        let heldStash = PromptInput.hasStash(screen)
        if !heldStash {
            try await transport.sendKeys([.stash], pane: target.paneID)
            await sleep(timing.afterClear)
            screen = try await transport.readScreen(pane: target.paneID)
            guard let left = PromptInput.parse(screen) else { throw DeliveryError.promptNotCleared(target.name) }
            if left.isEmpty {
                onDraft?(.cleared(draft))
                return .stashed(draft)
            }
        }
        return .cleared(try await clearRevealing(target, screen, onDraft: onDraft), heldStash: heldStash)
    }

    /// Clears the prompt, reading a draft taller than the box as its hidden rows scroll into view. Returns it.
    ///
    /// Each clearing round takes one row off at the cursor, so the cursor goes to the end of the input
    /// first: Down past the box's height until the box stops changing, then to the end of the row.
    /// Then all rows but the top one are cleared, and the screen read again: rows above the old top one
    /// show if there were any. When only one row is left, the start has been seen.
    private func clearRevealing(
        _ target: PinnedTarget, _ screen: String, onDraft: (@Sendable (DraftEvent) -> Void)?
    ) async throws -> String {
        let pane = target.paneID
        guard var box = PromptInput.read(screen) else { throw DeliveryError.promptNotCleared(target.name) }
        for _ in 0..<timing.revealLimit {
            try await transport.sendKeys(Array(repeating: .down, count: box.rows.count + 1), pane: pane)
            await sleep(timing.afterClear)
            guard let now = PromptInput.read(try await transport.readScreen(pane: pane)) else { break }
            let moved = now != box
            box = now
            if !moved { break }
        }
        try await transport.sendKeys([.end], pane: pane)

        var rows = box.rows
        var sawStart = false
        for _ in 0..<timing.revealLimit {
            if box.rows.count <= 1 {
                sawStart = true
                break
            }
            try await transport.sendClearKeys(pane: pane, rounds: box.rows.count - 1)
            await sleep(timing.afterClear)
            guard let now = PromptInput.read(try await transport.readScreen(pane: pane)), now != box else { break }
            // The last row is the old top row, which the last round's Backspace may have changed.
            if now.rows.count > 1 { rows = now.rows.dropLast() + rows }
            box = now
        }
        var whole = box
        whole.rows = rows
        let draft = whole.text
        onDraft?(.cleared(draft))
        guard sawStart else { throw DeliveryError.draftNotRead(target.name) }

        var lines = box.rows.count
        for _ in 0..<timing.clearAttempts {
            try await transport.sendClearKeys(pane: pane, rounds: lines + 1)
            await sleep(timing.afterClear)
            let now = try await transport.readScreen(pane: pane)
            guard let left = PromptInput.parse(now) else { break }
            if left.isEmpty { return draft }
            lines = PromptInput.lineCount(now)
        }
        throw DeliveryError.promptNotCleared(target.name)
    }

    /// Claude Code puts a stashed draft back when the message is submitted, queued or not.
    /// Returns why it isn't back, or nil when it is.
    private func stashCameBack(_ target: PinnedTarget) async -> String? {
        for _ in 0..<timing.emptyChecks {
            await sleep(timing.afterClear)
            guard let screen = try? await transport.readScreen(pane: target.paneID) else { continue }
            if !PromptInput.hasStash(screen), PromptInput.parse(screen)?.isEmpty == false { return nil }
        }
        return "Claude Code still holds it stashed: press Ctrl+S in an empty prompt to bring it back"
    }

    /// Types a cleared draft back once the sent message has left the prompt, a short piece at a time,
    /// and reads it back. Returns why it isn't back, or nil when the prompt shows it.
    private func typeBack(_ draft: String, into target: PinnedTarget, heldStash: Bool) async throws -> String? {
        var emptied = false
        var restashed = false
        for _ in 0..<timing.emptyChecks {
            await sleep(timing.afterClear)
            let screen = try await transport.readScreen(pane: target.paneID)
            guard let shown = PromptInput.parse(screen) else { continue }
            if shown.isEmpty {
                emptied = true
                break
            }
            // Sending put the stash you held in the prompt (the stash sign is gone): stash it again, once,
            // as a second Ctrl+S on the emptied prompt would bring it back out.
            if heldStash, !restashed, !PromptInput.hasStash(screen) {
                try await transport.sendKeys([.stash], pane: target.paneID)
                restashed = true
            }
        }
        guard emptied else { return "the prompt didn't empty after the message was sent" }
        var typed = false
        for piece in DraftRestore.pieces(draft, size: timing.typedPiece) {
            // Typed into a dialog, letters and digits would answer it.
            let agents = try await transport.listAgents()
            let screen = try await transport.readScreen(pane: target.paneID)
            guard target.locate(in: agents)?.status.acceptsInput == true, PromptInput.parse(screen) != nil else {
                return typed ? "a dialog opened while it was typed back; part of it is in the prompt"
                    : "the session showed a dialog"
            }
            try await transport.typeText(piece, pane: target.paneID)
            typed = true
            await sleep(timing.afterTypedPiece)
        }
        await sleep(timing.afterClear)
        guard let shown = PromptInput.parse(try await transport.readScreen(pane: target.paneID)),
              DraftRestore.shows(shown, draft) else { return "the prompt didn't show it after it was typed back" }
        return nil
    }

    private enum Ready {
        case ready(PinnedTarget)
        /// You chose to type the message as the answer to the question on screen.
        case answer(PinnedTarget)
    }

    /// Waits while the session shows a dialog. With `id` the message is held: `held` events say what the
    /// dialog is and what can be done, and your choice is taken; left undecided, it gives up after
    /// `blockedTimeout`. Without (a dialog that opened after pasting), it waits as long as that.
    private func waitUntilReady(_ target: PinnedTarget, holding id: String? = nil, pieces: [Piece] = []) async throws -> Ready {
        var waited = 0.0
        var hold: Hold?
        defer {
            if let id, hold != nil {
                heldIDs.remove(id)
                choices[id] = nil
                emit(.released(id))
            }
        }
        while true {
            let agents = try await transport.listAgents()
            guard let agent = target.locate(in: agents) else { throw DeliveryError.targetGone(target.name) }
            var updated = target
            updated.paneID = agent.paneID
            updated.terminalID = agent.terminalID
            if agent.status.acceptsInput { return .ready(updated) }
            guard let id else {
                if waited == 0 { emit(.waitingForApproval(target.name)) }
                if waited >= timing.blockedTimeout { throw DeliveryError.stillBlocked(target.name) }
                await sleep(timing.blockedPoll)
                waited += timing.blockedPoll
                continue
            }

            let dialog = (try? await transport.readScreen(pane: updated.paneID)).flatMap(Dialog.read)
            var sendAfter = hold?.sendAfter ?? false
            switch choices.removeValue(forKey: id) {
            case .cancel?: throw DeliveryError.cancelled(target.name)
            // Only for the question it was offered for: never into a permission prompt or another dialog.
            case .answer? where dialog?.canAnswer == true && Self.answerText(pieces) != nil: return .answer(updated)
            case .sendAfter?: sendAfter = true
            default: break
            }
            // A screen caught mid-redraw keeps what it was.
            let now = Hold(messageID: id, name: target.name, kind: dialog?.kind ?? hold?.kind ?? .other,
                           canAnswer: dialog?.canAnswer == true && Self.answerText(pieces) != nil,
                           hasPictures: pieces.contains { if case .image = $0 { return true } else { return false } },
                           sendAfter: sendAfter)
            if now != hold {
                hold = now
                heldIDs.insert(id)
                emit(.held(now))
            }
            if !sendAfter, waited >= timing.blockedTimeout { throw DeliveryError.stillBlocked(target.name) }
            await sleep(timing.blockedPoll)
            waited += timing.blockedPoll
        }
    }

    // MARK: Answering a question

    /// The message's words, as one line to type in a question's free-text option; pictures left out.
    /// Nil when it has no words.
    static func answerText(_ pieces: [Piece]) -> String? {
        let words = pieces.compactMap { piece -> String? in
            switch piece {
            case .text(let s), .copied(let s): return s
            case .image: return nil
            }
        }
        let line = words.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    private func readDialog(_ pane: String) async throws -> Dialog? {
        Dialog.read(try await transport.readScreen(pane: pane))
    }

    /// Types the message's words in the question's free-text option and sends them, checking the screen
    /// at each step. The focus moves with arrows (a number key on another option would pick it), and
    /// nothing is pressed unless the screen shows that question with the focus where it should be.
    /// With several questions only the one on screen is answered; the rest stay for you.
    private func answer(_ pieces: [Piece], in target: PinnedTarget) async throws -> Delivered {
        let pane = target.paneID
        func stop(_ why: String) -> DeliveryError { .notAnswered(target.name, why) }
        guard let text = Self.answerText(pieces) else { throw stop("the message has no words") }
        emit(.sending(target.name))
        guard let asked = try await readDialog(pane), let free = asked.freeText, let at = asked.focused else {
            throw stop("its question has no place to type an answer")
        }
        func sameQuestion(_ d: Dialog?) -> Bool { d?.kind == .question && d?.question == asked.question && d?.tabs == asked.tabs }

        let steps = free.number - at.number
        if steps != 0 {
            try await transport.sendKeys(Array(repeating: steps > 0 ? .down : .up, count: abs(steps)), pane: pane)
            await sleep(timing.afterClear)
        }
        var typed = false
        for piece in DraftRestore.pieces(text, size: timing.typedPiece) {
            // Typed anywhere but the free-text option, letters and digits would pick options.
            let now = try await readDialog(pane)
            guard sameQuestion(now), now?.focused?.number == free.number else {
                throw stop(typed ? "the question changed while it was typed; part of it is in the dialog"
                    : "couldn't move to its “\(free.label)” option")
            }
            try await transport.typeText(piece, pane: pane)
            typed = true
            await sleep(timing.afterTypedPiece)
        }
        await sleep(timing.afterClear)
        guard Dialog.shows(text, on: try await transport.readScreen(pane: pane)) else {
            throw stop("typed, but the question doesn't show it: check it there before pressing Enter")
        }
        if asked.multiSelect {
            // Enter would untick the answer; the row under it (Next or Submit) moves on.
            try await transport.sendKeys([.down], pane: pane)
            await sleep(timing.afterClear)
            guard let row = try await readDialog(pane)?.focusedRow, Dialog.actionRows.contains(row) else {
                throw stop("typed, but its Next button wasn't found: press it there yourself")
            }
        }
        try await transport.pressEnter(pane: pane)

        for _ in 0..<timing.emptyChecks {
            await sleep(timing.afterClear)
            let now = try await readDialog(pane)
            if now == nil || !sameQuestion(now) {
                emit(.delivered(target.name))
                return Delivered(target: target, answered: AnsweredQuestion(
                    question: asked.question,
                    picturesLeftOut: pieces.contains { if case .image = $0 { return true } else { return false } },
                    moreLeft: now != nil))
            }
        }
        throw stop("the question stayed open after Enter")
    }
}
