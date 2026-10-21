import SwiftUI
import UniformTypeIdentifiers

/// What a compose window opens with: a new email, or a reply, reply all
/// or forward to a conversation.
struct ComposeRequest: Codable, Hashable {
    var kind: Draft.Kind
    var thread: ThreadID?
    var to: String = ""
    var subject: String = ""
    var body: String = ""
    /// The account to send from, when it's known (a draft's own).
    var account: String?
    /// Continuing a draft saved on the server: replaced once sent.
    var serverDraftID: String?
    /// A whole draft waiting in MacComposeHandoff (a scheduled email being edited).
    var handoff: UUID?
    var id = UUID()
}

/// A compose window of its own, as on the Mac it should be: write while
/// reading, several at once, ⌘⇧D to send. Sending waits out Undo Send
/// before it goes, the same as on the iPhone.
struct MacComposeView: View {
    let request: ComposeRequest
    let services: MacServices

    @State private var draft = Draft(kind: .new, to: "", subject: "")
    @State private var replyingTo: Correspondence?
    @State private var fromAccount: String = ""
    @State private var showsCc = false
    @State private var confirmEmptySubject = false
    @State private var loaded = false
    /// What the body starts with (a reply's quote and signature).
    @State private var initialBody = ""
    @State private var attachmentError: String?
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field { case to, cc, subject, body }

