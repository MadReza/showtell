import AppKit
import ShowtellCore
import SwiftUI

/// What the bar shows. Updated on the main thread by `AppController`.
final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case listening, sending, sent, waiting(String), error(String), info(String) }

    @Published var targetName = ""
    @Published var phase: Phase = .listening
    @Published var text = ""
    /// How tall the transcript's text is laid out; the bar grows with it up to `maxTextHeight`, then scrolls.
    @Published var textHeight: CGFloat = 0
    /// Set from the screen the bar is on, so the whole bar stays within about 60% of its height.
    @Published var maxTextHeight: CGFloat = 150
    @Published var shots: [(Int, NSImage)] = []
    /// Text copied while talking, by `[📋 n]` number.
    @Published var clips: [(Int, String)] = []
    @Published var hint = ""
    /// The Screenshots and Copied text checkboxes: what the clipboard adds while listening.
    @Published var captureScreenshots = true
    @Published var captureText = true
    @Published var showsCapture = true
    @Published var screenshotsShortcut = ""
    @Published var textShortcut = ""
    @Published var elapsed: Double = 0
    /// The Send checkbox: press Enter after pasting, or leave the text in Claude's input.
    @Published var submit = true
    /// Hidden when inserting at the cursor, which never presses Enter.
    @Published var showsSubmit = true
    @Published var submitShortcut = ""
    @Published var targetShortcuts = ""
    /// What the spoken destination was ("heard “for the showtell session”"), or why it was ignored.
    @Published var routeNote = ""
    @Published var routeWarning = false
    /// The destination came from what you said (a microphone instead of the arrow).
    @Published var routeSpoken = false
    /// Bumped whenever the destination changes during a message: the session name pulses.
    @Published var targetPulse = 0
    /// True for a moment after `targetPulse` changes (kept here: @State needs Xcode's SwiftUI macros).
    @Published var pulsing = false
    /// Called when the user types in the bar (not when the transcript updates it).
    var onUserEdit: ((String) -> Void)?
    /// Called when the session name is clicked: shows the session list to switch to.
    var onShowSessions: (() -> Void)?
    var onToggleSubmit: (() -> Void)?
    var onToggleScreenshots: (() -> Void)?
    var onToggleText: (() -> Void)?
    var onShowHistory: (() -> Void)?
    /// The transcript's laid-out height changed; the panel decides whether to animate it.
    var onTextHeight: ((CGFloat) -> Void)?
    /// A message held because its session shows a dialog; shown in the bar when `showsHeld`,
    /// else in its own small panel.
    let held = HeldModel()
    @Published var showsHeld = false
}

/// A message held back because its session shows a dialog, and the choices for it.
final class HeldModel: ObservableObject {
    @Published var hold: Hold?
    var onChoice: ((HoldChoice) -> Void)?
}

/// What is held and why, and buttons to answer the question with it, send it after, or cancel it.
struct HeldView: View {
    @ObservedObject var held: HeldModel
    /// The bar's header already says it.
    var showsTitle = true

