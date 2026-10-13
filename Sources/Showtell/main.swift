import AppKit
import AVFoundation
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
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[2]))
            let duration = Double(file.length) / file.processingFormat.sampleRate
            print(String(format: "speech %.2f s of %.2f s", final.speech, duration))
            print("FINAL: \(final.text)")
            let kept = SpeechGate.keeps(final.text, duration: duration, speech: final.speech)
            print("SENT: \(kept ? final.text : "(nothing: no speech)")")
            exit(0)
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// `Showtell --tidy <model-id> <text> [term ...]` tidies one message with a clean-up model and exits.
if arguments.count >= 4, arguments[1] == "--tidy" {
    guard let model = CleanupModel.named(arguments[2]) else {
        print("models: " + CleanupModel.all.map(\.id).joined(separator: ", "))
        exit(2)
    }
    Task { @MainActor in
        let cleaner = TextCleaner(storage: Storage())
        let terms = Array(arguments.dropFirst(4))
        for round in 1...2 {  // the second run shows the time once the model is loaded
            let started = Date()
            let result = await cleaner.clean(arguments[3], terms: terms, with: model)
            print(String(format: "run %d, %.2f s: ", round, Date().timeIntervalSince(started)), result)
            if case .failure = result { print("  model said:", cleaner.lastRaw) }
        }
        cleaner.shutdownBlocking()
        exit(0)
    }
    RunLoop.main.run()
}

// Menu-bar app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated { AppController() }
MainActor.assumeIsolated { controller.start() }
app.run()
