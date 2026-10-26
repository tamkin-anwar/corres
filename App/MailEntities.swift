import AppIntents
import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Your mail, as Siri and Apple Intelligence understand mail: messages they
/// can find, open, archive or delete in Corres by name ("archive the email
/// from Maya"), through Apple's own mail schema. Everything is read from
/// the mail on this device.

@available(iOS 18.0, macOS 15.0, *)
@AppEntity(schema: .mail.account)
struct CorresMailAccount: AppEntity {
    static let defaultQuery = CorresMailAccountQuery()
    let id: String
    var name: String
    var emailAddress: String

    init(email: String) {
        id = email
        name = AccountPreferences.nickname(for: email)
        emailAddress = email
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(emailAddress)") }
}

@available(iOS 18.0, macOS 15.0, *)
struct CorresMailAccountQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [CorresMailAccount] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) || $0.emailAddress.localizedStandardContains(string) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [CorresMailAccount] {
        identifiers.map(CorresMailAccount.init(email:))
    }

    @MainActor
    func suggestedEntities() async throws -> [CorresMailAccount] {
        let accounts = Set(Organizer.shared.store?.threads.map(\.id.account) ?? []).subtracting(["sample"])
        return accounts.sorted().map(CorresMailAccount.init(email:))
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppEntity(schema: .mail.mailbox)
struct CorresMailbox: AppEntity {
    static let defaultQuery = CorresMailboxQuery()
    /// "account|list".
    let id: String
    var name: String
    var account: CorresMailAccount

    init(id: String) {
        self.id = id
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        account = CorresMailAccount(email: parts.first ?? "")
        name = switch parts.last ?? "" {
        case "needsYou": String(localized: "Needs You")
        case "waiting": String(localized: "Waiting")
        default: String(localized: "Mail")
        }
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

@available(iOS 18.0, macOS 15.0, *)
struct CorresMailboxQuery: EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [CorresMailbox] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }

    func entities(for identifiers: [String]) async throws -> [CorresMailbox] { identifiers.map(CorresMailbox.init(id:)) }
    @MainActor
    func suggestedEntities() async throws -> [CorresMailbox] {
        let accounts = Set(Organizer.shared.store?.threads.map(\.id.account) ?? []).subtracting(["sample"]).sorted()
        return accounts.flatMap { account in ["needsYou", "waiting", "mail"].map { CorresMailbox(id: account + "|" + $0) } }
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppEnum(schema: .mail.category)
enum CorresMailCategory: String, AppEnum {
    case primary, promotions, social, updates

    static let caseDisplayRepresentations: [CorresMailCategory: DisplayRepresentation] = [
        .primary: "Primary", .promotions: "Promotions", .social: "Social", .updates: "Updates",
    ]
}

@available(iOS 18.0, macOS 15.0, *)
@AppEntity(schema: .mail.message)
struct CorresMailMessage: AppEntity {
    static let defaultQuery = CorresMailMessageQuery()

    /// "account|thread id".
    let id: String
    var subject: String?
    var body: String?
    var account: CorresMailAccount
    var mailbox: CorresMailbox
    var sender: IntentPerson
    var to: [IntentPerson]
    var cc: [IntentPerson]
    var bcc: [IntentPerson]
    var attachments: [IntentFile]
    var category: CorresMailCategory?
    var dateReceived: Date
    var dateSent: Date
    var isFlagged: Bool
    var isJunk: Bool
    var isRead: Bool
    private let senderName: String

    init(_ thread: Correspondence) {
        id = thread.id.entityKey
        senderName = thread.sender
        subject = thread.subject
        body = thread.body.isEmpty ? thread.excerpt : thread.body
        account = CorresMailAccount(email: thread.id.account)
        mailbox = CorresMailbox(id: thread.id.account + "|" + (thread.attention == .needsYou ? "needsYou" : thread.attention == .waiting ? "waiting" : "mail"))
        sender = IntentPeople.person(name: thread.sender, email: thread.senderEmail ?? "", isMe: thread.isFromAccountOwner)
        to = thread.toRecipients.flatMap { IntentPeople.people(in: $0) }
        cc = thread.ccRecipients.flatMap { IntentPeople.people(in: $0) }
        bcc = []
        attachments = []
        let placed = InboxCategory.allCases.first { thread.labelIds.contains($0.gmailLabel) } ?? .primary
        category = switch placed {
        case .primary: .primary
        case .promotions: .promotions
        case .social: .social
        case .updates: .updates
        }
        dateReceived = thread.receivedAt
        dateSent = thread.receivedAt
        isFlagged = thread.isFlagged
        isJunk = thread.labelIds.contains("SPAM")
        isRead = !thread.isUnread
    }

    var threadID: ThreadID? {
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? ThreadID(account: parts[0], providerID: parts[1]) : nil
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(subject ?? "")", subtitle: "\(senderName)")
    }
}

/// In the system's own index, so Siri and Spotlight can find an email by
/// what it's about, not only by its words (see `SpotlightIndex`).
@available(iOS 18.0, macOS 15.0, *)
extension CorresMailMessage: IndexedEntity {}

/// What Siri reads, or hands to another app, when you ask about the email
/// on screen: who it's from, the subject and the words.
@available(iOS 18.0, macOS 15.0, *)
extension CorresMailMessage: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { message in Data(message.plainText.utf8) }
    }

    var plainText: String {
        let from = sender.displayName
        return [String(localized: "From: \(from)"), String(localized: "Subject: \(subject ?? "")"), "", body ?? ""].joined(separator: "\n")
    }
}

extension ThreadID {
    /// How Siri knows a conversation: "account|thread id".
    var entityKey: String { account + "|" + providerID }
}

@available(iOS 18.0, macOS 15.0, *)
struct CorresMailMessageQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [CorresMailMessage] {
        guard let store = Organizer.shared.store else { return [] }
        if store.state != .loaded { await store.load() }
        return identifiers.compactMap { identifier in
            let parts = identifier.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let thread = store.thread(ThreadID(account: parts[0], providerID: parts[1])) else { return nil }
            return CorresMailMessage(thread)
        }
    }

    /// "the email from Maya", "the invoice": the same search as Corres's.
    @MainActor
    func entities(matching string: String) async throws -> [CorresMailMessage] {
        guard let store = Organizer.shared.store else { return [] }
        if store.state != .loaded { await store.load() }
        return MailQuery.filter(store.searchableThreads, search: string).prefix(20).map(CorresMailMessage.init)
    }

    /// What needs you first, then the newest.
    @MainActor
    func suggestedEntities() async throws -> [CorresMailMessage] {
        guard let store = Organizer.shared.store else { return [] }
        if store.state != .loaded { await store.load() }
        let needsYou = MailQuery.prioritized(store.threads, attention: .needsYou)
        let rest = MailQuery.filter(store.threads).filter { $0.attention != .needsYou }
        return (needsYou + rest).prefix(20).map(CorresMailMessage.init)
    }
}