    var body: some View {
        if let hold = held.hold {
            VStack(alignment: .leading, spacing: 8) {
                if showsTitle {
                    HStack(spacing: 8) {
                        Circle().fill(Color.orange).frame(width: 9, height: 9)
                        Text(hold.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                }
                Text(detail(hold)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if hold.canAnswer {
                        Button("Answer the question") { held.onChoice?(.answer) }
                            .keyboardShortcut(.defaultAction)
                            .help("Type this message in the question's “Type something” option and send it as your answer")
                    }
                    if !hold.sendAfter {
                        Button("Send after") { held.onChoice?(.sendAfter) }
                            .help("Paste it into the prompt once the dialog closes")
                    }
                    Button("Cancel") { held.onChoice?(.cancel) }
                        .help("Don't send it; History keeps it, marked cancelled")
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }

    private func detail(_ hold: Hold) -> String {
        var parts: [String] = []
        if hold.sendAfter {
            parts.append("It will be pasted into the prompt when the dialog closes.")
        } else {
            parts.append("It goes into the prompt only when the dialog closes, unless you choose otherwise.")
        }
        switch hold.kind {
        case .question where hold.canAnswer:
            if hold.hasPictures { parts.append("A question takes only words: its pictures stay in History.") }
        case .question:
            parts.append("This question has no place to type an answer.")
        case .permission:
            parts.append("Showtell never presses anything in a permission prompt.")
        case .other:
            break
        }
        return parts.joined(separator: " ")
    }
}

/// A small floating panel for a held message while the bar is busy with a recording.
final class NoticePanel: NSPanel {
    init(held: HeldModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 90),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        if ProcessInfo.processInfo.environment["SHOWTELL_CAPTURE_BAR"] == nil { sharingType = .none }
        let view = NSHostingView(rootView: HeldView(held: held)
            .padding(12)
            .frame(width: 520, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08))))
        contentView = view
    }

    override var canBecomeKey: Bool { true }  // so its buttons take a click
    override var canBecomeMain: Bool { false }

    /// Just under `frame` (the bar), centred on it.
    func show(below frame: NSRect) {
        guard let content = contentView else { return }
        let size = content.fittingSize
        setContentSize(size)
        setFrameTopLeftPoint(NSPoint(x: frame.midX - size.width / 2, y: frame.minY - 8))
        orderFrontRegardless()
    }
}

/// Sizes the window to the bar. While the bar animates smaller, the window keeps `holdHeight`
/// so the bar isn't cut off; it is transparent around the bar.
final class BarHostingView: NSHostingView<OverlayView> {
    var holdHeight: CGFloat = 0 { didSet { invalidateIntrinsicContentSize() } }
    var onSizeChange: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = max(size.height, holdHeight)
        return size
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}

/// A floating bar that never takes focus from the app you are looking at until you click into it,
/// and never appears in screenshots or screen recordings.
final class OverlayPanel: NSPanel {
    let model = OverlayModel()
    private var bar: BarHostingView!
    /// How long the bar takes to grow or shrink with its text.
    static let resizeDuration = 0.18
    private var shownAt = Date.distantPast
    private var releaseHold: DispatchWorkItem?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        // Keep the bar out of screenshots and recordings (SHOWTELL_CAPTURE_BAR=1 lets it in, for docs and tests).
        if ProcessInfo.processInfo.environment["SHOWTELL_CAPTURE_BAR"] == nil { sharingType = .none }
        bar = BarHostingView(rootView: OverlayView(model: model))
        // At once, not on the next turn: a window grown after SwiftUI has drawn shows the bar too low for a frame.
        bar.onSizeChange = { [weak self] in self?.fitToBar() }
        contentView = bar
        model.onTextHeight = { [weak self] in self?.setTextHeight($0) }
        // Dragged to another screen: the most the bar may grow changes with it.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: self,
                                               queue: .main) { [weak self] _ in self?.fitMaxHeight() }
    }

    /// The bar grows with its text up to about 60% of the visible screen; the rest of the bar
    /// (header, screenshots, checkboxes) takes about 160 points of that.
    private func fitMaxHeight() {
        guard let f = (screen ?? NSScreen.main)?.visibleFrame else { return }
        model.maxTextHeight = max(64, f.height * 0.6 - 160)
    }

    override var canBecomeKey: Bool { true }  // so you can click in and edit the text
    override var canBecomeMain: Bool { false }

    /// Keeps the top edge where it is, so the bar grows and shrinks at the bottom.
    private func fitToBar() {
        let height = bar.intrinsicContentSize.height
        guard height > 0, abs(frame.height - height) > 0.5 else { return }
        var f = frame
        f.origin.y += f.height - height
        f.size.height = height
        setFrame(f, display: true)
        invalidateShadow()
    }

