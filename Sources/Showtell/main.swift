import AppKit
import ShowtellCore

// `Showtell --transcribe <audio> [term ...]` runs the speech path on a file and exits (self-test).
let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--transcribe" {
    let engine = SpeechEngine { state in print("speech:", state) }
    let terms = Vocabulary.simpleListTerms(arguments.dropFirst(3).joined(separator: "\n"))  // "herdr: herder"
    Task {
        let started = Date()
        await engine.load()
        print("models loaded in \(Int(Date().timeIntervalSince(started))) s")
        do {
            let final = try await engine.transcribeFile(URL(fileURLWithPath: arguments[2]), terms: terms) { text, ends, time in
                print(String(format: "partial @%.2fs (%d new timed words): %@", time, ends.count, text))
            }
            print("FINAL: \(final)")
            exit(0)
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Menu-bar app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated { AppController() }
MainActor.assumeIsolated { controller.start() }
app.run()
