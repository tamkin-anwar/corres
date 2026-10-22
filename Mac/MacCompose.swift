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
    @State private var inserter = MacTextInserter()
    /// The signature in the body now, to swap or take out.
    @State private var signatureText = ""
    /// Which suggestion Return or Tab would pick.
    @State private var highlighted = 0
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field { case to, cc, bcc, subject, body }

    var body: some View {
        VStack(spacing: 0) {
            fields
            Divider()
            if loaded {
                MacRichEditor(plain: $draft.body, html: $draft.bodyHTML, initialText: initialBody,
                              focusOnAppear: focus == .body, inserter: inserter)
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
            ToolbarItem {
                Menu {
                    TemplateMenuItems(recipientName: firstRecipientName, currentSubject: draft.subject,
                                      currentBody: draft.body) { subject, body in
                        if let subject, draft.subject.trimmingCharacters(in: .whitespaces).isEmpty { draft.subject = subject }
                        inserter.insert(body)
                    }
                    Divider()
                    SettingsLink { Text("Manage Templates…") }
                } label: {
                    Label("Templates", systemImage: "text.badge.plus")
                }
                .help("Templates")
            }
            ToolbarItem { signatureMenu }
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
        .task {
            load()
            // Your other addresses, and who to suggest as you type.
            await SendAsDirectory.shared.refresh(accounts: accounts)
            chooseDefaultAddress()
            services.people.update(from: services.store.threads, accounts: accounts)
        }
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

    /// The first person it's going to, by name, for a template's
    /// {first name}.
    private var firstRecipientName: String? {
        PeopleIndex.entries(in: draft.to).compactMap { PeopleIndex.parse($0) }.first
            .flatMap { $0.name.isEmpty ? nil : Person.readable($0.name) }
    }

    @State private var sent = false

    private var accounts: [String] { services.auth.accounts.map(\.email) }

    private var fields: some View {
        VStack(spacing: 0) {
            addressField(String(localized: "To"), .to) {
                if !showsCc {
                    Button("Cc/Bcc") { showsCc = true; focus = .cc }.buttonStyle(.borderless).foregroundStyle(CorresPalette.secondary)
                        .help("Add Cc and Bcc")
                }
            }
            if showsCc {
                Divider().padding(.leading, 14)
                addressField(String(localized: "Cc"), .cc) { EmptyView() }
                Divider().padding(.leading, 14)
                addressField(String(localized: "Bcc"), .bcc) { EmptyView() }
            }
            Divider().padding(.leading, 14)
            field(String(localized: "Subject")) { TextField("", text: $draft.subject).focused($focus, equals: .subject) }
            if fromOptions.count > 1 {
                Divider().padding(.leading, 14)
                field(String(localized: "From")) {
                    Picker("", selection: fromSelection) {
                        ForEach(fromOptions, id: \.tag) { option in
                            Text(option.address.name.isEmpty ? option.address.email : "\(option.address.name) <\(option.address.email)>")
                                .tag(option.tag)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
            }
        }
        .textFieldStyle(.plain)
        .onChange(of: fromAccount) { old, account in
            draft.fromAccount = account
            // Each account's own signature.
            if loaded, !old.isEmpty, old != account { useSignature(CorresSettings.signature(for: account, reply: draft.kind != .new)) }
        }
        .onChange(of: focus) { highlighted = 0 }
    }

    // MARK: Addresses

    private func addressText(_ field: Field) -> String {
        switch field {
        case .cc: draft.cc ?? ""
        case .bcc: draft.bcc ?? ""
        default: draft.to
        }
    }

    private func setAddressText(_ field: Field, _ text: String) {
        switch field {
        case .cc: draft.cc = text.isEmpty ? nil : text
        case .bcc: draft.bcc = text.isEmpty ? nil : text
        default: draft.to = text
        }
    }

    /// To, Cc or Bcc, with the people you email suggested as you type a
    /// name: ↑ and ↓ to choose, Return or Tab to pick.
    private func addressField<Trailing: View>(_ title: String, _ which: Field, @ViewBuilder trailing: () -> Trailing) -> some View {
        let found = focus == which ? suggestions(for: which) : []
        return VStack(spacing: 0) {
            field(title) {
                TextField("", text: Binding(get: { addressText(which) }, set: { setAddressText(which, $0); highlighted = 0 }))
                    .focused($focus, equals: which)
                    .onKeyPress(.downArrow) {
                        guard !found.isEmpty else { return .ignored }
                        highlighted = min(highlighted + 1, found.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !found.isEmpty else { return .ignored }
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.return) { pick(found, in: which) }
                    .onKeyPress(.tab) { pick(found, in: which) }
                trailing()
            }
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, person in
                        Button { choose(person, in: which) } label: {
                            HStack(spacing: 10) {
                                CorrespondentAvatar(initials: Self.initials(person.displayName), email: person.email,
                                                    size: CGSize(width: 24, height: 24))
                                Text(person.displayName).foregroundStyle(index == highlighted ? Color.white : CorresPalette.ink)
                                Text(person.email).font(.callout)
                                    .foregroundStyle(index == highlighted ? Color.white.opacity(0.85) : CorresPalette.secondary)
                                Spacer(minLength: 0)
                            }
                            .lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(index == highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { highlighted = index } }
                    }
                }
                .padding(.leading, 74).padding(.trailing, 14).padding(.bottom, 6)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Suggestions")
            }
        }
    }

    /// The name being typed after the last finished address.
    private func suggestions(for which: Field) -> [Person] {
        let typed = PeopleIndex.split(addressText(which)).typing.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        return services.people.suggestions(for: typed, excluding: alreadyAddressed, limit: 5)
    }

    /// Who's already addressed, and you, never offered again.
    private var alreadyAddressed: Set<String> {
        let entries = PeopleIndex.entries(in: draft.to) + PeopleIndex.entries(in: draft.cc ?? "") + PeopleIndex.entries(in: draft.bcc ?? "")
        return Set(entries.compactMap { PeopleIndex.parse($0)?.email } + accounts.map { $0.lowercased() })
            .union(SendAsDirectory.shared.allAddresses)
    }

    private func pick(_ found: [Person], in which: Field) -> KeyPress.Result {
        guard found.indices.contains(highlighted) else { return .ignored }
        choose(found[highlighted], in: which)
        return .handled
    }

    /// Completes the name you're on and leaves the field ready for the next.
    private func choose(_ person: Person, in which: Field) {
        let finished = PeopleIndex.split(addressText(which)).finished + [person.address]
        setAddressText(which, finished.map { $0 + ", " }.joined())
        highlighted = 0
        focus = which
    }

    private static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    // MARK: From

    /// Every address this can go from: each account's own and its send-as
    /// addresses. A reply stays in its conversation's account.
    private var fromOptions: [(tag: String, account: String, address: GmailAPIClient.SendAs)] {
        let choices = replyingTo.map { [$0.id.account] } ?? accounts
        return choices.filter { $0 != "sample" }.flatMap { account in
            SendAsDirectory.shared.addresses(for: account).map { (account + "|" + $0.email.lowercased(), account, $0) }
        }
    }

    private var fromSelection: Binding<String> {
        Binding(
            get: { fromAccount + "|" + (draft.fromAddress ?? fromAccount).lowercased() },
            set: { tag in
                guard let option = fromOptions.first(where: { $0.tag == tag }) else { return }
                draft.fromAddress = option.address.isPrimary ? nil : option.address.email
                draft.fromName = option.address.name.isEmpty ? nil : option.address.name
                fromAccount = option.account
            }
        )
    }

    /// New mail from the account's default send-as address; a reply from
    /// the address of yours it was sent to. Only when nothing's been picked.
    private func chooseDefaultAddress() {
        guard draft.fromAddress == nil, !fromAccount.isEmpty else { return }
        let directory = SendAsDirectory.shared
        let pick = replyingTo.flatMap { directory.address(for: fromAccount, answering: $0) }
            ?? (draft.kind == .new ? directory.defaultAddress(for: fromAccount) : nil)
        guard let pick, !pick.isPrimary else { return }
        draft.fromAddress = pick.email
        draft.fromName = pick.name.isEmpty ? nil : pick.name
    }

    // MARK: Signature

    /// Settings › Signatures, for this one email.
    @ViewBuilder
    private var signatureMenu: some View {
        let all = Signatures.all
        if !all.isEmpty {
            Menu {
                ForEach(all) { signature in
                    let text = signature.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    Button { useSignature(text) } label: {
                        if text == signatureText { Label(signature.name, systemImage: "checkmark") } else { Text(signature.name) }
                    }
                }
                Divider()
                Button { useSignature("") } label: {
                    if signatureText.isEmpty { Label("No Signature", systemImage: "checkmark") } else { Text("No Signature") }
                }
                Divider()
                SettingsLink { Text("Edit Signatures…") }
            } label: {
                Label("Signature", systemImage: "signature")
            }
            .help("Signature")
        }
    }

    /// Puts `text` where the signature is, adds it above the quoted email,
    /// or takes it out for none.
    private func useSignature(_ text: String) {
        guard text != signatureText else { return }
        if !signatureText.isEmpty, inserter.replace(signatureText, with: text) {
            // Swapped in place.
        } else if !text.isEmpty {
            let body = inserter.textView?.string ?? draft.body
            let quote = body.range(of: #"\n\nOn .+ wrote:\n"#, options: .regularExpression)
            let offset = quote.map { body.utf16.distance(from: body.startIndex, to: $0.lowerBound) } ?? (body as NSString).length
            inserter.insert("\n\n" + text, at: offset)
        }
        signatureText = text
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
            let signature = CorresSettings.signature(for: fromAccount, reply: whole.kind != .new)
            signatureText = !signature.isEmpty && whole.body.contains(signature) ? signature : ""
            showsCc = !(whole.cc ?? "").isEmpty || !(whole.bcc ?? "").isEmpty
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
        // Settings › Composing › Send new mail from, for a new email.
        let preferred = CorresSettings.defaultFromAccount.flatMap { accounts.contains($0) ? $0 : nil }
        let account = draft.fromAccount ?? replyingTo?.id.account ?? preferred ?? accounts.first ?? ""
        fromAccount = account
        draft.fromAccount = account.isEmpty ? nil : account
        let signature = CorresSettings.signature(for: account, reply: request.kind != .new)
        if request.serverDraftID == nil {
            draft.body = Draft.adding(signature: signature, to: draft.body)
        }
        signatureText = !signature.isEmpty && draft.body.contains(signature) ? signature : ""
        showsCc = !(draft.cc ?? "").isEmpty || !(draft.bcc ?? "").isEmpty
        initialBody = draft.body
        // Into To while there's an address to finish, then the message.
        let unfinished = !PeopleIndex.split(draft.to).typing.trimmingCharacters(in: .whitespaces).isEmpty
        focus = draft.to.isEmpty || unfinished ? .to : .body
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
