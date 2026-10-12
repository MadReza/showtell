import AppKit
import Carbon.HIToolbox
import os
import ShowtellCore

/// `log stream --predicate 'subsystem == "dev.showtell"'` shows what happened to each message
/// (states and word counts, never the words).
let log = Logger(subsystem: "dev.showtell", category: "app")

/// Ties the parts together: hotkey → bar + speech + clipboard screenshots → outbox → herdr pane.
@MainActor
final class AppController: NSObject, NSMenuDelegate {
    /// reviewing: listening stopped and the text tidied, waiting for you to send it.
    enum State { case idle, recording, finishing, reviewing }

    private let storage = Storage()
    private var settings: Settings
    private let sessions = AllSessions()
    private var terminalSessions: [HerdrAgent] = []
    private lazy var outbox = Outbox(transport: sessions)
    private var speech: SpeechEngine!
    private var speechState = SpeechEngine.State.notLoaded
    private let hotKeys = HotKeys()
    private let clipboard = ClipboardWatcher()
    private let screenshotKeys = ScreenshotKeyMonitor()
    private var startBinding: ShortcutBinding?
    private var cancelBinding: ShortcutBinding?
    private var cleanupBinding: ShortcutBinding?
    /// The Send checkbox and session shortcuts, while recording or reviewing.
    private var barBindings: [ShortcutBinding] = []
    private(set) lazy var cleaner = TextCleaner(storage: storage)
    /// The text before and after the last clean-up, so the shortcut can switch between them.
    private var beforeCleanup: String?
    private var afterCleanup: String?
    private lazy var settingsWindow = SettingsWindow(storage: storage)
    private var trustTimer: Timer?
    private let panel = OverlayPanel()
    private var statusItem: NSStatusItem!

    private var state = State.idle
    private var composer = Composer()
    private var recordingID = ""
    private var recordingStart = Date()
    /// Bumped on every recording, so late updates from an older one are ignored.
    private var generation = 0
    private var speechStart: Task<Bool, Never>?
    private var speechListening = false
    private var pendingSends = 0
    private var ticker: Timer?
    private var reappearWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?

    private var model: OverlayModel { panel.model }

    /// A destination said at the start or end of this message; it wins over the open session
    /// for this message only. A click or ⌃⌥↑↓ dismisses it.
    private var spokenRoute: Routing.Route?
    private var routeDismissed = false
    private var routeAgents: [String: HerdrAgent] = [:]
    private var routeCandidates: [Routing.Candidate] = []

    override init() {
        try? storage.prepare()
        settings = storage.loadSettings()
        super.init()
        speech = SpeechEngine { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.speechState = state
                if self.state == .recording { self.refreshHint() }
            }
        }
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
        model.onShowSessions = { [weak self] in self?.showSessionsInBar() }
        model.onToggleSubmit = { [weak self] in self?.toggleSendInBar() }
        clipboard.onImage = { [weak self] png in self?.screenshotArrived(png) }
        screenshotKeys.onScreenshotKeys = { [weak self] in self?.screenshotKeysPressed() }
        screenshotKeys.onEscape = { [weak self] in self?.screenshotOver() }

