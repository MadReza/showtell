import AppKit
import AVFoundation
import ServiceManagement
import ShowtellCore
import SwiftUI

/// The Settings window: shortcuts, behaviour, permissions and your words, without editing JSON.
@MainActor
final class SettingsWindow {
    private let storage: Storage
    private var window: NSWindow?
    private var model: SettingsModel?
    private var poll: Timer?
    private weak var cleaner: TextCleaner?

    init(storage: Storage) {
        self.storage = storage
    }

    func show(settings: ShowtellCore.Settings, onChange: @escaping (ShowtellCore.Settings) -> Void, onRecording: @escaping (Bool) -> Void,
              cleaner: TextCleaner, onAskAccessibility: @escaping () -> Void) {
        self.cleaner = cleaner
        defer { watchPermissions() }
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Showtell Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model, cleaner: cleaner))
        window.center()
        self.window = window
        self.model = model
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Permissions may have changed.
    func refresh() { model?.refresh() }

    /// Permissions change in System Settings without telling us, so look again while the window is open.
    private func watchPermissions() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isVisible else {
                    timer.invalidate()
                    return
                }
                self.model?.refresh()
                self.cleaner?.objectWillChange.send()  // Apple Intelligence may have been switched on
            }
        }
    }
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
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
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

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Login items remember the app's path, so this copy should be the installed one.
    var isInstalled: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    func refresh() {
        if SMAppService.mainApp.status == .enabled { openAtLogin = true }
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
    @ObservedObject var cleaner: TextCleaner

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Start and send") { ShortcutField(model: model, path: \.startShortcut) }
                LabeledContent("Cancel a recording") { ShortcutField(model: model, path: \.cancelShortcut) }
                Text("Click a shortcut, then press the new one: a key with modifiers such as ⌃⌥Space, or tap a single modifier such as the left ⌥. Esc on its own works for cancelling. Press nothing for 2 seconds to keep the old one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle("Second press sends (presses Enter)", isOn: $model.settings.submitOnSecondPress)
                Toggle("Hide the bar while taking a screenshot (⌘⌃⇧3 / ⌘⌃⇧4)", isOn: $model.settings.hideDuringScreenshots)
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                if let error = model.loginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else if !model.isInstalled {
                    Text("This copy runs from \(Bundle.main.bundlePath). Install it with scripts/install.sh so login opens the right one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            tidySection
            Section("Permissions") {
                LabeledContent("Microphone") { Text(model.microphone).foregroundStyle(.secondary) }
                LabeledContent("Accessibility") {
                    if model.accessibilityAllowed {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Allow…") { model.onAskAccessibility?() }
                    }
                }
                if !model.accessibilityAllowed {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.needsAccessibility {
                            Text("Needed for single-modifier shortcuts and to hide the bar on ⌘⌃⇧4.")
                                .foregroundStyle(.orange)
                        }
                        Text("Already switched on for Showtell? That entry belongs to an older build: select it, remove it with −, then click Allow… again.")
                            .foregroundStyle(.secondary)
                        Button("Open Accessibility settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                    .font(.caption)
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

extension SettingsView {
    var tidySection: some View {
        Section {
            ModelRow(title: "Off", summary: "Send exactly what the speech recogniser wrote.", pros: nil, cons: nil,
                     selected: model.settings.cleanupModel == nil) {
                model.settings.cleanupModel = nil
            } trailing: { EmptyView() }
            ForEach(CleanupModel.all) { option in
                ModelRow(title: option.name, summary: option.summary, pros: option.pros, cons: option.cons,
                         selected: model.settings.cleanupModel == option.id) {
                    model.settings.cleanupModel = option.id
                    // "It will be downloaded for you": picking a model fetches it.
                    if cleaner.status(option) == .needsDownload { cleaner.download(option) }
                } trailing: {
                    ModelStatusView(option: option, cleaner: cleaner)
                }
            }
            if let picked = CleanupModel.named(model.settings.cleanupModel) {
                if case .unavailable(let reason) = cleaner.status(picked) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reason).foregroundStyle(.orange)
                        Button("Open Apple Intelligence settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                        }
                    }
                    .font(.caption)
                }
                if let error = cleaner.downloadErrors[picked.id] {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Tidy every message when I send it", isOn: $model.settings.cleanupOnSend)
                LabeledContent("Tidy up and review") { ShortcutField(model: model, path: \.cleanupShortcut) }
                Text("While talking, press \(model.settings.cleanupShortcut.label): Showtell stops listening and shows the tidied text in the bar. Press it again to switch back to your own words, then \(model.settings.startShortcut.label) to send. With \"Tidy every message\" on, sending tidies first; if anything looks wrong you get the text back to check.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Tidy up text")
        } footer: {
            Text("Fixes punctuation, filler words (um, you know), numbers and misheard words, and keeps your own words. Runs on this Mac. If a screenshot marker or one of your words goes missing, your original text is kept.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One choice in "Tidy up text": a radio button with what it's good and bad at.
struct ModelRow<Trailing: View>: View {
    let title: String
    let summary: String
    let pros: String?
    let cons: String?
    let selected: Bool
    let pick: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(summary).font(.caption).foregroundStyle(.secondary)
                if let pros { Label(pros, systemImage: "plus.circle").font(.caption).foregroundStyle(.green) }
                if let cons { Label(cons, systemImage: "minus.circle").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .padding(.vertical, 2)
    }
}

/// Ready, needs downloading (with its size), downloading (with progress), or why it can't be used.
struct ModelStatusView: View {
    let option: CleanupModel
    @ObservedObject var cleaner: TextCleaner

    var body: some View {
        switch cleaner.status(option) {
        case .ready:
            HStack(spacing: 6) {
                Label("Ready", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                    .font(.caption).foregroundStyle(.green)
                if option.downloadBytes != nil {
                    Button { cleaner.delete(option) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete the downloaded model")
                }
            }
        case .needsDownload:
            Button("Download \(Self.size(option.downloadBytes ?? 0))") { cleaner.download(option) }
                .controlSize(.small)
        case .downloading(let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction).frame(width: 80)
                Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { cleaner.cancelDownload(option) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Stop the download")
            }
        case .unavailable:
            Label("Not on", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
        recorder.start(allowPlainEsc: path == \.cancelShortcut) { shortcut in
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
    private var allowPlainEsc = false
    /// Gives up, keeping the old shortcut, after this long without a key.
    private let patience: TimeInterval = 2
    private var giveUp: DispatchWorkItem?

    private static let modifierNames: [UInt16: String] = [
        58: "leftOption", 61: "rightOption", 59: "leftControl", 62: "rightControl",
        55: "leftCommand", 54: "rightCommand", 56: "leftShift", 60: "rightShift",
    ]
    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106]

    func start(allowPlainEsc: Bool, done: @escaping (Shortcut?) -> Void) {
        stop()
        self.done = done
        self.allowPlainEsc = allowPlainEsc
        hint = nil
        waitAgain()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            self.handle(event)
            return nil  // swallow keys while recording
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        giveUp?.cancel()
        giveUp = nil
        pendingTap = nil
        done = nil
        hint = nil
    }

    private func waitAgain() {
        giveUp?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        giveUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + patience, execute: work)
    }

    private func handle(_ event: NSEvent) {
        waitAgain()
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
        // A plain Esc is fine for cancelling (only listened for while recording), not for starting.
        let plainEscOK = allowPlainEsc && event.keyCode == 53
        guard !mods.isEmpty || plainEscOK || Self.functionKeys.contains(event.keyCode) else {
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