// MARK: Actions

/// Siri can be what opens Corres: its mail, and for a change the accounts
/// too, come back first, as for the Watch (`WatchBridge.perform`). Before,
/// a cold "archive the email from Maya" found no email, or no account to
/// send the change with, and said it was done.
@MainActor
enum IntentMail {
    static func store() async -> MailStore? {
        guard let store = Organizer.shared.store else { return nil }
        if store.state != .loaded { await store.load() }
        return store
    }

    static func ready() async -> (store: MailStore, actions: ThreadActionService)? {
        guard let store = await store(), let actions = Organizer.shared.actions else { return nil }
        await Organizer.shared.outbox?.waitForAccounts()
        return (store, actions)
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.archiveMail)
struct ArchiveMailIntent: AppIntent {
    @Parameter var entities: [CorresMailMessage]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard case let (store, actions)? = await IntentMail.ready() else { throw UpdateMailError.notFound }
        let threads = entities.compactMap(\.threadID).compactMap(store.thread)
        guard !threads.isEmpty else { throw UpdateMailError.notFound }
        await actions.archive(threads)
        await actions.commitPendingRemoval()
        return .result()
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.deleteMail)
struct DeleteMailIntent: AppIntent {
    @Parameter var entities: [CorresMailMessage]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard case let (store, actions)? = await IntentMail.ready() else { throw UpdateMailError.notFound }
        let threads = entities.compactMap(\.threadID).compactMap(store.thread)
        guard !threads.isEmpty else { throw UpdateMailError.notFound }
        await actions.trash(threads)
        await actions.commitPendingRemoval()
        return .result()
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.replyMail)
struct ReplyMailIntent: AppIntent {
    static let openAppWhenRun = true
    @Parameter var target: CorresMailMessage
    @Parameter var account: CorresMailAccount?
    @Parameter var to: [IntentPerson]
    @Parameter var cc: [IntentPerson]
    @Parameter var bcc: [IntentPerson]
    @Parameter var subject: String?
    @Parameter var body: String?
    @Parameter var attachments: [IntentFile]
    @Parameter var isReplyAll: Bool