        // Lets scripts and other tools drive Showtell: `showtell-cli toggle` / `showtell-cli cancel`.
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("dev.showtell.toggle"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        }
        center.addObserver(forName: .init("dev.showtell.cancel"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
        center.addObserver(forName: .init("dev.showtell.tidy"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanupPressed() }
        }
        center.addObserver(forName: .init("dev.showtell.settings"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }
        center.addObserver(forName: .init("dev.showtell.submit"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleSendInBar() }
        }
        center.addObserver(forName: .init("dev.showtell.next"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.moveTarget(by: 1) }
        }
        center.addObserver(forName: .init("dev.showtell.previous"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.moveTarget(by: -1) }
        }
        center.addObserver(forName: .init("dev.showtell.target"), object: nil, queue: .main) { [weak self] note in
            let target = note.object as? String
            MainActor.assumeIsolated {
                if target == "cursor" {
                    self?.pickCursor()
                } else if let target {
                    let mi = NSMenuItem()
                    mi.representedObject = target
                    self?.pick(mi)
                }
            }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }

        Task { await speech.load() }
        _ = sessionsNow()  // look up tmux and iTerm2 sessions early, so the first menu shows them
        if needsAccessibility, !ScreenshotKeyMonitor.isTrusted {
            ScreenshotKeyMonitor.askForPermission()
            watchForTrust()
        }
    }

    /// Key monitors added before Accessibility is granted may stay deaf, so add them again once it is.
    private func watchForTrust() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, ScreenshotKeyMonitor.isTrusted else { return }
                timer.invalidate()
                self.startBinding?.refresh()
                self.cancelBinding?.refresh()
                self.cleanupBinding?.refresh()
                self.barBindings.forEach { $0.refresh() }
                self.settingsWindow.refresh()
                if self.state == .recording, self.settings.hideDuringScreenshots { self.screenshotKeys.start() }
                self.flash(.info("Accessibility allowed · \(self.hotKeyLabel) to start talking"), for: 2.5)
            }
        }
    }

    // MARK: Hotkey

    private var hotKeyLabel: String { settings.startShortcut.label }
    private var needsAccessibility: Bool {
        settings.startShortcut.tap != nil || settings.cancelShortcut.tap != nil || settings.hideDuringScreenshots
            || settings.insertAtCursor || (cleanupChoice != nil && settings.cleanupShortcut.tap != nil)
            || [settings.sendToggleShortcut, settings.nextTargetShortcut, settings.previousTargetShortcut].contains { $0.tap != nil }
    }

    private func registerMainHotKey() {
        startBinding?.stop()
        startBinding = ShortcutBinding(settings.startShortcut, hotKeys: hotKeys) { [weak self] in self?.toggle() }
        if startBinding?.ok == false { flash(.error("\(hotKeyLabel) is taken by another app; pick another in Settings")) }
    }

    /// Settings changed in the Settings window: save and listen for the new shortcuts.
    private func apply(_ new: Settings) {
        let old = settings
        settings = new
        settings.pinned = old.pinned  // the window doesn't edit the destination; keep the latest
        settings.insertAtCursor = old.insertAtCursor
        storage.save(settings)
        if new.startShortcut != old.startShortcut { registerMainHotKey() }
        if new.cancelShortcut != old.cancelShortcut, state == .recording || state == .reviewing { bindCancel() }
        if state == .recording || state == .reviewing {
            bindCleanup()
            bindBarKeys()
            updateBarControls()
        }
        if new.cleanupModel != old.cleanupModel, let model = cleanupChoice { cleaner.prepare(model) }
        if needsAccessibility, !ScreenshotKeyMonitor.isTrusted { watchForTrust() }
    }

    /// The Settings window records a new shortcut: the current ones must not fire meanwhile.
    private func pauseShortcuts(_ paused: Bool) {
        if paused {
            startBinding?.stop()
            cancelBinding?.stop()
            cleanupBinding?.stop()
            unbindBarKeys()
        } else {
            registerMainHotKey()
            if state == .recording || state == .reviewing {
                bindCancel()
                bindCleanup()
                bindBarKeys()
            }
        }
    }

    private func bindCancel() {
        cancelBinding?.stop()
        cancelBinding = ShortcutBinding(settings.cancelShortcut, hotKeys: hotKeys) { [weak self] in
            self?.cancelRecording()
        }
    }

    /// The clean-up shortcut, listened for only while recording or reviewing.
    private func bindCleanup() {
        cleanupBinding?.stop()
        cleanupBinding = nil
        guard cleanupChoice != nil else { return }
        cleanupBinding = ShortcutBinding(settings.cleanupShortcut, hotKeys: hotKeys) { [weak self] in
            self?.cleanupPressed()
        }
    }

    private func bindBarKeys() {
        unbindBarKeys()
        barBindings = [
            ShortcutBinding(settings.sendToggleShortcut, hotKeys: hotKeys) { [weak self] in self?.toggleSendInBar() },
            ShortcutBinding(settings.nextTargetShortcut, hotKeys: hotKeys) { [weak self] in self?.moveTarget(by: 1) },
            ShortcutBinding(settings.previousTargetShortcut, hotKeys: hotKeys) { [weak self] in self?.moveTarget(by: -1) },
        ]
        for (binding, shortcut) in zip(barBindings, [settings.sendToggleShortcut, settings.nextTargetShortcut, settings.previousTargetShortcut])
        where !binding.ok {
            log.error("\(shortcut.label, privacy: .public) is taken by another app")
        }
    }

    private func unbindBarKeys() {
        barBindings.forEach { $0.stop() }
        barBindings = []
    }

    /// The Send checkbox or its shortcut: this message presses Enter or not, and so do the next
    /// ones (it is the "Second press sends" setting).
    private func toggleSendInBar() {
        guard state != .idle, !sendsToCursor else { return }
        settings.submitOnSecondPress.toggle()
        storage.save(settings)
        settingsWindow.update(settings)
        updateBarControls()
    }

    /// The session shortcuts: this message, and the next ones, go to the next or previous entry of
    /// the session list (the cursor first, as in the menu).
    private func moveTarget(by step: Int) {
        guard state != .idle else { return }
        dismissSpokenRoute()
        let agents = sessionsNow()
        let count = agents.count + 1
        let current = settings.insertAtCursor
            ? 0 : settings.pinned.flatMap { p in agents.firstIndex { p.locate(in: [$0]) != nil } }.map { $0 + 1 }
        let next = ((current ?? (step > 0 ? 0 : 1)) + step + count) % count
        if next == 0 {
            settings.insertAtCursor = true
        } else {
            settings.pinned = PinnedTarget(agent: agents[next - 1])
            settings.insertAtCursor = false
        }
        storage.save(settings)
        updateStatusTitle()
        updateBarControls()
    }

    /// The Send checkbox, the destination and the hint, after any of them changed.
    private func updateBarControls() {
        model.submit = settings.submitOnSecondPress
        model.showsSubmit = !sendsToCursor
        model.routeSpoken = spokenRoute != nil
        model.submitShortcut = settings.sendToggleShortcut.label
        model.targetShortcuts = Self.pairLabel(settings.previousTargetShortcut, settings.nextTargetShortcut)
        model.targetName = targetLabel
        if state == .reviewing { model.hint = reviewHint() } else if state == .recording { refreshHint() }
    }

    /// A destination said at the start or end of the message: shown, with a pulse, as soon as it
    /// is heard; used for this message only.
    private func evaluateRoute() {
        guard settings.spokenRouting, !routeDismissed else { return }
        let before = spokenRoute?.target
        switch Routing.find(in: composer.render(), candidates: routeCandidates) {
        case .route(let route):
            spokenRoute = route
            model.routeNote = "heard “\(route.phrase)”"
            model.routeWarning = false
        case .unclear(let why):
            spokenRoute = nil
            model.routeNote = why + " · not switching"
            model.routeWarning = true
        case .none:
            spokenRoute = nil
            model.routeNote = ""
        }
        if spokenRoute?.target != before {
            model.targetPulse += 1
            log.info("spoken route: \(self.spokenRoute == nil ? "none" : self.sendsToCursor ? "cursor" : "session", privacy: .public)")
        }
        updateBarControls()
    }

    /// Sessions that can be named, looked up when a recording starts.
    private func loadRouteCandidates() {
        let agents = sessionsNow()
        routeAgents = Dictionary(agents.map { ($0.paneID, $0) }, uniquingKeysWith: { a, _ in a })
        routeCandidates = agents.map { agent in
            let title = agent.displayName.components(separatedBy: " · ").first ?? agent.displayName
            return Routing.Candidate(id: agent.paneID, names: [agent.folderName, title])
        }
    }

    /// A click or a shortcut picked the destination: it beats anything said in this message.
    private func dismissSpokenRoute() {
        guard state != .idle else { return }
        routeDismissed = true
        spokenRoute = nil
        model.routeNote = ""
        model.targetPulse += 1
    }

    /// "⌃⌥↑↓" for the usual pair, otherwise both shortcuts.
    static func pairLabel(_ up: Shortcut, _ down: Shortcut) -> String {
        if up.tap == nil, down.tap == nil, up.modifiers == down.modifiers, up.keyName == "↑", down.keyName == "↓" {
            return Shortcut.describe(modifiers: up.modifiers) + "↑↓"
        }
        return "\(up.label) \(down.label)"
    }

    /// The model picked in Settings, if any.
    private var cleanupChoice: CleanupModel? { CleanupModel.named(settings.cleanupModel) }

    func toggle() {
        switch state {
        case .idle: startRecording()
        case .recording: Task { await finishAndSend() }
        case .reviewing: Task { await deliver() }
        case .finishing: break
        }
    }

    // MARK: Recording

    private func startRecording() {
        guard settings.insertAtCursor || settings.pinned != nil else {
            flash(.error("Open a session first: click the menu-bar icon and pick a Claude session"))
            return
        }
        hideWork?.cancel()
        log.info("recording; speech \(String(describing: self.speechState), privacy: .public)")
        state = .recording
        generation += 1
        composer = Composer()
        beforeCleanup = nil
        afterCleanup = nil
        spokenRoute = nil
        routeDismissed = false
        model.routeNote = ""
        if settings.spokenRouting { loadRouteCandidates() }
        recordingID = Self.stamp()
        recordingStart = Date()
        model.phase = .listening
        model.text = ""
        model.shots = []
        model.elapsed = 0
        updateBarControls()
        panel.present()

        bindCancel()
        bindCleanup()
        bindBarKeys()
        if let model = cleanupChoice { cleaner.prepare(model) }
        clipboard.start()
        if settings.hideDuringScreenshots { screenshotKeys.start() }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.elapsed = Date().timeIntervalSince(self?.recordingStart ?? Date()) }
        }

        speechListening = false
        speechStart = nil
        if speechState == .ready {
            let terms = storage.vocabulary(forRepoAt: repoPath)
            let gen = generation
            let speech = speech!
            speechStart = Task { [weak self] in
                guard let self else { return false }
                do {
                    try await speech.start(terms: terms) { [weak self] text, ends, time in
                        DispatchQueue.main.async { self?.transcriptUpdated(text, ends, time, generation: gen) }
                    }
                    if gen == generation { speechListening = true }
                    return true
                } catch {
                    if gen == generation, state == .recording {
                        model.phase = .error("Microphone unavailable: \(error.localizedDescription). You can still type.")
                    }
                    return false
                }
            }
        }
        if !settings.insertAtCursor, let target = settings.pinned { checkTargetStillThere(target) }
    }

    private func transcriptUpdated(_ text: String, _ ends: [Double], _ time: Double, generation gen: Int) {
        guard gen == generation, state != .idle else { return }
        composer.updateTranscript(text, newWordStartTimes: ends, at: time)
        model.text = composer.render()
        evaluateRoute()
    }

    private func userEdited(_ text: String) {
        guard state != .idle else { return }
        composer.userEdited(text)
        model.text = text
    }

    private func screenshotArrived(_ png: Data) {
        guard state == .recording else { return }
        reappearWork?.cancel()
        // The speech clock restarts when the microphone starts; until then use wall time.
        let time = speechListening ? speech.captured : Date().timeIntervalSince(recordingStart)
        let number = composer.shots.count + 1
        let url = storage.newShotURL(recording: recordingID, number: number)
        do { try png.write(to: url) } catch {
            model.phase = .error("Couldn't save screenshot: \(error.localizedDescription)")
            return
        }
        composer.addShot(url, at: time)
        if let image = NSImage(data: png) { model.shots.append((number, image)) }
        model.text = composer.render()
        screenshotOver()
    }

    /// ⌘⌃⇧3/4 copy to the clipboard: hide until the shot arrives. The file variants (no ⌃) need no
    /// hiding: the bar is excluded from captures and nothing would bring it back.
    private func screenshotKeysPressed() {
        guard state == .recording else { return }
        panel.vanish()
        // A plain-Esc cancel shortcut would swallow the Esc that aborts the screenshot selection.
        if settings.cancelShortcut == .chord(53, 0, "Esc") {
            cancelBinding?.stop()
            cancelBinding = nil
        }
        let work = DispatchWorkItem { [weak self] in self?.screenshotOver() }  // shot cancelled or slow
        reappearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    /// The screenshot arrived or was abandoned: show the bar and listen for the cancel shortcut again.
    private func screenshotOver() {
        reappearWork?.cancel()
        panel.reappear()
        if state == .recording, cancelBinding == nil { bindCancel() }
    }

    /// Stops listening and puts the final transcript in the bar. False if the recording was
    /// cancelled meanwhile.
    private func finishListening() async -> Bool {
        state = .finishing
        stopCapture()
        let gen = generation
        if let speechStart, await speechStart.value {
            model.phase = .info("Finishing…")
            let final = await speech.stop()
            if gen == generation {
                composer.updateTranscript(final.text, newWordStartTimes: final.wordStarts, at: final.time)
                composer.finish(at: final.time)
                model.text = composer.render()
                log.info("listening stopped: \(Cleanup.wordCount(self.model.text)) words")
                evaluateRoute()
                if let route = spokenRoute { setText(route.remaining) }  // the phrase isn't for Claude
            }
        }
        speechStart = nil
        speechListening = false
        return gen == generation
    }

    private func finishAndSend() async {
        guard state == .recording else { return }
        guard await finishListening() else { return }
        if settings.cleanupOnSend, cleanupChoice != nil {
            let gen = generation
            if let problem = await cleanUp() {
                guard gen == generation else { return }
                // Don't send something you haven't seen: show your text and let you decide.
                review(note: "Kept your text (\(problem))")
                return
            }
            guard gen == generation else { return }
        }
        await deliver()
    }

    /// The clean-up shortcut: while recording, stop listening and show the tidied text to check;
    /// while reviewing, switch between your text and the tidied one.
    private func cleanupPressed() {
        switch state {
        case .recording:
            Task {
                guard await finishListening() else { return }
                let gen = generation
                let problem = await cleanUp()
                guard gen == generation else { return }
                review(note: problem.map { "Kept your text (\($0))" })
            }
        case .reviewing:
            if let after = afterCleanup, let before = beforeCleanup, model.text == after {
                setText(before)
                review(note: "Your original text")
            } else if let after = afterCleanup, let before = beforeCleanup, model.text == before {
                setText(after)
                review(note: nil)
            } else {
                state = .finishing
                Task {
                    let gen = generation
                    let problem = await cleanUp()
                    guard gen == generation else { return }
                    review(note: problem.map { "Kept your text (\($0))" })
                }
            }
        default:
            break
        }
    }

    /// Tidies the text in the bar with the model picked in Settings. Returns why not, if it couldn't.
    private func cleanUp() async -> String? {
        guard let choice = cleanupChoice else { return "no model picked in Settings" }
        let terms = storage.vocabulary(forRepoAt: repoPath).map(\.text)
        let rules = storage.replacementRules() + terms.map { ($0, $0) }
        let original = Vocabulary.applyReplacements(composer.render(), rules)
        guard Cleanup.wordCount(original) > 0 else { return "nothing heard yet" }
        model.phase = .info("Tidying up with \(choice.name)…")
        let gen = generation
        let started = Date()
        let result = await cleaner.clean(original, terms: terms, with: choice)
        log.info("tidy with \(choice.id, privacy: .public): \(String(describing: result.map { Cleanup.wordCount($0) }), privacy: .public) in \(Date().timeIntervalSince(started)) s")
        guard gen == generation else { return "cancelled" }
        switch result {
        case .success(let cleaned):
            beforeCleanup = original
            afterCleanup = cleaned
            setText(cleaned)
            return nil
        case .failure(let failure):
            return failure.description
        }
    }

    private func setText(_ text: String) {
        composer.userEdited(text)
        model.text = text
    }

    /// Listening has stopped; the bar waits for you to check the text and send it.
    private func review(note: String?) {
        state = .reviewing
        model.phase = .info(note ?? "Tidied · check it, then send")
        model.hint = reviewHint()
        if cancelBinding == nil { bindCancel() }
        if cleanupBinding == nil { bindCleanup() }
        if barBindings.isEmpty { bindBarKeys() }
    }

    private func reviewHint() -> String {
        let send = sendsToCursor ? "insert" : settings.submitOnSecondPress ? "send" : "paste"
        var parts = ["\(hotKeyLabel) to \(send)", "\(settings.cancelShortcut.label) to cancel"]
        if afterCleanup != nil { parts.append("\(settings.cleanupShortcut.label) switches to \(model.text == afterCleanup ? "your original" : "the tidied text")") }
        return parts.joined(separator: "  ·  ")
    }

    /// Sends what the bar shows to the open session, or inserts it at the cursor.
    private func deliver() async {
        guard state == .finishing || state == .reviewing else { return }
        cancelBinding?.stop()
        cancelBinding = nil
        cleanupBinding?.stop()
        cleanupBinding = nil
        unbindBarKeys()
        // Replacements, then each of your terms in the case you wrote it ("Herdr" → "herdr").
        let rules = storage.replacementRules() + storage.vocabulary(forRepoAt: repoPath).map { ($0.text, $0.text) }
        let pieces = composer.pieces().map { piece -> Piece in
            if case .text(let s) = piece { return .text(Vocabulary.applyReplacements(s, rules)) }
            return piece
        }
        let rendered = composer.render()
        let id = recordingID
        let toCursor = sendsToCursor, sendTo = sendTarget, routed = spokenRoute != nil
        defer { if state == .idle { spokenRoute = nil } }  // a new recording has its own
        if routed, settings.spokenRouteSticks {
            // The named session becomes the open one, as if picked from the menu.
            settings.insertAtCursor = toCursor
            if !toCursor, let sendTo { settings.pinned = sendTo }
            storage.save(settings)
            updateStatusTitle()
        }
        state = .idle  // you can start the next message while this one is delivered
        log.info("deliver: \(pieces.count) pieces")
        guard !pieces.isEmpty else { panel.dismiss(); return }
        saveLastMessage(rendered)

        if toCursor {
            panel.dismiss()  // hand the keyboard back to the app with the cursor
            if await CursorInserter.insert(pieces) {
                if state == .idle { flash(.sent, for: 1.0) }
            } else {
                flash(.info("Copied — press ⌘V to paste (allow Accessibility to paste for you)"), for: 5)
            }
            return
        }
        guard let target = sendTo else {
            flash(.error("Open a session first: click the menu-bar icon and pick a Claude session"))
            return
        }
        model.phase = .sending
        pendingSends += 1
        await outbox.setEventHandler { [weak self] event in
            DispatchQueue.main.async { self?.deliveryEvent(event) }
        }
        let result = await outbox.enqueue(pieces, to: target, submit: settings.submitOnSecondPress)
        pendingSends -= 1
        switch result {
        case .success(let found):
            if !routed, found != settings.pinned, settings.pinned?.sessionID == found.sessionID {
                settings.pinned = found
                storage.save(settings)
            }
            log.info("sent")
            if state == .idle, pendingSends == 0 { flash(.sent, for: 1.2) }
        case .failure(let error):
            log.error("not sent: \(String(describing: error), privacy: .public)")
            let file = storage.root.appendingPathComponent("unsent-\(id).txt")
            try? rendered.write(to: file, atomically: true, encoding: .utf8)
            let message = "Not sent: \(error). Saved to \(file.lastPathComponent)"
            if state == .idle {
                flash(.error(message), for: 8)
            } else {
                model.hint = "⚠ Previous message — \(message)"  // don't disturb the recording
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
        guard state == .recording || state == .reviewing else { return }
        stopCapture()
        state = .idle
        spokenRoute = nil
        generation += 1
        let start = speechStart
        speechStart = nil
        speechListening = false
        if let start {
            let speech = speech!
            Task { if await start.value { await speech.cancel() } }
        }
        panel.dismiss()
    }

    private func stopCapture() {
        clipboard.stop()
        screenshotKeys.stop()
        ticker?.invalidate()
        reappearWork?.cancel()
        cancelBinding?.stop()
        cancelBinding = nil
        cleanupBinding?.stop()
        cleanupBinding = nil
        unbindBarKeys()
        panel.reappear()
    }

    private func checkTargetStillThere(_ target: PinnedTarget) {
        Task {
            do {
                let agents = try await sessions.listAgents()
                if target.locate(in: agents) == nil, state == .recording {
                    model.phase = .error("\(target.name) isn't running any more: pick another session")
                }
            } catch {
                if state == .recording { model.phase = .error("Sessions can't be listed: \(error)") }
            }
        }
    }

    // MARK: Bar helpers

    private func refreshHint() {
        let send = sendsToCursor ? "insert" : settings.submitOnSecondPress ? "send" : "paste"
        var parts = ["\(hotKeyLabel) to \(send)", "\(settings.cancelShortcut.label) to cancel", "⌘⌃⇧4 adds a screenshot"]
        if cleanupChoice != nil { parts.insert("\(settings.cleanupShortcut.label) to tidy up", at: 2) }
        switch speechState {
        case .loading(let s): parts.insert(s, at: 0)
        case .failed(let s): parts.insert(s + " (type instead)", at: 0)
        default: break
        }
        model.hint = parts.joined(separator: "  ·  ")
    }

    private func flash(_ phase: OverlayModel.Phase, for seconds: Double = 4) {
        guard state == .idle else { return }  // never cover a recording
        if phase != .sent {
            model.text = ""
            model.shots = []
        }
        model.hint = ""
        model.phase = phase
        model.targetName = targetLabel
        model.showsSubmit = false
        model.targetShortcuts = ""
        model.routeNote = ""
        panel.present()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .idle, self.pendingSends == 0 || phase != .sent else { return }
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
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }

    // MARK: Menu

    private func updateStatusTitle() {
        statusItem.button?.title = statusLabel.isEmpty ? "" : " " + statusLabel
        statusItem.button?.imagePosition = .imageLeading
    }

    /// The session list as a drop-down under the mouse, from the name in the bar.
    private func showSessionsInBar() {
        let menu = NSMenu()
        addSessionItems(to: menu)
        guard let view = panel.contentView else { return }
        let point = view.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let action = state == .recording || state == .reviewing ? "Send" : "Start talking"
        menu.addItem(item("\(action)   \(hotKeyLabel)", #selector(menuToggle)))
        menu.addItem(.separator())
        menu.addItem(header("Open a session"))

        addSessionItems(to: menu)

        menu.addItem(.separator())
        let submit = item("Second press sends (Enter)", #selector(toggleSubmit))
        submit.state = settings.submitOnSecondPress ? .on : .off
        menu.addItem(submit)
        let hide = item("Hide bar during screenshots", #selector(toggleHide))
        hide.state = settings.hideDuringScreenshots ? .on : .off
        menu.addItem(hide)
        if needsAccessibility, !ScreenshotKeyMonitor.isTrusted {
            menu.addItem(item("Allow Accessibility (for shortcuts and ⌘⌃⇧4)…", #selector(askAccessibility)))
        }
        menu.addItem(.separator())
        let prefs = item("Settings…", #selector(openSettings))
        prefs.keyEquivalent = ","
        menu.addItem(prefs)
        menu.addItem(item("Show screenshots folder", #selector(showShots)))
        menu.addItem(.separator())
        menu.addItem(disabled(speechStatus))
        menu.addItem(item("Quit Showtell", #selector(quit)))
    }

    private func addSessionItems(to menu: NSMenu) {
        let cursor = item("Insert at the cursor", #selector(pickCursor))
        cursor.state = settings.insertAtCursor ? .on : .off
        cursor.toolTip = "Paste into whatever app you are typing in, without pressing Enter"
        menu.addItem(cursor)
        let agents = sessionsNow()
        if agents.isEmpty { menu.addItem(disabled("No Claude sessions in herdr, tmux or iTerm2")) }
        do {
            for agent in agents {
                let mi = item("\(agent.folderName) — \(agent.displayName)", #selector(pick(_:)))
                mi.representedObject = agent.paneID
                let pinned = settings.pinned.map { $0.locate(in: [agent]) != nil } ?? false
                mi.state = pinned && !settings.insertAtCursor ? .on : .off
                mi.toolTip = "\(agent.paneID) · \(agent.status.rawValue) · \(agent.foregroundCwd ?? agent.cwd ?? "")"
                menu.addItem(mi)
            }
            if let p = settings.pinned, p.locate(in: agents) == nil {
                menu.addItem(disabled("\(p.name) (not running)"))
            }
        }
        if settings.spokenRouting {
            let name = agents.first?.folderName ?? "showtell"
            menu.addItem(.separator())
            menu.addItem(disabled(settings.spokenRouteSticks ? "Or say it:" : "Or say it, for one message:"))
            menu.addItem(disabled("   “For the \(name) session, …”   “Send to \(name): …”"))
            menu.addItem(disabled("   “… this should go to \(name)”   “… paste it at the cursor”"))
        }
    }

    /// Sessions for a menu, built on the spot: herdr answers in milliseconds, while tmux and
    /// iTerm2 (an AppleScript round trip, and a permission prompt the first time) are looked up in
    /// the background and shown from the last lookup.
    private func sessionsNow() -> [HerdrAgent] {
        let terminals = sessions.terminals
        Task { [weak self] in
            let found = await Task.detached { terminals.listNow() }.value
            self?.terminalSessions = found
        }
        return AllSessions.merge((try? sessions.herdr.listAgentsNow()) ?? [], terminalSessions).filter(\.isClaude)
    }

    private var speechStatus: String {
        switch speechState {
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
              let agent = sessionsNow().first(where: { $0.paneID == pane }) else { return }
        dismissSpokenRoute()
        settings.pinned = PinnedTarget(agent: agent)
        settings.insertAtCursor = false
        storage.save(settings)
        updateStatusTitle()
        if state == .idle {
            flash(.info("Opened \(agent.displayName) · \(hotKeyLabel) to start talking"), for: 2.5)
        } else {
            updateBarControls()  // this message goes to the new session
        }
    }

    @objc private func pickCursor() {
        dismissSpokenRoute()
        settings.insertAtCursor = true
        storage.save(settings)
        updateStatusTitle()
        if state == .idle {
            flash(.info("Inserting at the cursor · \(hotKeyLabel) to start talking"), for: 2.5)
        } else {
            updateBarControls()
        }
    }

    /// Where this message goes: a spoken destination, else the open session or the cursor.
    private var sendsToCursor: Bool {
        if let route = spokenRoute { return route.target == .cursor }
        return settings.insertAtCursor
    }
    private var sendTarget: PinnedTarget? {
        if case .session(let id)? = spokenRoute?.target, let agent = routeAgents[id] { return PinnedTarget(agent: agent) }
        return settings.pinned
    }
    /// Where the message goes, as shown in the bar.
    private var targetLabel: String { sendsToCursor ? "Cursor" : sendTarget?.name ?? "" }
    /// The open session, as shown in the menu bar.
    private var statusLabel: String { settings.insertAtCursor ? "Cursor" : settings.pinned?.name ?? "" }
    /// The repo whose `.github/dictation.md` adds words: the open session's, unless inserting at the cursor.
    private var repoPath: String? { settings.insertAtCursor ? nil : settings.pinned?.cwd }

    @objc private func toggleSubmit() {
        var s = settings
        s.submitOnSecondPress.toggle()
        apply(s)
        settingsWindow.update(settings)
    }

    @objc private func toggleHide() {
        var s = settings
        s.hideDuringScreenshots.toggle()
        apply(s)
        if settings.hideDuringScreenshots, !ScreenshotKeyMonitor.isTrusted { ScreenshotKeyMonitor.askForPermission() }
    }

    @objc private func askAccessibility() {
        ScreenshotKeyMonitor.askForPermission()
        watchForTrust()
    }
    @objc private func openSettings() {
        settingsWindow.show(
            settings: settings,
            onChange: { [weak self] new in self?.apply(new) },
            onRecording: { [weak self] recording in self?.pauseShortcuts(recording) },
            cleaner: cleaner,
            onAskAccessibility: { [weak self] in self?.askAccessibility() })
    }
    @objc private func showShots() { NSWorkspace.shared.open(storage.shotsURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// llama.cpp must let go of a loaded model before the process exits.
    func shutdown() { cleaner.shutdownBlocking() }
}
