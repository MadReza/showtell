import AppKit
import AVFoundation
import ShowtellCore
import SwiftUI

/// The Settings window: shortcuts, behaviour, permissions and your words, without editing JSON.
@MainActor
final class SettingsWindow {
    private let storage: Storage
    private var window: NSWindow?
    private var model: SettingsModel?

    init(storage: Storage) {
        self.storage = storage
    }

    func show(settings: ShowtellCore.Settings, onChange: @escaping (ShowtellCore.Settings) -> Void, onRecording: @escaping (Bool) -> Void,
              onAskAccessibility: @escaping () -> Void) {
        if let window, let model {
            model.settings = settings
            model.refresh()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = SettingsModel(settings: settings, storage: storage)
        model.onChange = onChange
        model.onRecording = onRecording
        model.onAskAccessibility = onAskAccessibility
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Showtell Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        self.window = window
        self.model = model
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Permissions may have changed.
    func refresh() { model?.refresh() }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: ShowtellCore.Settings {
        didSet { if settings != oldValue { onChange?(settings) } }
    }
    @Published var words: String {
        didSet { try? words.write(to: storage.vocabularyURL, atomically: true, encoding: .utf8) }
    }
    @Published var replacements: String {
        didSet { try? replacements.write(to: storage.replacementsURL, atomically: true, encoding: .utf8) }
    }
    @Published var accessibilityAllowed = ScreenshotKeyMonitor.isTrusted
    @Published var microphone = SettingsModel.microphoneStatus()
    /// Which shortcut is listening for keys, if any.
    @Published var recording: WritableKeyPath<ShowtellCore.Settings, Shortcut>? {
        didSet { onRecording?(recording != nil) }
    }

    let storage: Storage
    var onChange: ((ShowtellCore.Settings) -> Void)?
    var onRecording: ((Bool) -> Void)?
    var onAskAccessibility: (() -> Void)?

    init(settings: ShowtellCore.Settings, storage: Storage) {
        self.settings = settings
        self.storage = storage
        words = (try? String(contentsOf: storage.vocabularyURL, encoding: .utf8)) ?? ""
        replacements = (try? String(contentsOf: storage.replacementsURL, encoding: .utf8)) ?? ""
    }

    func refresh() {
        accessibilityAllowed = ScreenshotKeyMonitor.isTrusted
        microphone = Self.microphoneStatus()
    }

    var needsAccessibility: Bool {
        settings.startShortcut.tap != nil || settings.cancelShortcut.tap != nil || settings.hideDuringScreenshots
    }

    static func microphoneStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "Allowed"
        case .denied, .restricted: return "Not allowed"
        default: return "Asked on the first recording"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Start and send") { ShortcutField(model: model, path: \.startShortcut) }
                LabeledContent("Cancel a recording") { ShortcutField(model: model, path: \.cancelShortcut) }
                Text("Click a shortcut, then press the new one: a key with modifiers such as ⌃⌥Space, or tap a single modifier such as the left ⌥. Esc keeps the old one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle("Second press sends (presses Enter)", isOn: $model.settings.submitOnSecondPress)
                Toggle("Hide the bar while taking a screenshot (⌘⌃⇧3 / ⌘⌃⇧4)", isOn: $model.settings.hideDuringScreenshots)
            }
            Section("Permissions") {
                LabeledContent("Microphone") { Text(model.microphone).foregroundStyle(.secondary) }
                LabeledContent("Accessibility") {
                    if model.accessibilityAllowed {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Allow…") { model.onAskAccessibility?() }
                    }
                }
                if !model.accessibilityAllowed, model.needsAccessibility {
                    Text("Needed for single-modifier shortcuts and to hide the bar on ⌘⌃⇧4.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                TextEditor(text: $model.words).font(.system(.body, design: .monospaced)).frame(minHeight: 90)
            } header: {
                Text("Your words")
            } footer: {
                Text("One per line, spelled the way it should appear. Your repo's .github/dictation.md is added for its session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $model.replacements).font(.system(.body, design: .monospaced)).frame(minHeight: 70)
            } header: {
                Text("Replacements")
            } footer: {
                Text("wrong => right, applied to the finished text.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Show screenshots folder") { NSWorkspace.shared.open(model.storage.shotsURL) }
                    Spacer()
                    Button("Open settings file") { NSWorkspace.shared.open(model.storage.settingsURL) }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}

/// Shows a shortcut; click it and press keys to record a new one.
struct ShortcutField: View {
    @ObservedObject var model: SettingsModel
    let path: WritableKeyPath<ShowtellCore.Settings, Shortcut>
    @StateObject private var recorder = ShortcutRecorder()

    private var isRecording: Bool { model.recording == path }

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? (recorder.hint ?? "Press the new shortcut…") : model.settings[keyPath: path].label)
                .frame(minWidth: 170)
                .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .onDisappear { if isRecording { stop() } }
    }

    private func start() {
        model.recording = path
        recorder.start { shortcut in
            if let shortcut { model.settings[keyPath: path] = shortcut }
            stop()
        }
    }

    private func stop() {
        recorder.stop()
        if model.recording == path { model.recording = nil }
    }
}

/// Listens to keys inside the Settings window (no permission needed there) for a new shortcut.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published var hint: String?
    private var monitor: Any?
    private var pendingTap: (name: String, at: Date)?
    private var done: ((Shortcut?) -> Void)?

    private static let modifierNames: [UInt16: String] = [
        58: "leftOption", 61: "rightOption", 59: "leftControl", 62: "rightControl",
        55: "leftCommand", 54: "rightCommand", 56: "leftShift", 60: "rightShift",
    ]
    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106]

    func start(done: @escaping (Shortcut?) -> Void) {
        stop()
        self.done = done
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            self.handle(event)
            return nil  // swallow keys while recording
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingTap = nil
        done = nil
        hint = nil
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .flagsChanged {
            guard let name = Self.modifierNames[event.keyCode] else { return }
            if ModifierTap.isDown(event.keyCode, event.modifierFlags) {
                // One modifier went down on its own: a tap if it comes back up with nothing else.
                pendingTap = [.option, .control, .command, .shift].contains(where: { mods == $0 }) ? (name, Date()) : nil
                hint = Shortcut.describe(modifiers: carbon(mods)) + "…"
            } else if let tap = pendingTap, tap.name == name, Date().timeIntervalSince(tap.at) < 1.0 {
                finish(.tap(name))
            } else {
                pendingTap = nil
                hint = mods.isEmpty ? nil : Shortcut.describe(modifiers: carbon(mods)) + "…"
            }
            return
        }
        pendingTap = nil
        if event.keyCode == 53, mods.isEmpty {  // Esc: keep the old shortcut
            finish(nil)
            return
        }
        guard !mods.isEmpty || Self.functionKeys.contains(event.keyCode) else {
            hint = "Add ⌃, ⌥, ⇧ or ⌘, or tap one modifier"
            return
        }
        finish(.chord(UInt32(event.keyCode), carbon(mods), Self.keyName(event)))
    }

    private func finish(_ shortcut: Shortcut?) {
        let done = self.done
        stop()
        done?(shortcut)
    }

    private func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= 0x100 }
        if flags.contains(.shift) { m |= 0x200 }
        if flags.contains(.option) { m |= 0x800 }
        if flags.contains(.control) { m |= 0x1000 }
        return m
    }

    private static func keyName(_ event: NSEvent) -> String {
        let named: [UInt16: String] = [
            49: "Space", 36: "Return", 48: "Tab", 51: "⌫", 117: "⌦", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 115: "Home", 119: "End",
            116: "Page Up", 121: "Page Down",
        ]
        if let name = named[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
