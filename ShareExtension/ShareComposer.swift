import Foundation
import Observation

/// The email being written in the Share sheet, and sending it: straight to
/// Gmail as the account you pick, the way Mail and Gmail's own share
/// sheets do, so it's gone before the sheet closes. With no connection it
/// goes to Corres to send as soon as it can, instead of being lost.
@MainActor @Observable
final class ShareComposer {
    enum Field: Hashable {
        case to, cc, bcc, subject, body
        var isAddress: Bool { self == .to || self == .cc || self == .bcc }
        var title: String { self == .cc ? String(localized: "Cc") : self == .bcc ? String(localized: "Bcc") : String(localized: "To") }
    }

    enum Phase: Equatable {
        case loading, editing, sending, sent, queued
        case failed(String)
        /// The mail server took the whole email and never answered.
        case mayHaveSent
        /// Save Draft: saved, or not.
        case saved, unsaved
    }

    let snapshot: ShareSnapshot?
    var content = SharedContent()
    var phase = Phase.loading

    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var typing: [Field: String] = [:]
    var account: String?
    var fromAddress: String?
    var subject = ""
    var note = ""
    var photoSize = PhotoSize.actual
    /// Total size at each photo size, worked out once the photos are in.
    var totals: [PhotoSize: Int] = [:]

    private let client = MailClient()
    private let draftID = UUID()
    /// Sent once already: a try again asks the server first, since the
    /// first may have gone with only its answer lost.
    private var triedSending = false

    init() {
        snapshot = ShareSnapshot.load()
        account = snapshot?.defaultAccount ?? snapshot?.accounts.first?.email
        if let account { fromAddress = defaultAddress(for: account) }
    }

    var accounts: [ShareSnapshot.Account] { snapshot?.accounts ?? [] }
    var isSignedIn: Bool { !accounts.isEmpty }

    // MARK: Recipients

    func list(_ field: Field) -> [String] {
        switch field {
        case .to: to
        case .cc: cc
        case .bcc: bcc
        default: []
        }
    }

    func setList(_ field: Field, _ value: [String]) {
        switch field {
        case .to: to = value
        case .cc: cc = value
        case .bcc: bcc = value
        default: break
        }
    }

    var everyone: Set<String> {
        Set((to + cc + bcc).compactMap { PeopleIndex.parse($0)?.email })
    }

    /// Who you're in touch with now, before anything is typed.
    var suggestedPeople: [Person] {
        guard let snapshot else { return [] }
        let own = Set(accounts.flatMap { [$0.email] + $0.addresses.map(\.email) })
        return snapshot.people.top(limit: 8, excluding: everyone.union(own), favored: snapshot.favored, ownNames: snapshot.ownNames)
    }

    func matches(for query: String) -> [Person] {
        guard let snapshot, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return snapshot.people.suggestions(for: query, excluding: everyone, favored: snapshot.favored, limit: 6)
    }

    func add(_ person: Person, to field: Field) {
        setList(field, list(field) + [person.address])
        typing[field] = ""
    }

    /// What's typed becomes a chip once it ends in a comma or space, or
    /// the field is left.
    func typed(_ text: String, in field: Field) {
        let split = PeopleIndex.split(text)
        if !split.finished.isEmpty {
            setList(field, list(field) + split.finished)
            typing[field] = split.typing
        } else {
            typing[field] = text
        }
    }

