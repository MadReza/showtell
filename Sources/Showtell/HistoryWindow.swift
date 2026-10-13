import AppKit
import ShowtellCore
import SwiftUI

/// The History window: every message sent, with its pictures and copied text, to copy, send
/// again or delete; and a way to empty the screenshots folder.
@MainActor
final class HistoryWindow {
    private let store: HistoryStore
    private var window: NSWindow?
    private var model: HistoryModel?
    private var poll: Timer?
    /// Sessions to send to again (the cursor is always offered).
    var sessions: () -> [HerdrAgent] = { [] }
    /// Whether sending presses Enter (the Send checkbox).
    var submits: () -> Bool = { true }
    /// Sends a message again; returns why not, if it couldn't.
    var resend: (HistoryEntry, HistoryDestination) async -> String? = { _, _ in nil }
    /// Picture files a recording or a delivery still needs: never deleted.
    var filesInUse: () -> Set<String> = { [] }

    init(store: HistoryStore) {
        self.store = store
    }

    func show() {
        defer { watchSessions() }
        if let window, let model {
            model.reload()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = HistoryModel(store: store, owner: self)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Showtell History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 420)
        window.contentView = NSHostingView(rootView: HistoryView(model: model))
        window.setFrameAutosaveName("ShowtellHistory")
        if window.frame.origin == .zero { window.center() }
        self.window = window
        self.model = model
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A message was sent or its outcome changed: show it, if the window is open.
    func reload() { model?.reload() }

    /// Sessions come and go: look again while the window is open.
    private func watchSessions() {
        model?.refreshSessions()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isVisible else {
                    timer.invalidate()
                    return
                }
                self.model?.refreshSessions()
            }
        }
    }
}

/// A picture shown large.
struct EnlargedShot: Identifiable {
    let url: URL
    let number: Int
    var id: URL { url }
}