    var body: some View {
        VStack(spacing: 0) {
            fields
            Divider()
            if loaded {
                MacRichEditor(plain: $draft.body, html: $draft.bodyHTML, initialText: initialBody,
                              focusOnAppear: !draft.to.isEmpty)
            } else {
                Spacer()
            }
            if !draft.attachments.isEmpty { attachmentStrip }
        }
        .background(CorresPalette.canvas)
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle(draft.subject.isEmpty ? String(localized: "New Message") : draft.subject)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { send() } label: { Label("Send", systemImage: "paperplane.fill") }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!draft.isSendable)
                    .help("Send (⇧⌘D)")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(sendLaterPresets, id: \.date) { preset in
                        Button(preset.title) { send(at: preset.date) }
                    }
                    Divider()
                    Button("Choose a Time…") { choosingTime = true }
                } label: {
                    Label("Send Later", systemImage: "clock.arrow.circlepath")
                }
                .disabled(!draft.isSendable)
                .help("Send Later")
            }
            ToolbarItem {
                Button { attach() } label: { Label("Attach", systemImage: "paperclip") }
                    .help("Attach a file")
            }
        }
        .popover(isPresented: $choosingTime, arrowEdge: .top) { sendLaterPicker }
        // Files dragged in from Finder or another app are attached.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            add(files)
            return true
        }
        .confirmationDialog("Send without a subject?", isPresented: $confirmEmptySubject) {
            Button("Send") { send(confirmed: true) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't Attach", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(attachmentError ?? "") }
        .task { load() }
        .onChange(of: draft) { _, value in
            guard loaded else { return }
            services.outbox.autosave(value, replyingTo: replyingTo)
        }
        .onDisappear {
            // Closing the window keeps what you wrote in Drafts.
            guard loaded, !sent, !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.to.isEmpty else { return }
            services.outbox.autosave(draft, replyingTo: replyingTo)
        }
    }

    @State private var sent = false

    private var accounts: [String] { services.auth.accounts.map(\.email) }

    private var fields: some View {
        VStack(spacing: 0) {
            field("To") {
                TextField("", text: $draft.to).focused($focus, equals: .to)
                if !showsCc {
                    Button("Cc") { showsCc = true; focus = .cc }.buttonStyle(.borderless).foregroundStyle(CorresPalette.secondary)
                }
            }
            if showsCc {
                Divider().padding(.leading, 14)
                field("Cc") {
                    TextField("", text: Binding(get: { draft.cc ?? "" }, set: { draft.cc = $0.isEmpty ? nil : $0 }))
                        .focused($focus, equals: .cc)
                }
            }
            Divider().padding(.leading, 14)
            field("Subject") { TextField("", text: $draft.subject).focused($focus, equals: .subject) }
            if accounts.count > 1 {
                Divider().padding(.leading, 14)
                field("From") {
                    Picker("", selection: $fromAccount) {
                        ForEach(accounts, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
            }
        }
        .textFieldStyle(.plain)
        .onChange(of: fromAccount) { _, account in draft.fromAccount = account }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title + ":").foregroundStyle(CorresPalette.secondary).frame(width: 58, alignment: .trailing)
            content()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { file in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                        Text(file.filename).lineLimit(1)
                        Button { draft.attachments.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Remove \(file.filename)").help("Remove this attachment")
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(10)
        }
    }

    private func load() {
        guard !loaded else { return }
        if let handoff = request.handoff, let whole = MacComposeHandoff.drafts.removeValue(forKey: handoff) {
            draft = whole
            replyingTo = whole.threadID.flatMap { services.store.thread($0) }
            fromAccount = whole.fromAccount ?? accounts.first ?? ""
            showsCc = !(whole.cc ?? "").isEmpty
            initialBody = whole.body
            focus = .body
            loaded = true
            return
        }
        if let id = request.thread, let thread = services.store.thread(id) {
            replyingTo = thread
            draft = thread.draft(kind: request.kind)
        } else {
            draft = Draft(kind: .new, to: request.to, subject: request.subject, body: request.body)
            draft.fromAccount = request.account
            draft.gmailDraftID = request.serverDraftID
        }
        let account = draft.fromAccount ?? replyingTo?.id.account ?? accounts.first ?? ""
        fromAccount = account
        draft.fromAccount = account.isEmpty ? nil : account
        if request.serverDraftID == nil {
            draft.body = Draft.adding(signature: CorresSettings.signature(for: account, reply: request.kind != .new), to: draft.body)
        }
        showsCc = !(draft.cc ?? "").isEmpty
        initialBody = draft.body
        focus = draft.to.isEmpty ? .to : .body
        loaded = true
    }

    private func send(confirmed: Bool = false) {
        guard draft.isSendable else { return }
        if !confirmed && draft.subject.trimmingCharacters(in: .whitespaces).isEmpty {
            confirmEmptySubject = true
            return
        }
        sent = true
        services.outbox.queueSend(draft, replyingTo: replyingTo)
        dismiss()
    }

    // MARK: Send Later

    @State private var choosingTime = false
    @State private var chosenTime = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now

    /// Mail's own choices: tonight, tomorrow morning, and Monday.
    private var sendLaterPresets: [(title: String, date: Date)] {
        let calendar = Calendar.current
        let now = Date.now
        var presets: [(String, Date)] = []
        if let tonight = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: now), tonight > now.addingTimeInterval(1_800) {
            presets.append(("Tonight at 9:00 PM", tonight))
        }
        if let morning = calendar.date(byAdding: .day, value: 1, to: now).flatMap({ calendar.date(bySettingHour: 8, minute: 0, second: 0, of: $0) }) {
            presets.append(("Tomorrow at 8:00 AM", morning))
        }
        if let monday = calendar.nextDate(after: now, matching: DateComponents(hour: 8, weekday: 2), matchingPolicy: .nextTime),
           !calendar.isDateInTomorrow(monday) {
            presets.append(("Monday at 8:00 AM", monday))
        }
        return presets
    }

    private var sendLaterPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Later").font(.headline)
            DatePicker("Send at", selection: $chosenTime, in: Date.now.addingTimeInterval(60)...,
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            Text("Corres sends it from this Mac at that time, or the moment it can if your Mac is asleep or offline.")
                .font(.caption).foregroundStyle(CorresPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { choosingTime = false }
                Button("Schedule") {
                    choosingTime = false
                    send(at: chosenTime)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    /// Held on this Mac until the time, then sent; the copy in Drafts goes,
    /// so another device can't send it too.
    private func send(at date: Date) {
        guard draft.isSendable else { return }
        sent = true
        services.outbox.removeGmailDraft(of: draft, replyingTo: replyingTo)
        var scheduled = draft
        scheduled.gmailDraftID = nil
        ScheduledSends.shared.schedule(scheduled, at: date)
        dismiss()
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// From the Attach button, or dropped on the window from Finder.
    private func add(_ urls: [URL]) {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let file = PendingAttachment(filename: url.lastPathComponent, mimeType: type, data: data)
            let total = draft.attachments.reduce(0) { $0 + $1.data.count } + data.count
            guard total <= Draft.maxAttachmentsBytes else {
                attachmentError = "Attachments can add up to 25 MB in one email."
                break
            }
            draft.attachments.append(file)
        }
    }
}
