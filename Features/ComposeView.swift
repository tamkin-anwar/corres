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
    /// To, Cc and Bcc are UIKit fields (`AddressTextField`), which
    /// SwiftUI's focus state can't hold, so they keep their own.
    @State private var addressFocus: Field?
    private var activeField: Field? { addressFocus ?? focusedField }

    private func focus(_ field: Field?) {
        if let field, field.isAddress || field == .body {
            addressFocus = field
        } else {
            addressFocus = nil
            focusedField = field
        }
    }
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

    private enum Field {
        case to, cc, bcc, subject, body
        var isAddress: Bool { self == .to || self == .cc || self == .bcc }
        var title: String { self == .cc ? "Cc" : self == .bcc ? "Bcc" : "To" }
    }
    /// Bcc stays out of the way until asked for, as in Mail and Gmail.
    @State private var showsBcc = false
    @State private var richEditor = RichEditorController()
    /// Bumped whenever Compose itself changes the words (a rewrite, a
    /// snippet, dictation, a new signature), the only time the editor takes
    /// them from outside.
    @State private var bodyRevision = 0
    /// The Aa strip: bold, italic, underline, strikethrough, lists, link.
    @State private var showsFormatting = false
    @State private var addingLink = false
    @State private var linkText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fields and suggestions appearing: brief, no bounce (Apple's "brief
    /// and precise"), a plain fade with Reduce Motion.
    private var reveal: Animation { reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3, extraBounce: 0) }
    private var revealTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -8)), removal: .opacity)
    }
    /// Sent or deleted: nothing left to save when Compose closes.
    @State private var isFinished = false
    /// The chip Backspace has picked, ready to go on the next Backspace
    /// (Mail's two-step delete, so one stray tap never loses a recipient).
    @State private var selectedChip: (field: Field, index: Int)?

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
        // A reply, Reply All or a saved draft arrives with its people
        // already written in: chips from the start, as in Mail, not text
        // that looks half-typed.
        initial.to = Self.chipped(initial.to)
        initial.cc = initial.cc.map(Self.chipped)
        initial.bcc = initial.bcc.map(Self.chipped)
        self._draft = State(initialValue: initial)
        self.initialDraft = initial
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The address fields, animated together as focus moves
                    // (suggestions in and out, Bcc opening); never the
                    // message you're typing.
                    VStack(alignment: .leading, spacing: 0) {
                    if fromOptions.count > 1 {
                        fromPicker
                        Divider().padding(.leading, CorresSpace.page)
                    }
                    recipientField(.to)
                    if activeField == .to { recipientSuggestions(for: .to).transition(revealTransition) }
                    Divider().padding(.leading, CorresSpace.page)
                    recipientField(.cc)
                    if activeField == .cc { recipientSuggestions(for: .cc).transition(revealTransition) }
                    Divider().padding(.leading, CorresSpace.page)
                    if showsBcc || !(draft.bcc ?? "").isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            recipientField(.bcc)
                            if activeField == .bcc { recipientSuggestions(for: .bcc).transition(revealTransition) }
                            Divider().padding(.leading, CorresSpace.page)
                        }
                        .transition(revealTransition)
                    }
                    bccNotices
                    }
                    .animation(reveal, value: activeField)
                    .animation(reveal, value: showsBcc)
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
                    // Formatting (bold, lists, links) needs a UIKit text view;
                    // its plain words still drive everything else.
                    RichBodyEditor(text: $draft.body, html: $draft.bodyHTML, controller: richEditor, revision: bodyRevision,
                                   isFocused: addressFocus == .body,
                                   onFocus: { focused in
                                       if focused { addressFocus = .body } else if addressFocus == .body { addressFocus = nil }
                                   })
                        .padding(.horizontal, CorresSpace.page)
                        .padding(.vertical, 4)
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
                    // Tap sends; press and hold for Send Later, as in Mail.
                    Button("Send") { checkThenSend() }
                    .fontWeight(.semibold)
                    .prominentToolbarButton()
                    .disabled(!canSend)
                    .contextMenu {
                        Section("Send Later") {
                            ForEach(ScheduledSends.suggestions(), id: \.date) { option in
                                Button {
                                    checkThenSend(at: option.date)
                                } label: {
                                    Text(option.title)
                                    Text(ScheduledSends.describe(option.date).capitalizedFirst)
                                }
                            }
                            Button { showingSendLaterPicker = true } label: { Label("Pick a Time\u{2026}", systemImage: "calendar") }
                        }
                    }
                    .accessibilityHint("Press and hold to send later")
                }
            }
            // "See attached", and nothing attached: Gmail and Outlook ask too.
            .confirmationDialog("Did you mean to attach something?", isPresented: $confirmingNoAttachment, titleVisibility: .visible) {
                Button("Attach a File") { showingFileImporter = true }
                Button("Attach a Photo") { showingPhotoPicker = true }
                Button(pendingSendAt == nil ? "Send Anyway" : "Schedule Anyway") { checkThenSend(skippingAttachment: true) }
                Button("Keep Editing", role: .cancel) { pendingSendAt = nil }
            } message: {
                Text("Your email mentions an attachment, but nothing is attached.")
            }
            .confirmationDialog("Send without a subject?", isPresented: $confirmingNoSubject, titleVisibility: .visible) {
                Button(pendingSendAt == nil ? "Send" : "Schedule") { sendAndDismiss() }
                Button("Add a Subject", role: .cancel) { pendingSendAt = nil; focusedField = .subject }
            }
            .sheet(isPresented: $showingSendLaterPicker) {
                NavigationStack {
                    DatePicker("Send at", selection: $sendLaterDate, in: Date.now.addingTimeInterval(60)...,
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .tint(CorresPalette.accent)
                        .padding(.horizontal, CorresSpace.page)
                    Text("Corres sends it from this iPhone at that time, or the moment it can if your iPhone is off or offline.")
                        .font(.footnote).foregroundStyle(CorresPalette.secondary)
                        .padding(.horizontal, CorresSpace.page)
                    Spacer()
                        .navigationTitle("Send Later")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingSendLaterPicker = false } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Schedule") {
                                    showingSendLaterPicker = false
                                    checkThenSend(at: sendLaterDate)
                                }
                                .fontWeight(.semibold)
                            }
                        }
                }
                .presentationDetents([.large])
            }
            // Mail's choices: keep it (saved to Drafts, a tap away at the
            // bottom of the screen) or delete it.
            .confirmationDialog("Save this draft?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
                Button("Save Draft") { dismiss() }
                Button("Delete Draft", role: .destructive) {
                    isFinished = true
                    outbox.discard(draft, replyingTo: sourceThread)
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Saved drafts wait at the bottom of the screen and in Drafts, on every device.")
            }
            // Swiping Compose away never loses what you wrote: it's saved
            // and tucked away, as Gmail saves and Mail minimizes.
            .onDisappear {
                if !isFinished, hasUnsavedChanges || draft.gmailDraftID != nil {
                    outbox.shelve(draft, replyingTo: sourceThread)
                }
            }
            // Who to suggest: current as Compose opens, and your Sent
            // history read once if it hasn't been yet.
            .task {
                let accounts = auth?.accounts.map(\.email) ?? []
                await SendAsDirectory.shared.refresh(accounts: accounts)
                chooseDefaultFrom()
                people?.update(from: store.threads, accounts: accounts)
                await people?.backfillIfNeeded(accounts: accounts)
            }
            // Leaving To, Cc or Bcc turns a finished address into a chip.
            .onChange(of: addressFocus) { old, _ in
                if let old, old.isAddress { commitTyping(in: old) }
                selectedChip = nil
            }
            // Subject or the message took over.
            .onChange(of: focusedField) { _, new in
                if new != nil { addressFocus = nil }
            }
            .onAppear {
                focus(draft.to.isEmpty ? .to : .body)
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
            if showsFormatting { formattingStrip.transition(.move(edge: .bottom).combined(with: .opacity)) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Aa: bold, italic, lists, links, as Mail's Aa.
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { showsFormatting.toggle() }
                    } label: {
                        Text("Aa").font(.subheadline.weight(.semibold)).frame(minWidth: 22)
                    }
                    .buttonStyle(CorresPillStyle())
                    .accessibilityLabel(showsFormatting ? "Hide formatting" : "Formatting")
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
                            bodyRevision += 1
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

    /// Bold, italic, underline, strikethrough, bullets, numbers, link: each
    /// lit when it's on where you're typing.
    private var formattingStrip: some View {
        HStack(spacing: 4) {
            formatButton("bold", "Bold", on: richEditor.isBold) { richEditor.toggle(.bold) }
            formatButton("italic", "Italic", on: richEditor.isItalic) { richEditor.toggle(.italic) }
            formatButton("underline", "Underline", on: richEditor.isUnderline) { richEditor.toggle(.underline) }
            formatButton("strikethrough", "Strikethrough", on: richEditor.isStrikethrough) { richEditor.toggle(.strikethrough) }
            Divider().frame(height: 22).padding(.horizontal, 4)
            formatButton("list.bullet", "Bulleted list", on: richEditor.isBulleted) { richEditor.toggleList(numbered: false) }
            formatButton("list.number", "Numbered list", on: richEditor.isNumbered) { richEditor.toggleList(numbered: true) }
            formatButton("link", "Add link", on: false) { linkText = ""; addingLink = true }
        }
        .padding(.horizontal, CorresSpace.page).padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Add Link", isPresented: $addingLink) {
            TextField("https://", text: $linkText)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add") {
                let typed = linkText.trimmingCharacters(in: .whitespaces)
                let withScheme = typed.contains("://") ? typed : "https://" + typed
                if !typed.isEmpty, let url = URL(string: withScheme) { richEditor.addLink(url, title: nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Select words first to link them; otherwise the address itself is added.")
        }
    }

    private func formatButton(_ symbol: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 40, height: 36)
                .foregroundStyle(on ? Color.white : CorresPalette.ink)
                .background(on ? CorresPalette.accent : CorresPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
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
        bodyRevision += 1
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
            bodyRevision += 1
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
        draft.to != initialDraft.to || draft.cc != initialDraft.cc || draft.bcc != initialDraft.bcc || draft.subject != initialDraft.subject
            || draft.body != initialDraft.body || !draft.attachments.isEmpty
    }

    private func attemptDismiss() {
        // A saved draft always offers Delete too, not only once changed.
        if hasUnsavedChanges || draft.gmailDraftID != nil { showingDiscardConfirmation = true } else { dismiss() }
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
            bodyRevision += 1
        } else if !newSignature.isEmpty {
            draft.body = Self.addingSignature(to: draft.body, account: new)
            bodyRevision += 1
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

    @State private var confirmingNoAttachment = false
    @State private var showingSendLaterPicker = false
    @State private var sendLaterDate = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
    /// When it's to go, if later; carried through the checks.
    @State private var pendingSendAt: Date?

    /// The checks before anything goes: a promised attachment, then a
    /// subject. Each asks once and never blocks. `at`: Send Later.
    private func checkThenSend(at sendAt: Date? = nil, skippingAttachment: Bool = false) {
        if let sendAt { pendingSendAt = sendAt }
        if !skippingAttachment, draft.attachments.isEmpty, MailDigest.mentionsAttachment(draft.body) {
            confirmingNoAttachment = true
        } else if !draft.hasSubject {
            confirmingNoSubject = true
        } else {
            sendAndDismiss()
        }
    }

    private func sendAndDismiss() {
        isFinished = true
        if outbox.shelved?.id == draft.id { outbox.clearShelf() }
        if let sendAt = pendingSendAt {
            ScheduledSends.shared.schedule(draft, at: sendAt)
            dismiss()
            return
        }
        outbox.queueSend(draft, replyingTo: sourceThread)
        dismiss()
    }

    // MARK: - Recipients

    /// The text of the To or Cc field.
    private func addressText(_ field: Field) -> String {
        switch field {
        case .cc: draft.cc ?? ""
        case .bcc: draft.bcc ?? ""
        default: draft.to
        }
    }

    /// The name being typed after the last chip.
    private func typedName(in field: Field) -> String {
        PeopleIndex.split(addressText(field)).typing.trimmingCharacters(in: .whitespaces)
    }

    private func setAddresses(_ field: Field, finished: [String], typing: String) {
        let text = finished.map { $0 + ", " }.joined() + typing
        switch field {
        case .cc: draft.cc = text
        case .bcc: draft.bcc = text
        default: draft.to = text
        }
    }

    /// "a@x.com, Sara <s@y.com>" as chips: a trailing finished address
    /// counts as one.
    private static func chipped(_ field: String) -> String {
        let (finished, typing) = PeopleIndex.split(field)
        let typed = typing.trimmingCharacters(in: .whitespaces)
        guard PeopleIndex.parse(typed) != nil else { return field }
        return (finished + [typed]).map { $0 + ", " }.joined()
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
        let entries = PeopleIndex.entries(in: draft.to) + PeopleIndex.entries(in: draft.cc ?? "") + PeopleIndex.entries(in: draft.bcc ?? "")
        let accounts = (auth?.accounts.map(\.email) ?? []).map { $0.lowercased() }
        // Your send-as addresses are you, not someone to write to.
        return Set(entries.compactMap { PeopleIndex.parse($0)?.email } + accounts).union(SendAsDirectory.shared.allAddresses)
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
                        CorrespondentAvatar(initials: Self.initials(for: person.displayName), email: person.email, size: CGSize(width: 34, height: 34))
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
                .accessibilityHint("Adds them to \(field.title)")
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
        let ownNames = Set((auth?.accounts ?? []).compactMap { auth?.profile(for: $0.email)?.name })
        let top = people?.top(excluding: alreadyAddressed, ownNames: ownNames) ?? []
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
                                    CorrespondentAvatar(initials: Self.initials(for: person.displayName), email: person.email, size: CGSize(width: 52, height: 52))
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
                            .accessibilityHint("Adds them to \(field.title)")
                        }
                        // Photos and everyone in Contacts, asked once,
                        // at the end of the row rather than as a pop-up.
                        if people?.canAskForContacts == true, CorresSettings.suggestContacts {
                            Button {
                                Task { await people?.includeContacts() }
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "person.crop.circle.badge.plus")
                                        .font(.system(size: 22, weight: .regular))
                                        .foregroundStyle(CorresPalette.accent)
                                        .frame(width: 52, height: 52)
                                        .background(CorresPalette.accent.opacity(0.1), in: Circle())
                                    Text("Add from Contacts")
                                        .font(.caption).foregroundStyle(CorresPalette.accent)
                                        .multilineTextAlignment(.center).lineLimit(2)
                                        .frame(width: 72)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows people from your Contacts, with their photos. Stays on this iPhone.")
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
                if !value.isEmpty { selectedChip = nil }
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
            Text(field.title).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                .frame(width: 64, alignment: .leading).frame(minHeight: 44)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array(finished.enumerated()), id: \.offset) { index, entry in
                    recipientChip(entry, at: index, in: field)
                }
                // UIKit underneath: SwiftUI's TextField never reports a
                // Backspace in an empty field, which is how Mail removes
                // the last recipient. The first picks it, the second
                // removes it, so one stray press never loses anyone.
                AddressTextField(text: typing, placeholder: finished.isEmpty ? (field == .to ? "Recipient" : "Optional") : "",
                                 isFocused: addressFocus == field,
                                 onFocus: { focused in
                                     if focused { addressFocus = field } else if addressFocus == field { addressFocus = nil }
                                 },
                                 onEmptyBackspace: { backspace(in: field) },
                                 onSubmit: {
                                     commitTyping(in: field)
                                     focus(.subject)
                                 })
                    .accessibilityLabel(field.title)
                    .frame(minWidth: 90, minHeight: 32)
                    .frame(minWidth: 90, minHeight: 32)
            }
            .padding(.vertical, 6)
            if field == .cc, !showsBcc, (draft.bcc ?? "").isEmpty {
                Button("Bcc") {
                    withAnimation(reveal) { showsBcc = true }
                    focus(.bcc)
                }
                .transition(.opacity)
                .font(.subheadline).foregroundStyle(CorresPalette.accent)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("Adds a Bcc field: people copied without the others seeing")
            }
        }
        .padding(.horizontal, CorresSpace.page).frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { focus(field) }
    }

    /// Backspace with nothing typed: picks the last recipient, and a
    /// second press removes it, as in Mail.
    private func backspace(in field: Field) {
        let current = PeopleIndex.split(addressText(field)).finished
        guard !current.isEmpty else { return }
        if let chosen = selectedChip, chosen.field == field, current.indices.contains(chosen.index) {
            var remaining = current
            remaining.remove(at: chosen.index)
            setAddresses(field, finished: remaining, typing: "")
            selectedChip = nil
        } else {
            selectedChip = (field, current.count - 1)
        }
    }

    // MARK: - Bcc, when it matters

    /// Bcc is out of the way until it matters, and then Corres says so:
    /// - replying to all on an email you were Bcc'd on would show everyone
    ///   you had it (Gmail warns since 2026; here it's one tap to fix);
    /// - a new email to a crowd in To shows them all each other's
    ///   addresses (one tap moves them to Bcc).
    @ViewBuilder
    private var bccNotices: some View {
        if draft.kind == .replyAll, let source = sourceThread, source.reachedYouHidden, !dismissedHiddenNotice {
            bccNotice("You weren't in To or Cc on this email, so you were Bcc'd or it was forwarded to you. Replying to all lets everyone see you had it.",
                      action: "Reply to Sender Only") {
                draft.to = source.replyAddresses.joined(separator: ", ")
                draft.cc = nil
                dismissedHiddenNotice = true
            }
        }
        let crowd = PeopleIndex.entries(in: draft.to)
        if draft.kind == .new, crowd.count >= Self.crowdSize, (draft.bcc ?? "").isEmpty, !dismissedCrowdNotice {
            bccNotice("Sending to \(crowd.count) people? In Bcc, they won't see each other's addresses.",
                      action: "Move All to Bcc") {
                draft.bcc = draft.to
                draft.to = ""
                showsBcc = true
                dismissedCrowdNotice = true
            }
        }
    }

    /// Enough people in To that showing them each other's addresses is
    /// probably not meant: a class, a team list, a party invite.
    private static let crowdSize = 8
    @State private var dismissedHiddenNotice = false
    @State private var dismissedCrowdNotice = false

    private func bccNotice(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "eye.slash")
                .labelStyle(TightLabelStyle())
                .font(.footnote).foregroundStyle(CorresPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action) { withAnimation(.snappy) { perform() } }
                .font(.footnote.weight(.semibold)).foregroundStyle(CorresPalette.accent)
                .frame(minHeight: 32)
        }
        .padding(.horizontal, CorresSpace.page).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CorresPalette.accent.opacity(0.06))
    }

    /// Moves one recipient to another of To, Cc and Bcc: thanking someone
    /// for an introduction and moving them to Bcc (Superhuman's Instant
    /// Intro), or taking a long Cc list out of view.
    private func move(_ index: Int, from field: Field, to target: Field) {
        var from = PeopleIndex.split(addressText(field)).finished
        guard from.indices.contains(index) else { return }
        let entry = from.remove(at: index)
        setAddresses(field, finished: from, typing: PeopleIndex.split(addressText(field)).typing)
        let into = PeopleIndex.split(addressText(target))
        setAddresses(target, finished: into.finished + [entry], typing: into.typing)
        if target == .bcc { showsBcc = true }
        selectedChip = nil
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
            Section {
                ForEach([Field.to, .cc, .bcc].filter { $0 != field }, id: \.self) { target in
                    Button { move(index, from: field, to: target) } label: {
                        Label("Move to \(target.title)", systemImage: target == .bcc ? "eye.slash" : "arrow.right")
                    }
                }
            }
            Button(role: .destructive) {
                var finished = PeopleIndex.split(addressText(field)).finished
                if finished.indices.contains(index) { finished.remove(at: index) }
                setAddresses(field, finished: finished, typing: PeopleIndex.split(addressText(field)).typing)
            } label: { Label("Remove", systemImage: "minus.circle") }
        } label: {
            let isSelected = selectedChip?.field == field && selectedChip?.index == index
            let tint = parsed == nil ? CorresPalette.alert : CorresPalette.accent
            Text(label)
                .font(.subheadline)
                .foregroundStyle(isSelected ? Color.white : tint)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(isSelected ? tint : tint.opacity(0.12), in: Capsule())
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
    /// Every address this can go from: each account's own and its Gmail
    /// send-as addresses. A reply stays in its conversation's account, so
    /// only that account's.
    private var fromOptions: [(account: String, address: GmailAPIClient.SendAs)] {
        let accounts = draft.kind == .new ? (auth?.accounts.map(\.email) ?? []) : [draft.threadID?.account ?? draft.fromAccount].compactMap { $0 }
        return accounts.filter { $0 != "sample" }.flatMap { account in
            SendAsDirectory.shared.addresses(for: account).map { (account, $0) }
        }
    }

    private var fromSelection: String {
        let account = draft.fromAccount ?? draft.threadID?.account ?? auth?.primaryAccount?.email ?? ""
        return account + "|" + (draft.fromAddress ?? account).lowercased()
    }

    private var fromPicker: some View {
        HStack(spacing: 12) {
            Text("From").font(.subheadline).foregroundStyle(CorresPalette.secondary).frame(width: 64, alignment: .leading)
            Picker("From", selection: Binding(
                get: { fromSelection },
                set: { newValue in
                    guard let option = fromOptions.first(where: { $0.account + "|" + $0.address.email == newValue }) else { return }
                    let previous = draft.fromAccount
                    draft.fromAccount = option.account
                    draft.fromAddress = option.address.isPrimary ? nil : option.address.email
                    draft.fromName = option.address.name.isEmpty ? nil : option.address.name
                    if previous != option.account { swapSignature(from: previous, to: option.account) }
                }
            )) {
                ForEach(fromOptions, id: \.address.email) { option in
                    Text(option.address.email).tag(option.account + "|" + option.address.email)
                }
            }
            .labelsHidden()
            Spacer()
        }
        .padding(.horizontal, CorresSpace.page).frame(minHeight: 44)
    }

    /// New mail from Gmail's default send-as address; a reply from the
    /// address of yours it was sent to. Only when nothing's been picked.
    private func chooseDefaultFrom() {
        guard draft.fromAddress == nil else { return }
        let directory = SendAsDirectory.shared
        let account = draft.fromAccount ?? draft.threadID?.account ?? auth?.primaryAccount?.email ?? ""
        let pick = sourceThread.flatMap { directory.address(for: account, answering: $0) }
            ?? (draft.kind == .new ? directory.defaultAddress(for: account) : nil)
        guard let pick, !pick.isPrimary else { return }
        draft.fromAddress = pick.email
        draft.fromName = pick.name.isEmpty ? nil : pick.name
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

/// An address field that hears Backspace even when it's empty (UIKit's
/// `deleteBackward`), which SwiftUI's TextField doesn't pass on. Focus is
/// kept in step with Compose's own `addressFocus`.
private struct AddressTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isFocused: Bool
    var onFocus: (Bool) -> Void
    var onEmptyBackspace: () -> Void
    var onSubmit: () -> Void

    final class Field: UITextField {
        var onEmptyBackspace: (() -> Void)?
        override func deleteBackward() {
            if (text ?? "").isEmpty { onEmptyBackspace?() }
            super.deleteBackward()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressTextField
        init(_ parent: AddressTextField) { self.parent = parent }

        /// What the field last handed out (see RichBodyEditor's).
        var lastText = ""

        @objc func changed(_ field: UITextField) {
            let value = field.text ?? ""
            if value != parent.text { parent.text = value }
            // The binding may have turned it into a chip; show what's left.
            if field.text != parent.text { field.text = parent.text }
            lastText = field.text ?? ""
        }
        func textFieldDidBeginEditing(_ textField: UITextField) { if !parent.isFocused { parent.onFocus(true) } }
        func textFieldDidEndEditing(_ textField: UITextField) { if parent.isFocused { parent.onFocus(false) } }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.keyboardType = .emailAddress
        field.textContentType = .emailAddress
        field.returnKeyType = .next
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.onEmptyBackspace = onEmptyBackspace
        // Only what changed from outside (a chip made, a suggestion picked),
        // never a value a keystroke behind what's typed.
        if text != context.coordinator.lastText, field.text != text {
            field.text = text
            context.coordinator.lastText = text
        }
        if field.placeholder != placeholder {
            field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor.tertiaryLabel])
        }
        // A beat later: becoming first responder while SwiftUI is still
        // laying out is ignored.
        if isFocused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Field, context: Context) -> CGSize? {
        let fitted = uiView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 32))
        return CGSize(width: max(90, fitted.width + 8), height: max(32, fitted.height))
    }
}

private extension String {
    /// "tomorrow at 8:00 AM" → "Tomorrow at 8:00 AM".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
