import AppKit
import Carbon.HIToolbox
import ShowtellCore

/// Ties the parts together: hotkey → bar + speech + clipboard screenshots → outbox → herdr pane.
@MainActor
final class AppController: NSObject, NSMenuDelegate {
    enum State { case idle, recording, finishing }

    private let storage = Storage()
    private var settings: Settings
    private let herdr = HerdrClient()
    private lazy var outbox = Outbox(transport: herdr)
    private let speech = SpeechEngine()
    private let hotKeys = HotKeys()
    private let clipboard = ClipboardWatcher()
    private let screenshotKeys = ScreenshotKeyMonitor()
    private let panel = OverlayPanel()
    private var statusItem: NSStatusItem!

    private var state = State.idle
    private var composer = Composer()
    private var recordingID = ""
    private var recordingStart = Date()
    private var speechRunning = false
    private var cancelKey: UInt32?
    private var ticker: Timer?
    private var reappearWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?

    private var model: OverlayModel { panel.model }

    override init() {
        try? storage.prepare()
        settings = storage.loadSettings()
        super.init()
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.badge.plus", accessibilityDescription: "Showtell")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusTitle()

        registerMainHotKey()
        model.onUserEdit = { [weak self] text in self?.userEdited(text) }
        clipboard.onImage = { [weak self] png in self?.screenshotArrived(png) }
        screenshotKeys.onScreenshotKeys = { [weak self] in self?.screenshotKeysPressed() }
        screenshotKeys.onEscape = { [weak self] in self?.panel.reappear() }
        speech.onState = { [weak self] _ in self?.refreshHint() }

        // Lets scripts and other tools drive Showtell: `showtell-cli toggle` / `showtell-cli cancel`.
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("dev.showtell.toggle"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        }
        center.addObserver(forName: .init("dev.showtell.cancel"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }

        Task { await speech.load() }
        if settings.hideDuringScreenshots, !ScreenshotKeyMonitor.isTrusted {
            ScreenshotKeyMonitor.askForPermission()
        }
    }

    // MARK: Hotkey

    private var hotKeyLabel: String { HotKeys.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers) }

    private func registerMainHotKey() {
        let ok = hotKeys.register(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers) { [weak self] in
            self?.toggle()
        }
        if ok == nil { flash(.error("\(hotKeyLabel) is taken by another app; change hotKeyCode in settings.json")) }
    }

    func toggle() {
        switch state {
        case .idle: startRecording()
        case .recording: Task { await finishAndSend() }
        case .finishing: break
        }
    }

    // MARK: Recording