    /// Opens the reply in Corres with what Siri wrote, for you to read
    /// and send: nothing goes out on its own.
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = target.threadID, let thread = await IntentMail.store()?.thread(id) else { throw UpdateMailError.notFound }
        var draft = thread.draft(kind: isReplyAll ? .replyAll : .reply)
        if let body, !body.isEmpty { draft.body = body + draft.body }
        AppRouter.shared.pending = .draft(draft)
        return .result()
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.forwardMail)
struct ForwardMailIntent: AppIntent {
    static let openAppWhenRun = true
    @Parameter var target: CorresMailMessage
    @Parameter var account: CorresMailAccount?
    @Parameter var to: [IntentPerson]
    @Parameter var cc: [IntentPerson]
    @Parameter var bcc: [IntentPerson]
    @Parameter var subject: String?
    @Parameter var body: String?
    @Parameter var attachments: [IntentFile]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = target.threadID, let thread = await IntentMail.store()?.thread(id) else { throw UpdateMailError.notFound }
        var draft = thread.draft(kind: .forward)
        draft.attachments = await thread.attachmentsToForward().files
        let addresses = to.compactMap(Self.address)
        if !addresses.isEmpty { draft.to = addresses.joined(separator: ", ") }
        if let body, !body.isEmpty { draft.body = body + draft.body }
        AppRouter.shared.pending = .draft(draft)
        return .result()
    }

    static func address(_ person: IntentPerson) -> String? {
        if case .emailAddress(let email)? = person.handle?.value { return email }
        return nil
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.updateMail)
struct UpdateMailIntent: AppIntent {
    @Parameter var target: [CorresMailMessage]
    @Parameter var isRead: Bool?
    @Parameter var isFlagged: Bool?
    @Parameter var isJunk: Bool?
    @Parameter var mailbox: CorresMailbox?

    /// Read or unread, flagged or not, as asked. Junk reports it as spam,
    /// not junk brings it back to the Inbox, and a mailbox moves it there.
    /// Says so when it can't, rather than reporting a change it didn't make.
    @MainActor
    func perform() async throws -> some IntentResult {
        guard case let (store, actions)? = await IntentMail.ready() else { throw UpdateMailError.notFound }
        let threads = target.compactMap(\.threadID).compactMap(store.thread)
        guard !threads.isEmpty else { throw UpdateMailError.notFound }
        guard isRead != nil || isFlagged != nil || isJunk != nil || mailbox != nil else { throw UpdateMailError.nothingToChange }
        if let isRead { for thread in threads { await actions.setUnread(!isRead, for: thread) } }
        if let isFlagged { for thread in threads { await actions.setFlagged(isFlagged, for: thread) } }
        if isJunk == true {
            for thread in threads { await actions.reportSpam(thread, animated: false) }
            // Sent now: there's no Undo pill for Siri to wait out.
            await actions.commitPendingRemoval()
        } else if isJunk == false {
            for thread in threads where thread.labelIds.contains("SPAM") {
                guard await actions.moveToInbox(thread) else { throw UpdateMailError.notMoved }
            }
        }
        if let mailbox, isJunk != true { try await move(threads, to: mailbox, actions: actions) }
        return .result()
    }

