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
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let client = HerdrClient()

switch args.first {
case "sessions":
    do {
        let agents = try await client.listAgents().filter(\.isClaude)
        if agents.isEmpty { print("no Claude sessions in herdr") }
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
            fail("no herdr agent with pane or session \(key)")
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

default:
    fail(usage)
}