@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var selection: Set<String> = []
    @Published var search = ""
    @Published var sessions: [HerdrAgent] = []
    @Published var submits = true
    @Published var shotsUsage: (files: Int, bytes: Int64) = (0, 0)
    @Published var enlarged: EnlargedShot?
    /// A short note at the bottom ("Copied", "Sent to showtell"), cleared after a moment.
    @Published var note: (text: String, warning: Bool)?
    @Published var confirmDelete: Set<String>?
    @Published var confirmClearHistory = false
    @Published var confirmClearShots = false
    @Published var sending = false

    let store: HistoryStore
    private weak var owner: HistoryWindow?
    private var thumbnails: [String: NSImage] = [:]
    private var noteWork: DispatchWorkItem?

    init(store: HistoryStore, owner: HistoryWindow) {
        self.store = store
        self.owner = owner
        reload()
        selection = entries.first.map { [$0.id] } ?? []
    }

    func reload() {
        entries = store.load()
        selection = selection.filter { id in entries.contains { $0.id == id } }
        shotsUsage = store.shotsUsage()
        submits = owner?.submits() ?? true
    }

    func refreshSessions() {
        sessions = owner?.sessions() ?? []
        submits = owner?.submits() ?? true
    }

    var filtered: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.text.localizedCaseInsensitiveContains(q) || $0.destination.label.localizedCaseInsensitiveContains(q)
                || $0.clips.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
    }

    /// The list grouped by day, newest first.
    var days: [(title: String, entries: [HistoryEntry])] {
        let cal = Calendar.current
        var out: [(String, [HistoryEntry])] = []
        for entry in filtered {
            let title: String
            if cal.isDateInToday(entry.date) { title = "Today" }
            else if cal.isDateInYesterday(entry.date) { title = "Yesterday" }
            else { title = entry.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) }
            if out.last?.0 == title { out[out.count - 1].1.append(entry) } else { out.append((title, [entry])) }
        }
        return out
    }

    var selected: HistoryEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return entries.first { $0.id == id }
    }

    func thumbnail(_ shot: HistoryEntry.Shot) -> NSImage? {
        if let image = thumbnails[shot.file] { return image }
        guard let image = NSImage(contentsOf: store.shotURL(shot)) else { return nil }
        thumbnails[shot.file] = image
        return image
    }

    func copy(_ text: String, what: String = "Message") {
        let pb = NSPasteboard.general
        pb.declareTypes([.string, ClipboardWatcher.ownType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: ClipboardWatcher.ownType)  // not a copy for a recording to pick up
        show("\(what) copied")
    }

    func copyImage(_ url: URL) {
        guard let png = try? Data(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.declareTypes([.png, .tiff, ClipboardWatcher.ownType], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        pb.setData(Data(), forType: ClipboardWatcher.ownType)
        show("Picture copied")
    }

    func resend(_ entry: HistoryEntry, to destination: HistoryDestination) {
        guard let owner else { return }
        sending = true
        show("Sending to \(destination.label)…")
        Task {
            let problem = await owner.resend(entry, destination)
            sending = false
            reload()
            if let problem { show(problem, warning: true) } else { show("Sent to \(destination.label)") }
            if problem == nil, let newest = entries.first { selection = [newest.id] }
        }
    }

    func delete(_ ids: Set<String>) {
        do {
            let removed = try store.delete(ids)
            thumbnails = [:]
            reload()
            show(ids.count == 1 ? "Message deleted" : "\(ids.count) messages deleted"
                + (removed > 0 ? ", with \(removed) picture\(removed == 1 ? "" : "s")" : ""))
        } catch {
            show("Couldn't delete: \(error.localizedDescription)", warning: true)
        }
    }

    func clearHistory() {
        do {
            let removed = try store.clear()
            thumbnails = [:]
            selection = []
            reload()
            show("History cleared" + (removed > 0 ? ", with \(removed) picture\(removed == 1 ? "" : "s")" : ""))
        } catch {
            show("Couldn't clear: \(error.localizedDescription)", warning: true)
        }
    }

    func clearShots() {
        let removed = store.clearShots(keeping: owner?.filesInUse() ?? [])
        thumbnails = [:]
        reload()
        show("Deleted \(removed) picture\(removed == 1 ? "" : "s")")
    }

    var usageLabel: String {
        "\(shotsUsage.files) picture\(shotsUsage.files == 1 ? "" : "s") · "
            + ByteCountFormatter.string(fromByteCount: shotsUsage.bytes, countStyle: .file)
    }

    func show(_ text: String, warning: Bool = false) {
        note = (text, warning)
        noteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.note = nil }
        noteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (warning ? 6 : 2.5), execute: work)
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
            detail.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $model.enlarged) { shot in EnlargedView(shot: shot, model: model) }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { model.confirmDelete != nil },
                                                               set: { if !$0 { model.confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let ids = model.confirmDelete { model.delete(ids) }
                model.confirmDelete = nil
            }
        } message: {
            Text("Their pictures are deleted too, unless another message still uses them.")
        }
        .confirmationDialog("Clear the whole history?", isPresented: $model.confirmClearHistory, titleVisibility: .visible) {
            Button("Clear \(model.entries.count) message\(model.entries.count == 1 ? "" : "s")", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Every message is removed from the list, with the pictures it used. This can't be undone.")
        }
        .confirmationDialog("Empty the screenshots folder?", isPresented: $model.confirmClearShots, titleVisibility: .visible) {
            Button("Delete \(model.usageLabel)", role: .destructive) { model.clearShots() }
        } message: {
            Text("Deletes \(model.shotsUsage.files) picture file\(model.shotsUsage.files == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: model.shotsUsage.bytes, countStyle: .file))) from the screenshots folder. Messages keep their text and show where a picture was. This can't be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.reload()
            model.refreshSessions()
        }
    }

    private var deleteTitle: String {
        let n = model.confirmDelete?.count ?? 0
        return n == 1 ? "Delete this message?" : "Delete \(n) messages?"
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search messages", text: $model.search).textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .padding(10)

            List(selection: $model.selection) {
                ForEach(model.days, id: \.title) { day in
                    Section(day.title) {
                        ForEach(day.entries) { entry in
                            HistoryRow(entry: entry)
                                .tag(entry.id)
                                .contextMenu { rowMenu(entry) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { if !model.selection.isEmpty { model.confirmDelete = model.selection } }
            .overlay {
                if model.entries.isEmpty {
                    Text("Nothing sent yet").foregroundStyle(.secondary)
                } else if model.filtered.isEmpty {
                    Text("No message matches").foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(model.entries.count) message\(model.entries.count == 1 ? "" : "s")").font(.caption.weight(.medium))
                    Text("Screenshots: \(model.usageLabel)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Clear history…") { model.confirmClearHistory = true }
                        .disabled(model.entries.isEmpty)
                    Button("Clear screenshots folder…") { model.confirmClearShots = true }
                        .disabled(model.shotsUsage.files == 0)
                    Divider()
                    Button("Show screenshots folder") { NSWorkspace.shared.open(model.store.shotsURL) }
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Clear the history or empty the screenshots folder")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: HistoryEntry) -> some View {
        Button("Copy text") { model.copy(entry.text) }
        Menu("Send again") { destinationButtons(entry) }
        Divider()
        Button("Delete…", role: .destructive) {
            model.confirmDelete = model.selection.contains(entry.id) ? model.selection : [entry.id]
        }
    }

    @ViewBuilder
    private func destinationButtons(_ entry: HistoryEntry) -> some View {
        Section(model.submits ? "Pasted, then Enter (Send is on)" : "Pasted, without Enter (Send is off)") {
            ForEach(model.sessions, id: \.paneID) { agent in
                Button("\(agent.folderName) — \(agent.displayName)") {
                    model.resend(entry, to: .session(PinnedTarget(agent: agent)))
                }
            }
            if model.sessions.isEmpty { Text("No Claude sessions in herdr, tmux or iTerm2") }
        }
        Section("Insert without Enter") {
            Button("At the cursor (the app you switch back to)") { model.resend(entry, to: .cursor) }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = model.selected {
            ZStack(alignment: .bottom) {
                ScrollView {
                    EntryDetail(entry: entry, model: model, destinations: { destinationButtons(entry) })
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                noteView
            }
        } else if model.selection.count > 1 {
            VStack(spacing: 12) {
                Image(systemName: "square.stack").font(.system(size: 38)).foregroundStyle(.secondary)
                Text("\(model.selection.count) messages selected").font(.title3.weight(.medium))
                Button("Delete \(model.selection.count) messages…", role: .destructive) { model.confirmDelete = model.selection }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { noteView }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 40)).foregroundStyle(.secondary)
                Text(model.entries.isEmpty ? "No messages yet" : "Pick a message").font(.title3.weight(.medium))
                Text(model.entries.isEmpty
                     ? "Every message you send appears here, with its screenshots and copied text."
                     : "See what was sent and where, copy it, or send it again.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { noteView }
        }
    }

    @ViewBuilder
    private var noteView: some View {
        if let note = model.note {
            Label(note.text, systemImage: note.warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(note.warning ? Color.orange : Color.primary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// One message in the list: where it went, when, the first words, and what it carried.
struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: entry.destination.icon).font(.caption).foregroundStyle(.secondary)
                Text(entry.destination.label).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(entry.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Text(entry.preview.isEmpty ? "(pictures only)" : entry.preview)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            if !entry.shots.isEmpty || !entry.clips.isEmpty || entry.failure != nil {
                HStack(spacing: 8) {
                    if !entry.shots.isEmpty { Label("\(entry.shots.count)", systemImage: "photo") }
                    if !entry.clips.isEmpty { Label("\(entry.clips.count)", systemImage: "doc.on.clipboard") }
                    if entry.failure != nil {
                        Label("Not sent", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The selected message: header with actions, the text as sent, its pictures and copied text.
struct EntryDetail<Destinations: View>: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryModel
    @ViewBuilder let destinations: () -> Destinations

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if let failure = entry.failure {
                Label("Not delivered: \(failure)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            if let draft = entry.clearedDraft {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Cleared from the prompt:", systemImage: "eraser")
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    switch entry.draftOutcome {
                    case .restoredFromStash:
                        Text("Stashed in Claude Code (Ctrl+S), which put it back when the message was sent.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .retyped:
                        Text("Typed back into the prompt after the message was sent.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .leftStashed:
                        Text("Stashed in Claude Code (Ctrl+S): it comes back when you send the message.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .notRestored:
                        Text("Not put back: \(entry.draftNotRestored ?? "unknown reason").")
                            .font(.caption).foregroundStyle(.orange)
                    case nil:
                        EmptyView()
                    }
                    Text(draft).font(.system(size: 13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.copy(draft) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .controlSize(.small)
                        .help("Copy the text that was in the prompt before this message was pasted")
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            section("Message") {
                Text(Self.styled(entry.text.isEmpty ? " " : entry.text))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            }
            if !entry.shots.isEmpty {
                section("Screenshots") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(entry.shots, id: \.number) { shot in ShotTile(shot: shot, model: model) }
                    }
                }
            }
            if !entry.clips.isEmpty {
                section("Copied text") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entry.clips, id: \.number) { clip in ClipCard(clip: clip, model: model) }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: entry.destination.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.destination.label).font(.title3.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 0) {
                        Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · ")
                        Text(how).foregroundStyle(entry.failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if case .session(let target) = entry.destination, let cwd = target.cwd {
                        Text(cwd).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    }
                }
            }
            HStack(spacing: 8) {
                Button { model.copy(entry.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the text, with its [📷 n] and [📋 n] markers")
                Menu { destinations() } label: { Label("Send again", systemImage: "paperplane") }
                    .menuStyle(.button)
                    .fixedSize()
                    .disabled(model.sending)
                    .help("Send this message, pictures included, to a session or the cursor")
                Spacer()
                Button(role: .destructive) { model.confirmDelete = [entry.id] } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete this message and its pictures")
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private var how: String {
        if entry.failure != nil { return "Not delivered" }
        switch entry.destination {
        case .cursor: return "Inserted at the cursor"
        case .session: return entry.submitted ? "Pasted and sent with Enter" : "Pasted, Enter not pressed"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
            content()
        }
    }

    /// The markers stand out from the words, as chips do in Claude Code.
    static func styled(_ text: String) -> AttributedString {
        var out = AttributedString()
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: #"\[(📷|📋) \d+\]"#)
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += AttributedString(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            var marker = AttributedString(ns.substring(with: match.range))
            marker.foregroundColor = .accentColor
            marker.font = .system(size: 13, weight: .semibold)
            out += marker
            cursor = match.range.location + match.range.length
        }
        out += AttributedString(ns.substring(from: cursor))
        return out
    }
}

/// A screenshot thumbnail; click to see it large. A deleted file shows where it was.
struct ShotTile: View {
    let shot: HistoryEntry.Shot
    @ObservedObject var model: HistoryModel

    var body: some View {
        let url = model.store.shotURL(shot)
        ZStack(alignment: .topLeading) {
            if let image = model.thumbnail(shot) {
                Button { model.enlarged = EnlargedShot(url: url, number: shot.number) } label: {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(height: 120).frame(maxWidth: .infinity).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to enlarge")
                .contextMenu {
                    Button("Copy picture") { model.copyImage(url) }
                    Button("Open in Preview") { NSWorkspace.shared.open(url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 22))
                    Text("Picture removed").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(height: 120).frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.tertiary))
            }
            Text("📷 \(shot.number)").font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white).padding(6)
        }
    }
}

/// One piece of copied text, exactly as it was pasted.
struct ClipCard: View {
    let clip: HistoryEntry.Clip
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("📋 \(clip.number)").font(.caption.weight(.bold))
                Text("\(clip.text.count) characters").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.copy(clip.text, what: "Copied text") } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption)
            }
            ScrollView {
                Text(clip.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: clip.text.count < 600)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A screenshot at full size, with ways to use it.
struct EnlargedView: View {
    let shot: EnlargedShot
    @ObservedObject var model: HistoryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let image = NSImage(contentsOf: shot.url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(image.size.width, 1100), maxHeight: min(image.size.height, 760))
                }
                .frame(minWidth: 480, idealWidth: min(image.size.width, 1100) + 2,
                       minHeight: 320, idealHeight: min(image.size.height, 760) + 2)
                .background(Color.black.opacity(0.85))
            } else {
                Text("Picture removed").foregroundStyle(.secondary).frame(width: 480, height: 320)
            }
            Divider()
            HStack {
                Text("📷 \(shot.number) · \(shot.url.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy picture") { model.copyImage(shot.url) }
                Button("Open in Preview") { NSWorkspace.shared.open(shot.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}

extension HistoryDestination {
    var icon: String {
        switch self {
        case .cursor: return "character.cursor.ibeam"
        case .session: return "terminal"
        }
    }
}
