import SwiftUI

/// Settings → Out of Office: Gmail's vacation reply or Outlook's automatic
/// replies, from the phone, as Gmail and Outlook offer it (Mail and Spark
/// don't). The service sends the
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
    private let client = MailClient()

    enum LoadState { case loading, needsPermission, ready, failed }

    private var isOutlook: Bool { MailAccounts.provider(for: account) == .microsoft }
    /// Who sends the replies: "Gmail" or "Outlook".
    private var service: String { MailAccounts.provider(for: account).title }

    var body: some View {
        Form {
            if auth.accounts.count > 1 {
                Picker("Account", selection: $account) {
                    ForEach(auth.accounts) { Text($0.email).tag($0.email) }
                }
            }
            if MailAccounts.provider(for: account) == .imap {
                Section {} footer: {
                    Text("Other mail apps can't change this service's automatic reply. Set it on your email provider's website, usually under Settings, then Vacation or Auto Reply.")
                }
            } else if MailAccounts.provider(for: account) == .icloud {
                Section {
                    Link("Open iCloud Mail Settings", destination: URL(string: "https://www.icloud.com/mail/")!)
                } footer: {
                    Text("Apple doesn't let other mail apps change iCloud's automatic reply. Set it at icloud.com/mail, under Settings, then Vacation.")
                }
            } else {
            switch state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .needsPermission:
                Section {
                    Button("Allow Corres to Change Out of Office") { Task { await allow() } }
                } footer: {
                    Text(message ?? String(localized: "Google asks once for permission to change this setting for \(account). Corres asks only now, not when you sign in."))
                }
            case .failed:
                Section {
                    Button("Try Again") { Task { await load() } }
                } footer: {
                    Text("Couldn't reach \(service). Check your connection.")
                }
            case .ready:
                Section {
                    Toggle("Out of Office", isOn: $vacation.enableAutoReply)
                } footer: {
                    Text("While it's on, \(service) answers new email with your message and sends it even with this \(Device.name) off.")
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
                        // Outlook's automatic reply has no subject of its own.
                        if !isOutlook {
                            TextField("Subject", text: Binding(get: { vacation.responseSubject ?? "" },
                                                               set: { vacation.responseSubject = $0 }))
                        }
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
                    if isMissingMessage { Text("Write the message \(service) should send.") }
                    else if let message { Text(message) }
                }
            }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Out of Office")
        .inlineTitle()
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
            message = String(localized: "Google didn\u{2019}t give Corres permission. Make sure you pick \(account) and tick the Gmail settings box.")
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
            let from = start.formatted(date: .abbreviated, time: .shortened)
            let until = end.formatted(date: .abbreviated, time: .shortened)
            message = !updated.enableAutoReply ? String(localized: "Off. No automatic replies.")
                : hasEnd ? String(localized: "On. \(service) will reply from \(from) until \(until).")
                : String(localized: "On. \(service) will reply from \(from).")
        } catch {
            message = String(localized: "Couldn't save. Try again.")
        }
    }
}