    /// The bar follows its text with a short ease-out, but not just after it appears or is reset
    /// for a new recording. Growing, the window takes the new height at once and the bar grows into
    /// it; shrinking, the window waits until the bar has.
    private func setTextHeight(_ height: CGFloat) {
        guard height != model.textHeight else { return }
        guard isVisible, Date().timeIntervalSince(shownAt) > 0.3 else {
            model.textHeight = height
            return
        }
        let duration = Self.resizeDuration
        if height < model.textHeight {
            releaseHold?.cancel()
            bar.holdHeight = max(bar.holdHeight, frame.height)
            let release = DispatchWorkItem { [weak self] in self?.bar.holdHeight = 0 }
            releaseHold = release
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02, execute: release)
        }
        withAnimation(.easeOut(duration: duration)) { model.textHeight = height }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in self?.invalidateShadow() }
    }

    func present() {
        shownAt = Date()
        releaseHold?.cancel()
        bar.holdHeight = 0
        fitToBar()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameTopLeftPoint(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - 12))
        }
        fitMaxHeight()
        alphaValue = 1
        orderFrontRegardless()
    }

    /// Steps out of the way while a native screenshot is taken.
    func vanish() { alphaValue = 0 }
    func reappear() { if isVisible { alphaValue = 1 } }
    func dismiss() { orderOut(nil) }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    private var pulse: Bool { model.pulsing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // The panel keeps its top edge when its content grows, so the bar grows downwards.
            TranscriptEditor(text: model.text, onUserEdit: { model.onUserEdit?($0) },
                             onHeight: { model.onTextHeight?($0) })
                .frame(height: min(max(model.textHeight, 64), model.maxTextHeight))
            if !model.shots.isEmpty || !model.clips.isEmpty { shotStrip }
            if model.showsHeld { HeldView(held: model.held, showsTitle: false) }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.hint).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.showsCapture {
                    captureToggle("Screenshots", model.screenshotsShortcut, isOn: model.captureScreenshots,
                                  help: "Checked: screenshots you copy (⌘⌃⇧4) are added where you were speaking. Changes the default too.") {
                        model.onToggleScreenshots?()
                    }
                    captureToggle("Copied text", model.textShortcut, isOn: model.captureText,
                                  help: "Checked: text you copy (⌘C) is added where you were speaking. Changes the default too.") {
                        model.onToggleText?()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
        // Pinned to the window's top while the window is taller than the bar (see `BarHostingView`).
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 9, height: 9)
            Text(phaseLabel).font(.system(size: 12, weight: .semibold))
            if model.phase == .listening {
                Text(String(format: "%d:%02d", Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.routeNote.isEmpty {
                Text(model.routeNote)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.routeWarning ? Color.orange : Color.accentColor)
                    .lineLimit(1).truncationMode(.middle)
                    .transition(.opacity)
            }
            if model.showsSubmit {
                Toggle(isOn: Binding(get: { model.submit }, set: { _ in model.onToggleSubmit?() })) {
                    HStack(spacing: 4) {
                        Text("Send").font(.system(size: 12, weight: .medium))
                        Text(model.submitShortcut).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .help("Checked: press Enter after pasting. Unchecked: leave the text in Claude's input for you. Changes the default too.")
            }
            Button { model.onShowSessions?() } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.routeSpoken ? "mic.fill" : "arrow.right").font(.system(size: 11))
                        .foregroundStyle(pulse ? Color.white : model.routeSpoken ? Color.accentColor : Color.secondary)
                    Text(model.targetName.isEmpty ? "no session" : model.targetName)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    if !model.targetShortcuts.isEmpty {
                        Text(model.targetShortcuts).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(pulse ? Color.accentColor : Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(model.routeSpoken ? 0.9 : 0), lineWidth: 1.5))
                .scaleEffect(pulse ? 1.08 : 1, anchor: .trailing)
                .shadow(color: Color.accentColor.opacity(pulse ? 0.8 : 0), radius: pulse ? 10 : 0)
            }
            .buttonStyle(.plain)
            .help("Send this message to another session (\(model.targetShortcuts) moves through the list)")
            Button { model.onShowHistory?() } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("History: every message sent, to copy or send again")
        }
        .animation(.easeOut(duration: 0.25), value: model.routeNote)
        .onChange(of: model.targetPulse) { _, _ in
            // The destination changed: a bounce and a glow that fades, to catch the eye.
            withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { model.pulsing = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.easeOut(duration: 0.9)) { model.pulsing = false }
            }
        }
    }

    private func captureToggle(_ title: String, _ shortcut: String, isOn: Bool, help: String,
                               toggle: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(shortcut).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .fixedSize()
        .help(help)
    }

    private var shotStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.clips, id: \.0) { number, text in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("📋 \(number)").font(.system(size: 10, weight: .bold))
                        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.tail)
                    }
                    .padding(5)
                    .frame(width: 140, height: 52, alignment: .topLeading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                ForEach(model.shots, id: \.0) { number, image in
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 84, height: 52).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("📷 \(number)").font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white).padding(3)
                    }
                }
            }
        }
    }

    private var phaseLabel: String {
        switch model.phase {
        case .listening: return "Listening"
        case .sending: return "Sending…"
        case .sent: return "Sent"
        case .waiting(let s), .error(let s), .info(let s): return s
        }
    }

    private var dotColor: Color {
        switch model.phase {
        case .listening: return .red
        case .sending, .waiting: return .orange
        case .sent: return .green
        case .error: return .yellow
        case .info: return .gray
        }
    }
}

