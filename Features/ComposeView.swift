import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    let store: MailStore
    let outbox: OutboxService
    /// The conversation this draft replies to or forwards, when there is
    /// one; nil for a brand-new compose. Passed straight through to
    /// `OutboxService.queueSend`, which needs it for real Gmail threading.
    let sourceThread: Correspondence?
    @State var draft: Draft
    private let initialDraft: Draft
    @Environment(\.dismiss) private var dismiss
    @State private var showingDiscardConfirmation = false
    @FocusState private var focusedField: Field?
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var attachmentError: String?

    private enum Field { case to, subject, body }

    /// Someone typed into "To" can be filled in without spelling out a full
    /// address, the same convenience Gmail and Apple Mail both offer.
    /// Deliberately scoped to who has ever emailed *me* (real, already-known
    /// senders in `store.threads`), not a real contacts-book: Corres has no
    /// first-class record of who a person has sent *to* that never replied,
    /// only of who has actually corresponded with them, which is the data
    /// actually available and the case the request was made against.
    private struct RecipientSuggestion: Identifiable, Hashable {
        let name: String
        let email: String
        var id: String { email }
    }

    init(store: MailStore, outbox: OutboxService, draft: Draft, sourceThread: Correspondence?) {
        self.store = store
        self.outbox = outbox
        self.sourceThread = sourceThread
        self._draft = State(initialValue: draft)
        self.initialDraft = draft
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    field(title: "To", text: $draft.to, isEditable: draft.kind == .new || draft.kind == .forward)
                        .focused($focusedField, equals: .to)
                    if !toSuggestions.isEmpty {
                        recipientSuggestionsList
                    }
                    Divider().padding(.leading, CorresSpace.page)
                    field(title: "Subject", text: $draft.subject, isEditable: true)
                        .focused($focusedField, equals: .subject)
                    Divider().padding(.leading, CorresSpace.page)
                    TextEditor(text: $draft.body)
                        .focused($focusedField, equals: .body)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 260)
                        .padding(.horizontal, CorresSpace.page - 5)
                        .padding(.vertical, 12)
                    if !draft.attachments.isEmpty {
                        Divider().padding(.leading, CorresSpace.page)
                        attachmentChips
                    }
                }
                .padding(.vertical, 12)
            }
            .background(CorresPalette.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { attemptDismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        PhotosPicker(selection: $pickedPhoto, matching: .images) {
                            Label("Photo Library", systemImage: "photo")
                        }
                        Button { showingFileImporter = true } label: {
                            Label("Choose File", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "paperclip").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Add Attachment")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { sendAndDismiss() }
                        .disabled(!draft.isSendable)
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Delete this draft?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
                Button("Delete Draft", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .interactiveDismissDisabled(hasUnsavedChanges)
            .onAppear { focusedField = draft.to.isEmpty ? .to : .body }
            .onChange(of: pickedPhoto) { _, newValue in
                guard let newValue else { return }
                Task { await addPhoto(newValue) }
            }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { addFiles(urls) }
            }
            .alert("Could not attach this file", isPresented: Binding(
                get: { attachmentError != nil },
                set: { if !$0 { attachmentError = nil } }
            )) {
                Button("OK", role: .cancel) { attachmentError = nil }
            } message: { Text(attachmentError ?? "Please try again.") }
        }
        // Self-contained, like PreferencesView: a distant .preferredColorScheme
        // does not reliably re-trait an already-presented sheet if Appearance
        // changes while it's open (e.g. via system auto dark mode).
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
    }

    private var title: String {
        switch draft.kind {
        case .new: "New Message"
        case .reply: "Reply"
        case .replyAll: "Reply All"
        case .forward: "Forward"
        }
    }

    /// Compares against the draft's pre-filled starting point (quoted reply
    /// text, "Re:"/"Fwd:" subject) rather than just "is anything non-empty":
    /// a reply or forward already has non-empty fields before the user types
    /// a single character, so "has content" alone would nag on every cancel.
    private var hasUnsavedChanges: Bool {
        draft.to != initialDraft.to || draft.subject != initialDraft.subject || draft.body != initialDraft.body
            || !draft.attachments.isEmpty
    }

    private func attemptDismiss() {
        if hasUnsavedChanges { showingDiscardConfirmation = true } else { dismiss() }
    }

    /// Optimistic: the sheet closes the instant Send is tapped, matching the
    /// speed a premium mail client is expected to feel like. The actual send
    /// (a real Gmail delivery when replying/forwarding a connected thread,
    /// plus local bookkeeping) happens in OutboxService after a short undo
    /// window; see its doc comment and ADR 005.
    private func sendAndDismiss() {
        outbox.queueSend(draft, replyingTo: sourceThread)
        dismiss()
    }

    /// Most recently corresponded with first, matching how Gmail's own
    /// suggestions are recency-weighted, not alphabetical.
    private var knownContacts: [RecipientSuggestion] {
        var seenEmails: Set<String> = []
        var contacts: [RecipientSuggestion] = []
        for thread in store.threads.sorted(by: { $0.receivedAt > $1.receivedAt }) {
            guard thread.id.account != "sample", let email = thread.senderEmail,
                  !seenEmails.contains(email) else { continue }
            seenEmails.insert(email)
            contacts.append(RecipientSuggestion(name: thread.sender, email: email))
        }
        return contacts
    }

    private var toSuggestions: [RecipientSuggestion] {
        let query = draft.to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, focusedField == .to else { return [] }
        return Array(knownContacts.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.email.localizedCaseInsensitiveContains(query) }.prefix(5))
    }

    private var recipientSuggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(toSuggestions) { suggestion in
                Button {
                    draft.to = suggestion.email
                    focusedField = .subject
                } label: {
                    HStack(spacing: 10) {
                        CorrespondentAvatar(initials: Self.initials(for: suggestion.name), size: CGSize(width: 34, height: 34))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.name).font(.subheadline.weight(.medium)).foregroundStyle(CorresPalette.ink)
                            Text(suggestion.email).font(.caption).foregroundStyle(CorresPalette.secondary)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, CorresSpace.page).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if suggestion.id != toSuggestions.last?.id {
                    Divider().padding(.leading, CorresSpace.page + 44)
                }
            }
        }
        .background(CorresPalette.surface)
    }

    private static func initials(for name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    private var attachmentChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(draft.attachments) { attachment in
                HStack(spacing: 8) {
                    Image(systemName: "paperclip").font(.footnote).foregroundStyle(CorresPalette.secondary)
                    Text(attachment.filename).font(.footnote).lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        draft.attachments.removeAll { $0.id == attachment.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(CorresPalette.secondary)
                    }
                    .accessibilityLabel("Remove \(attachment.filename)")
                }
            }
        }
        .padding(.horizontal, CorresSpace.page).padding(.vertical, 8)
    }

    /// Gmail's own 25 MB cap (`Draft.maxAttachmentsBytes`) is enforced here,
    /// before a queued send ever reaches the network, rather than only
    /// discovered as a send failure after the person already waited through
    /// the undo window.
    private func addAttachment(filename: String, mimeType: String, data: Data) {
        guard draft.attachmentsSizeBytes + data.count <= Draft.maxAttachmentsBytes else {
            attachmentError = "\(filename) would put this message over Gmail's 25 MB limit."
            return
        }
        draft.attachments.append(PendingAttachment(filename: filename, mimeType: mimeType, data: data))
    }

    private func addPhoto(_ item: PhotosPickerItem) async {
        defer { pickedPhoto = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            attachmentError = "Could not load that photo."
            return
        }
        let contentType = item.supportedContentTypes.first
        let ext = contentType?.preferredFilenameExtension ?? "jpg"
        let mimeType = contentType?.preferredMIMEType ?? "image/jpeg"
        addAttachment(filename: "Photo-\(draft.attachments.count + 1).\(ext)", mimeType: mimeType, data: data)
    }

    /// `.fileImporter` hands back security-scoped URLs: access must be
    /// explicitly started before reading and stopped afterward, or the read
    /// fails (or worse, silently succeeds once and then breaks later),
    /// per Apple's own documented contract for these URLs.
    private func addFiles(_ urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else {
                attachmentError = "Could not access \(url.lastPathComponent)."
                continue
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else {
                attachmentError = "Could not read \(url.lastPathComponent)."
                continue
            }
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            addAttachment(filename: url.lastPathComponent, mimeType: mimeType, data: data)
        }
    }

    private func field(title: String, text: Binding<String>, isEditable: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline).foregroundStyle(CorresPalette.secondary).frame(width: 64, alignment: .leading)
            if isEditable {
                TextField(title == "To" ? "Recipient" : "Subject", text: text)
                    .textInputAutocapitalization(title == "To" ? .never : .sentences)
                    .keyboardType(title == "To" ? .emailAddress : .default)
                    .autocorrectionDisabled(title == "To")
            } else {
                Text(text.wrappedValue).foregroundStyle(CorresPalette.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, CorresSpace.page).frame(minHeight: 44)
    }
}

extension Correspondence {
    func draft(kind: Draft.Kind) -> Draft {
        let quoted = "\n\n\(sender) wrote:\n\(body.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n"))"
        switch kind {
        case .new:
            return Draft(kind: .new, to: "", subject: "")
        case .reply, .replyAll:
            return Draft(kind: kind, threadID: id, to: senderEmail ?? sender,
                         subject: subject.hasPrefix("Re: ") ? subject : "Re: \(subject)",
                         body: quoted)
        case .forward:
            return Draft(kind: .forward, threadID: id, to: "",
                         subject: subject.hasPrefix("Fwd: ") ? subject : "Fwd: \(subject)",
                         body: quoted)
        }
    }
}
