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
        c.updateTranscript("this", newWordEndTimes: [0.4])
        c.addShot(URL(fileURLWithPath: "/a.png"), at: 1.2)  // recogniser lags: only "this" known
        c.updateTranscript("this button is cut off", newWordEndTimes: [0.9, 1.1, 1.6, 1.9])
        #expect(c.render() == "this button is [📷 1] cut off")
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
    func paste(_ text: String, pane: String) async throws { record("paste \(pane) \(text)") }
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