/// An NSTextView that accepts transcript updates without moving your cursor,
/// and reports only the changes you type, and how tall its text is.
struct TranscriptEditor: NSViewRepresentable {
    var text: String
    var onUserEdit: (String) -> Void
    var onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onUserEdit: onUserEdit, onHeight: onHeight) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: 15)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        // The text wraps again when the view gets its width.
        tv.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameDidChange(_:)),
                                               name: NSView.frameDidChangeNotification, object: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onUserEdit = onUserEdit
        context.coordinator.onHeight = onHeight
        let tv = scroll.documentView as! NSTextView
        guard tv.string != text else { return }
        defer { context.coordinator.measure(tv) }
        let selection = tv.selectedRanges
        let atEnd = tv.selectedRange().location >= (tv.string as NSString).length
        context.coordinator.applyingUpdate = true
        tv.string = text
        tv.undoManager?.removeAllActions()  // old undo ranges no longer match the new text
        context.coordinator.applyingUpdate = false
        if atEnd || tv.window?.firstResponder !== tv {
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            tv.scrollToEndOfDocument(nil)
        } else {
            let len = (text as NSString).length
            tv.selectedRanges = selection.map { v in
                let r = v.rangeValue
                return NSValue(range: NSRange(location: min(r.location, len), length: min(r.length, max(0, len - r.location))))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onUserEdit: (String) -> Void
        var onHeight: (CGFloat) -> Void
        var applyingUpdate = false
        private var lastHeight: CGFloat = -1
        init(onUserEdit: @escaping (String) -> Void, onHeight: @escaping (CGFloat) -> Void) {
            self.onUserEdit = onUserEdit
            self.onHeight = onHeight
        }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            measure(tv)
            guard !applyingUpdate else { return }
            onUserEdit(tv.string)
        }
        @objc func frameDidChange(_ notification: Notification) {
            if let tv = notification.object as? NSTextView { measure(tv) }
        }
        /// Reports the laid-out height of the text, after this view update (the bar resizes to it).
        func measure(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer, tc.size.width > 0 else { return }
            lm.ensureLayout(for: tc)
            let height = ceil(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2)
            guard height != lastHeight else { return }
            lastHeight = height
            DispatchQueue.main.async { [onHeight] in onHeight(height) }
        }
    }
}
