import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Writing an email by voice, as Siri does in Mail: "Write an email to Maya
/// about Thursday", then "add Sam", "send it tomorrow at 9", or "save it for
/// later". Each of those is one of Apple's mail actions; Corres keeps the
/// email Siri is working on here until it's sent, saved to Drafts, opened
/// in Compose or deleted. Sending asks you first.
@MainActor
final class SiriDrafts {
    static let shared = SiriDrafts()

    private struct Saved: Codable {
        var draft: Draft
        var updated: Date
    }
    private var drafts: [UUID: Saved] = [:]

    private static var fileURL: URL { URL.applicationSupportDirectory.appending(path: "siri-drafts.json") }
    /// Older than this, Siri has long moved on.
    private static let keepFor: TimeInterval = 7 * 86_400

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode([Saved].self, from: data) {
            drafts = Dictionary(saved.filter { $0.updated.timeIntervalSinceNow > -Self.keepFor }.map { ($0.draft.id, $0) },
                                uniquingKeysWith: { a, _ in a })
        }
    }

    var all: [Draft] { drafts.values.sorted { $0.updated > $1.updated }.map(\.draft) }

    func draft(_ id: UUID) -> Draft? { drafts[id]?.draft }

    func keep(_ draft: Draft) {
        drafts[draft.id] = Saved(draft: draft, updated: .now)
        save()
    }

    func remove(_ id: UUID) {
        drafts[id] = nil
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(drafts.values)) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
}

// MARK: People and files, between Siri and Corres

