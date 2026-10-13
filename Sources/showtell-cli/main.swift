import Foundation
import ShowtellCore

// Debug companion: list herdr Claude sessions and send a message the same way the app does.
//
//   showtell-cli sessions
//   showtell-cli send <pane-id|session-id> [--submit] "text" @/path/shot.png "more text"

let usage = """
usage:
  showtell-cli sessions
  showtell-cli send <pane-id|session-id> [--submit] [--if-held answer|after|cancel] <piece>...
      a piece is text, or @/absolute/path.png for a screenshot
      --if-held: what to do if the session shows a dialog (left undecided, it waits up to 10 minutes)
  showtell-cli toggle | cancel | tidy | settings | history | submit | next | previous
      same as pressing the shortcut / the cancel shortcut / the tidy-up shortcut / choosing Settings…
      or History… / the Send checkbox / the next or previous session shortcut, in the running app
  showtell-cli target cursor | <pane-id>
      where the running app sends: insert at the cursor, or a herdr pane
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let client = AllSessions()

switch args.first {
case "sessions":
    do {
        let agents = try await client.listAgents().filter(\.isClaude)
        if agents.isEmpty { print("no Claude sessions in herdr, tmux or iTerm2") }
        for a in agents {
            print("\(a.paneID)\t\(a.status.rawValue)\t\(a.sessionID ?? "-")\t\(a.folderName)\t\(a.displayName)")
        }
    } catch { fail("\(error)") }

case "send":
    guard args.count >= 3 else { fail(usage) }
    let key = args[1]
    var submit = false
    var ifHeld: HoldChoice?
    var pieces: [Piece] = []
    var rest = args.dropFirst(2).makeIterator()
    while let arg = rest.next() {
        if arg == "--submit" { submit = true; continue }
        if arg == "--if-held" {
            switch rest.next() {
            case "answer": ifHeld = .answer
            case "after": ifHeld = .sendAfter
            case "cancel": ifHeld = .cancel
            default: fail(usage)
            }
            continue
        }
        if arg.hasPrefix("@") {
            let path = String(arg.dropFirst())
            guard FileManager.default.fileExists(atPath: path) else { fail("no such file: \(path)") }
            pieces.append(.image(URL(fileURLWithPath: path)))
        } else {
            pieces.append(.text(arg))
        }
    }
    do {
        let agents = try await client.listAgents()
        guard let agent = agents.first(where: { $0.paneID == key || $0.sessionID == key }) else {
            fail("no Claude session with pane or session \(key)")
        }
        let outbox = Outbox(transport: client)
        let ifHeld = ifHeld
        await outbox.setEventHandler { event in
            print("·", event)
            if case .held(let hold) = event, let choice = ifHeld, !hold.sendAfter {
                print("·", hold.title, hold.canAnswer ? "(can answer)" : "(can't answer)")
                Task { await outbox.decide(hold.messageID, choice) }
            }
        }
        let result = await outbox.enqueue(pieces, to: PinnedTarget(agent: agent), submit: submit) { event in
            switch event {
            case .cleared(let draft): print("· cleared from the prompt:", draft.debugDescription)
            case .outcome(let outcome, let reason): print("· draft:", outcome.rawValue, reason ?? "")
            }
        }
        switch result {
        case .success(let delivered):
            if let answered = delivered.answered {
                print("· answered:", answered.question, answered.picturesLeftOut ? "(pictures left out)" : "",
                      answered.moreLeft ? "(more questions left)" : "")
            }
        case .failure(let error):
            fail("\(error)")
        }
    } catch { fail("\(error)") }

case "toggle", "cancel", "tidy", "settings", "history", "submit", "next", "previous":
    DistributedNotificationCenter.default().postNotificationName(
        .init("dev.showtell.\(args[0])"), object: nil, userInfo: nil, deliverImmediately: true)

case "target" where args.count == 2:
    DistributedNotificationCenter.default().postNotificationName(
        .init("dev.showtell.target"), object: args[1], userInfo: nil, deliverImmediately: true)

default:
    fail(usage)
}