    private func startRecording() {
        guard let target = settings.pinned else {
            flash(.error("Open a session first: click the menu-bar icon and pick a Claude session"))
            return
        }
        hideWork?.cancel()
        state = .recording
        composer = Composer()
        recordingID = Self.stamp()
        recordingStart = Date()
        model.targetName = target.name
        model.phase = .listening
        model.text = ""
        model.shots = []
        model.elapsed = 0
        refreshHint()
        panel.present()

        cancelKey = hotKeys.register(keyCode: UInt32(kVK_Delete), modifiers: settings.hotKeyModifiers) { [weak self] in
            self?.cancelRecording()
        }
        clipboard.start()
        if settings.hideDuringScreenshots { screenshotKeys.start() }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.elapsed = Date().timeIntervalSince(self?.recordingStart ?? Date()) }
        }

        if speech.state == .ready {
            let terms = storage.vocabulary(forRepoAt: target.cwd)
            speechRunning = true
            Task {
                do {
                    try await speech.start(terms: terms) { [weak self] text, ends, time in
                        DispatchQueue.main.async { self?.transcriptUpdated(text, ends, time) }
                    }
                } catch {
                    speechRunning = false
                    model.phase = .error("Microphone unavailable: \(error.localizedDescription)")
                }
            }
        }
        checkTargetStillThere(target)
    }

    private func transcriptUpdated(_ text: String, _ ends: [Double], _ time: Double) {
        guard state == .recording else { return }
        composer.updateTranscript(text, newWordEndTimes: ends, at: time)
        model.text = composer.render()
    }

    private func userEdited(_ text: String) {
        guard state == .recording else { return }
        composer.userEdited(text)
        model.text = text
    }

    private func screenshotArrived(_ png: Data) {
        guard state == .recording else { return }
        reappearWork?.cancel()
        let time = speechRunning ? speech.elapsed : Date().timeIntervalSince(recordingStart)
        let number = composer.shots.count + 1
        let url = storage.newShotURL(recording: recordingID, number: number)
        do { try png.write(to: url) } catch {
            model.phase = .error("Couldn't save screenshot: \(error.localizedDescription)")
            return
        }
        composer.addShot(url, at: time)
        if let image = NSImage(data: png) { model.shots.append((number, image)) }
        model.text = composer.render()
        panel.reappear()
    }

    private func screenshotKeysPressed() {
        guard state == .recording else { return }
        panel.vanish()
        let work = DispatchWorkItem { [weak self] in self?.panel.reappear() }  // shot cancelled or slow
        reappearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func finishAndSend() async {
        guard state == .recording, let target = settings.pinned else { return }
        state = .finishing
        stopCapture()
        if speechRunning {
            model.phase = .info("Finishing…")
            let final = await speech.stop()
            speechRunning = false
            composer.updateTranscript(final.text, newWordEndTimes: final.wordEnds, at: final.time)
            composer.finish(at: final.time)
            model.text = composer.render()
        }
        let rules = storage.replacementRules()
        let pieces = composer.pieces().map { piece -> Piece in
            if case .text(let s) = piece { return .text(Vocabulary.applyReplacements(s, rules)) }
            return piece
        }
        state = .idle  // you can start the next message while this one is delivered
        guard !pieces.isEmpty else { panel.dismiss(); return }
        saveLastMessage(composer.render())

        model.phase = .sending
        await outbox.setEventHandler { [weak self] event in
            DispatchQueue.main.async { self?.deliveryEvent(event) }
        }
        let result = await outbox.enqueue(pieces, to: target, submit: settings.submitOnSecondPress)
        switch result {
        case .success(let found):
            if found != settings.pinned, settings.pinned?.sessionID == found.sessionID {
                settings.pinned = found
                storage.save(settings)
            }
            if state == .idle { flash(.sent, for: 1.2) }
        case .failure(let error):
            if state == .idle {
                flash(.error("Not sent: \(error). Your text is in last-message.txt"), for: 8)
            }
        }
    }

    private func deliveryEvent(_ event: DeliveryEvent) {
        guard state == .idle else { return }
        if case .waitingForApproval(let name) = event {
            model.phase = .waiting("\(name) shows a dialog: waiting before pasting")
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        stopCapture()
        state = .idle
        if speechRunning { Task { await speech.cancel() } }
        speechRunning = false
        panel.dismiss()
    }

    private func stopCapture() {
        clipboard.stop()
        screenshotKeys.stop()
        ticker?.invalidate()
        reappearWork?.cancel()
        hotKeys.unregister(cancelKey)
        cancelKey = nil
        panel.reappear()
    }

    private func checkTargetStillThere(_ target: PinnedTarget) {
        Task {
            do {
                let agents = try await herdr.listAgents()
                if target.locate(in: agents) == nil, state == .recording {
                    model.phase = .error("\(target.name) isn't running in herdr any more: pick another session")
                }
            } catch {
                if state == .recording { model.phase = .error("herdr isn't reachable: \(error)") }
            }
        }
    }

    // MARK: Bar helpers

    private func refreshHint() {
        let send = settings.submitOnSecondPress ? "send" : "paste"
        var parts = ["\(hotKeyLabel) to \(send)", "\(HotKeys.describe(keyCode: 51, modifiers: settings.hotKeyModifiers)) to cancel", "⌘⌃⇧4 adds a screenshot"]
        switch speech.state {
        case .loading(let s): parts.insert(s, at: 0)
        case .failed(let s): parts.insert(s + " (type instead)", at: 0)
        default: break
        }
        model.hint = parts.joined(separator: "  ·  ")
    }

    private func flash(_ phase: OverlayModel.Phase, for seconds: Double = 4) {
        if state == .idle, phase != .sent {
            model.text = ""
            model.shots = []
        }
        model.phase = phase
        model.targetName = settings.pinned?.name ?? ""
        panel.present()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .idle else { return }
            self.panel.dismiss()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func saveLastMessage(_ text: String) {
        try? text.write(to: storage.root.appendingPathComponent("last-message.txt"), atomically: true, encoding: .utf8)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    // MARK: Menu

    private func updateStatusTitle() {
        statusItem.button?.title = settings.pinned.map { " " + $0.name } ?? ""
        statusItem.button?.imagePosition = .imageLeading
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let action = state == .recording ? "Send" : "Start talking"
        menu.addItem(item("\(action)   \(hotKeyLabel)", #selector(menuToggle)))
        menu.addItem(.separator())
        menu.addItem(header("Open a session"))

        do {
            let agents = try herdr.listAgentsNow().filter(\.isClaude)
            if agents.isEmpty { menu.addItem(disabled("No Claude sessions in herdr")) }
            for agent in agents {
                let mi = item("\(agent.folderName) — \(agent.displayName)", #selector(pick(_:)))
                mi.representedObject = agent.paneID
                let pinned = settings.pinned.map { $0.locate(in: [agent]) != nil } ?? false
                mi.state = pinned ? .on : .off
                mi.toolTip = "\(agent.paneID) · \(agent.status.rawValue) · \(agent.foregroundCwd ?? agent.cwd ?? "")"
                menu.addItem(mi)
            }
            if let p = settings.pinned, p.locate(in: agents) == nil {
                menu.addItem(disabled("\(p.name) (not running)"))
            }
        } catch {
            menu.addItem(disabled("herdr isn't running"))
        }

        menu.addItem(.separator())
        let submit = item("Second press sends (Enter)", #selector(toggleSubmit))
        submit.state = settings.submitOnSecondPress ? .on : .off
        menu.addItem(submit)
        let hide = item("Hide bar during screenshots", #selector(toggleHide))
        hide.state = settings.hideDuringScreenshots ? .on : .off
        menu.addItem(hide)
        if settings.hideDuringScreenshots, !ScreenshotKeyMonitor.isTrusted {
            menu.addItem(item("Allow Accessibility (to notice ⌘⇧4)…", #selector(askAccessibility)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Edit your words…", #selector(editVocabulary)))
        menu.addItem(item("Edit replacements…", #selector(editReplacements)))
        menu.addItem(item("Open settings.json…", #selector(editSettings)))
        menu.addItem(item("Show screenshots folder", #selector(showShots)))
        menu.addItem(.separator())
        menu.addItem(disabled(speechStatus))
        menu.addItem(item("Quit Showtell", #selector(quit)))
    }

    private var speechStatus: String {
        switch speech.state {
        case .notLoaded: return "Speech: not loaded"
        case .loading(let s): return "Speech: \(s)"
        case .ready: return "Speech: ready (Parakeet, on this Mac)"
        case .failed(let s): return "Speech: \(s)"
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        return disabled(title)
    }

    @objc private func menuToggle() { toggle() }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? String,
              let agent = try? herdr.listAgentsNow().first(where: { $0.paneID == pane }) else { return }
        settings.pinned = PinnedTarget(agent: agent)
        storage.save(settings)
        updateStatusTitle()
        flash(.info("Opened \(agent.displayName) · \(hotKeyLabel) to start talking"), for: 2.5)
    }

    @objc private func toggleSubmit() {
        settings.submitOnSecondPress.toggle()
        storage.save(settings)
    }

    @objc private func toggleHide() {
        settings.hideDuringScreenshots.toggle()
        storage.save(settings)
        if settings.hideDuringScreenshots, !ScreenshotKeyMonitor.isTrusted { ScreenshotKeyMonitor.askForPermission() }
    }

    @objc private func askAccessibility() { ScreenshotKeyMonitor.askForPermission() }
    @objc private func editVocabulary() { NSWorkspace.shared.open(storage.vocabularyURL) }
    @objc private func editReplacements() { NSWorkspace.shared.open(storage.replacementsURL) }
    @objc private func editSettings() {
        storage.save(settings)
        NSWorkspace.shared.open(storage.settingsURL)
    }
    @objc private func showShots() { NSWorkspace.shared.open(storage.shotsURL) }
    @objc private func quit() { NSApp.terminate(nil) }
}