@available(iOS 18.0, macOS 15.0, *)
extension IntentPerson {
    /// "Maya Chen", however Siri gave the name.
    var displayName: String {
        switch name {
        case .displayName(let text): text
        case .components(let parts): parts.formatted()
        case .unknown: ""
        @unknown default: ""
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
enum IntentPeople {
    static func person(name: String, email: String, isMe: Bool = false) -> IntentPerson {
        IntentPerson(identifier: .applicationDefined(email.lowercased()), name: .displayName(name.isEmpty ? email : name),
                     handle: email.isEmpty ? nil : IntentPerson.Handle(emailAddress: email), isMe: isMe)
    }

    static func people(in field: String?) -> [IntentPerson] {
        PeopleIndex.entries(in: field ?? "").map { entry in
            let parsed = PeopleIndex.parse(entry)
            return person(name: parsed?.name ?? entry, email: parsed?.email ?? entry)
        }
    }

    /// "Maya Chen <maya@x.com>" for each person: their address when Siri
    /// has one, otherwise the address they last wrote to you from.
    @MainActor
    static func field(_ people: [IntentPerson]) -> String {
        people.compactMap { person -> String? in
            let name = person.displayName
            if case .emailAddress(let email)? = person.handle?.value { return name.isEmpty || name == email ? email : "\(name) <\(email)>" }
            guard !name.isEmpty else { return nil }
            let known = Organizer.shared.store?.searchableThreads.first {
                !$0.isFromAccountOwner && $0.senderEmail != nil && $0.sender.localizedCaseInsensitiveContains(name)
            }
            return known.flatMap { thread in thread.senderEmail.map { "\(thread.sender) <\($0)>" } }
        }
        .joined(separator: ", ")
    }

    static func attachments(_ files: [IntentFile]) -> [PendingAttachment] {
        files.map { file in
            PendingAttachment(filename: file.filename, mimeType: file.type?.preferredMIMEType ?? "application/octet-stream", data: file.data)
        }
    }

    static func files(_ attachments: [PendingAttachment]) -> [IntentFile] {
        attachments.map { IntentFile(data: $0.data, filename: $0.filename, type: UTType(mimeType: $0.mimeType)) }
    }
}

// MARK: The draft

@available(iOS 18.0, macOS 15.0, *)
@AppEntity(schema: .mail.draft)
struct CorresMailDraft: AppEntity {
    static let defaultQuery = CorresMailDraftQuery()

    let id: UUID
    var to: [IntentPerson]
    var cc: [IntentPerson]
    var bcc: [IntentPerson]
    var subject: String?
    var body: AttributedString?
    var attachments: [IntentFile]
    var account: CorresMailAccount

    @MainActor
    init(_ draft: Draft) {
        id = draft.id
        to = IntentPeople.people(in: draft.to)
        cc = IntentPeople.people(in: draft.cc)
        bcc = IntentPeople.people(in: draft.bcc)
        subject = draft.subject.isEmpty ? nil : draft.subject
        body = draft.body.isEmpty ? nil : AttributedString(draft.body)
        attachments = IntentPeople.files(draft.attachments)
        account = CorresMailAccount(email: draft.fromAccount ?? Organizer.shared.store?.threads.first?.id.account ?? "")
    }

    var displayRepresentation: DisplayRepresentation {
        let names = to.map(\.displayName).filter { !$0.isEmpty }
        return DisplayRepresentation(title: "\(subject ?? String(localized: "New Email"))",
                                     subtitle: names.isEmpty ? nil : "\(String(localized: "To \(names.joined(separator: ", "))"))")
    }
}

@available(iOS 18.0, macOS 15.0, *)
struct CorresMailDraftQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [CorresMailDraft] {
        identifiers.compactMap { SiriDrafts.shared.draft($0) }.map(CorresMailDraft.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [CorresMailDraft] {
        SiriDrafts.shared.all.filter {
            $0.subject.localizedStandardContains(string) || $0.to.localizedStandardContains(string) || $0.body.localizedStandardContains(string)
        }.map(CorresMailDraft.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [CorresMailDraft] {
        SiriDrafts.shared.all.map(CorresMailDraft.init)
    }
}

// MARK: Actions

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.createDraft)
struct CreateMailDraftIntent: AppIntent {
    @Parameter var to: [IntentPerson]
    @Parameter var cc: [IntentPerson]
    @Parameter var bcc: [IntentPerson]
    @Parameter var subject: String?
    @Parameter var body: AttributedString?
    @Parameter var account: CorresMailAccount?
    @Parameter var attachments: [IntentFile]

    @MainActor
    func perform() async throws -> some ReturnsValue<CorresMailDraft> {
        // An account always: with none named and no default set, Siri was
        // shown the account of whatever email was first in the list, and
        // the email then went from the first connected account instead.
        let connected = UserDefaults.standard.stringArray(forKey: "corres.connectedAccounts") ?? []
        let from = account?.id ?? CorresSettings.defaultFromAccount.flatMap { connected.contains($0) ? $0 : nil } ?? connected.first
        let text = body.map { String($0.characters) } ?? ""
        let draft = Draft(kind: .new, fromAccount: from, to: IntentPeople.field(to),
                          cc: cc.isEmpty ? nil : IntentPeople.field(cc), bcc: bcc.isEmpty ? nil : IntentPeople.field(bcc),
                          subject: subject ?? "", body: Draft.adding(signature: CorresSettings.signature(for: from), to: text),
                          attachments: IntentPeople.attachments(attachments))
        SiriDrafts.shared.keep(draft)
        return .result(value: CorresMailDraft(draft))
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.updateDraft)
struct UpdateMailDraftIntent: AppIntent {
    @Parameter var target: CorresMailDraft
    @Parameter var to: [IntentPerson]?
    @Parameter var cc: [IntentPerson]?
    @Parameter var bcc: [IntentPerson]?
    @Parameter var subject: String?
    @Parameter var body: AttributedString?
    @Parameter var account: CorresMailAccount?
    @Parameter var attachments: [IntentFile]?

    @MainActor
    func perform() async throws -> some ReturnsValue<CorresMailDraft> {
        guard var draft = SiriDrafts.shared.draft(target.id) else { throw DraftGone() }
        if let to { draft.to = IntentPeople.field(to) }
        if let cc { draft.cc = IntentPeople.field(cc) }
        if let bcc { draft.bcc = IntentPeople.field(bcc) }
        if let subject { draft.subject = subject }
        if let body {
            let signature = CorresSettings.signature(for: draft.fromAccount)
            draft.body = Draft.adding(signature: signature, to: String(body.characters))
            draft.bodyHTML = nil
        }
        if let account { draft.fromAccount = account.id }
        if let attachments { draft.attachments = IntentPeople.attachments(attachments) }
        SiriDrafts.shared.keep(draft)
        return .result(value: CorresMailDraft(draft))
    }
}

/// "Save it": into the account's Drafts, on every device, and on the pill
/// at the bottom of Corres to pick up where you left off.
@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.saveDraft)
struct SaveMailDraftIntent: AppIntent {
    @Parameter var target: CorresMailDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let draft = SiriDrafts.shared.draft(target.id) else { throw DraftGone() }
        // Siri can open Corres for this: before the accounts are back, the
        // save to Drafts was turned away and the email kept only in memory.
        await Organizer.shared.outbox?.waitForAccounts()
        Organizer.shared.outbox?.shelve(draft, replyingTo: draft.threadID.flatMap { Organizer.shared.store?.thread($0) })
        SiriDrafts.shared.remove(draft.id)
        return .result()
    }
}

/// "Send it", or "send it tomorrow at 9": asks first, then goes the way
/// every email from Corres goes (or waits in Send Later).
@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.sendDraft)
struct SendMailDraftIntent: AppIntent {
    @Parameter var target: CorresMailDraft
    @Parameter var sendLaterDate: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let draft = SiriDrafts.shared.draft(target.id), let outbox = Organizer.shared.outbox else { throw DraftGone() }
        // Sample mail only: it would be recorded as sent and go nowhere.
        guard GoogleAuthService.hasSavedAccounts else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Add your email account in Corres first.")))
        }
        guard draft.isSendable, draft.recipientsLookValid else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Add a recipient, then try again.")))
        }
        // Who it really goes to: a name Siri gave without an address Corres
        // knows isn't in the email, and asking "to Maya and Sam?" then
        // sending to Maya alone isn't asking.
        let names = Self.recipients(of: draft)
        if let sendLaterDate, sendLaterDate > .now {
            let when = sendLaterDate.formatted(date: .abbreviated, time: .shortened)
            try await requestConfirmation(dialog: IntentDialog(stringLiteral: String(localized: "Send this email to \(names) on \(when)?")))
            ScheduledSends.shared.schedule(draft, at: sendLaterDate)
            SiriDrafts.shared.remove(draft.id)
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "It'll go out \(when).")))
        }
        try await requestConfirmation(dialog: IntentDialog(stringLiteral: String(localized: "Send this email to \(names)?")))
        SiriDrafts.shared.remove(draft.id)
        await outbox.sendNow(draft, replyingTo: draft.threadID.flatMap { Organizer.shared.store?.thread($0) })
        // Kept to try again (no connection, say): never "Sent." when it wasn't.
        if outbox.failedSends.contains(where: { $0.draft.id == draft.id }) {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "It didn't send. It's waiting in Corres to try again.")))
        }
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Sent.")))
    }

    /// "Maya Chen, sam@x.com": everyone in To, Cc and Bcc, by name where
    /// there is one.
    static func recipients(of draft: Draft) -> String {
        (PeopleIndex.entries(in: draft.to) + PeopleIndex.entries(in: draft.cc ?? "") + PeopleIndex.entries(in: draft.bcc ?? ""))
            .map { entry in PeopleIndex.parse(entry).map { $0.name.isEmpty ? $0.email : $0.name } ?? entry }
            .joined(separator: ", ")
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.deleteDraft)
struct DeleteMailDraftIntent: DeleteIntent {
    @Parameter var entities: [CorresMailDraft]

    @MainActor
    func perform() async throws -> some IntentResult {
        for entity in entities {
            guard let draft = SiriDrafts.shared.draft(entity.id) else { continue }
            SiriDrafts.shared.remove(draft.id)
            Organizer.shared.outbox?.discard(draft, replyingTo: nil)
        }
        return .result()
    }
}

/// "Open the draft to Maya": in Compose, to finish by hand.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .mail.openDraft)
struct OpenMailDraftIntent: OpenIntent {
    static let openAppWhenRun = true
    @Parameter var target: CorresMailDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let draft = SiriDrafts.shared.draft(target.id) else { throw DraftGone() }
        SiriDrafts.shared.remove(draft.id)
        AppRouter.shared.pending = .draft(draft)
        return .result()
    }
}

/// The email Siri was working on was sent or put away in the meantime.
struct DraftGone: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "That email isn't open in Corres anymore." }
}
