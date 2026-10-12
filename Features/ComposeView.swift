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
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var showingCamera = false
    @State private var showingScanner = false
    @State private var showingFileImporter = false
    @State private var attachmentError: String?
    /// A quiet line under the attachments ("made smaller to fit").
    @State private var attachmentNote: String?
    @State private var rewriting: MailIntelligence.Tone?
    @State private var beforeRewrite: String?
    @Environment(MailIntelligence.self) private var intelligence
    @Environment(SnippetStore.self) private var snippets
    @Environment(PeopleDirectory.self) private var people: PeopleDirectory?
    @Environment(\.proUnlocked) private var proUnlocked
    @State private var dictation = DictationService()

    private enum Field { case to, cc, subject, body }

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
                    recipientField(.to)
                    if focusedField == .to { recipientSuggestions(for: .to) }
                    Divider().padding(.leading, CorresSpace.page)
                    recipientField(.cc)
                    if focusedField == .cc { recipientSuggestions(for: .cc) }
                    Divider().padding(.leading, CorresSpace.page)
                    field(title: "Subject", text: $draft.subject, isEditable: true)
                        .focused($focusedField, equals: .subject)
                    Divider().padding(.leading, CorresSpace.page)
                    // Above the message, not below it: under the editor
                    // the keyboard covered them, so attaching looked like
                    // nothing had happened.
                    if !draft.attachments.isEmpty {
                        attachmentChips
                        if let attachmentNote {
                            Text(attachmentNote).font(.caption).foregroundStyle(CorresPalette.secondary)
                                .padding(.horizontal, CorresSpace.page).padding(.bottom, 6)
                        }
                        Divider().padding(.leading, CorresSpace.page)
                    }
                    TextEditor(text: $draft.body)
                        .focused($focusedField, equals: .body)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 260)
                        .padding(.horizontal, CorresSpace.page - 5)
                        .padding(.vertical, 12)
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
                    // Each item only asks for its picker; the pickers are
                    // presented from the screen (below). A PhotosPicker
                    // inside the menu closed with the menu, so choosing
                    // Photo Library did nothing at all.
                    Menu {
                        Button { showingPhotoPicker = true } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                        if CameraPicker.isAvailable {
                            Button { showingCamera = true } label: {
                                Label("Take Photo", systemImage: "camera")
                            }
                        }
                        if DocumentScanner.isAvailable {
                            Button { showingScanner = true } label: {
                                Label("Scan Document", systemImage: "doc.viewfinder")
                            }
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
            // Who to suggest: current as Compose opens, and your Sent
            // history read once if it hasn't been yet.
            .task {
                let accounts = auth?.accounts.map(\.email) ?? []
                people?.update(from: store.threads, accounts: accounts)
                await people?.backfillIfNeeded(accounts: accounts)
            }
            // Leaving To or Cc turns a finished address into a chip.
            .onChange(of: focusedField) { old, _ in
                if old == .to || old == .cc, let old { commitTyping(in: old) }
            }
            .onAppear {
                focusedField = draft.to.isEmpty ? .to : .body
                if draft.kind != .new { placeCursorAboveQuote() }
            }
            .photosPicker(isPresented: $showingPhotoPicker, selection: $pickedPhotos, maxSelectionCount: 10,
                          matching: .any(of: [.images, .videos]), photoLibrary: .shared())
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                Task { await addPhotos(items) }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { image in
                    if let file = AttachmentFiles.fromCamera(image, number: photoNumber) {
                        addAttachment(filename: file.filename, mimeType: file.mimeType, data: file.data)
                    }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showingScanner) {
                DocumentScanner { pdf in
                    addAttachment(filename: "Scan \(scanNumber).pdf", mimeType: "application/pdf", data: pdf)
                }
                .ignoresSafeArea()
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

    // MARK: - Recipients

    /// The text of the To or Cc field.
    private func addressText(_ field: Field) -> String {
        field == .cc ? (draft.cc ?? "") : draft.to
    }

    /// The name being typed after the last chip.
    private func typedName(in field: Field) -> String {
        PeopleIndex.split(addressText(field)).typing.trimmingCharacters(in: .whitespaces)
    }

    private func setAddresses(_ field: Field, finished: [String], typing: String) {
        let text = finished.map { $0 + ", " }.joined() + typing
        if field == .cc { draft.cc = text } else { draft.to = text }
    }

    /// What's typed becomes a chip once it's a whole address.
    private func commitTyping(in field: Field) {
        let (finished, typing) = PeopleIndex.split(addressText(field))
        let typed = typing.trimmingCharacters(in: .whitespaces)
        guard PeopleIndex.parse(typed) != nil else { return }
        setAddresses(field, finished: finished + [typed], typing: "")
    }

    /// Who's already addressed, and you, never offered again.
    private var alreadyAddressed: Set<String> {
        let entries = PeopleIndex.entries(in: draft.to) + PeopleIndex.entries(in: draft.cc ?? "")
        let accounts = (auth?.accounts.map(\.email) ?? []).map { $0.lowercased() }
        return Set(entries.compactMap { PeopleIndex.parse($0)?.email } + accounts)
    }

    private func suggestions(for field: Field) -> [Person] {
        let typed = typedName(in: field)
        guard !typed.isEmpty else { return [] }
        return people?.suggestions(for: typed, excluding: alreadyAddressed, limit: 5) ?? []
    }

    /// Whoever you're typing, from your own mail: people you write to
    /// first. Picking one completes the name you're on and leaves the field
    /// ready for the next, as Mail and Gmail do.
    @ViewBuilder
    private func recipientSuggestions(for field: Field) -> some View {
        let typed = typedName(in: field)
        let found = suggestions(for: field)
        if typed.isEmpty { suggestedPeople(for: field) }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(found) { person in
                Button { choose(person, in: field) } label: {
                    HStack(spacing: 10) {
                        CorrespondentAvatar(initials: Self.initials(for: person.displayName), size: CGSize(width: 34, height: 34))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.displayName).font(.subheadline.weight(.medium)).foregroundStyle(CorresPalette.ink)
                                .lineLimit(1)
                            Text(person.email).font(.caption).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, CorresSpace.page).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { people?.hide(person.email) } label: {
                        Label("Don\u{2019}t Suggest \(person.displayName)", systemImage: "person.crop.circle.badge.minus")
                    }
                }
                .accessibilityLabel("\(person.displayName), \(person.email)")
                .accessibilityHint("Adds them to \(field == .cc ? "Cc" : "To")")
                .accessibilityAction(named: "Don\u{2019}t Suggest") { people?.hide(person.email) }
                if person.id != found.last?.id {
                    Divider().padding(.leading, CorresSpace.page + 44)
                }
            }
            // Someone Corres doesn't know yet may be in Contacts; asked
            // only then, once.
            if found.isEmpty, typed.count >= 2, people?.canAskForContacts == true, people?.isLookingUp != true {
                Button {
                    Task { await people?.includeContacts() }
                } label: {
                    Label("Include People from Your Contacts", systemImage: "person.crop.circle.badge.plus")
                        .font(.subheadline).foregroundStyle(CorresPalette.accent)
                        .padding(.horizontal, CorresSpace.page).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            if found.isEmpty, people?.isLookingUp == true, typed.count >= 3 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Looking in your mail for \u{201C}\(typed)\u{201D}…").font(.caption).foregroundStyle(CorresPalette.secondary)
                }
                .padding(.horizontal, CorresSpace.page).padding(.vertical, 10)
            }
        }
        .background(found.isEmpty ? Color.clear : CorresPalette.surface)
        // Someone not in synced mail (archived long ago): Gmail is asked,
        // once typing pauses.
        .task(id: typed) {
            guard typed.count >= 3, found.isEmpty, let people else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await people.lookUp(typed, accounts: auth?.accounts.map(\.email) ?? [])
        }
    }

    /// Before you type, as Gmail does it: the people you're in touch with
    /// now, one tap each. Gone the moment you start typing.
    @ViewBuilder
    private func suggestedPeople(for field: Field) -> some View {
        let top = people?.top(excluding: alreadyAddressed) ?? []
        // Same name, different address: maybe different people. Say which.
        let names = top.map(\.displayName)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggested").font(.caption.weight(.semibold)).foregroundStyle(CorresPalette.secondary)
                    .padding(.horizontal, CorresSpace.page)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(top) { person in
                            Button { choose(person, in: field) } label: {
                                VStack(spacing: 6) {
                                    CorrespondentAvatar(initials: Self.initials(for: person.displayName), size: CGSize(width: 52, height: 52))
                                    Text(person.displayName)
                                        .font(.caption).foregroundStyle(CorresPalette.ink)
                                        .multilineTextAlignment(.center).lineLimit(2)
                                        .frame(width: 72)
                                    if names.filter({ $0 == person.displayName }).count > 1 {
                                        Text(person.email.split(separator: "@").last.map(String.init) ?? person.email)
                                            .font(.caption2).foregroundStyle(CorresPalette.secondary)
                                            .lineLimit(1).frame(width: 72)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Text(person.email)
                                Button { people?.hide(person.email) } label: {
                                    Label("Don\u{2019}t Suggest \(person.displayName)", systemImage: "person.crop.circle.badge.minus")
                                }
                            }
                            .accessibilityLabel("\(person.displayName), \(person.email)")
                            .accessibilityHint("Adds them to \(field == .cc ? "Cc" : "To")")
                        }
                    }
                    .padding(.horizontal, CorresSpace.page)
                }
            }
            .padding(.vertical, 10)
            .transition(.opacity)
        }
    }

    private func choose(_ person: Person, in field: Field) {
        setAddresses(field, finished: PeopleIndex.split(addressText(field)).finished + [person.address], typing: "")
    }

    /// To or Cc as Mail shows them: each recipient a chip (tap for its
    /// address or to remove it), then room to type the next. A comma, a
    /// space after a whole address, Return, or leaving the field finishes
    /// one; pasting a list makes a chip of each.
    private func recipientField(_ field: Field) -> some View {
        let (finished, _) = PeopleIndex.split(addressText(field))
        let typing = Binding<String>(
            get: { PeopleIndex.split(addressText(field)).typing },
            set: { value in
                let current = PeopleIndex.split(addressText(field)).finished
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if value.contains(where: { $0 == "," || $0 == ";" }) {
                    let parts = PeopleIndex.split(value)
                    setAddresses(field, finished: current + parts.finished, typing: parts.typing)
                } else if value.hasSuffix(" "), PeopleIndex.parse(trimmed) != nil, !trimmed.contains(" ") {
                    setAddresses(field, finished: current + [trimmed], typing: "")
                } else {
                    setAddresses(field, finished: current, typing: value)
                }
            })
        return HStack(alignment: .top, spacing: 12) {
            Text(field == .cc ? "Cc" : "To").font(.subheadline).foregroundStyle(CorresPalette.secondary)
                .frame(width: 64, alignment: .leading).frame(minHeight: 44)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array(finished.enumerated()), id: \.offset) { index, entry in
                    recipientChip(entry, at: index, in: field)
                }
                TextField(finished.isEmpty ? (field == .cc ? "Optional" : "Recipient") : "", text: typing)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                    .submitLabel(.next)
                    .onSubmit {
                        commitTyping(in: field)
                        focusedField = field == .to ? .subject : .subject
                    }
                    .focused($focusedField, equals: field)
                    .frame(minWidth: 90, minHeight: 32)
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, CorresSpace.page).frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = field }
    }

    private func recipientChip(_ entry: String, at index: Int, in field: Field) -> some View {
        let parsed = PeopleIndex.parse(entry)
        let label = parsed.map { $0.name.isEmpty ? (people?.suggestions(for: $0.email, limit: 1).first { $0.email == parsed?.email }?.displayName ?? $0.email) : $0.name } ?? entry
        return Menu {
            if let email = parsed?.email {
                Section(email) {
                    Button { UIPasteboard.general.string = email } label: { Label("Copy Address", systemImage: "doc.on.doc") }
                }
            }
            Button(role: .destructive) {
                var finished = PeopleIndex.split(addressText(field)).finished
                if finished.indices.contains(index) { finished.remove(at: index) }
                setAddresses(field, finished: finished, typing: PeopleIndex.split(addressText(field)).typing)
            } label: { Label("Remove", systemImage: "minus.circle") }
        } label: {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(parsed == nil ? CorresPalette.alert : CorresPalette.accent)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background((parsed == nil ? CorresPalette.alert : CorresPalette.accent).opacity(0.12), in: Capsule())
        }
        .accessibilityLabel(parsed == nil ? "\(entry), not a valid address" : "\(label), \(parsed?.email ?? "")")
        .accessibilityHint("Shows options for this recipient")
    }

    private static func initials(for name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    /// One row that scrolls sideways, so ten photos don't push the message
    /// off the screen: a thumbnail for pictures, the name and size, and a
    /// remove button.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { attachment in
                    HStack(spacing: 8) {
                        AttachmentThumbnail(attachment: attachment)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.filename).font(.footnote.weight(.medium)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                .font(.caption2).foregroundStyle(CorresPalette.secondary)
                        }
                        .frame(maxWidth: 140, alignment: .leading)
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { draft.attachments.removeAll { $0.id == attachment.id } }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(CorresPalette.tertiary)
                                .frame(minWidth: 28, minHeight: 28)
                        }
                        .accessibilityLabel("Remove \(attachment.filename)")
                    }
                    .padding(.leading, 6).padding(.trailing, 4).padding(.vertical, 6)
                    .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding(.horizontal, CorresSpace.page).padding(.vertical, 8)
        }
        .animation(.snappy(duration: 0.2), value: draft.attachments.count)
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

    /// "Photo 3": counts the photos already attached, so names don't repeat.
    private var photoNumber: Int {
        draft.attachments.filter { $0.filename.hasPrefix("Photo ") || $0.filename.hasPrefix("Video ") }.count + 1
    }
    private var scanNumber: Int { draft.attachments.filter { $0.filename.hasPrefix("Scan ") }.count + 1 }

    /// In the order picked. iPhone photos go as JPEG (see `AttachmentFiles`).
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        defer { pickedPhotos = [] }
        var failed = 0
        var shrank = 0
        for item in items {
            guard var file = await AttachmentFiles.fromPhotosItem(item, number: photoNumber) else { failed += 1; continue }
            // Too big to fit with the rest: made smaller, as Mail does,
            // rather than refused. Videos and files keep their size.
            if draft.attachmentsSizeBytes + file.data.count > Draft.maxAttachmentsBytes,
               file.mimeType.hasPrefix("image/"), let smaller = AttachmentFiles.shrunk(file.data) {
                file = (file.filename.replacingOccurrences(of: #"\.[A-Za-z0-9]+$"#, with: ".jpg", options: .regularExpression),
                        "image/jpeg", smaller)
                shrank += 1
            }
            addAttachment(filename: file.filename, mimeType: file.mimeType, data: file.data)
        }
        if shrank > 0, failed == 0, attachmentError == nil {
            attachmentNote = shrank == 1 ? "A photo was made smaller to fit Gmail's 25 MB limit."
                                         : "\(shrank) photos were made smaller to fit Gmail's 25 MB limit."
        }
        if failed > 0 { attachmentError = failed == 1 ? "One item couldn't be loaded." : "\(failed) items couldn't be loaded." }
    }

    /// `.fileImporter` hands back security-scoped URLs: access must be
    /// explicitly started before reading and stopped afterward, or the read
    /// fails (or worse, silently succeeds once and then breaks later),
    /// per Apple's own documented contract for these URLs.
    private func addFiles(_ urls: [URL]) {
        for url in urls {
            guard let data = AttachmentFiles.read(url) else {
                attachmentError = "Could not open \(url.lastPathComponent)."
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
            return Draft(kind: kind, threadID: id, fromAccount: id.account, to: replyAddresses.joined(separator: ", "),
                         subject: subject.hasPrefix("Re: ") ? subject : "Re: \(subject)",
                         body: quoted)
        case .replyAll:
            return Draft(kind: kind, threadID: id, fromAccount: id.account, to: replyAddresses.joined(separator: ", "),
                         cc: replyAllCc.isEmpty ? nil : replyAllCc.joined(separator: ", "),
                         subject: subject.hasPrefix("Re: ") ? subject : "Re: \(subject)",
                         body: quoted)
        case .forward:
            return Draft(kind: .forward, threadID: id, fromAccount: id.account, to: "",
                         subject: subject.hasPrefix("Fwd: ") ? subject : "Fwd: \(subject)",
                         body: quoted)
        }
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

/// A small preview of an attached picture, or its kind of file.
private struct AttachmentThumbnail: View {
    let attachment: PendingAttachment
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: symbol).font(.footnote).foregroundStyle(CorresPalette.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .background(CorresPalette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .task(id: attachment.id) {
            guard attachment.mimeType.hasPrefix("image/") else { return }
            let data = attachment.data
            image = await Task.detached(priority: .utility) {
                UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 96, height: 96))
            }.value
        }
    }

    private var symbol: String {
        if attachment.mimeType.hasPrefix("video/") { return "film" }
        if attachment.mimeType == "application/pdf" { return "doc.richtext" }
        return "doc"
    }
}

/// Lays chips out in lines, wrapping like text; the last view (the text
/// field) takes what's left of its line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                let size = item.size
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                           proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let isLast = index == subviews.indices.last
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let used = rows[rows.count - 1].width + (rows[rows.count - 1].items.isEmpty ? 0 : spacing)
            if isLast {
                // The field fills the rest of the line, or a line of its own.
                let rest = width - used
                if rest < size.width, !rows[rows.count - 1].items.isEmpty { rows.append(Row()) }
                let start = rows[rows.count - 1].width + (rows[rows.count - 1].items.isEmpty ? 0 : spacing)
                size.width = max(size.width, width - start)
            } else if used + size.width > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
            rows[rows.count - 1] = row
        }
        return rows
    }
}

