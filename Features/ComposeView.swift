import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    let store: MailStore
    let outbox: OutboxService
    /// Optional: only needed to offer a "From" picker for a brand-new
    /// compose when more than one account is connected. Nil for the offline
    /// preview-render script and for reply/forward, where the account is
    /// already fixed by the thread being replied to.
    var auth: GoogleAuthService?
    /// The conversation this draft replies to or forwards, when there is
    /// one; nil for a brand-new compose. Passed straight through to
    /// `OutboxService.queueSend`, which needs it for real Gmail threading.
    let sourceThread: Correspondence?
    @State var draft: Draft
    private let initialDraft: Draft
    @Environment(\.dismiss) private var dismiss
    @State private var showingDiscardConfirmation = false
    @State private var confirmingNoSubject = false
    @FocusState private var focusedField: Field?
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var attachmentError: String?
    @State private var rewriting: MailIntelligence.Tone?
    @State private var beforeRewrite: String?
    @Environment(MailIntelligence.self) private var intelligence
    @Environment(SnippetStore.self) private var snippets
    @Environment(\.proUnlocked) private var proUnlocked
    @State private var dictation = DictationService()

    private enum Field { case to, cc, subject, body }

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

    init(store: MailStore, outbox: OutboxService, auth: GoogleAuthService? = nil, draft: Draft, sourceThread: Correspondence?) {
        self.store = store
        self.outbox = outbox
        self.auth = auth
        self.sourceThread = sourceThread
        var initial = draft
        if initial.kind == .new, initial.fromAccount == nil {
            // Settings → Composing → Send new mail from, when it's still connected.
            let connected = auth?.accounts.map(\.email) ?? []
            initial.fromAccount = CorresSettings.defaultFromAccount.flatMap { connected.contains($0) ? $0 : nil }
                ?? auth?.primaryAccount?.email
        }
        initial.body = Self.addingSignature(to: initial.body, account: initial.fromAccount ?? initial.threadID?.account ?? "sample")
        self._draft = State(initialValue: initial)
        self.initialDraft = initial
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if draft.kind == .new, let accounts = auth?.accounts, accounts.count > 1 {
                        fromPicker(accounts)
                        Divider().padding(.leading, CorresSpace.page)
                    }
                    field(title: "To", text: $draft.to, isEditable: true)
                        .focused($focusedField, equals: .to)
                    if !toSuggestions.isEmpty {
                        recipientSuggestionsList
                    }
                    Divider().padding(.leading, CorresSpace.page)
                    field(title: "Cc", text: Binding(get: { draft.cc ?? "" }, set: { draft.cc = $0 }), isEditable: true)
                        .focused($focusedField, equals: .cc)
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
            .safeAreaInset(edge: .bottom) { toneBar }
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
                    Button("Send") {
                        if draft.hasSubject { sendAndDismiss() } else { confirmingNoSubject = true }
                    }
                        .fontWeight(.semibold)
                        .prominentToolbarButton()
                        .disabled(!canSend)
                }
            }
            .confirmationDialog("Send without a subject?", isPresented: $confirmingNoSubject, titleVisibility: .visible) {
                Button("Send") { sendAndDismiss() }
                Button("Add a Subject", role: .cancel) { focusedField = .subject }
            }
            .confirmationDialog("Delete this draft?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
                Button("Delete Draft", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .interactiveDismissDisabled(hasUnsavedChanges)
            .onAppear {
                focusedField = draft.to.isEmpty ? .to : .body
                if draft.kind != .new { placeCursorAboveQuote() }
            }
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

    /// A reply opens with the cursor above the quoted original, the way
    /// Mail does; UIKit otherwise puts it at the end, below the quote.
    /// Done once on the underlying text view: a SwiftUI selection binding
    /// on the editor was tried first and dropped keystrokes while typing.
    private func placeCursorAboveQuote() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            (UIResponder.currentFirstResponder as? UITextView)?.selectedRange = NSRange(location: 0, length: 0)
        }
    }

    /// The person's own words, without the quoted original below them:
    /// only this part is ever rewritten.
    private var ownText: (text: String, quote: String) {
        guard let marker = draft.body.range(of: #"\n\nOn .+ wrote:\n"#, options: .regularExpression) else {
            return (draft.body, "")
        }
        return (String(draft.body[..<marker.lowerBound]), String(draft.body[marker.lowerBound...]))
    }

    /// Shorter / Warmer / More formal / Proofread, rewritten on this
    /// iPhone. One tap to undo, so trying a tone costs nothing.
    @ViewBuilder
    private var toneBar: some View {
        // Always present when available, never inserted mid-typing:
        // changing the bottom inset while the editor has focus disturbs
        // UITextView and drops keystrokes.
        let hasText = ownText.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12
        VStack(spacing: 0) {
            if dictation.isListening {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true)
                        .foregroundStyle(CorresPalette.accent)
                    Text(dictation.transcript.isEmpty ? "Listening…" : dictation.transcript)
                        .font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Done") { finishDictation() }.font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, CorresSpace.page).padding(.vertical, 10)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if dictation.isSupported {
                        Button {
                            if dictation.isListening { finishDictation() } else { Task { await dictation.start() } }
                        } label: {
                            Image(systemName: dictation.isListening ? "stop.fill" : "mic")
                                .frame(width: 18)
                        }
                        .buttonStyle(CorresPillStyle())
                        .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")
                    }
                    Menu {
                        ForEach(snippets.snippets) { snippet in
                            Button(snippet.title) { insert(SnippetStore.expand(snippet.body, recipientName: recipientName)) }
                        }
                        if snippets.snippets.isEmpty { Text("Add snippets in Settings") }
                    } label: {
                        Label("Snippets", systemImage: "text.badge.plus").labelStyle(TightLabelStyle())
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 15).frame(minHeight: 36)
                            .background(CorresPalette.surfaceRaised, in: Capsule())
                            .overlay(Capsule().strokeBorder(CorresPalette.line, lineWidth: 0.5))
                    }
                    .foregroundStyle(CorresPalette.ink)
                    if intelligence.isAvailable && proUnlocked {
                    if let beforeRewrite {
                        Button {
                            draft.body = beforeRewrite + ownText.quote
                            self.beforeRewrite = nil
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(TightLabelStyle())
                        }
                        .buttonStyle(CorresPillStyle())
                    }
                    ForEach(MailIntelligence.Tone.allCases) { tone in
                        Button {
                            rewrite(tone)
                        } label: {
                            HStack(spacing: 6) {
                                if rewriting == tone { ProgressView().controlSize(.mini) }
                                Text(tone.rawValue)
                            }
                        }
                        .buttonStyle(CorresPillStyle())
                        .disabled(rewriting != nil || !hasText)
                        .opacity(hasText ? 1 : 0.45)
                    }
                    }
                }
                .padding(.horizontal, CorresSpace.page).padding(.vertical, 8)
            }
        }
        .background(.bar)
        .animation(.easeOut(duration: 0.2), value: dictation.isListening)
        .onDisappear { dictation.stop() }
        .alert("Dictation", isPresented: Binding(
            get: { dictation.errorMessage != nil },
            set: { if !$0 { dictation.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { dictation.errorMessage = nil }
        } message: { Text(dictation.errorMessage ?? "") }
    }

    /// The recipient's display name, for `{first name}` in snippets.
    private var recipientName: String? {
        if let sourceThread, draft.kind != .forward { return sourceThread.sender }
        return nil
    }

    /// Adds text at the end of the person's own words, above any quote.
    private func insert(_ text: String) {
        let (own, quote) = ownText
        let trimmed = own.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = trimmed.isEmpty ? text : trimmed + (trimmed.hasSuffix("\n") ? "" : " ") + text
        draft.body = joined + quote
        beforeRewrite = nil
    }

    private func finishDictation() {
        dictation.stop()
        let spoken = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty { insert(spoken) }
    }

    private func rewrite(_ tone: MailIntelligence.Tone) {
        let (text, quote) = ownText
        rewriting = tone
        Task {
            let result = await intelligence.rewrite(text, tone: tone)
            rewriting = nil
            guard let result else { return }
            beforeRewrite = text
            draft.body = result + quote
        }
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
        draft.to != initialDraft.to || draft.cc != initialDraft.cc || draft.subject != initialDraft.subject
            || draft.body != initialDraft.body || !draft.attachments.isEmpty
    }

    private func attemptDismiss() {
        if hasUnsavedChanges { showingDiscardConfirmation = true } else { dismiss() }
    }

    /// Optimistic: the sheet closes the instant Send is tapped, matching the
    /// speed a premium mail client is expected to feel like. The actual send
    /// (a real Gmail delivery when replying/forwarding a connected thread,
    /// plus local bookkeeping) happens in OutboxService after a short undo
    /// window; see its doc comment and ADR 005.
    /// The account's signature, between where you type and the quoted
    /// email, the way Mail places it.
    static func addingSignature(to body: String, account: String?) -> String {
        let signature = CorresSettings.signature(for: account)
        guard !signature.isEmpty, !body.contains(signature) else { return body }
        if let quote = body.range(of: #"\n\nOn .+ wrote:\n"#, options: .regularExpression) {
            var result = body
            result.insert(contentsOf: "\n\n" + signature, at: quote.lowerBound)
            return result
        }
        return body + "\n\n" + signature
    }

    /// Switching From swaps in that account's signature.
    private func swapSignature(from old: String?, to new: String?) {
        let oldSignature = CorresSettings.signature(for: old)
        let newSignature = CorresSettings.signature(for: new)
        if !oldSignature.isEmpty, let range = draft.body.range(of: oldSignature) {
            draft.body.replaceSubrange(range, with: newSignature)
        } else if !newSignature.isEmpty {
            draft.body = Self.addingSignature(to: draft.body, account: new)
        }
    }

    /// Real mail needs real addresses; sample mail can go to a name.
    private var canSend: Bool {
        guard draft.isSendable else { return false }
        // A reply is real exactly when its conversation is; a new message
        // when an account is connected.
        let isReal = sourceThread.map { $0.id.account != "sample" } ?? !(auth?.accounts.isEmpty ?? true)
        return !isReal || draft.recipientsLookValid
    }

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

    /// Only shown for a brand-new compose with more than one account
    /// connected: a reply/forward already has its account fixed by which
    /// thread it belongs to, so there is nothing to choose there.
    private func fromPicker(_ accounts: [GmailAccount]) -> some View {
        HStack(spacing: 12) {
            Text("From").font(.subheadline).foregroundStyle(CorresPalette.secondary).frame(width: 64, alignment: .leading)
            Picker("From", selection: Binding(
                get: { draft.fromAccount ?? accounts.first?.email ?? "" },
                set: { newValue in
                    let previous = draft.fromAccount
                    draft.fromAccount = newValue
                    swapSignature(from: previous, to: newValue)
                }
            )) {
                ForEach(accounts) { account in Text(account.email).tag(account.email) }
            }
            .labelsHidden()
            Spacer()
        }
        .padding(.horizontal, CorresSpace.page).frame(minHeight: 44)
    }

    private func field(title: String, text: Binding<String>, isEditable: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline).foregroundStyle(CorresPalette.secondary).frame(width: 64, alignment: .leading)
            if isEditable {
                let isAddressField = title == "To" || title == "Cc"
                TextField(title == "To" ? "Recipient" : title == "Cc" ? "Optional" : "Subject", text: text)
                    .textInputAutocapitalization(isAddressField ? .never : .sentences)
                    .keyboardType(isAddressField ? .emailAddress : .default)
                    .autocorrectionDisabled(isAddressField)
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
        // Blank lines stay as ">" so the quoted email keeps its paragraphs.
        let quotedLines = body.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \($0)" }
        // The standard attribution Gmail and Mail write, which is also what
        // Corres itself looks for when hiding quoted history in a thread.
        let when = receivedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
        let who = senderEmail.map { "\(sender) <\($0)>" } ?? sender
        let quoted = "\n\nOn \(when), \(who) wrote:\n\(quotedLines.joined(separator: "\n"))"
        switch kind {
        case .new:
            return Draft(kind: .new, to: "", subject: "")
        case .reply:
            return Draft(kind: kind, threadID: id, fromAccount: id.account, to: senderEmail ?? sender,
                         subject: subject.hasPrefix("Re: ") ? subject : "Re: \(subject)",
                         body: quoted)
        case .replyAll:
            return Draft(kind: kind, threadID: id, fromAccount: id.account, to: senderEmail ?? sender,
                         cc: replyAllCc.isEmpty ? nil : replyAllCc.joined(separator: ", "),
                         subject: subject.hasPrefix("Re: ") ? subject : "Re: \(subject)",
                         body: quoted)
        case .forward:
            return Draft(kind: .forward, threadID: id, fromAccount: id.account, to: "",
                         subject: subject.hasPrefix("Fwd: ") ? subject : "Fwd: \(subject)",
                         body: quoted)
        }
    }

    /// Everyone who was on the original message besides the sender (already
    /// in `to`) and the account reading it (no reason to Cc yourself): a
    /// real fix, not a new feature. `toRecipients`/`ccRecipients` weren't
    /// captured at all before this, which meant "Reply All" silently
    /// behaved exactly like "Reply" — reported and root-caused directly.
    var replyAllCc: [String] {
        let me = id.account.lowercased()
        let originalSender = (senderEmail ?? "").lowercased()
        var seen = Set([me, originalSender])
        var result: [String] = []
        for email in toRecipients + ccRecipients {
            let lowered = email.lowercased()
            guard !seen.contains(lowered) else { continue }
            seen.insert(lowered)
            result.append(email)
        }
        return result
    }
}

extension UIResponder {
    private nonisolated(unsafe) static weak var found: UIResponder?

    /// Whatever currently has keyboard focus, found by sending a nil-target
    /// action (UIKit delivers it to the first responder).
    @MainActor static var currentFirstResponder: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(captureFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func captureFirstResponder() { UIResponder.found = self }
}
