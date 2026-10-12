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
}

@Suite struct ComposerTests {
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
    func readVisible(pane: String) async throws -> String { "" }
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
        #expect((try? result.get())?.paneID == "w1:p2")
    }

    @Test func waitsWhileBlocked() async {
        let fake = FakeHerdr(statuses: [.blocked, .blocked, .idle])
        let events = EventLog()
        let outbox = Outbox(transport: fake, sleep: { _ in })
        await outbox.setEventHandler { events.add($0) }
        await outbox.enqueue([.text("hi")], to: target, submit: false)
        #expect(fake.calls == ["paste w1:p2 hi"])
        #expect(events.all.first == .waitingForApproval("showtell"))
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
        var s = Settings()
        s.nextTargetShortcut = .chord(124, 0x1000, "→")
        s.sendToggleShortcut = .tap("rightShift")
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
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
