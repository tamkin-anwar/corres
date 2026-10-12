import SwiftUI

/// Settings → Out of Office: Gmail's vacation reply, from the phone, as
/// Gmail and Outlook offer it (Mail and Spark don't). Gmail sends the
/// replies itself, so they go out with this iPhone off.
struct OutOfOfficeView: View {
    let auth: GoogleAuthService
    @State private var account = ""
    @State private var vacation = GmailAPIClient.Vacation(enableAutoReply: false)
    @State private var start = Date.now
    @State private var hasEnd = true
    @State private var end = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var state: LoadState = .loading
    @State private var saving = false
    @State private var message: String?
    private let client = GmailAPIClient()

    enum LoadState { case loading, needsPermission, ready, failed }

    var body: some View {
        Form {
            if auth.accounts.count > 1 {
                Picker("Account", selection: $account) {
                    ForEach(auth.accounts) { Text($0.email).tag($0.email) }
                }
            }
            switch state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .needsPermission:
                Section {
                    Button("Allow Corres to Change Out of Office") { Task { await allow() } }
                } footer: {
                    Text(message ?? "Google asks once for permission to change this setting for \(account). Corres asks only now, not when you sign in.")
                }
            case .failed:
                Section {
                    Button("Try Again") { Task { await load() } }
                } footer: {
                    Text("Couldn't reach Gmail. Check your connection.")
                }
            case .ready:
                Section {
                    Toggle("Out of Office", isOn: $vacation.enableAutoReply)
                } footer: {
                    Text("While it's on, Gmail answers new email with your message, once per sender every few days, and sends it even with this iPhone off.")
                }
                if vacation.enableAutoReply {
                    Section("When") {
                        DatePicker("Starts", selection: $start, displayedComponents: [.date, .hourAndMinute])
                        Toggle("Ends", isOn: $hasEnd)
                        if hasEnd {
                            DatePicker("Ends", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                        }
                    }
                    Section("Message") {
                        TextField("Subject", text: Binding(get: { vacation.responseSubject ?? "" },
                                                           set: { vacation.responseSubject = $0 }))
                        TextField("I'm away until…", text: Binding(get: { vacation.responseBodyPlainText ?? "" },
                                                                   set: {
                                                                       vacation.responseBodyPlainText = $0
                                                                       // Changed here: this is the message now.
                                                                       vacation.responseBodyHtml = nil
                                                                   }), axis: .vertical)
                            .lineLimit(4...10)
                    }
                    Section {
                        Toggle("Only Reply to My Contacts", isOn: Binding(get: { vacation.restrictToContacts ?? false },
                                                                         set: { vacation.restrictToContacts = $0 }))
                    }
                }
                Section {
                    Button(saving ? "Saving\u{2026}" : "Save") { Task { await save() } }
                        .disabled(saving || isMissingMessage)
                } footer: {
                    if isMissingMessage { Text("Write the message Gmail should send.") }
                    else if let message { Text(message) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Out of Office")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if account.isEmpty { account = auth.primaryAccount?.email ?? "" }
            await load()
        }
        .onChange(of: account) { Task { await load() } }
    }

    private func load() async {
        guard !account.isEmpty else { return }
        state = .loading
        message = nil
        guard await auth.canManageSettings(account) else { state = .needsPermission; return }
        do {
            var loaded = try await client.vacation(account: account)
            // Written on Gmail's website: shown as its words.
            if (loaded.responseBodyPlainText ?? "").isEmpty, let html = loaded.responseBodyHtml,
               let text = try? NSAttributedString(data: Data(html.utf8),
                                                  options: [.documentType: NSAttributedString.DocumentType.html,
                                                            .characterEncoding: String.Encoding.utf8.rawValue],
                                                  documentAttributes: nil).string {
                loaded.responseBodyPlainText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            vacation = loaded
            if let ms = loaded.startTime.flatMap(Double.init) { start = Date(timeIntervalSince1970: ms / 1000) }
            if let ms = loaded.endTime.flatMap(Double.init) { end = Date(timeIntervalSince1970: ms / 1000); hasEnd = true }
            // On with no end date (set elsewhere): kept that way, not given
            // a week's end on the next save.
            else if loaded.enableAutoReply { hasEnd = false }
            state = .ready
        } catch {
            state = .failed
        }
    }

    private func allow() async {
        message = nil
        if await auth.grantSettings(for: account) {
            await load()
        } else {
            message = "Google didn\u{2019}t give Corres permission. Make sure you pick \(account) and tick the Gmail settings box."
        }
    }

    /// On with no message would send an empty reply.
    private var isMissingMessage: Bool {
        vacation.enableAutoReply && (vacation.responseBodyPlainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var updated = vacation
        updated.startTime = String(Int64(start.timeIntervalSince1970 * 1000))
        updated.endTime = hasEnd ? String(Int64(end.timeIntervalSince1970 * 1000)) : nil
        do {
            try await client.setVacation(updated, account: account)
            vacation = updated
            message = updated.enableAutoReply
                ? "On. Gmail will reply from \(start.formatted(date: .abbreviated, time: .shortened))\(hasEnd ? " until \(end.formatted(date: .abbreviated, time: .shortened))" : "")."
                : "Off. No automatic replies."
        } catch {
            message = "Couldn't save. Please try again."
        }
    }
}
