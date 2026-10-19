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
    @State private var attachmentError: String?
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field { case to, cc, subject, body }

    var body: some View {
        VStack(spacing: 0) {
            fields
            Divider()
            TextEditor(text: $draft.body)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .focused($focus, equals: .body)
            if !draft.attachments.isEmpty { attachmentStrip }
        }
        .background(CorresPalette.canvas)
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle(draft.subject.isEmpty ? "New Message" : draft.subject)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { send() } label: { Label("Send", systemImage: "paperplane.fill") }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!draft.isSendable)
                    .help("Send (⇧⌘D)")
            }
            ToolbarItem {
                Button { attach() } label: { Label("Attach", systemImage: "paperclip") }
                    .help("Attach a file")
            }
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

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
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
