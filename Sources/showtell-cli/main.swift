import Foundation
import ShowtellCore

// Debug companion: list herdr Claude sessions and send a message the same way the app does.
//
//   showtell-cli sessions
//   showtell-cli send <pane-id|session-id> [--submit] "text" @/path/shot.png "more text"

let usage = """
usage:
  showtell-cli sessions
  showtell-cli send <pane-id|session-id> [--submit] <piece>...
      a piece is text, or @/absolute/path.png for a screenshot
  showtell-cli toggle | cancel | settings
      same as pressing the shortcut / the cancel shortcut / choosing Settings… in the running app
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
    var pieces: [Piece] = []
    for arg in args.dropFirst(2) {
        if arg == "--submit" { submit = true; continue }
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
        await outbox.setEventHandler { event in print("·", event) }
        if case .failure(let error) = await outbox.enqueue(pieces, to: PinnedTarget(agent: agent), submit: submit) {
            fail("\(error)")
        }
    } catch { fail("\(error)") }

case "toggle", "cancel", "settings":
    DistributedNotificationCenter.default().postNotificationName(
        .init("dev.showtell.\(args[0])"), object: nil, userInfo: nil, deliverImmediately: true)

case "target" where args.count == 2:
    DistributedNotificationCenter.default().postNotificationName(
        .init("dev.showtell.target"), object: args[1], userInfo: nil, deliverImmediately: true)

default:
    fail(usage)
}