    func commit(_ field: Field) {
        let text = (typing[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
        guard !text.isEmpty else { return }
        setList(field, list(field) + [text])
        typing[field] = ""
    }

    func remove(at index: Int, from field: Field) {
        var entries = list(field)
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        setList(field, entries)
    }

    func move(at index: Int, from field: Field, to target: Field) {
        let entries = list(field)
        guard entries.indices.contains(index) else { return }
        remove(at: index, from: field)
        setList(target, list(target) + [entries[index]])
    }

    // MARK: From

    func defaultAddress(for account: String) -> String {
        let addresses = accounts.first { $0.email == account }?.addresses ?? []
        return (addresses.first { $0.isDefault } ?? addresses.first)?.email ?? account
    }

    var fromChoices: [(account: String, address: ShareSnapshot.Address)] {
        accounts.flatMap { account in
            (account.addresses.isEmpty ? [ShareSnapshot.Address(email: account.email, name: account.name ?? "", isDefault: true, isPrimary: true)]
                : account.addresses).map { (account.email, $0) }
        }
    }

    var fromLabel: String { fromAddress ?? account ?? "" }

    // MARK: Attachments

    var photos: [SharedContent.File] { content.files.filter(\.isImage) }

    var totalBytes: Int {
        totals[photoSize] ?? content.files.reduce(0) { $0 + $1.size }
    }

    var isTooLarge: Bool { totalBytes > provider.attachmentLimit }
    /// The service the picked account sends through.
    var provider: MailProvider { MailAccounts.provider(for: account ?? "") }

    func load(_ items: [NSExtensionItem]) async {
        content = await SharedContent.load(from: items)
        subject = content.suggestedSubject
        if !content.text.isEmpty { note = content.text }
        phase = .editing
        if let url = content.link?.url {
            Task {
                guard let metadata = await SharedContent.fetchMetadata(for: url) else { return }
                content.link?.metadata = metadata
                if content.link?.title == nil, let title = metadata.title, !title.isEmpty {
                    content.link?.title = title
                    if subject.isEmpty { subject = title }
                }
            }
        }
        await measurePhotos()
    }

    /// Each size's total, as Mail shows it, and a size that fits Gmail's
    /// 25 MB when the originals don't.
    private func measurePhotos() async {
        let files = content.files
        guard files.contains(where: \.isImage) else { return }
        let measured = await Task.detached(priority: .userInitiated) {
            var totals: [PhotoSize: Int] = [:]
            for size in PhotoSize.allCases {
                totals[size] = files.reduce(0) { $0 + ($1.isImage ? size.resized($1.data).count : $1.size) }
            }
            return totals
        }.value
        totals = measured
        if (measured[.actual] ?? 0) > provider.attachmentLimit {
            photoSize = [PhotoSize.large, .medium, .small].first { (measured[$0] ?? .max) <= provider.attachmentLimit } ?? .small
        }
    }

    func removeFile(_ id: UUID) {
        content.files.removeAll { $0.id == id }
        totals = [:]
        Task { await measurePhotos() }
    }

    // MARK: Sending

    /// Every recipient, chips and what's still being typed, is a real
    /// address: "jer" half-typed doesn't light up Send.
    var canSend: Bool {
        let typed = [typing[.to], typing[.cc], typing[.bcc]].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let all = to + cc + bcc + typed
        return phase == .editing && isSignedIn && !all.isEmpty && !isTooLarge && all.allSatisfy { PeopleIndex.parse($0) != nil }
    }


    var hasChanges: Bool {
        !(to + cc + bcc).isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || subject != content.suggestedSubject
    }

    private func draft() -> Draft {
        for field in [Field.to, .cc, .bcc] { commit(field) }
        var body = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = content.link {
            let block = [link.title, link.url.absoluteString].compactMap { $0 }.joined(separator: "\n")
            body = body.isEmpty ? block : body + "\n\n" + block
        }
        if let signature = accounts.first(where: { $0.email == account })?.signature, !signature.isEmpty, !body.contains(signature) {
            body += "\n\n" + signature
        }
        // A file too big to read (`unreadSize`) can't go: Send stays off for
        // it, and a saved draft is kept without it rather than with it empty.
        let attachments = content.files.filter { $0.unreadSize == nil }.map { file -> PendingAttachment in
            guard file.isImage, photoSize != .actual else {
                return PendingAttachment(filename: file.filename, mimeType: file.mimeType, data: file.data)
            }
            let resized = photoSize.resized(file.data)
            guard resized != file.data else { return PendingAttachment(filename: file.filename, mimeType: file.mimeType, data: file.data) }
            return PendingAttachment(filename: (file.filename as NSString).deletingPathExtension + ".jpg", mimeType: "image/jpeg", data: resized)
        }
        var draft = Draft(id: draftID, kind: .new, fromAccount: account, to: to.joined(separator: ", "),
                          cc: cc.isEmpty ? nil : cc.joined(separator: ", "), bcc: bcc.isEmpty ? nil : bcc.joined(separator: ", "),
                          subject: subject.trimmingCharacters(in: .whitespacesAndNewlines), body: body, attachments: attachments)
        // Signed here already: opened in Compose from Send Later, it's kept as written.
        draft.signatureAdded = true
        if let fromAddress, fromAddress != account {
            draft.fromAddress = fromAddress
            draft.fromName = fromName(fromAddress)
        }
        return draft
    }

    private func fromName(_ address: String) -> String? {
        let name = accounts.first { $0.email == account }?.addresses.first { $0.email == address }?.name
            ?? accounts.first { $0.email == account }?.name
        return name?.isEmpty == false ? name : nil
    }

    private func raw(_ draft: Draft, withAttachments: Bool = true) -> String {
        let address = draft.fromAddress ?? draft.fromAccount ?? ""
        let name = fromName(address) ?? ""
        return GmailMessageComposer.compose(from: name.isEmpty ? address : "\(name) <\(address)>", to: draft.to, cc: draft.cc,
                                            bcc: draft.bcc, subject: draft.subject, body: draft.body, inReplyTo: nil,
                                            messageID: "\(draft.id.uuidString)@corres.app",
                                            attachments: withAttachments ? draft.attachments : [])
    }

    func send() async {
        guard let account else { return }
        let draft = draft()
        phase = .sending
        if triedSending,
           (try? await client.findMessage(rfc822MessageID: "\(draft.id.uuidString)@corres.app", account: account)) != nil {
            phase = .sent
            return
        }
        triedSending = true
        do {
            let full = raw(draft), bare = raw(draft, withAttachments: false)
            try await client.send(attachments: draft.attachments, threadId: nil, account: account) { $0 ? full : bare }
            phase = .sent
        } catch let error as URLError where Self.neverReachedGmail(error) || Self.mayHaveGone(error) {
            // Never reached the server, or the connection dropped before
            // its answer came back (it may have gone): either way Corres
            // sends it as soon as it can, asking the server first (the same
            // Message-ID), so it never arrives twice.
            if (try? ShareOutbox.add(draft)) != nil {
                phase = .queued
            } else {
                phase = .failed(String(localized: "Couldn\u{2019}t send it. Check your connection and try again."))
            }
        } catch GmailAPIClient.ClientError.notSignedIn {
            phase = .failed(String(localized: "Open Corres once, then share again. Corres finishes setting up sharing the first time it opens after updating."))
        } catch where IMAPMailClient.isUnconfirmed(error) {
            // The mail server took it all and never answered: it may have
            // gone, so it isn't "didn't accept it".
            phase = .mayHaveSent
        } catch {
            phase = .failed(String(localized: "\(MailAccounts.serviceTitle(for: account)) didn\u{2019}t accept it. Try again in a moment."))
        }
    }

    /// Saved to Gmail's Drafts, to finish anywhere.
    func saveDraft() async -> Bool {
        guard let account else { return false }
        let draft = draft()
        phase = .sending
        let full = raw(draft), bare = raw(draft, withAttachments: false)
        let saved = (try? await client.saveDraft(attachments: draft.attachments, threadId: nil, existingID: nil, account: account,
                                                 compose: { $0 ? full : bare })) != nil
        // Not saved is said, not just back to editing as if nothing happened.
        phase = saved ? .saved : .unsaved
        return saved
    }

    func retry() { phase = .editing }

    /// The connection went mid-send: the server may have it.
    private static func mayHaveGone(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost].contains(error.code)
    }

    private static func neverReachedGmail(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost,
         .cannotConnectToHost, .dnsLookupFailed, .callIsActive].contains(error.code)
    }
}
