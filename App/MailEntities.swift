import AppIntents
import Foundation

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

    @MainActor
    init(_ thread: Correspondence) {
        id = thread.id.account + "|" + thread.id.providerID
        senderName = thread.sender
        subject = thread.subject
        body = thread.body.isEmpty ? thread.excerpt : thread.body
        account = CorresMailAccount(email: thread.id.account)
        mailbox = CorresMailbox(id: thread.id.account + "|" + (thread.attention == .needsYou ? "needsYou" : thread.attention == .waiting ? "waiting" : "mail"))
        sender = Self.person(name: thread.sender, email: thread.senderEmail ?? "", isMe: thread.isFromAccountOwner)
        to = thread.toRecipients.map { Self.person(entry: $0) }
        cc = thread.ccRecipients.map { Self.person(entry: $0) }
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

    private static func person(name: String, email: String, isMe: Bool = false) -> IntentPerson {
        IntentPerson(identifier: .applicationDefined(email.lowercased()), name: .displayName(name.isEmpty ? email : name),
                     handle: email.isEmpty ? nil : IntentPerson.Handle(emailAddress: email), isMe: isMe)
    }

    private static func person(entry: String) -> IntentPerson {
        let parsed = PeopleIndex.parse(entry)
        return person(name: parsed?.name ?? entry, email: parsed?.email ?? entry)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(subject ?? "")", subtitle: "\(senderName)")
    }
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

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.archiveMail)
struct ArchiveMailIntent: AppIntent {
    @Parameter var entities: [CorresMailMessage]

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let store = Organizer.shared.store, let actions = Organizer.shared.actions else { return .result() }
        let threads = entities.compactMap(\.threadID).compactMap(store.thread)
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
        guard let store = Organizer.shared.store, let actions = Organizer.shared.actions else { return .result() }
        let threads = entities.compactMap(\.threadID).compactMap(store.thread)
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
        guard let id = target.threadID, let thread = Organizer.shared.store?.thread(id) else { return .result() }
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
        guard let id = target.threadID, let thread = Organizer.shared.store?.thread(id) else { return .result() }
        var draft = thread.draft(kind: .forward)
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

    /// Read or unread, flagged or not, as asked. Junk reports it as spam.
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let store = Organizer.shared.store, let actions = Organizer.shared.actions else { return .result() }
        let threads = target.compactMap(\.threadID).compactMap(store.thread)
        if let isRead { for thread in threads { await actions.setUnread(!isRead, for: thread) } }
        if let isFlagged { for thread in threads { await actions.setFlagged(isFlagged, for: thread) } }
        if isJunk == true { for thread in threads { await actions.reportSpam(thread, animated: false) } }
        return .result()
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