    /// Mail goes back to the Inbox; any other name is one of the account's
    /// own labels or folders. Needs You and Waiting are Corres's own lists,
    /// not places mail can be moved to.
    @MainActor
    private func move(_ threads: [Correspondence], to mailbox: CorresMailbox, actions: ThreadActionService) async throws {
        let list = mailbox.id.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let account = mailbox.account.emailAddress
        let inAccount = threads.filter { $0.id.account == account }
        guard !inAccount.isEmpty else { throw UpdateMailError.noSuchMailbox(mailbox.name) }
        switch list.lowercased() {
        case "mail", "inbox":
            for thread in inAccount where !thread.labelIds.contains("INBOX") || thread.labelIds.contains("SPAM")
                || thread.labelIds.contains("TRASH") {
                guard await actions.moveToInbox(thread) else { throw UpdateMailError.notMoved }
            }
        case "needsyou", "waiting":
            throw UpdateMailError.noSuchMailbox(mailbox.name)
        default:
            let labels = (try? await MailClient().fetchUserLabels(account: account)) ?? []
            guard let label = labels.first(where: { label in
                !label.isCategory && (label.id == list || label.name.localizedCaseInsensitiveCompare(list) == .orderedSame
                                      || label.name.localizedCaseInsensitiveCompare(mailbox.name) == .orderedSame)
            }) else { throw UpdateMailError.noSuchMailbox(mailbox.name) }
            for thread in inAccount { await actions.moveToLabel(label.id, named: label.name, thread) }
            await actions.commitPendingRemoval()
        }
    }
}

/// What Siri says when a change to mail can't be made.
enum UpdateMailError: Error, CustomLocalizedStringResourceConvertible {
    case notFound, nothingToChange, notMoved
    case noSuchMailbox(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notFound: "Corres couldn't find that email."
        case .nothingToChange: "There was nothing to change."
        case .notMoved: "Couldn't move this conversation to the Inbox. Try again."
        case .noSuchMailbox(let name): "Corres can't move mail to \(name)."
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .mail.openMessage)
struct OpenMailMessageIntent: AppIntent {
    static let openAppWhenRun = true
    @Parameter var target: CorresMailMessage

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = target.threadID { AppRouter.shared.pending = .thread(id) }
        return .result()
    }
}

/// "Search my email for the Lisbon trip": Corres's own search, opened with
/// those words.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct SearchMailIntent: AppIntent {
    static let openAppWhenRun = true
    @Parameter var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pending = .search(criteria.term)
        return .result()
    }
}

/// "Remind me about this email tomorrow": added to Reminders, with a link
/// back to it (see `MailReminders`).
@available(iOS 18.0, macOS 15.0, *)
struct RemindAboutMailIntent: AppIntent {
    static let title: LocalizedStringResource = "Remind Me About an Email"
    static let description = IntentDescription("Adds the email to Reminders, with a link that opens it in Corres.")

    @Parameter(title: "Email") var target: CorresMailMessage
    @Parameter(title: "When") var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Remind me about \(\.$target)") { \.$date }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let id = target.threadID, let thread = await IntentMail.store()?.thread(id) else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "That email isn't in Corres anymore.")))
        }
        switch await MailReminders.add(thread, due: date ?? thread.dueAt) {
        case .added: return .result(dialog: IntentDialog(stringLiteral: String(localized: "Added to Reminders.")))
        case .notAllowed: return .result(dialog: IntentDialog(stringLiteral: String(localized: "Corres can't add to Reminders. You can allow it in Settings.")))
        case .failed: return .result(dialog: IntentDialog(stringLiteral: String(localized: "Reminders didn't save it. Try again.")))
        }
    }
}

extension View {
    /// Tells Siri which email a row shows, so "archive this one" or "the
    /// second email" means what's on screen.
    @ViewBuilder
    func mailEntity(_ id: ThreadID) -> some View {
        if #available(iOS 18.4, macOS 15.4, *), id.account != "sample" {
            appEntityIdentifier(EntityIdentifier(for: CorresMailMessage.self, identifier: id.entityKey))
        } else {
            self
        }
    }
}
