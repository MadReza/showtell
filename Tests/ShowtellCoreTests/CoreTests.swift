import Foundation
import Testing
@testable import ShowtellCore

@Suite struct MessageTests {
    let shots = [1: URL(fileURLWithPath: "/s/1.png"), 2: URL(fileURLWithPath: "/s/2.png")]

    @Test func splitsTextAndImagesInOrder() {
        let pieces = ShotMarker.pieces(from: "the header [📷 1] is cut off, see [📷 2]", shots: shots)
        #expect(pieces == [
            .text("the header "), .image(shots[1]!), .text(" is cut off, see "), .image(shots[2]!),
        ])
    }

    @Test func dropsMarkersWithoutFilesAndMergesText() {
        let pieces = ShotMarker.pieces(from: "a [📷 9] b", shots: shots)
        #expect(pieces == [.text("a b")])
    }

    @Test func imageOnly() {
        #expect(ShotMarker.pieces(from: "  [📷 2]  ", shots: shots) == [.image(shots[2]!)])
    }

    @Test func copiedTextKeepsItsWhitespace() {
        let code = "if  x {\n    run()\n}"
        let pieces = ShotMarker.pieces(from: "use [📋 1] here   [📷 1] [📋 7]", shots: shots, clips: [1: code])
        #expect(pieces == [.text("use "), .copied(code), .text(" here "), .image(shots[1]!)])
    }
}

@Suite struct ClipboardTests {
    @Test func textWinsOverAnImageOfIt() {
        #expect(ClipboardChange.classify(types: ["public.utf8-plain-text", "public.tiff"], string: "A1 B1") == .text("A1 B1"))
        #expect(ClipboardChange.classify(types: ["public.png"], string: nil) == .screenshot)
        #expect(ClipboardChange.classify(types: ["public.utf8-plain-text"], string: "  \n") == .ignore)
    }

    @Test func ownWritesAndPasswordsAreIgnored() {
        #expect(ClipboardChange.classify(types: ["public.utf8-plain-text", ClipboardChange.ownType], string: "sent") == .ignore)
        #expect(ClipboardChange.classify(types: ["public.png", ClipboardChange.ownType], string: nil) == .ignore)
        #expect(ClipboardChange.classify(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], string: "hunter2") == .ignore)
    }
}

@Suite struct ComposerTests {
    @Test func placesCopiedTextByWordTiming() {
        var c = Composer()
        c.updateTranscript("run", newWordStartTimes: [0.0])
        c.addClip("npm test -- --watch", at: 1.2)  // recogniser lags: only "run" known
        c.updateTranscript("run this command and see", newWordStartTimes: [0.6, 0.95, 1.3, 1.7])
        #expect(c.render() == "run this command [📋 1] and see")
        #expect(c.pieces() == [.text("run this command "), .copied("npm test -- --watch"), .text(" and see")])
    }

    @Test func copiedTextGoesOneLagLaterWithoutTimings() {
        var c = Composer(lag: 2)
        c.updateTranscript("the", at: 1)
        c.addClip("<button>", at: 1.5)
        c.updateTranscript("the save button", at: 3.6)
        c.updateTranscript("the save button does nothing", at: 5)
        #expect(c.render() == "the save button [📋 1] does nothing")
    }

    @Test func screenshotsAndCopiesAreNumberedApart() {
        var c = Composer()
        c.updateTranscript("look", newWordStartTimes: [0.0])
        c.addShot(URL(fileURLWithPath: "/a.png"), at: 0.5)
        c.addClip("Error: 404", at: 1.5)
        #expect(c.nextShotNumber == 2)
        c.updateTranscript("look here then this error", newWordStartTimes: [0.6, 1.0, 1.2, 1.8])
        c.finish(at: 2)
        #expect(c.render() == "look [📷 1] here then this [📋 1] error")
        #expect(c.pieces() == [
            .text("look "), .image(URL(fileURLWithPath: "/a.png")), .text(" here then this "), .copied("Error: 404"), .text(" error"),
        ])
    }

    @Test func placesShotByWordTiming() {
        var c = Composer()
        c.updateTranscript("this", newWordStartTimes: [0.0])
        c.addShot(URL(fileURLWithPath: "/a.png"), at: 1.2)  // recogniser lags: only "this" known
        c.updateTranscript("this button is cut off", newWordStartTimes: [0.6, 0.95, 1.3, 1.7])
        #expect(c.render() == "this button is [📷 1] cut off")
    }

    @Test func timingsOverruleTheLagGuess() {
        // A pause after the shot lets the recogniser catch up, so one lag later the transcript
        // already holds words spoken after the shot. The word timings put it back in place.
        var c = Composer(lag: 2)
        c.updateTranscript("now the second one", newWordStartTimes: [0.0, 0.3, 0.5, 0.9], at: 1.5)
        c.addShot(URL(fileURLWithPath: "/a.png"), at: 3.0)
        c.updateTranscript("now the second one should land after", at: 5.2)
        #expect(c.render() == "now the second one should land after [📷 1]")  // guess, not yet timed
        c.updateTranscript("now the second one should land after the word", newWordStartTimes: [4.0, 4.3, 4.6], at: 5.6)
        #expect(c.render() == "now the second one [📷 1] should land after the word")
    }

    @Test func placesShotOneLagLaterWithoutTimings() {
        var c = Composer(lag: 2)
        c.updateTranscript("the", at: 1)
        c.addShot(URL(fileURLWithPath: "/a.png"), at: 1.5)  // said "the login button" by now
        c.updateTranscript("the login", at: 2.5)
        c.updateTranscript("the login button", at: 3.6)  // first update ≥ 1.5 + 2
        c.updateTranscript("the login button is cut off", at: 5)
        #expect(c.render() == "the login button [📷 1] is cut off")
    }

    @Test func shotNearTheEndGoesLastAfterFinish() {
        var c = Composer(lag: 2)
        c.updateTranscript("look at", at: 4)
        c.addShot(URL(fileURLWithPath: "/a.png"), at: 4.5)
        c.updateTranscript("look at this", at: 5)
        c.finish(at: 5)
        #expect(c.render() == "look at this [📷 1]")
    }

    @Test func editSurvivesRecogniserMergingEarlierWords() {
        var c = Composer()
        c.updateTranscript("see you to day at the")
        c.userEdited("See you today at the")
        c.updateTranscript("see you today at the office")  // "to day" merged: one word fewer
        #expect(c.render() == "See you today at the office")
    }

    @Test func editSurvivesRecogniserSplittingEarlierWords() {
        var c = Composer()
        c.updateTranscript("open showtell now")
        c.userEdited("Open Showtell now")
        c.updateTranscript("open show tell now please")
        #expect(c.render() == "Open Showtell now please")
    }

    @Test func shotNeverPlacedBeforeWordsAlreadyShown() {
        var c = Composer()
        c.updateTranscript("one two three")  // no timings at all
        c.addShot(URL(fileURLWithPath: "/a.png"), at: 5)
        c.updateTranscript("one two three four")
        #expect(c.render() == "one two three [📷 1] four")
    }

    @Test func editsFreezeAndSpeechContinues() {
        var c = Composer()
        c.updateTranscript("the bottom is broken")
        c.addShot(URL(fileURLWithPath: "/a.png"), at: 9)
        #expect(c.render() == "the bottom is broken [📷 1]")
        c.userEdited("the button is broken [📷 1]")
        c.updateTranscript("the bottom is broken on mobile")
        #expect(c.render() == "the button is broken [📷 1] on mobile")
        c.addShot(URL(fileURLWithPath: "/b.png"), at: 12)
        c.updateTranscript("the bottom is broken on mobile too")
        #expect(c.render() == "the button is broken [📷 1] on mobile [📷 2] too")
        #expect(c.pieces().count == 5)  // text, image, text, image, text
    }
}

@Suite struct TerminalSessionTests {
    @Test func claudeStatusesMap() {
        #expect(TerminalSessions.status("idle") == .idle)
        #expect(TerminalSessions.status("busy") == .working)
        #expect(TerminalSessions.status("waiting") == .blocked)  // a dialog is open: don't paste
        #expect(TerminalSessions.status(nil) == .unknown)
    }

    @Test func herdrWinsWhenASessionIsSeenTwice() {
        let inHerdr = HerdrAgent(paneID: "w1:p1", terminalID: "t1", status: .idle, sessionID: "s1")
        let sameInTmux = HerdrAgent(paneID: "tmux:%1", terminalID: "tty:/dev/ttys001", status: .idle, sessionID: "s1")
        let onlyInITerm = HerdrAgent(paneID: "iterm:ABC", terminalID: "tty:/dev/ttys002", status: .idle, sessionID: "s2")
        #expect(AllSessions.merge([inHerdr], [sameInTmux, onlyInITerm]).map(\.paneID) == ["w1:p1", "iterm:ABC"])
    }

