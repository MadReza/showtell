import AppKit
import SwiftUI

/// What the bar shows. Updated on the main thread by `AppController`.
final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case listening, sending, sent, waiting(String), error(String), info(String) }

    @Published var targetName = ""
    @Published var phase: Phase = .listening
    @Published var text = ""
    @Published var shots: [(Int, NSImage)] = []
    @Published var hint = ""
    @Published var elapsed: Double = 0
    /// Called when the user types in the bar (not when the transcript updates it).
    var onUserEdit: ((String) -> Void)?
}

/// A floating bar that never takes focus from the app you are looking at until you click into it,
/// and never appears in screenshots or screen recordings.
final class OverlayPanel: NSPanel {
    let model = OverlayModel()

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
        sharingType = .none  // keep the bar out of screenshots and recordings
        contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    override var canBecomeKey: Bool { true }  // so you can click in and edit the text
    override var canBecomeMain: Bool { false }

    func present() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameTopLeftPoint(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - 12))
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TranscriptEditor(text: model.text, onUserEdit: { model.onUserEdit?($0) })
                .frame(minHeight: 64, maxHeight: 150)
            if !model.shots.isEmpty { shotStrip }
            Text(model.hint).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
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
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(model.targetName.isEmpty ? "no session" : model.targetName)
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
    }

    private var shotStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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
/// and reports only the changes you type.
struct TranscriptEditor: NSViewRepresentable {
    var text: String
    var onUserEdit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onUserEdit: onUserEdit) }

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
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onUserEdit = onUserEdit
        let tv = scroll.documentView as! NSTextView
        guard tv.string != text else { return }
        let selection = tv.selectedRanges
        let atEnd = tv.selectedRange().location >= (tv.string as NSString).length
        context.coordinator.applyingUpdate = true
        tv.string = text
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
        var applyingUpdate = false
        init(onUserEdit: @escaping (String) -> Void) { self.onUserEdit = onUserEdit }
        func textDidChange(_ notification: Notification) {
            guard !applyingUpdate, let tv = notification.object as? NSTextView else { return }
            onUserEdit(tv.string)
        }
    }
}
