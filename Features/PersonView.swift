import SwiftUI

/// Who someone is in your mail: tap a sender to see your conversations
/// with them, the files you've exchanged, and what you've decided about
/// them (VIP, allowed, blocked), with each a tap to change. Superhuman's
/// contact pane, from your own mail rather than the web.
struct PersonRef: Identifiable, Hashable {
    let email: String
    let name: String
    let account: String
    var id: String { email.lowercased() }
}

struct PersonView: View {
    let person: PersonRef
    let store: MailStore
    /// Opens one of your conversations with them.
    let open: (ThreadID) -> Void
    /// Starts a new email to them.
    let write: (String) -> Void
    @State private var confirmingBlock = false
    @Environment(\.dismiss) private var dismiss

    private var email: String { person.email.lowercased() }

    /// Everything with them, newest first: what they sent, and what you
    /// sent them.
    private var conversations: [Correspondence] {
        store.searchableThreads.filter { thread in
            thread.senderEmail?.lowercased() == email
                || (thread.isFromAccountOwner && (thread.toRecipients + thread.ccRecipients).contains { $0.lowercased().contains(email) })
        }
        .sorted { $0.receivedAt > $1.receivedAt }
    }

    private var isVIP: Bool { InboxClassifier.isVIP(email) }
    private var decision: SenderDecision? {
        store.threadsIncludingHidden.first { $0.senderEmail?.lowercased() == email }?.senderDecision
    }

    var body: some View {
        let conversations = conversations
        let files = conversations.flatMap { thread in thread.attachments.map { (thread: thread, file: $0) } }
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        CorrespondentAvatar(initials: Self.initials(person.name.isEmpty ? person.email : person.name),
                                            email: person.email, size: CGSize(width: 72, height: 72))
                        Text(person.name.isEmpty ? person.email : person.name)
                            .font(CorresType.heading)
                            .multilineTextAlignment(.center)
                        if !person.name.isEmpty {
                            Text(person.email).font(.subheadline).foregroundStyle(CorresPalette.secondary).textSelection(.enabled)
                        }
                        if let organization = conversations.first?.organization, !organization.isEmpty,
                           organization.lowercased() != person.name.lowercased() {
                            Text(organization).font(.subheadline).foregroundStyle(CorresPalette.tertiary)
                        }
                        HStack(spacing: 10) {
                            Button { write(person.email) } label: { Label("Write", systemImage: "square.and.pencil") }
                                .buttonStyle(CorresPillStyle())
                            Button {
                                Task { await store.setVIP(email, account: person.account, isVIP: !isVIP) }
                            } label: {
                                Label(isVIP ? "VIP" : "Make VIP", systemImage: isVIP ? "star.fill" : "star")
                            }
                            .buttonStyle(CorresPillStyle())
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    LabeledContent("Conversations", value: conversations.count, format: .number)
                    if let last = conversations.first(where: { !$0.isFromAccountOwner }) {
                        LabeledContent("Last email from them") {
                            Text(last.receivedAt, format: .relative(presentation: .named))
                        }
                    }
                    if let lastSent = conversations.first(where: \.isFromAccountOwner) {
                        LabeledContent("You last wrote") {
                            Text(lastSent.receivedAt, format: .relative(presentation: .named))
                        }
                    }
                }

                if !conversations.isEmpty {
                    Section("Recent") {
                        ForEach(conversations.prefix(8)) { thread in
                            Button {
                                open(thread.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(thread.subject.isEmpty ? String(localized: "No subject") : thread.subject)
                                            .foregroundStyle(CorresPalette.ink).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(thread.receivedAt, format: .dateTime.month(.abbreviated).day())
                                            .font(.caption).foregroundStyle(CorresPalette.tertiary)
                                    }
                                    Text(thread.excerpt).font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !files.isEmpty {
                    Section(files.count == 1 ? "1 File" : "\(files.count) Files") {
                        ForEach(Array(files.prefix(12).enumerated()), id: \.offset) { _, item in
                            Button {
                                open(item.thread.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: AttachmentKind.symbol(for: item.file))
                                        .foregroundStyle(CorresPalette.accent).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.file.filename).foregroundStyle(CorresPalette.ink).lineLimit(1)
                                        Text(item.thread.receivedAt, format: .dateTime.month(.abbreviated).day().year())
                                            .font(.caption).foregroundStyle(CorresPalette.tertiary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.file.sizeBytes), countStyle: .file))
                                        .font(.caption).foregroundStyle(CorresPalette.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    if decision == .blocked {
                        Button("Allow \(person.name.isEmpty ? person.email : person.name)") {
                            Task { await store.setSenderDecision(.approved, senders: [(email: email, account: person.account)]) }
                        }
                    } else {
                        Button("Block \(person.name.isEmpty ? person.email : person.name)", role: .destructive) { confirmingBlock = true }
                    }
                } footer: {
                    Text("From your mail on this \(Device.name). Nothing about them is looked up anywhere else.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(CorresPalette.canvas)
            .navigationTitle(person.name.isEmpty ? person.email : person.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Block \(person.name.isEmpty ? person.email : person.name)?", isPresented: $confirmingBlock,
                                titleVisibility: .visible) {
                Button("Block", role: .destructive) { Task { await store.blockSender(email, account: person.account) } }
            } message: {
                Text("Their mail is hidden in Corres from now on, with no notice to them. Your email account isn't changed.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    private static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(2)
        return parts.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}