    @Test func ttyListsParse() {
        #expect(TerminalSessions.pairs("/dev/ttys003 %1\n/dev/ttys004 %2\n") == ["/dev/ttys003": "%1", "/dev/ttys004": "%2"])
        #expect(TerminalSessions.handles(pane: "tmux:%1") && TerminalSessions.handles(pane: "iterm:X"))
        #expect(!TerminalSessions.handles(pane: "w1:p1"))
    }
}

@Suite struct HerdrNameTests {
    let names = try! JSONDecoder().decode(HerdrNames.self, from: Data(#"""
    {"workspaces": [
      {"workspace_id": "w1", "label": "firstmate", "tab_count": 1},
      {"workspace_id": "w2", "label": "└ crm8965-prod-mobile-uat · p:nqZpWUZx6-e1sheDjYCrbQ", "tab_count": 1},
      {"workspace_id": "w3", "label": "guild", "tab_count": 2},
      {"workspace_id": "w4", "label": "", "tab_count": 1}],
     "tabs": [
      {"tab_id": "w1:t1", "number": 1, "label": "1"},
      {"tab_id": "w2:t2", "number": 2, "label": "fm-crm8965-prod-mobile-uat"},
      {"tab_id": "w3:t1", "number": 1, "label": "1"},
      {"tab_id": "w3:t2", "number": 2, "label": "showtell"},
      {"tab_id": "w4:t1", "number": 1, "label": "1"}]}
    """#.utf8))

    func agent(_ ws: String, _ tab: String, title: String? = "Some task") throws -> HerdrAgent {
        let titleJSON = title.map { "\"\($0)\"" } ?? "null"
        let json = #"{"pane_id": "\#(ws):p1", "terminal_id": "t", "workspace_id": "\#(ws)", "tab_id": "\#(tab)", "#
            + #""agent_status": "idle", "cwd": "/src/firstmate", "terminal_title_stripped": \#(titleJSON)}"#
        return names.named([try JSONDecoder().decode(HerdrAgent.self, from: Data(json.utf8))])[0]
    }

    @Test func menusShowTheSidebarNames() throws {
        #expect(try agent("w1", "w1:t1").displayName == "firstmate")
        #expect(try agent("w2", "w2:t2").displayName == "crm8965-prod-mobile-uat")
        #expect(try agent("w3", "w3:t1").displayName == "guild")  // an unnamed tab adds nothing
        #expect(try agent("w3", "w3:t2").displayName == "guild · showtell")
    }

    @Test func fallsBackToTitleThenFolder() throws {
        #expect(try agent("w4", "w4:t1").displayName == "Some task")
        #expect(try agent("w9", "w9:t1", title: nil).displayName == "firstmate")
    }
}

@Suite struct SettingsTests {
    @Test func shortcutLabels() {
        #expect(Shortcut.tap("leftOption").label == "Left ⌥ tap")
        #expect(Shortcut.chord(49, 0x1000 | 0x800, "Space").label == "⌃⌥Space")
        #expect(Shortcut.chord(40, 0x100 | 0x200, "K").label == "⇧⌘K")
    }

    @Test func oldSettingsFilesCarryOver() throws {
        let tap = #"{"hotKeyCode":49,"hotKeyModifiers":6144,"tapKey":"leftOption","submitOnSecondPress":false}"#
        let a = try JSONDecoder().decode(Settings.self, from: Data(tap.utf8))
        #expect(a.startShortcut == .tap("leftOption"))
        #expect(a.submitOnSecondPress == false)
        let chord = #"{"hotKeyCode":49,"hotKeyModifiers":6144,"tapKey":"off"}"#
        #expect(try JSONDecoder().decode(Settings.self, from: Data(chord.utf8)).startShortcut == .chord(49, 6144, "Space"))
    }

    @Test func roundTrip() throws {
        var s = Settings()
        s.startShortcut = .chord(40, 0x100, "K")
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

@Suite struct VocabularyTests {
    @Test func dictationFile() {
        let md = """
        # Terms
        Some paragraph with `useAuth.ts` inside.
        - Voxtral — the speech model
        - **Claude Code**: the agent
        - `herdr`
        1. Showtell - our app
        ```
        - not a term
        ```
        """
        #expect(Vocabulary.dictationFileTerms(md).map(\.text) == ["useAuth.ts", "Voxtral", "Claude Code", "herdr", "Showtell"])
    }

    @Test func simpleListRoundTrip() {
        let terms = Vocabulary.simpleListTerms("# c\nherdr: herder, her dr\nShowtell\nherdr: hurdle\n")
        #expect(terms.count == 3)
        #expect(Vocabulary.simpleListText(terms) == "herdr: herder, her dr, hurdle\nShowtell\n")
    }

    @Test func replacementsWholeWordsAnyCase() {
        let rules = Vocabulary.replacements("clawed code => Claude Code\nlay vish => Lavish\nbad line")
        #expect(Vocabulary.applyReplacements("Clawed code and lay vish, not clawed coder", rules)
            == "Claude Code and Lavish, not clawed coder")
    }
}

/// Records calls instead of talking to herdr.
final class FakeHerdr: HerdrTransport, @unchecked Sendable {
    var statuses: [AgentStatus]
    var paneID = "w1:p2"
    var calls: [String] = []
    let lock = NSLock()

    init(statuses: [AgentStatus]) { self.statuses = statuses }

    func listAgents() async throws -> [HerdrAgent] {
        lock.lock(); defer { lock.unlock() }
        let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        return [HerdrAgent(paneID: paneID, terminalID: "t1", status: status, sessionID: "S1", title: "showtell")]
    }
    var failOnPaste: String?
    func paste(_ text: String, pane: String) async throws {
        if let f = failOnPaste, text == f { throw HerdrError(code: "test", message: "boom") }
        record("paste \(pane) \(text)")
    }
    func pressEnter(pane: String) async throws { record("enter \(pane)") }
    /// Screens returned by successive reads; the last one repeats.
    var screens: [String] = [""]
    /// When set, the screen follows from the calls so far instead (for screens read an unknown number of times).
    var screenFor: (([String]) -> String)?
    func readScreen(pane: String) async throws -> String {
        lock.withLock {
            if let screenFor { return screenFor(calls) }
            return screens.count > 1 ? screens.removeFirst() : screens[0]
        }
    }
    func sendClearKeys(pane: String, rounds: Int) async throws { record("clear \(pane) \(rounds)") }
    func sendKeys(_ keys: [PromptKey], pane: String) async throws {
        record("keys \(pane) \(keys.map(\.rawValue).joined(separator: " "))")
    }
    func typeText(_ text: String, pane: String) async throws { record("type \(pane) \(text)") }
    var lineBreaks = true
    func typesLineBreaks(pane: String) -> Bool { lineBreaks }
    private func record(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }
}

@Suite struct OutboxTests {
    let target = PinnedTarget(agent: HerdrAgent(paneID: "w1:p1", terminalID: "t1", status: .idle, sessionID: "S1", title: "showtell"))

    @Test func deliversPiecesInOrderToMovedPane() async {
        let fake = FakeHerdr(statuses: [.working])
        let outbox = Outbox(transport: fake, sleep: { _ in })
        let result = await outbox.enqueue(
            [.text("look "), .image(URL(fileURLWithPath: "/s/1.png")), .text(" here")], to: target, submit: true)
        #expect(fake.calls == ["paste w1:p2 look ", "paste w1:p2 /s/1.png", "paste w1:p2  here", "enter w1:p2"])
        #expect((try? result.get())?.target.paneID == "w1:p2")
    }

    @Test func waitsWhileBlocked() async {
        let fake = FakeHerdr(statuses: [.blocked, .blocked, .idle])
        let events = EventLog()
        let outbox = Outbox(transport: fake, sleep: { _ in })
        await outbox.setEventHandler { events.add($0) }
        await outbox.enqueue([.text("hi")], to: target, submit: false, id: "m1")
        #expect(fake.calls == ["paste w1:p2 hi"])
        #expect(events.all.prefix(2) == [
            .held(Hold(messageID: "m1", name: "showtell", kind: .other, canAnswer: false, hasPictures: false, sendAfter: false)),
            .released("m1"),
        ])
    }

    /// An outbox that makes `choice` for each message as soon as it is held.
    func choosing(_ choice: HoldChoice, _ fake: FakeHerdr, timing: Outbox.Timing = Outbox.Timing(),
                  events: EventLog = EventLog()) async -> Outbox {
        // A real millisecond per poll, so the choice is made before the timeout.
        let outbox = Outbox(transport: fake, timing: timing, sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
        await outbox.setEventHandler { event in
            events.add(event)
            if case .held(let hold) = event, !hold.sendAfter { Task { await outbox.decide(hold.messageID, choice) } }
        }
        return outbox
    }

    @Test func heldMessageCanBeCancelled() async {
        let fake = FakeHerdr(statuses: [.blocked])
        fake.screens = [DialogScreens.load("q-single")]
        let events = EventLog()
        let result = await choosing(.cancel, fake, events: events)
            .enqueue([.text("hello")], to: target, submit: true, id: "m1")
        if case .failure(let e) = result { #expect(e as? DeliveryError == .cancelled("showtell")) } else {
            Issue.record("expected failure")
        }
        #expect(fake.calls.isEmpty)
        #expect(events.all.first == .held(Hold(messageID: "m1", name: "showtell", kind: .question, canAnswer: true,
                                                hasPictures: false, sendAfter: false)))
        #expect(events.all.contains(.released("m1")))
    }

    @Test func answersAQuestionInItsFreeTextOption() async {
        let fake = FakeHerdr(statuses: [.blocked])
        fake.screenFor = { calls in
            if calls.contains(where: { $0.hasPrefix("enter") }) { return PromptScreens.empty }
            if calls.contains(where: { $0.hasPrefix("type") }) { return DialogScreens.load("q-typed") }
            if calls.contains("keys w1:p2 down down") { return DialogScreens.load("q-typing") }
            return DialogScreens.load("q-single")
        }
        let shot = URL(fileURLWithPath: "/s/1.png")
        let result = await choosing(.answer, fake)
            .enqueue([.text("Mango,"), .image(shot), .text("\nripe")], to: target, submit: true)
        // Arrows to the free-text option (a number key on another would pick it), the words, Enter.
        #expect(fake.calls == ["keys w1:p2 down down", "type w1:p2 Mango, ripe", "enter w1:p2"])
        #expect((try? result.get())?.answered
            == AnsweredQuestion(question: "Which fruit do you like?", picturesLeftOut: true, moreLeft: false))
    }

    @Test func multiSelectAnswerMovesOnWithNextAndLeavesTheRest() async {
        let fake = FakeHerdr(statuses: [.blocked])
        let typed = DialogScreens.load("q-multi-typed")
        // Down from the answer: the focus on the Next row.
        let onNext = typed.replacingOccurrences(of: "\u{1b}[38;2;177;185;249m❯ \u{1b}[0m\u{1b}[38;2;153;153;153m4.",
                                                with: "  \u{1b}[0m\u{1b}[38;2;153;153;153m4.")
            .replacingOccurrences(of: "     \u{1b}[0m\u{1b}[1mNext", with: "❯    \u{1b}[0m\u{1b}[1mNext")
        fake.screenFor = { calls in
            if calls.contains(where: { $0.hasPrefix("enter") }) { return DialogScreens.load("q-tabs-second") }
            if calls.last == "keys w1:p2 down" { return onNext }
            if calls.contains(where: { $0.hasPrefix("type") }) { return typed }
            if calls.contains("keys w1:p2 down down down") { return typed }
            return DialogScreens.load("q-multi")
        }
        let result = await choosing(.answer, fake).enqueue([.text("Purple")], to: target, submit: true)
        #expect(fake.calls == ["keys w1:p2 down down down", "type w1:p2 Purple", "keys w1:p2 down", "enter w1:p2"])
        #expect((try? result.get())?.answered
            == AnsweredQuestion(question: "Which colours?", picturesLeftOut: false, moreLeft: true))
    }

    @Test func nothingIsPressedInAPermissionPrompt() async {
        let fake = FakeHerdr(statuses: Array(repeating: .blocked, count: 6) + [.idle])
        fake.screenFor = { calls in calls.isEmpty ? DialogScreens.load("perm") : PromptScreens.empty }
        let events = EventLog()
        let result = await choosing(.answer, fake, events: events).enqueue([.text("hello")], to: target, submit: false)
        // The choice is ignored; the message goes into the prompt once the prompt is gone.
        #expect(fake.calls == ["paste w1:p2 hello"])
        #expect((try? result.get())?.answered == nil)
        guard case .held(let hold)? = events.all.first else { Issue.record("not held"); return }
        #expect(hold.kind == .permission && !hold.canAnswer)
    }

    @Test func picturesAloneCantAnswer() async {
        let fake = FakeHerdr(statuses: Array(repeating: .blocked, count: 4) + [.idle])
        fake.screens = [DialogScreens.load("q-single")]
        let events = EventLog()
        await choosing(.answer, fake, events: events)
            .enqueue([.image(URL(fileURLWithPath: "/s/1.png"))], to: target, submit: false)
        #expect(fake.calls == ["paste w1:p2 /s/1.png"])
        guard case .held(let hold)? = events.all.first else { Issue.record("not held"); return }
        #expect(hold.kind == .question && !hold.canAnswer && hold.hasPictures)
    }

    @Test func sendAfterWaitsPastTheTimeout() async {
        var timing = Outbox.Timing()
        timing.blockedTimeout = 1
        let fake = FakeHerdr(statuses: Array(repeating: .blocked, count: 10) + [.idle])
        let result = await choosing(.sendAfter, fake, timing: timing).enqueue([.text("later")], to: target, submit: false)
        #expect(fake.calls == ["paste w1:p2 later"])
        #expect((try? result.get()) != nil)

        let undecided = FakeHerdr(statuses: Array(repeating: .blocked, count: 10) + [.idle])
        let gaveUp = await Outbox(transport: undecided, timing: timing, sleep: { _ in })
            .enqueue([.text("later")], to: target, submit: false)
        if case .failure(let e) = gaveUp { #expect(e as? DeliveryError == .stillBlocked("showtell")) } else {
            Issue.record("expected failure")
        }
    }

    @Test func messagesStayInOrder() async {
        let fake = FakeHerdr(statuses: [.idle])
        let outbox = Outbox(transport: fake, sleep: { _ in await Task.yield() })
        async let a: Void = { _ = await outbox.enqueue([.text("one")], to: target, submit: true) }()
        async let b: Void = { _ = await outbox.enqueue([.text("two")], to: target, submit: true) }()
        _ = await (a, b)
        let pastes = fake.calls.filter { $0.hasPrefix("paste") }
        #expect(Set(pastes) == ["paste w1:p2 one", "paste w1:p2 two"])
        #expect(fake.calls.count == 4)
        #expect(fake.calls[1] == "enter w1:p2" && fake.calls[3] == "enter w1:p2")
    }

    @Test func messagesQueuedBehindAPartialFailureAreHeldBack() async {
        let fake = FakeHerdr(statuses: [.idle])
        fake.failOnPaste = "second half"
        // Each pause takes 20 ms, so "next message" is queued while the first is still pasting.
        let outbox = Outbox(transport: fake, sleep: { _ in try? await Task.sleep(nanoseconds: 20_000_000) })
        async let a = outbox.enqueue([.text("first half"), .text("second half")], to: target, submit: true)
        try? await Task.sleep(nanoseconds: 5_000_000)
        async let b = outbox.enqueue([.text("next message")], to: target, submit: true)
        let (ra, rb) = await (a, b)
        if case .success = ra { Issue.record("first should fail") }
        if case .failure(let e) = rb { #expect(e as? DeliveryError == .earlierMessageFailed) } else {
            Issue.record("second should be held back")
        }
        let later = await outbox.enqueue([.text("later")], to: target, submit: false)
        if case .failure = later { Issue.record("new messages go through again") }
        #expect(fake.calls == ["paste w1:p2 first half", "paste w1:p2 later"])
    }

    @Test func stashesTextLeftInThePromptAndSeesItComeBack() async {
        let fake = FakeHerdr(statuses: [.idle])
        fake.screens = [PromptScreens.typed, PromptScreens.emptyStashed, PromptScreens.typed]
        let drafts = DraftLog()
        let result = await Outbox(transport: fake, sleep: { _ in })
            .enqueue([.text("hello")], to: target, submit: true, onDraft: { drafts.add($0) })
        #expect((try? result.get()) != nil)
        #expect(fake.calls == ["keys w1:p2 ctrl+s", "paste w1:p2 hello", "enter w1:p2"])
        #expect(drafts.all == [.cleared("fgd g junk"), .outcome(.restoredFromStash)])
    }

    @Test func unsentMessageLeavesTheDraftStashed() async {
        let fake = FakeHerdr(statuses: [.idle])
        fake.screens = [PromptScreens.typed, PromptScreens.emptyStashed]
        let drafts = DraftLog()
        await Outbox(transport: fake, sleep: { _ in })
            .enqueue([.text("hello")], to: target, submit: false, onDraft: { drafts.add($0) })
        #expect(fake.calls == ["keys w1:p2 ctrl+s", "paste w1:p2 hello"])
        #expect(drafts.all == [.cleared("fgd g junk"), .outcome(.leftStashed)])
    }

    @Test func stashThatStaysStashedIsReported() async {
        let fake = FakeHerdr(statuses: [.idle])
        fake.screens = [PromptScreens.typed, PromptScreens.emptyStashed]
        let drafts = DraftLog()
        await Outbox(transport: fake, sleep: { _ in })
            .enqueue([.text("hello")], to: target, submit: true, onDraft: { drafts.add($0) })
        guard case .outcome(.notRestored, let reason) = drafts.all.last else { Issue.record("\(drafts.all)"); return }
        #expect(reason?.contains("Ctrl+S") == true)
    }

    /// Your own stash is never replaced: the draft is cleared, your stash (which sending puts in the
    /// prompt) stashed again, and the draft typed back.
    @Test func heldStashIsKeptAndTheDraftTypedBack() async {
        let fake = FakeHerdr(statuses: [.idle])
        fake.screens = [
            PromptScreens.typedStashed, PromptScreens.typedStashed,  // read, then after Down: at the end already
            PromptScreens.emptyStashed,  // cleared
            PromptScreens.olderStashInPrompt, PromptScreens.emptyStashed,  // sent: your stash came out; stashed again
            PromptScreens.emptyStashed,  // before typing
            PromptScreens.typedStashed,  // typed back
        ]
        let drafts = DraftLog()
        await Outbox(transport: fake, sleep: { _ in })
            .enqueue([.text("hello")], to: target, submit: true, onDraft: { drafts.add($0) })
        #expect(fake.calls == [
            "keys w1:p2 down down", "keys w1:p2 ctrl+e", "clear w1:p2 2", "paste w1:p2 hello", "enter w1:p2",
            "keys w1:p2 ctrl+s", "type w1:p2 fgd g junk",
        ])
        #expect(drafts.all == [.cleared("fgd g junk"), .outcome(.retyped)])
    }

    @Test func tallDraftIsReadWhileItIsCleared() async {
        let fake = FakeHerdr(statuses: [.idle])
        fake.screens = [
            PromptScreens.window(["four", "five", "six"]), PromptScreens.window(["four", "five", "six"]),
            PromptScreens.window(["two", "three", "fou"]),  // Backspace took the old top row's last letter
            PromptScreens.window(["one", "tw"]),
            PromptScreens.window(["on"]),
            PromptScreens.emptyStashed,
        ]
        let drafts = DraftLog()
        await Outbox(transport: fake, sleep: { _ in })
            .enqueue([.text("hello")], to: target, submit: false, onDraft: { drafts.add($0) })
        #expect(fake.calls == [
            "keys w1:p2 down down down down", "keys w1:p2 ctrl+e",
            "clear w1:p2 2", "clear w1:p2 2", "clear w1:p2 1", "clear w1:p2 2", "paste w1:p2 hello",
        ])
        #expect(drafts.all == [
            .cleared("one\ntwo\nthree\nfour\nfive\nsix"),
            .outcome(.notRestored, reason: "the message was left in the prompt unsent"),
        ])
    }

    @Test func draftWhoseStartNeverShowsIsNotPastedOver() async {
        let fake = FakeHerdr(statuses: [.idle])
        fake.screens = [PromptScreens.window(["four", "five", "six"])]
        let drafts = DraftLog()
        let result = await Outbox(transport: fake, sleep: { _ in })
            .enqueue([.text("hello")], to: target, submit: true, onDraft: { drafts.add($0) })
        if case .failure(let e) = result { #expect(e as? DeliveryError == .draftNotRead("showtell")) } else {
            Issue.record("expected failure")
        }
        #expect(fake.calls == ["keys w1:p2 down down down down", "keys w1:p2 ctrl+e", "clear w1:p2 2"])
        #expect(drafts.all == [.cleared("four\nfive\nsix")])
    }

    @Test func draftIsNotTypedIntoADialog() async {
        // agent.list: before pasting, before Enter, then before typing back: a dialog.
        let fake = FakeHerdr(statuses: [.idle, .idle, .blocked])
        fake.screens = [PromptScreens.typed, PromptScreens.typed, PromptScreens.typed, PromptScreens.empty]
        let drafts = DraftLog()
        await Outbox(transport: fake, sleep: { _ in })
            .enqueue([.text("hello")], to: target, submit: true, onDraft: { drafts.add($0) })
        #expect(!fake.calls.contains { $0.hasPrefix("type") })
        #expect(drafts.all.last == .outcome(.notRestored, reason: "the session showed a dialog"))
    }

    @Test func emptyPromptIsNotTouched() async {
        let fake = FakeHerdr(statuses: [.idle])
        fake.screens = [PromptScreens.empty]
        await Outbox(transport: fake, sleep: { _ in }).enqueue([.text("hello")], to: target, submit: false)
        #expect(fake.calls == ["paste w1:p2 hello"])
    }

    @Test func promptThatWontClearIsNotPastedInto() async {
        let fake = FakeHerdr(statuses: [.idle])
        fake.screens = [PromptScreens.typed]
        let drafts = DraftLog()
        let result = await Outbox(transport: fake, sleep: { _ in })
            .enqueue([.text("hello")], to: target, submit: true, onDraft: { drafts.add($0) })
        if case .failure(let e) = result { #expect(e as? DeliveryError == .promptNotCleared("showtell")) } else {
            Issue.record("expected failure")
        }
        #expect(fake.calls == [
            "keys w1:p2 ctrl+s", "keys w1:p2 down down", "keys w1:p2 ctrl+e",
            "clear w1:p2 2", "clear w1:p2 2", "clear w1:p2 2",
        ])
        #expect(drafts.all == [.cleared("fgd g junk")])
    }

    @Test func targetGone() async {
        let fake = FakeHerdr(statuses: [.idle])
        var other = target
        other.sessionID = "S2"
        other.terminalID = "t9"
        let result = await Outbox(transport: fake, sleep: { _ in }).enqueue([.text("x")], to: other, submit: false)
        if case .failure(let e) = result { #expect(e as? DeliveryError == .targetGone("showtell")) } else {
            Issue.record("expected failure")
        }
    }
}

final class EventLog: @unchecked Sendable {
    private var events: [DeliveryEvent] = []
    private let lock = NSLock()
    func add(_ e: DeliveryEvent) { lock.lock(); events.append(e); lock.unlock() }
    var all: [DeliveryEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

final class DraftLog: @unchecked Sendable {
    private var events: [DraftEvent] = []
    private let lock = NSLock()
    func add(_ e: DraftEvent) { lock.lock(); events.append(e); lock.unlock() }
    var all: [DraftEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

/// Bottoms of Claude Code 2.1 screens as herdr's `pane.read` (format ansi) returns them.
enum PromptScreens {
    static let rule = "\u{1b}[0m\u{1b}[38;2;136;136;136m" + String(repeating: "─", count: 60) + "\u{1b}[0m\r"
    static let footer = """
      \u{1b}[0m\u{1b}[1m\u{1b}[38;5;6mOpus 5.5 (1M context)\u{1b}[0m\u{1b}[38;2;153;153;153m ctx 0/1.00M\u{1b}[0m\r
      \u{1b}[0m\u{1b}[38;2;255;107;128m⏵⏵ bypass permissions on\u{1b}[0m\u{1b}[38;2;153;153;153m (shift+tab to cycle)\u{1b}[0m
    """

    /// `stash`: Claude Code holds a stashed prompt, and says so above the box.
    static func screen(_ box: String, stash: Bool = false) -> String {
        let above = stash ? String(repeating: " ", count: 40) + "\u{1b}[0m\u{1b}[38;2;153;153;153m › stashed\u{1b}[0m\r" : "\r"
        return "⏺ Earlier answer\r\n\(above)\n\(rule)\n\(box)\n\(rule)\n\(footer)"
    }

    /// An empty prompt: only the dim placeholder.
    static let empty = screen("❯\u{a0}\u{1b}[0m\u{1b}[2mTry \"fix lint errors\"\u{1b}[0m\r")
    static let emptyStashed = screen("❯\u{a0}\u{1b}[0m\u{1b}[2mTry \"fix lint errors\"\u{1b}[0m\r", stash: true)
    static let typed = screen("❯\u{a0}fgd g junk\r")
    static let typedStashed = screen("❯\u{a0}fgd g junk\r", stash: true)
    /// Sending brought the stash back into the prompt.
    static let olderStashInPrompt = screen("❯\u{a0}older stash\r")

    /// A box showing `rows` of a taller draft, with a stash held.
    static func window(_ rows: [String]) -> String {
        screen((["❯\u{a0}" + rows[0]] + rows.dropFirst().map { "  " + $0 }).map { $0 + "\r" }.joined(separator: "\n"),
               stash: true)
    }
    static let multiline = screen("""
    ❯\u{a0}fgd g junkline one of a pasted draft\r
      line two that wraps and\r
      on\r
      line three\r
    """)
}

@Suite struct DraftRestoreTests {
    @Test func typedBackOnlyAfterTheMessageIsSent() {
        #expect(DraftRestore.reasonToKeep("draft", submitted: true, typesLineBreaks: true) == nil)
        #expect(DraftRestore.reasonToKeep("draft", submitted: false, typesLineBreaks: true)
            == "the message was left in the prompt unsent")
    }

    @Test func chipsAreNotTypedBack() {
        #expect(DraftRestore.reasonToKeep("see [Pasted text #1 +4 lines] here", submitted: true, typesLineBreaks: true) != nil)
        #expect(DraftRestore.reasonToKeep("[Image #2] this", submitted: true, typesLineBreaks: true) != nil)
        #expect(DraftRestore.reasonToKeep("[Image] is fine", submitted: true, typesLineBreaks: true) == nil)
    }

    @Test func lineBreaksOnlyWhereTheTerminalTypesThem() {
        #expect(DraftRestore.reasonToKeep("a\nb", submitted: true, typesLineBreaks: true) == nil)
        #expect(DraftRestore.reasonToKeep("a\nb", submitted: true, typesLineBreaks: false) != nil)
        #expect(DraftRestore.reasonToKeep("a b", submitted: true, typesLineBreaks: false) == nil)
    }

    @Test func piecesKeepEveryCharacter() {
        #expect(DraftRestore.pieces("abcdefg", size: 3) == ["abc", "def", "g"])
        #expect(DraftRestore.pieces("", size: 3) == [])
        #expect(DraftRestore.pieces("é👍🏽x", size: 2) == ["é👍🏽", "x"])
    }

    @Test func promptShowsTheDraftOrItsEnd() {
        #expect(DraftRestore.shows("one\ntwo", "one\ntwo"))
        #expect(DraftRestore.shows("one two", "one\ntwo"))  // a break that fell at a wrap
        #expect(DraftRestore.shows("five\nsix", "one\ntwo\nfive\nsix"))  // a tall draft shows its end
        #expect(!DraftRestore.shows("one\ntwo", "one\ntwo\nthree"))  // typing stopped early
        #expect(!DraftRestore.shows("", "one"))
    }
}

@Suite struct PromptInputTests {
    @Test func emptyPromptShowsOnlyThePlaceholder() {
        #expect(PromptInput.parse(PromptScreens.empty) == "")
        #expect(PromptInput.parse(PromptScreens.screen("❯ \r")) == "")
    }

    @Test func typedText() {
        #expect(PromptInput.parse(PromptScreens.typed) == "fgd g junk")
        #expect(PromptInput.lineCount(PromptScreens.typed) == 1)
    }

    @Test func severalLinesKeepTheirBreaksWithoutTheIndent() {
        #expect(PromptInput.parse(PromptScreens.multiline)
            == "fgd g junkline one of a pasted draft\nline two that wraps and\non\nline three")
        #expect(PromptInput.lineCount(PromptScreens.multiline) == 4)
    }

    @Test func dimSuggestionAfterTypedTextIsLeftOut() {
        let s = PromptScreens.screen("❯\u{a0}fix the\u{1b}[2m login bug\u{1b}[22m\r")
        #expect(PromptInput.parse(s) == "fix the")
    }

    @Test func bashModeKeepsItsBang() {
        #expect(PromptInput.parse(PromptScreens.screen("! ls -la\r")) == "!ls -la")
    }

    @Test func plainTextPlaceholderCountsAsEmpty() {
        let rule = String(repeating: "─", count: 60)
        #expect(PromptInput.parse("\(rule)\n❯ Try \"refactor auth.ts\"\n\(rule)\n") == "")
        #expect(PromptInput.parse("\(rule)\n❯ fgd g\n\(rule)\n") == "fgd g")
        #expect(PromptInput.parse("\(rule)\n❯ Press up to edit queued messages\n\(rule)\n") == "")
    }

    @Test func stashSignAboveTheBox() {
        #expect(PromptInput.hasStash(PromptScreens.emptyStashed))
        #expect(PromptInput.hasStash(PromptScreens.typedStashed))
        #expect(!PromptInput.hasStash(PromptScreens.typed))
        #expect(!PromptInput.hasStash(""))
    }

    /// Rows as Claude Code wraps them at 56 columns (a 60-column rule).
    @Test func wrappedRowsAreJoinedBack() {
        let w = 56
        let full = String(repeating: "a", count: 53) + " mu"  // 56: the space before "nu" was taken by the wrap
        #expect(PromptInput.unwrap([full, "nu xi"], width: w) == full + " nu xi")
        let short = String(repeating: "b", count: 50) + " pi"  // 53: "omicron" didn't fit
        #expect(PromptInput.unwrap([short, "omicron"], width: w) == short + " omicron")
        let long = "en " + String(repeating: "x", count: 53)  // a 57-letter word is too long for a row
        #expect(PromptInput.unwrap([long, "xxxx tail"], width: w) == long + "xxxx tail")
        #expect(PromptInput.unwrap(["line one", "line two", "", "line four"], width: w)
            == "line one\nline two\n\nline four")
    }

    @Test func boxRowsKeepTheirBreaksAndWidth() {
        let box = PromptInput.read(PromptScreens.window(["one", "two"]))
        #expect(box?.rows == ["one", "two"])
        #expect(box?.width == 56)
        #expect(box?.text == "one\ntwo")
    }

    @Test func noInputBoxOnScreen() {
        #expect(PromptInput.parse("") == nil)
        #expect(PromptInput.parse("$ ls\n❯ not claude\n") == nil)
        // A dialog replaces the box: the ❯ there is a menu cursor, not under a rule.
        #expect(PromptInput.parse(" Do you trust this folder?\n\n ❯ No, exit\n   Yes, I trust this folder\n") == nil)
    }

    @Test func lowestBoxWins() {
        let s = PromptScreens.screen("❯ old\r") + "\n" + PromptScreens.typed
        #expect(PromptInput.parse(s) == "fgd g junk")
    }
}

@Suite struct CleanupTests {
    let original = "so um the button is cut off [📷 1] while herdr looks fine [📷 2] question is this CSS"

    @Test func acceptsATidiedMessage() {
        let tidied = "The button is cut off [Screenshot 1] while herdr looks fine [Screenshot 2]. Is this CSS?"
        #expect(Cleanup.accept(original: original, cleaned: tidied, terms: ["herdr"])
            == "The button is cut off [📷 1] while herdr looks fine [📷 2]. Is this CSS?")
    }

    @Test func refusesLostOrMovedScreenshots() {
        #expect(Cleanup.accept(original: original, cleaned: "The button is cut off while herdr looks fine [📷 2].", terms: []) == nil)
        #expect(Cleanup.accept(original: original, cleaned: "[📷 2] The button is cut off [📷 1] while herdr looks fine.", terms: []) == nil)
    }

    @Test func refusesLostTermsAndBigChanges() {
        #expect(Cleanup.accept(original: original, cleaned: "The button is cut off [📷 1] while it looks fine [📷 2]. Is this CSS?", terms: ["herdr"]) == nil)
        #expect(Cleanup.accept(original: original, cleaned: "Bug [📷 1] [📷 2]", terms: []) == nil)
    }

    @Test func stripsPreambleAndQuotes() {
        #expect(Cleanup.accept(original: "hello there my friend how are you", cleaned: "Here is the tidied text: \"Hello there, my friend. How are you?\"", terms: [])
            == "Hello there, my friend. How are you?")
    }

    @Test func modelTextRoundTrip() {
        #expect(Cleanup.modelText("a [📷 1] b [📷 12]") == "a [Screenshot 1] b [Screenshot 12]")
        #expect(Cleanup.fromModelText("a [screenshot 1] b") == "a [📷 1] b")
        #expect(Cleanup.modelText("a [📋 2] b [📷 1]") == "a [Copied 2] b [Screenshot 1]")
        #expect(Cleanup.fromModelText("a [Copied 2] b [Screenshot 1]") == "a [📋 2] b [📷 1]")
    }

    @Test func refusesLostCopiedText() {
        let original = "run this command [📋 1] and see what happens"
        #expect(Cleanup.accept(original: original, cleaned: "Run this command and see what happens.", terms: []) == nil)
        #expect(Cleanup.accept(original: original, cleaned: "Run this command [Copied 1] and see what happens.", terms: [])
            == "Run this command [📋 1] and see what happens.")
    }

    @Test func splitAndJoinKeepScreenshotsInPlace() {
        #expect(Cleanup.split("open the page [📷 1] it fails") == ["open the page", "[📷 1]", "it fails"])
        #expect(Cleanup.join(["Open the page", "[📷 1]", "It fails."]) == "Open the page [📷 1] it fails.")
        #expect(Cleanup.join(["Open the page.", "[📷 1]", "It fails."]) == "Open the page. [📷 1] It fails.")
        #expect(Cleanup.join(["Look at this", "[📷 1]", "I think it fails."]) == "Look at this [📷 1] I think it fails.")
        #expect(Cleanup.join(["Look at this", "[📷 1]", "CSS is wrong."]) == "Look at this [📷 1] CSS is wrong.")
    }

    @Test func settingsKeepCleanupChoices() throws {
        var s = Settings()
        s.cleanupModel = "qwen3-4b"
        s.cleanupOnSend = true
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(old.cleanupModel == nil && old.cleanupOnSend == false && old.cleanupShortcut.label == "⌃⌥C")
    }

    @Test func settingsKeepBarShortcuts() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(old.sendToggleShortcut.label == "⌃⌥S")
        #expect(old.nextTargetShortcut.label == "⌃⌥↓" && old.previousTargetShortcut.label == "⌃⌥↑")
        #expect(old.spokenRouting && old.spokenRouteSticks)
        var s = Settings()
        s.nextTargetShortcut = .chord(124, 0x1000, "→")
        s.sendToggleShortcut = .tap("rightShift")
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func settingsKeepCaptureToggles() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(old.captureScreenshots && old.captureCopiedText)
        #expect(old.screenshotsToggleShortcut.label == "⌃⌥I" && old.copiedTextToggleShortcut.label == "⌃⌥T")
        var s = Settings()
        s.captureScreenshots = false
        s.captureCopiedText = false
        s.copiedTextToggleShortcut = .chord(8, 0x1000 | 0x200, "C")
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s && !back.captureScreenshots && !back.captureCopiedText)
        #expect(back.copiedTextToggleShortcut.label == "⌃⇧C")
    }
}

@Suite struct RoutingTests {
    let sessions = [
        Routing.Candidate(id: "w89:p1", names: ["showtell", "showtell"]),
        Routing.Candidate(id: "w88:p1", names: ["claude-banner", "claude-banner"]),
        Routing.Candidate(id: "w1:p1", names: ["firstmate", "Presentation file location"]),
        Routing.Candidate(id: "wA:p3", names: ["firstmate", "Firstmate operational inbox message"]),
    ]

    func route(_ text: String) -> Routing.Route? {
        if case .route(let r) = Routing.find(in: text, candidates: sessions) { return r }
        return nil
    }

    @Test func startPhrases() {
        let r = route("For the Showtell session, do XYZ.")
        #expect(r?.target == .session("w89:p1") && r?.remaining == "Do XYZ.")
        #expect(route("Showtell session: look at the bar")?.remaining == "Look at the bar")
        #expect(route("Send to claude banner, fix the colours")?.target == .session("w88:p1"))
        #expect(route("for the showtell session do xyz")?.remaining == "Do xyz")
        #expect(route("At the cursor: hello there")?.target == .cursor)
    }

    @Test func endPhrasesAndMishearings() {
        let r = route("I need you to do XYZ with the XYZ, this should go to Chotel.")
        #expect(r?.target == .session("w89:p1"))
        #expect(r?.remaining == "I need you to do XYZ with the XYZ.")
        #expect(route("Fix the colours and send this to cloud banner")?.target == .session("w88:p1"))
        let the = route("Write a short haiku about tea, this should go to the showtell session")
        #expect(the?.target == .session("w89:p1") && the?.remaining == "Write a short haiku about tea")
        #expect(route("Send to the showtell session, fix it")?.remaining == "Fix it")
        #expect(route("Rename the file, for the showtell session.")?.remaining == "Rename the file.")
        let c = route("Thanks for the help, paste this at the cursor.")
        #expect(c?.target == .cursor && c?.remaining == "Thanks for the help.")
    }

    @Test func ordinaryTextDoesNotRoute() {
        #expect(route("For the record, the Showtell bar is cut off.") == nil)
        #expect(route("The showtell session has a bug in the bar") == nil)
        #expect(route("Showtell, do XYZ") == nil)
        #expect(route("look at this [📷 1] for the showtell session") != nil)
        #expect(Routing.find(in: "", candidates: sessions) == .none)
    }

    @Test func unclearNamesChangeNothing() {
        if case .unclear = Routing.find(in: "Fix it, send this to firstmate", candidates: sessions) {} else {
            Issue.record("two firstmate sessions should be unclear")
        }
        if case .unclear = Routing.find(in: "Send to zebra, fix it", candidates: sessions) {} else {
            Issue.record("an unknown name should be unclear")
        }
        #expect(route("Fix it, send this to presentation file location")?.target == .session("w1:p1"))
    }
}

@Suite struct HistoryTests {
    func makeStore() throws -> HistoryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("showtell-history-\(UUID().uuidString)")
        let storage = Storage(root: root)
        try storage.prepare()
        return HistoryStore(storage: storage)
    }

    func picture(_ store: HistoryStore, _ name: String, bytes: Int = 10) throws {
        try Data(repeating: 1, count: bytes).write(to: store.shotsURL.appendingPathComponent(name))
    }

    @Test func recordsNewestFirstAndSurvivesReload() throws {
        let store = try makeStore()
        let target = try JSONDecoder().decode(PinnedTarget.self, from: Data(
            #"{"sessionID":"s1","terminalID":"t1","paneID":"w1:p1","name":"showtell","cwd":"/r"}"#.utf8))
        try store.record(HistoryEntry(id: "a", destination: .cursor, text: "first", submitted: false))
        try store.record(HistoryEntry(id: "b", destination: .session(target), text: "look [📷 1] and [📋 1]",
                                      shots: [.init(number: 1, file: "b-01.png")], clips: [.init(number: 1, text: "npm test")],
                                      submitted: true))
        let entries = store.load()
        #expect(entries.map(\.id) == ["b", "a"])
        #expect(entries[0].destination == .session(target))
        #expect(entries[0].destination.label == "showtell")
        #expect(entries[0].clips == [.init(number: 1, text: "npm test")])
        try store.markFailed("a", "no session")
        #expect(store.load()[1].failure == "no session")
        try store.setClearedDraft("b", "fgd g")
        #expect(store.load()[0].clearedDraft == "fgd g")
        #expect(store.load()[1].clearedDraft == nil)
        try store.setDraftOutcome("b", .notRestored, reason: "the session showed a dialog")
        #expect(store.load()[0].draftOutcome == .notRestored)
        #expect(store.load()[0].draftNotRestored == "the session showed a dialog")
        try store.setDraftOutcome("b", .restoredFromStash, reason: "ignored")
        #expect(store.load()[0].draftOutcome == .restoredFromStash)
        #expect(store.load()[0].draftNotRestored == nil)
    }

    @Test func keepsOnlyWhatTheSentTextStillMarks() {
        let e = HistoryEntry.sent(id: "r", destination: .cursor, text: "see [📷 2] and [📋 1]",
                                  shots: [1: URL(fileURLWithPath: "/s/r-01.png"), 2: URL(fileURLWithPath: "/s/r-02.png")],
                                  clips: [1: "kept", 2: "deleted marker"], submitted: false)
        #expect(e.shots == [.init(number: 2, file: "r-02.png")])
        #expect(e.clips == [.init(number: 1, text: "kept")])
    }

    @Test func piecesLeaveOutRemovedPictures() throws {
        let store = try makeStore()
        try picture(store, "x-01.png")
        let entry = HistoryEntry(destination: .cursor, text: "a [📷 1] b [📷 2] c [📋 1]",
                                 shots: [.init(number: 1, file: "x-01.png"), .init(number: 2, file: "x-02.png")],
                                 clips: [.init(number: 1, text: "  kept  as is ")], submitted: false)
        #expect(entry.pieces(shotsIn: store.shotsURL) == [
            .text("a "), .image(store.shotsURL.appendingPathComponent("x-01.png")), .text(" b c "), .copied("  kept  as is "),
        ])
        #expect(entry.preview == "a [📷 1] b [📷 2] c [📋 1]")
    }

    @Test func deletingKeepsPicturesAnotherEntryUses() throws {
        let store = try makeStore()
        try picture(store, "p-01.png")
        try picture(store, "p-02.png")
        let shared = HistoryEntry.Shot(number: 1, file: "p-01.png")
        try store.record(HistoryEntry(id: "original", destination: .cursor, text: "[📷 1] [📷 2]",
                                      shots: [shared, .init(number: 2, file: "p-02.png")], submitted: false))
        try store.record(HistoryEntry(id: "resent", destination: .cursor, text: "[📷 1]", shots: [shared], submitted: false))
        #expect(try store.delete(["original"]) == 1)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: store.shotsURL.appendingPathComponent("p-01.png").path))
        #expect(!fm.fileExists(atPath: store.shotsURL.appendingPathComponent("p-02.png").path))
        #expect(store.load().map(\.id) == ["resent"])
        #expect(try store.clear() == 1)
        #expect(store.load().isEmpty)
    }

    @Test func clearingShotsKeepsTextAndTheRecordingInProgress() throws {
        let store = try makeStore()
        try picture(store, "old-01.png", bytes: 100)
        try picture(store, "old-02.png", bytes: 50)
        try picture(store, "now-01.png", bytes: 5)
        try "not a picture".write(to: store.shotsURL.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try store.record(HistoryEntry(id: "a", destination: .cursor, text: "see [📷 1]",
                                      shots: [.init(number: 1, file: "old-01.png")], submitted: true))
        let usage = store.shotsUsage()
        #expect(usage.files == 3 && usage.bytes == 155)
        #expect(store.clearShots(keeping: ["now-01.png"]) == 2)
        #expect(store.shotsUsage().files == 1)
        #expect(store.load()[0].text == "see [📷 1]")
        #expect(store.load()[0].pieces(shotsIn: store.shotsURL) == [.text("see")])
    }

    @Test func renamedPicturesFollowInEveryEntry() throws {
        let store = try makeStore()
        let shot = HistoryEntry.Shot(number: 1, file: "a-01.png")
        try store.record(HistoryEntry(id: "a", destination: .cursor, text: "[📷 1]", shots: [shot], submitted: false))
        try store.record(HistoryEntry(id: "b", destination: .cursor, text: "[📷 1] [📷 2]",
                                      shots: [shot, .init(number: 2, file: "other.png")], submitted: false))
        try store.renameShots(["a-01.png": "new name.png"])
        #expect(store.load().map { $0.shots.map(\.file) } == [["new name.png", "other.png"], ["new name.png"]])
    }
}

@Suite struct ShotNameTests {
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 14, minute: 3))!

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("showtell-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func buildsTheName() {
        #expect(ShotNames.name(date: date, destination: "showtell", number: 2, words: "the header is cut off")
            == "2026-10-12 14.03 showtell 📷2 — the header is cut off")
        #expect(ShotNames.name(date: date, destination: "cursor", number: 1, words: nil) == "2026-10-12 14.03 cursor 📷1")
        #expect(ShotNames.name(date: date, destination: "unsent", number: 3, words: "  ") == "2026-10-12 14.03 unsent 📷3")
    }

    @Test func capsTheLength() {
        let long = String(repeating: "word ", count: 60)
        let name = ShotNames.name(date: date, destination: "showtell", number: 1, words: long)
        #expect(name.count <= ShotNames.maxLength)
        #expect(name.hasSuffix("…"))
        #expect(name.hasPrefix("2026-10-12 14.03 showtell 📷1 — word word"))
        let longSession = ShotNames.name(date: date, destination: String(repeating: "x", count: 200), number: 1, words: "hi")
        #expect(longSession.count <= ShotNames.maxLength)
    }

    @Test func sanitises() {
        #expect(ShotNames.sanitize("api/v2: the\tbad\n\nlogin  ") == "api-v2- the bad login")
        #expect(ShotNames.sanitize("..hidden") == "hidden")
        #expect(ShotNames.sanitize("a\u{0}b") == "a b")
    }

    @Test func picksWordsBeforeTheMarker() {
        let text = "So when I open [📋 1] the settings page and click save, here [📷 1] it breaks. [📷 2] And again [📷 3]"
        #expect(ShotNames.words(before: 1, in: text) == "settings page and click save, here")
        #expect(ShotNames.words(before: 2, in: text) == "and click save, here it breaks")
        #expect(ShotNames.words(before: 3, in: text) == "save, here it breaks. And again")
        #expect(ShotNames.words(before: 4, in: text) == nil)
        #expect(ShotNames.words(before: 1, in: "[📷 1] first thing") == nil)
        #expect(ShotNames.words(before: 2, in: "[📷 1] [📷 2] then") == nil)
        #expect(ShotNames.words(before: 1, in: "why? [📷 1]") == "why?")
    }

    @Test func makesNamesUnique() {
        let taken: Set<String> = ["a.png", "a (2).png"]
        #expect(ShotNames.unique("a", ext: "png", taken: taken.contains) == "a (3).png")
        #expect(ShotNames.unique("b", ext: "png", taken: taken.contains) == "b.png")
    }

    @Test func renamesFilesAndSetsTheComment() throws {
        let dir = try folder()
        let one = dir.appendingPathComponent("20261012-140300-000-01.png")
        let two = dir.appendingPathComponent("20261012-140300-000-02.png")
        let gone = dir.appendingPathComponent("20261012-140300-000-03.png")
        let old = dir.appendingPathComponent("20250101-000000-000-01.png")
        for url in [one, two, old] { try Data([1]).write(to: url) }
        // Someone else's picture already has the first name.
        try Data([2]).write(to: dir.appendingPathComponent("2026-10-12 14.03 showtell 📷1 — the login- button.png"))

        let text = "the login: button [📷 1] looks wrong"
        let renamed = ShotNames.rename([1: one, 2: two, 3: gone], text: text, destination: "showtell", delivered: true, date: date)
        let first = try #require(renamed[1])
        #expect(first.lastPathComponent == "2026-10-12 14.03 showtell 📷1 — the login- button (2).png")
        #expect(renamed[2]?.lastPathComponent == "2026-10-12 14.03 unsent 📷2.png")  // its marker was deleted
        #expect(renamed[3] == nil)
        #expect(ShotNames.finderComment(of: first) == "Showtell → showtell\n\n" + text)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: one.path) && fm.fileExists(atPath: old.path))

        // Delivery failed afterwards: named again as unsent, keeping the words.
        let unsent = ShotNames.rename(renamed, text: text, destination: "showtell", delivered: false, date: date)
        #expect(unsent[1]?.lastPathComponent == "2026-10-12 14.03 unsent 📷1 — the login- button.png")
        #expect(unsent[2] == renamed[2])
        #expect(ShotNames.finderComment(of: unsent[1]!) == "Showtell, unsent (for showtell)\n\n" + text)
    }
}

@Suite struct WordDiffTests {
    @Test func marksRemovedAndAddedWords() {
        let parts = WordDiff.diff("so um I think the header is cut off", "I think the header is clipped.")
        #expect(parts == [
            .removed("so"), .removed("um"), .same("I"), .same("think"), .same("the"), .same("header"), .same("is"),
            .removed("cut"), .removed("off"), .added("clipped."),
        ])
    }

    @Test func ignoresCasePunctuationAndMarkers() {
        let parts = WordDiff.diff("the header is cut off see this", "The header is cut off, see [📷 1] this.")
        #expect(parts.allSatisfy { if case .same = $0 { return true } else { return false } })
        #expect(parts.first == .same("The"))
        #expect(WordDiff.sameWords("fix the bug", "Fix the bug. [📋 2]"))
        #expect(!WordDiff.sameWords("fix the bug", "fix a bug"))
        #expect(WordDiff.diff("", "") == [])
        #expect(WordDiff.diff("", "hi") == [.added("hi")])
    }

    @Test func removedFractionLeavesOutFillers() {
        #expect(WordDiff.removedFraction("um uh fix the bug now", "Fix the bug now.") == 0)
        #expect(WordDiff.removedFraction("one two three four five six seven eight nine ten", "one two three four five six seven eight") == 0.2)
        #expect(WordDiff.removedFraction("", "anything") == 0)
    }
}

@Suite struct HistoryStageTests {
    func makeStore() throws -> HistoryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("showtell-stages-\(UUID().uuidString)")
        let storage = Storage(root: root)
        try storage.prepare()
        return HistoryStore(storage: storage)
    }

    @Test func keepsOnlyTheStepsThatChangedWords() {
        var e = HistoryEntry(destination: .cursor, text: "Fix the herdr bug.", submitted: false)
        e.setStages(raw: "so fix the herder bug please", edited: "so fix the herder bug please",
                    replaced: "so fix the herdr bug please", tidied: "Fix the herdr bug.", tidyModel: "Qwen 3 4B Instruct")
        #expect(e.editedText == nil)
        #expect(e.replacedText == "so fix the herdr bug please")
        #expect(e.tidyInput == "so fix the herdr bug please")
        #expect(e.tidyModel == "Qwen 3 4B Instruct")
        #expect(e.tidyRemovedFraction == 2.0 / 6.0)
        #expect(e.tidyDroppedWords)
        #expect(e.changes?.contains(.removed("please")) == true)

        var off = HistoryEntry(destination: .cursor, text: "typed", submitted: false)
        off.setStages(raw: nil, edited: "typed", replaced: "typed", tidied: nil, tidyModel: nil)
        #expect(off.tidyModel == HistoryEntry.tidyOff)
        #expect(off.editedText == "typed")
        #expect(off.tidiedText == nil)
        #expect(off.tidyRemovedFraction == nil)
        #expect(!off.tidyDroppedWords)
        #expect(off.changes == nil)
        #expect(off.hasStages)
    }

    @Test func roundTripsWithAndWithoutStages() throws {
        let store = try makeStore()
        var e = HistoryEntry(id: "new", date: Date(timeIntervalSince1970: 1_790_000_000), destination: .cursor, text: "Fix it.", submitted: false)
        e.setStages(raw: "fix it", edited: "fix it", replaced: "fix it", tidied: "Fix it.", tidyModel: "Apple Intelligence")
        try store.record(HistoryEntry(id: "plain", destination: .cursor, text: "no stages", submitted: false))
        try store.record(e)
        let loaded = store.load()
        #expect(loaded[0] == e)
        #expect(loaded[0].rawTranscript == "fix it")
        #expect(loaded[1].hasStages == false)
        #expect(loaded[1].changes == nil)
        #expect(loaded[1].tidyRemovedFraction == nil)
    }

    @Test func readsEntriesSavedBeforeStagesWereKept() throws {
        let store = try makeStore()
        let old = #"[{"id":"old","date":"2026-10-01T10:00:00Z","destination":{"cursor":{}},"text":"hello","shots":[],"clips":[],"submitted":false}]"#
        try Data(old.utf8).write(to: store.url)
        let loaded = store.load()
        #expect(loaded.map(\.id) == ["old"])
        #expect(loaded[0].rawTranscript == nil && loaded[0].tidyModel == nil && !loaded[0].hasStages)
    }
}

@Suite struct SpeechGateTests {
    @Test func quickPressIsDropped() {
        #expect(!SpeechGate.keeps("Yeah.", duration: 0.4, speech: 0.4))
        #expect(!SpeechGate.keeps("Fix the header", duration: 0.5, speech: 0.5))
    }

    @Test func silenceIsDropped() {
        #expect(!SpeechGate.keeps("Yeah.", duration: 3, speech: 0))
        #expect(!SpeechGate.keeps("Okay, so the", duration: 5, speech: 0.1))
    }

    @Test func fillerNeedsClearSpeech() {
        #expect(!SpeechGate.keeps("Yeah.", duration: 1.5, speech: 0.2))
        #expect(!SpeechGate.keeps("um", duration: 2, speech: 0.16))
        #expect(SpeechGate.keeps("Yeah.", duration: 1.2, speech: 0.45))
        #expect(SpeechGate.keeps("Okay!", duration: 0.8, speech: 0.3))
    }

    @Test func shortRealMessagesStay() {
        #expect(SpeechGate.keeps("Do it.", duration: 0.9, speech: 0.2))
        #expect(SpeechGate.keeps("Yeah, do it.", duration: 1.0, speech: 0.2))
        #expect(SpeechGate.keeps("Fix the header on the profile page", duration: 4, speech: 2.5))
    }

    @Test func fillerList() {
        for word in ["yeah", "Yes.", "uh", "Um,", "mm", "Okay.", "oh", "The"] {
            #expect(SpeechGate.isLoneFiller(word), "\(word)")
        }
        #expect(!SpeechGate.isLoneFiller("Yeah, okay"))
        #expect(!SpeechGate.isLoneFiller("Stop."))
        #expect(!SpeechGate.isLoneFiller(""))
    }

    @Test func voiceDetectorVetoesNoise() {
        #expect(SpeechGate.speechSeconds(energy: 0.8, vad: 0) == 0)
        #expect(SpeechGate.speechSeconds(energy: 0.3, vad: 0.512) == 0.512)
        #expect(SpeechGate.speechSeconds(energy: 0.4, vad: 0.256) == 0.4)
        #expect(SpeechGate.speechSeconds(energy: 0.4, vad: nil) == 0.4)
        #expect(SpeechGate.vadSeconds(probabilities: [0.1, 0.6, 0.9, 0.49], chunkSeconds: 0.256) == 0.512)
    }

    @Test func levels() {
        #expect(SpeechGate.level(of: [Float]()) == -120)
        #expect(SpeechGate.level(of: [Float](repeating: 0, count: 320)) == -120)
        #expect(abs(SpeechGate.level(of: [Float](repeating: 0.1, count: 320)) - -20) < 0.01)
    }

    @Test func energyAgainstTheNoiseFloor() {
        // Room at -60 dBFS, two seconds; quiet speech at -45 dBFS for 0.4 s.
        let room = [Float](repeating: -60, count: 100)
        #expect(SpeechGate.voicedSeconds(levels: room) == 0)
        let quiet = room + [Float](repeating: -45, count: 20)
        #expect(abs(SpeechGate.voicedSeconds(levels: quiet) - 0.4) < 1e-9)
        // A noisy room at -42 dBFS: the same quiet speech no longer stands out, a fan bump doesn't count.
        let noisy = [Float](repeating: -42, count: 100) + [Float](repeating: -40, count: 20)
        #expect(SpeechGate.voicedSeconds(levels: noisy) == 0)
        // All speech, no quiet part: loud frames still count.
        let allSpeech = [Float](repeating: -30, count: 40)
        #expect(abs(SpeechGate.voicedSeconds(levels: allSpeech) - 0.8) < 1e-9)
        // A digital-silence floor: hiss at -100 isn't speech.
        let hiss = [Float](repeating: -120, count: 50) + [Float](repeating: -100, count: 50)
        #expect(SpeechGate.voicedSeconds(levels: hiss) == 0)
    }
}

/// Claude Code 2.1.296 dialogs captured from a scratch session in herdr (`pane.read`, format ansi), in Screens/.
enum DialogScreens {
    static func load(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "ansi", subdirectory: "Screens"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}

@Suite struct DialogTests {
    @Test func questionWithAFreeTextOption() throws {
        let d = try #require(Dialog.read(DialogScreens.load("q-single")))
        #expect(d.kind == .question)
        #expect(d.question == "Which fruit do you like?")
        #expect(d.options.map(\.label) == ["Apple", "Banana", "Type something.", "Chat about this"])
        #expect(d.focused?.number == 1)
        #expect(d.freeText?.number == 3)
        #expect(d.canAnswer && !d.multiSelect && d.tabs.isEmpty)
    }

    @Test func focusedFreeTextKeepsItsDimPlaceholder() throws {
        let d = try #require(Dialog.read(DialogScreens.load("q-typing")))
        #expect(d.focused?.number == 3 && d.freeText?.number == 3)
    }

    @Test func typedAnswerReplacesThePlaceholder() throws {
        let screen = DialogScreens.load("q-typed")
        let d = try #require(Dialog.read(screen))
        #expect(d.focused?.label == "Mango, ripe")
        #expect(d.freeText == nil)
        #expect(Dialog.shows("Mango, ripe", on: screen))
        #expect(!Dialog.shows("Mango, unripe", on: screen))
    }

    @Test func multiSelectWithSeveralQuestions() throws {
        let d = try #require(Dialog.read(DialogScreens.load("q-multi")))
        #expect(d.kind == .question && d.multiSelect)
        #expect(d.question == "Which colours?")
        #expect(d.tabs == ["Colours", "Size"])
        #expect(d.freeText?.number == 4 && d.freeText?.checkbox == true)
        #expect(d.focused?.number == 1)
    }

    @Test func secondQuestionOfSeveral() throws {
        let d = try #require(Dialog.read(DialogScreens.load("q-tabs-second")))
        #expect(d.question == "Which size?" && d.tabs == ["Colours", "Size"] && !d.multiSelect)
        #expect(d.freeText?.number == 3)
    }

    @Test func oneMultiSelectQuestionHasTabsToo() throws {
        let d = try #require(Dialog.read(DialogScreens.load("q-multiselect-one")))
        #expect(d.tabs == ["Pets"] && d.multiSelect && d.freeText?.number == 3)
    }

    @Test func reviewPageHasNothingToType() throws {
        let d = try #require(Dialog.read(DialogScreens.load("q-submit")))
        #expect(d.kind == .question && !d.canAnswer)
        #expect(d.question == "Ready to submit your answers?")
        #expect(d.options.map(\.label) == ["Submit answers", "Cancel"])
    }

    @Test func permissionPromptIsNeverAnswered() throws {
        let d = try #require(Dialog.read(DialogScreens.load("perm")))
        #expect(d.kind == .permission)
        #expect(d.question == "Do you want to proceed?")
        #expect(d.options.count == 4 && d.focused?.label == "Yes")
        #expect(!d.canAnswer)
    }

    @Test func longAnswerWrapsAndStillShows() {
        let text = "a hamster named Biscuit who lives in a cage by the window and eats sunflower seeds every "
            + "single morning, plus two goldfish called Salt and Pepper that my daughter feeds before school each day of the week"
        #expect(Dialog.shows(text, on: DialogScreens.load("q-long")))
    }

    @Test func promptIsNotADialog() {
        #expect(Dialog.read(PromptScreens.empty) == nil)
        #expect(Dialog.read(PromptScreens.typed) == nil)
        #expect(Dialog.read("") == nil)
    }

    @Test func answerTextIsTheWordsOnOneLine() {
        let shot = URL(fileURLWithPath: "/s/1.png")
        #expect(Outbox.answerText([.text("look "), .image(shot), .text("here\nand there"), .copied("x  y")])
            == "look here and there x y")
        #expect(Outbox.answerText([.image(shot)]) == nil)
    }
}
