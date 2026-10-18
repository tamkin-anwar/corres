import Foundation

/// Outlook (Microsoft Graph) behind the same calls as `GmailAPIClient`, so
/// everything above it treats both alike. Graph's model is folders,
/// read state, flags, Focused/Other and categories; Corres's is Gmail's
/// labels, so each message is described in labels:
///
/// - Inbox → `INBOX`, Sent Items → `SENT`, Deleted Items → `TRASH`,
///   Junk Email → `SPAM`, Drafts → `DRAFT`; Archive is simply not `INBOX`.
/// - unread → `UNREAD`, flagged → `STARRED`.
/// - Focused → `CATEGORY_PERSONAL`; Other → `CATEGORY_PROMOTIONS` for mail
///   with an unsubscribe link, `CATEGORY_UPDATES` otherwise. Corres's own
///   sorting (`InboxCategory`) works on top, as it does for Gmail.
/// - Outlook categories → labels "cat:<name>".
///
/// A conversation is Outlook's `conversationId`. Every request asks for
/// immutable ids, so a message keeps its id when it moves between folders.
struct OutlookClient: Sendable {
    typealias ClientError = GmailAPIClient.ClientError

    private static let base = "https://graph.microsoft.com/v1.0"
    private static let listFields = "id,conversationId,subject,bodyPreview,from,sender,toRecipients,ccRecipients,replyTo,receivedDateTime,isRead,isDraft,flag,internetMessageId,hasAttachments,parentFolderId,inferenceClassification,categories"
    private static let fullFields = listFields + ",body,internetMessageHeaders"
    /// Graph's limit for one $batch.
    private static let batchLimit = 20
    private static let initialInboxDays = 60
    private static let initialSentDays = 60

    // MARK: Sync

    /// The cursor is both folders' delta links, as JSON.
    private struct Cursor: Codable { var inbox: String; var sent: String }

    func planFullListing(account: String) async throws -> GmailAPIClient.SyncPlan {
        let since = Self.isoDate(Date.now.addingTimeInterval(-Double(Self.initialInboxDays) * 86_400))
        let inbox = try await deltaRound(start: "\(Self.base)/me/mailFolders/inbox/messages/delta?$select=\(Self.listFields)&$filter=receivedDateTime+ge+\(since)", account: account)
        let sentSince = Self.isoDate(Date.now.addingTimeInterval(-Double(Self.initialSentDays) * 86_400))
        let sent = try await deltaRound(start: "\(Self.base)/me/mailFolders/sentitems/messages/delta?$select=\(Self.listFields)&$filter=receivedDateTime+ge+\(sentSince)", account: account)
        let messages = (inbox.messages + sent.messages).filter { $0.removed == nil }
            .sorted { ($0.receivedDate ?? .distantPast) > ($1.receivedDate ?? .distantPast) }
        await OutlookCache.shared.keep(messages, account: account)
        let cursor = try JSONEncoder().encode(Cursor(inbox: inbox.deltaLink, sent: sent.deltaLink))
        return GmailAPIClient.SyncPlan(messageIDs: messages.map(\.id), historyId: String(data: cursor, encoding: .utf8),
                                       olderInboxPageToken: "\(Self.base)/me/mailFolders/inbox/messages?$select=id&$top=100&$orderby=receivedDateTime+desc&$filter=receivedDateTime+lt+\(since)")
    }

    func planIncremental(account: String, since cursorString: String) async throws -> GmailAPIClient.SyncPlan {
        guard let data = cursorString.data(using: .utf8), let cursor = try? JSONDecoder().decode(Cursor.self, from: data) else {
            throw ClientError.historyExpired
        }
        let inbox = try await deltaRound(start: cursor.inbox, account: account)
        let sent = try await deltaRound(start: cursor.sent, account: account)
        let changed = inbox.messages + sent.messages
        let current = changed.filter { $0.removed == nil }
        await OutlookCache.shared.keep(current, account: account)
        let folders = try await OutlookFolders.shared.ids(for: account, client: self)
        // Left the Inbox (archived, moved, deleted elsewhere): leaves Corres
        // the way it would after archiving here. Changes to what's still
        // here (read, flagged) come as its current labels.
        // Graph names a removed message by its id alone, without its
        // conversation, so the store finds it by message.
        var remote: [RemoteMessageChange] = inbox.messages.filter { $0.removed != nil }.map { message in
            RemoteMessageChange(threadID: ThreadID(account: account, providerID: message.conversationId ?? ""), messageID: message.id,
                                currentLabelIds: nil, removed: true)
        }
        remote += current.compactMap { message in
            guard let conversation = message.conversationId else { return nil }
            return RemoteMessageChange(threadID: ThreadID(account: account, providerID: conversation), messageID: message.id,
                                       currentLabelIds: Self.labels(for: message, folders: folders), removed: false)
        }
        let next = try JSONEncoder().encode(Cursor(inbox: inbox.deltaLink, sent: sent.deltaLink))
        return GmailAPIClient.SyncPlan(messageIDs: current.map(\.id), historyId: String(data: next, encoding: .utf8),
                                       remoteChanges: remote)
    }

    /// One delta round: every page until Graph hands back the next delta link.
    private func deltaRound(start: String, account: String) async throws -> (messages: [GraphMessage], deltaLink: String) {
        var url = start
        var messages: [GraphMessage] = []
        for _ in 0..<200 {
            let (data, status) = try await get(url, account: account, extraHeaders: ["Prefer": "odata.maxpagesize=100, IdType=\"ImmutableId\""])
            // An expired delta link: start again from a full listing.
            if status == 410 || status == 400 && String(data: data, encoding: .utf8)?.contains("syncStateNotFound") == true
                || String(data: data, encoding: .utf8)?.contains("SyncStateNotFound") == true { throw ClientError.historyExpired }
            try Self.check(status, data)
            let page = try JSONDecoder().decode(GraphPage<GraphMessage>.self, from: data)
            messages += page.value
            if let next = page.nextLink { url = next; continue }
            if let delta = page.deltaLink { return (messages, delta) }
            break
        }
        throw ClientError.decodingFailed
    }

    func listRecentSent(account: String) async throws -> [String] {
        let page: GraphPage<GraphMessage> = try await getJSON("\(Self.base)/me/mailFolders/sentitems/messages?$select=\(Self.listFields)&$top=100&$orderby=receivedDateTime+desc", account: account)
        await OutlookCache.shared.keep(page.value, account: account)
        return page.value.map(\.id)
    }

    func listOlderInbox(account: String, pageToken: String?) async throws -> (ids: [(id: String, threadId: String?)], nextPageToken: String?) {
        guard let pageToken else { return ([], nil) }
        let page: GraphPage<GraphMessage> = try await getJSON(pageToken.replacingOccurrences(of: "$select=id&", with: "$select=\(Self.listFields)&"), account: account)
        await OutlookCache.shared.keep(page.value, account: account)
        return (page.value.map { ($0.id, $0.conversationId) }, page.nextLink)
    }

    // MARK: Messages

    func fetchMetadata(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        // Most come with the delta that listed them, already here.
        let cached = await OutlookCache.shared.take(ids, account: account)
        let missing = ids.filter { cached[$0] == nil }
        let fetched = try await batchGet(missing, fields: Self.listFields, account: account)
        let folders = try await OutlookFolders.shared.ids(for: account, client: self)
        let all = ids.compactMap { cached[$0] ?? fetched.found[$0] }
        return (all.map { map($0, account: account, folders: folders, full: false) }, fetched.failed)
    }

    func fetchFull(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        try await fetchMessages(ids: ids, account: account)
    }

    /// Just enough to notify about an email: who, what, its preview, and
    /// the headers that tell bulk mail apart. One request, no body.
    func fetchSummary(ids: [String], account: String) async throws -> [Correspondence] {
        let fetched = try await batchGet(ids, fields: Self.listFields + ",internetMessageHeaders", account: account)
        let folders = try await OutlookFolders.shared.ids(for: account, client: self)
        return ids.compactMap { fetched.found[$0] }.map { map($0, account: account, folders: folders, full: false) }
    }

    func fetchMessages(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        let fetched = try await batchGet(ids, fields: Self.fullFields, account: account, expandAttachments: true)
        let folders = try await OutlookFolders.shared.ids(for: account, client: self)
        var items: [Correspondence] = []
        for id in ids {
            guard var message = fetched.found[id] else { continue }
            if let html = message.body?.content, message.body?.contentType?.lowercased() == "html", html.contains("cid:") {
                message.inlinedHTML = await inlineImages(in: html, messageID: id, account: account)
            }
            items.append(map(message, account: account, folders: folders, full: true))
        }
        return (items, fetched.failed)
    }

    func fetchThreadMessages(threadId: String, account: String) async throws -> [Correspondence] {
        let escaped = threadId.replacingOccurrences(of: "'", with: "''")
        let filter = "conversationId eq '\(escaped)'".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let page: GraphPage<GraphMessage> = try await getJSON("\(Self.base)/me/messages?$select=id&$filter=\(filter)&$top=50", account: account)
        let ids = page.value.map(\.id)
        return try await fetchMessages(ids: ids, account: account).items.sorted { $0.receivedAt < $1.receivedAt }
    }

    func searchMessages(query: String, account: String) async throws -> [Correspondence] {
        let term = "\"\(query.replacingOccurrences(of: "\"", with: ""))\"".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let page: GraphPage<GraphMessage> = try await getJSON("\(Self.base)/me/messages?$select=\(Self.listFields)&$search=\(term)&$top=25", account: account)
        let folders = try await OutlookFolders.shared.ids(for: account, client: self)
        return page.value.map { map($0, account: account, folders: folders, full: false) }
    }

    func sentAddressing(account: String, limit: Int) async throws -> [GmailAPIClient.Addressing] {
        let page: GraphPage<GraphMessage> = try await getJSON("\(Self.base)/me/mailFolders/sentitems/messages?$select=toRecipients,ccRecipients,subject,receivedDateTime&$top=\(min(limit, 500))&$orderby=receivedDateTime+desc", account: account)
        return page.value.map(Self.addressing)
    }

    func addressing(matching name: String, account: String) async throws -> [GmailAPIClient.Addressing] {
        let term = "\"\(name.replacingOccurrences(of: "\"", with: ""))\"".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let page: GraphPage<GraphMessage> = try await getJSON("\(Self.base)/me/messages?$select=from,toRecipients,ccRecipients,subject,receivedDateTime&$search=\(term)&$top=25", account: account)
        return page.value.map(Self.addressing)
    }

    private static func addressing(_ message: GraphMessage) -> GmailAPIClient.Addressing {
        GmailAPIClient.Addressing(from: message.from.map(\.formatted) ?? "",
                                  recipients: (message.toRecipients ?? []).map(\.formatted) + (message.ccRecipients ?? []).map(\.formatted),
                                  subject: message.subject ?? "", date: message.receivedDate ?? .now)
    }

    func findMessage(rfc822MessageID: String, account: String) async throws -> ThreadID? {
        let filter = "internetMessageId eq '<\(rfc822MessageID)>'".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let page: GraphPage<GraphMessage> = try await getJSON("\(Self.base)/me/messages?$select=id,conversationId&$filter=\(filter)&$top=1", account: account)
        return page.value.first?.conversationId.map { ThreadID(account: account, providerID: $0) }
    }

    func fetchAttachmentData(messageId: String, attachmentId: String, account: String) async throws -> Data {
        let attachment: GraphAttachment = try await getJSON("\(Self.base)/me/messages/\(messageId)/attachments/\(attachmentId)", account: account)
        guard let bytes = attachment.contentBytes, let data = Data(base64Encoded: bytes) else { throw ClientError.decodingFailed }
        return data
    }

    #if DEBUG
    /// Settings → Developer: the newest Inbox mail, for the corpus. Never
    /// in a release build.
    func exportCorpus(account: String, limit: Int) async throws -> (items: [Correspondence], missing: Int) {
        let page: GraphPage<GraphMessage> = try await getJSON("\(Self.base)/me/mailFolders/inbox/messages?$select=id&$top=\(min(limit, 500))&$orderby=receivedDateTime+desc", account: account)
        let fetched = try await fetchMessages(ids: page.value.map(\.id), account: account)
        return (fetched.items, fetched.failedIDs.count)
    }
    #endif

    // MARK: Sending

    /// The same MIME message Corres builds for Gmail, sent as it is (Graph
    /// takes base64 MIME). Bcc, formatting, attachments and calendar replies
    /// all go exactly as written. Graph doesn't answer with the new
    /// message, so it's found again by its Message-ID.
    @discardableResult
    func send(raw: String, threadId: String?, account: String) async throws -> String {
        let status = try await postMIME("\(Self.base)/me/sendMail", raw: raw, account: account).status
        guard (200..<300).contains(status) else { throw ClientError.badResponse(statusCode: status) }
        if let messageID = Self.messageID(inRaw: raw) {
            for delay in [0.6, 1.2, 2.4] {
                try? await Task.sleep(for: .seconds(delay))
                if let found = try? await findMessage(rfc822MessageID: messageID, account: account) { return found.providerID }
            }
        }
        return threadId ?? "outlook-sent-\(UUID().uuidString)"
    }

    func saveDraft(raw: String, threadId: String?, existingID: String?, account: String) async throws -> String {
        // A MIME draft can't be edited in place: the old one goes, the new
        // one takes its place.
        if let existingID { try? await deleteDraft(id: existingID, account: account) }
        let result = try await postMIME("\(Self.base)/me/messages", raw: raw, account: account)
        guard (200..<300).contains(result.status) else { throw ClientError.badResponse(statusCode: result.status) }
        return try JSONDecoder().decode(GraphMessage.self, from: result.data).id
    }

    /// Graph takes about 4 MB in one request. Bigger emails go the way
    /// Microsoft recommends: the email as a draft without its attachments,
    /// each attachment added (large ones uploaded in pieces), then sent.
    static let singleRequestLimit = 3_000_000

    /// Sends with attachments too big for one request. `rawWithout` is the
    /// same email built without them.
    func sendLarge(rawWithout: String, attachments: [PendingAttachment], threadId: String?, account: String) async throws -> String {
        let draftID = try await draftWithAttachments(rawWithout: rawWithout, attachments: attachments, account: account)
        try await change("POST", "\(Self.base)/me/messages/\(draftID)/send", body: nil, account: account)
        if let messageID = Self.messageID(inRaw: rawWithout) {
            for delay in [0.8, 1.6, 3.2] {
                try? await Task.sleep(for: .seconds(delay))
                if let found = try? await findMessage(rfc822MessageID: messageID, account: account) { return found.providerID }
            }
        }
        return threadId ?? "outlook-sent-\(UUID().uuidString)"
    }

    /// A draft with attachments too big for one request.
    func draftWithAttachments(rawWithout: String, attachments: [PendingAttachment], existingID: String? = nil, account: String) async throws -> String {
        if let existingID { try? await deleteDraft(id: existingID, account: account) }
        let created = try await postMIME("\(Self.base)/me/messages", raw: rawWithout, account: account)
        guard (200..<300).contains(created.status) else { throw ClientError.badResponse(statusCode: created.status) }
        let draftID = try JSONDecoder().decode(GraphMessage.self, from: created.data).id
        for attachment in attachments {
            if attachment.data.count < Self.singleRequestLimit {
                try await change("POST", "\(Self.base)/me/messages/\(draftID)/attachments", body: [
                    "@odata.type": "#microsoft.graph.fileAttachment", "name": attachment.filename,
                    "contentType": attachment.mimeType, "contentBytes": attachment.data.base64EncodedString(),
                ], account: account)
            } else {
                try await upload(attachment, toDraft: draftID, account: account)
            }
        }
        return draftID
    }

    /// One large attachment, in 4 MB pieces (a multiple of 320 KB, as
    /// Graph asks), to the upload URL Graph hands out.
    private func upload(_ attachment: PendingAttachment, toDraft draftID: String, account: String) async throws {
        var request = URLRequest(url: URL(string: "\(Self.base)/me/messages/\(draftID)/attachments/createUploadSession")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await token(account))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["AttachmentItem": [
            "attachmentType": "file", "name": attachment.filename, "size": attachment.data.count, "contentType": attachment.mimeType,
        ]])
        let (data, status) = try await perform(request, account: account)
        try Self.check(status, data)
        struct Session: Decodable { let uploadUrl: String }
        let session = try JSONDecoder().decode(Session.self, from: data)
        let chunk = 320 * 1024 * 12
        var offset = 0
        let total = attachment.data.count
        while offset < total {
            let end = min(offset + chunk, total)
            var put = URLRequest(url: URL(string: session.uploadUrl)!)
            put.httpMethod = "PUT"
            put.setValue("bytes \(offset)-\(end - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            put.httpBody = attachment.data.subdata(in: offset..<end)
            let (_, response) = try await URLSession.shared.data(for: put)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else { throw ClientError.badResponse(statusCode: code) }
            offset = end
        }
    }

    func deleteDraft(id: String, account: String) async throws {
        try await change("DELETE", "\(Self.base)/me/messages/\(id)", body: nil, account: account)
    }

    // MARK: Changes

    /// Labels on a conversation, done the Outlook way: read state and flags
    /// on each message, moves for Inbox, Archive and Junk, Focused/Other for
    /// the categories, and Outlook categories for labels.
    func modifyThread(threadId: String, addLabelIds: [String] = [], removeLabelIds: [String] = [], account: String) async throws {
        let messages = try await conversation(threadId, account: account)
        let folders = try await OutlookFolders.shared.ids(for: account, client: self)
        // One PATCH per message with every change in it, then the moves:
        // a $batch runs its requests in parallel, and two changes to the
        // same message at once can fail with a conflict.
        var patches: [GraphRequest] = []
        var moves: [GraphRequest] = []
        func move(_ id: String, to folder: String) { moves.append(GraphRequest(method: "POST", url: "/me/messages/\(id)/move", body: ["destinationId": folder])) }
        for message in messages {
            var changes: [String: Any] = [:]
            if addLabelIds.contains("UNREAD") { changes["isRead"] = false }
            if removeLabelIds.contains("UNREAD") { changes["isRead"] = true }
            if addLabelIds.contains("STARRED") { changes["flag"] = ["flagStatus": "flagged"] }
            if removeLabelIds.contains("STARRED") { changes["flag"] = ["flagStatus": "notFlagged"] }
            if let category = addLabelIds.first(where: { $0.hasPrefix("CATEGORY_") }) {
                changes["inferenceClassification"] = category == "CATEGORY_PERSONAL" ? "focused" : "other"
            }
            let addCats = addLabelIds.filter { $0.hasPrefix("cat:") }.map { String($0.dropFirst(4)) }
            let removeCats = Set(removeLabelIds.filter { $0.hasPrefix("cat:") }.map { String($0.dropFirst(4)) })
            if !addCats.isEmpty || !removeCats.isEmpty {
                changes["categories"] = Array(Set((message.categories ?? []) + addCats).subtracting(removeCats))
            }
            if !changes.isEmpty { patches.append(GraphRequest(method: "PATCH", url: "/me/messages/\(message.id)", body: changes)) }
            let inInbox = message.parentFolderId == folders.inbox
            // Archive: out of the Inbox, into Archive. Back: into the Inbox.
            if removeLabelIds.contains("INBOX"), inInbox { move(message.id, to: "archive") }
            if addLabelIds.contains("INBOX"), !inInbox, message.parentFolderId != folders.sent { move(message.id, to: "inbox") }
            // Move to one of the person's folders, and back out of it.
            if let folder = addLabelIds.first(where: { $0.hasPrefix("folder:") }).map({ String($0.dropFirst(7)) }),
               message.parentFolderId != folder, message.parentFolderId != folders.sent, message.parentFolderId != folders.drafts {
                move(message.id, to: folder)
            }
            if let folder = removeLabelIds.first(where: { $0.hasPrefix("folder:") }).map({ String($0.dropFirst(7)) }),
               message.parentFolderId == folder {
                move(message.id, to: "inbox")
            }
            if addLabelIds.contains("SPAM") { move(message.id, to: "junkemail") }
            if removeLabelIds.contains("SPAM"), message.parentFolderId == folders.junk { move(message.id, to: "inbox") }
        }
        try await batch(patches, account: account)
        try await batch(moves, account: account)
    }

    func trashThread(threadId: String, account: String) async throws {
        let folders = try await OutlookFolders.shared.ids(for: account, client: self)
        let messages = try await conversation(threadId, account: account).filter { $0.parentFolderId != folders.trash }
        try await batch(messages.map { GraphRequest(method: "POST", url: "/me/messages/\($0.id)/move", body: ["destinationId": "deleteditems"]) }, account: account)
    }

    func untrashThread(threadId: String, account: String) async throws {
        let folders = try await OutlookFolders.shared.ids(for: account, client: self)
        let messages = try await conversation(threadId, account: account).filter { $0.parentFolderId == folders.trash }
        try await batch(messages.map { GraphRequest(method: "POST", url: "/me/messages/\($0.id)/move", body: ["destinationId": "inbox"]) }, account: account)
    }

    private func conversation(_ threadId: String, account: String) async throws -> [GraphMessage] {
        let escaped = threadId.replacingOccurrences(of: "'", with: "''")
        let filter = "conversationId eq '\(escaped)'".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let page: GraphPage<GraphMessage> = try await getJSON("\(Self.base)/me/messages?$select=id,parentFolderId,categories&$filter=\(filter)&$top=100", account: account)
        return page.value
    }

    // MARK: Settings

    /// Outlook sends only from the account's own address through Graph.
    func sendAs(account: String) async throws -> [GmailAPIClient.SendAs] { [] }

    /// Outlook's Automatic Replies, described as Gmail's vacation reply.
    func vacation(account: String) async throws -> GmailAPIClient.Vacation {
        let settings: AutoReplyEnvelope = try await getJSON("\(Self.base)/me/mailboxSettings/automaticRepliesSetting", account: account)
        let reply = settings.value ?? AutoReply(status: settings.status, externalAudience: settings.externalAudience,
                                                internalReplyMessage: settings.internalReplyMessage, externalReplyMessage: settings.externalReplyMessage,
                                                scheduledStartDateTime: settings.scheduledStartDateTime, scheduledEndDateTime: settings.scheduledEndDateTime)
        let message = MailDigest.readableText(body: "", html: reply.externalReplyMessage ?? reply.internalReplyMessage ?? "")
        return GmailAPIClient.Vacation(
            enableAutoReply: reply.status != "disabled", responseSubject: nil, responseBodyPlainText: message,
            responseBodyHtml: nil, restrictToContacts: reply.externalAudience == "contactsOnly", restrictToDomain: nil,
            startTime: reply.status == "scheduled" ? reply.scheduledStartDateTime?.date.map { String(Int64($0.timeIntervalSince1970 * 1000)) } : nil,
            endTime: reply.status == "scheduled" ? reply.scheduledEndDateTime?.date.map { String(Int64($0.timeIntervalSince1970 * 1000)) } : nil)
    }

    func setVacation(_ vacation: GmailAPIClient.Vacation, account: String) async throws {
        let html = PlainTextEmail.escape(vacation.responseBodyPlainText ?? "").replacingOccurrences(of: "\n", with: "<br>")
        var setting: [String: Any] = [
            "status": !vacation.enableAutoReply ? "disabled" : (vacation.endTime != nil ? "scheduled" : "alwaysEnabled"),
            "externalAudience": vacation.restrictToContacts == true ? "contactsOnly" : "all",
            "internalReplyMessage": html, "externalReplyMessage": html,
        ]
        func when(_ ms: String?) -> [String: String]? {
            guard let ms, let value = Double(ms) else { return nil }
            return ["dateTime": Self.graphDateTime(Date(timeIntervalSince1970: value / 1000)), "timeZone": "UTC"]
        }
        if vacation.enableAutoReply, vacation.endTime != nil {
            setting["scheduledStartDateTime"] = when(vacation.startTime) ?? ["dateTime": Self.graphDateTime(.now), "timeZone": "UTC"]
            setting["scheduledEndDateTime"] = when(vacation.endTime)
        }
        try await change("PATCH", "\(Self.base)/me/mailboxSettings", body: ["automaticRepliesSetting": setting], account: account)
    }

    // MARK: Mailboxes and labels

    func listMailbox(labelId: String?, account: String, pageToken: String?, pageSize: Int = 25) async throws -> (items: [Correspondence], nextPageToken: String?) {
        let url: String
        if let pageToken {
            url = pageToken
        } else {
            let top = "$select=\(Self.listFields)&$top=\(pageSize)&$orderby=receivedDateTime+desc"
            switch labelId {
            case "SENT": url = "\(Self.base)/me/mailFolders/sentitems/messages?\(top)"
            case "TRASH": url = "\(Self.base)/me/mailFolders/deleteditems/messages?\(top)"
            case "SPAM": url = "\(Self.base)/me/mailFolders/junkemail/messages?\(top)"
            case "DRAFT": url = "\(Self.base)/me/mailFolders/drafts/messages?\(top)"
            case "INBOX": url = "\(Self.base)/me/mailFolders/inbox/messages?\(top)"
            case "STARRED":
                let filter = "flag/flagStatus eq 'flagged'".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                url = "\(Self.base)/me/messages?$select=\(Self.listFields)&$top=\(pageSize)&$filter=\(filter)"
            case let label? where label.hasPrefix("folder:"):
                let id = String(label.dropFirst(7)).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                url = "\(Self.base)/me/mailFolders/\(id)/messages?\(top)"
            case let label? where label.hasPrefix("cat:"):
                let name = String(label.dropFirst(4)).replacingOccurrences(of: "'", with: "''")
                let filter = "categories/any(c:c eq '\(name)')".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                url = "\(Self.base)/me/messages?$select=\(Self.listFields)&$top=\(pageSize)&$filter=\(filter)"
            default:
                // All Mail, as Gmail means it: everything but Deleted Items and Junk.
                let folders = try await OutlookFolders.shared.ids(for: account, client: self)
                let excluded = [folders.trash, folders.junk].compactMap { $0 }.map { "parentFolderId ne '\($0)'" }
                let filter = (["receivedDateTime ge 1900-01-01T00:00:00Z"] + excluded).joined(separator: " and ")
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                url = "\(Self.base)/me/messages?\(top)&$filter=\(filter)"
            }
        }
        let page: GraphPage<GraphMessage> = try await getJSON(url, account: account)
        let folders = try await OutlookFolders.shared.ids(for: account, client: self)
        return (page.value.map { map($0, account: account, folders: folders, full: false) }, page.nextLink)
    }

    func listDrafts(account: String, pageToken: String?, pageSize: Int = 25) async throws -> (items: [(draftID: String, message: Correspondence)], nextPageToken: String?) {
        let listed = try await listMailbox(labelId: "DRAFT", account: account, pageToken: pageToken, pageSize: pageSize)
        // In Outlook a draft is its own message: its id is the draft's id.
        return (listed.items.map { ($0.latestMessageID ?? $0.id.providerID, $0) }, listed.nextPageToken)
    }

    /// The person's own folders (and those inside them, as "Parent/Child",
    /// Gmail's way of naming nested labels), then their categories.
    func fetchUserLabels(account: String) async throws -> [GmailUserLabel] {
        let known = try await OutlookFolders.shared.ids(for: account, client: self)
        let builtIn = Set([known.inbox, known.sent, known.trash, known.junk, known.drafts].compactMap { $0 })
        // Outlook's own system folders that aren't mail you filed.
        let skipped: Set<String> = ["outbox", "conversation history", "sync issues", "rss feeds", "rss subscriptions", "scheduled"]
        var folders: [GmailUserLabel] = []
        func add(_ list: [GraphFolder], prefix: String, depth: Int) async {
            for folder in list where !builtIn.contains(folder.id) && !skipped.contains(folder.displayName.lowercased()) {
                let name = prefix.isEmpty ? folder.displayName : "\(prefix)/\(folder.displayName)"
                folders.append(GmailUserLabel(id: "folder:\(folder.id)", name: name))
                if (folder.childFolderCount ?? 0) > 0, depth < 3,
                   let children: GraphPage<GraphFolder> = try? await getJSON("\(Self.base)/me/mailFolders/\(folder.id)/childFolders?$top=100&$select=id,displayName,childFolderCount", account: account) {
                    await add(children.value, prefix: name, depth: depth + 1)
                }
            }
        }
        let top: GraphPage<GraphFolder> = try await getJSON("\(Self.base)/me/mailFolders?$top=100&$select=id,displayName,childFolderCount", account: account)
        await add(top.value, prefix: "", depth: 0)
        // Every Outlook account starts with six colour categories nobody
        // named ("Blue category"); left as they came, they're clutter.
        let categories = ((try? await getJSON("\(Self.base)/me/outlook/masterCategories", account: account) as GraphPage<GraphCategory>)?.value ?? [])
            .filter { $0.displayName.patternRange(#"^(Blue|Green|Orange|Purple|Red|Yellow) category$"#) == nil }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            + categories.map { GmailUserLabel(id: "cat:\($0.displayName)", name: $0.displayName) }
    }

    /// Gmail's watch has no Outlook twin by that name; Outlook's
    /// notifications are `subscribe` below.
    func watch(topicName: String, account: String) async throws -> String? { nil }

    func stopWatching(account: String) async throws {
        guard let saved = OutlookSubscription.load(account) else { return }
        try? await change("DELETE", "\(Self.base)/subscriptions/\(saved.id)", body: nil, account: account)
        OutlookSubscription.clear(account)
    }

    /// New mail in the Inbox, told to the relay as it arrives (Microsoft
    /// Graph change notifications). Renewed well before it lapses; a lost
    /// one is made again. Returns the subscription and its secret, for the
    /// relay to check each notification against.
    func subscribe(account: String, notificationURL: URL) async throws -> OutlookSubscription {
        // Graph's longest for Outlook mail is 4,230 minutes (under 3 days);
        // longer is refused outright. Kept a little under, and renewed once
        // under two days are left, at launch, background refresh or any push.
        let lifetime: TimeInterval = 4_200 * 60
        if var saved = OutlookSubscription.load(account) {
            if saved.expires > Date.now.addingTimeInterval(2 * 86_400) { return saved }
            let next = Date.now.addingTimeInterval(lifetime)
            do {
                try await change("PATCH", "\(Self.base)/subscriptions/\(saved.id)",
                                 body: ["expirationDateTime": Self.isoDate(next)], account: account)
                saved.expires = next
                saved.save(account)
                return saved
            } catch {
                OutlookSubscription.clear(account)
            }
        }
        let secret = (0..<2).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined().lowercased()
        let expires = Date.now.addingTimeInterval(lifetime)
        var request = URLRequest(url: URL(string: "\(Self.base)/subscriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await token(account))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Notifications name each new message by the same lasting id
        // Corres uses everywhere, for the notification to fetch it by.
        request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "changeType": "created", "notificationUrl": notificationURL.absoluteString,
            "resource": "me/mailFolders('inbox')/messages", "expirationDateTime": Self.isoDate(expires),
            "clientState": secret,
        ])
        let (data, status) = try await perform(request, account: account)
        try Self.check(status, data)
        struct Created: Decodable { let id: String }
        let created = try JSONDecoder().decode(Created.self, from: data)
        let subscription = OutlookSubscription(id: created.id, secret: secret, expires: expires)
        subscription.save(account)
        return subscription
    }

    // MARK: Mapping

    private func map(_ message: GraphMessage, account: String, folders: OutlookFolders.IDs, full: Bool) -> Correspondence {
        let from = message.from ?? message.sender
        let senderEmail = from?.emailAddress.address?.lowercased() ?? ""
        let sender = from?.emailAddress.name.flatMap { $0.isEmpty ? nil : $0 } ?? senderEmail
        let headers = Dictionary((message.internetMessageHeaders ?? []).map { ($0.name.lowercased(), $0.value) },
                                 uniquingKeysWith: { first, _ in first })
        let (mailto, url) = GmailAPIClient.parseListUnsubscribe(headers["list-unsubscribe"] ?? "")
        let isHTML = message.body?.contentType?.lowercased() == "html"
        let html = isHTML ? (message.inlinedHTML ?? message.body?.content) : nil
        let plain: String = {
            guard let body = message.body?.content else { return message.bodyPreview ?? "" }
            return isHTML ? MailDigest.readableText(body: "", html: body) : body
        }()
        let attachments = (message.attachments ?? []).filter { $0.isInline != true }.map {
            MailAttachment(id: $0.id, filename: $0.name ?? "Attachment", mimeType: $0.contentType ?? "application/octet-stream", sizeBytes: $0.size ?? 0)
        }
        return GmailAPIClient.build(
            account: account, threadID: message.conversationId ?? message.id, messageID: message.id,
            sender: sender, senderEmail: senderEmail, organization: GmailAPIClient.organization(fromEmail: senderEmail),
            subject: (message.subject ?? "").isEmpty ? "(no subject)" : message.subject!, excerpt: message.bodyPreview ?? "",
            body: full ? plain : (message.bodyPreview ?? ""), htmlBody: html,
            messageIdHeader: message.internetMessageId?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")),
            receivedAt: message.receivedDate ?? .now, isUnread: message.isRead == false,
            labelIds: Self.labels(for: message, folders: folders, hasUnsubscribe: mailto != nil || url != nil),
            attachments: attachments, toRecipients: (message.toRecipients ?? []).map(\.formatted),
            ccRecipients: (message.ccRecipients ?? []).map(\.formatted), replyTo: (message.replyTo ?? []).map(\.formatted),
            listUnsubscribeMailto: mailto, listUnsubscribeURL: url,
            listUnsubscribeOneClick: url != nil && (headers["list-unsubscribe-post"]?.lowercased().contains("one-click") ?? false),
            bodyLoaded: full)
    }

    static func labels(for message: GraphMessage, folders: OutlookFolders.IDs, hasUnsubscribe: Bool = false) -> [String] {
        var labels: [String] = []
        switch message.parentFolderId {
        case folders.inbox: labels.append("INBOX")
        case folders.sent: labels.append("SENT")
        case folders.trash: labels.append("TRASH")
        case folders.junk: labels.append("SPAM")
        case folders.drafts: labels.append("DRAFT")
        default: break
        }
        // One of the person's own folders: a label, as Gmail's are, so its
        // mailbox lists it.
        if let folder = message.parentFolderId,
           ![folders.inbox, folders.sent, folders.trash, folders.junk, folders.drafts].contains(folder) {
            labels.append("folder:\(folder)")
        }
        if message.isRead == false { labels.append("UNREAD") }
        if message.flag?.flagStatus == "flagged" { labels.append("STARRED") }
        if message.parentFolderId == folders.inbox {
            switch message.inferenceClassification {
            case "focused": labels.append("CATEGORY_PERSONAL")
            case "other": labels.append(hasUnsubscribe ? "CATEGORY_PROMOTIONS" : "CATEGORY_UPDATES")
            default: break
            }
        }
        labels += (message.categories ?? []).map { "cat:\($0)" }
        return labels
    }

    /// Inline images (cid:) as data, so a signature logo or a pasted photo
    /// shows in the email.
    private func inlineImages(in html: String, messageID: String, account: String) async -> String {
        guard let page: GraphPage<GraphAttachment> = try? await getJSON("\(Self.base)/me/messages/\(messageID)/attachments", account: account) else { return html }
        var result = html
        for attachment in page.value where attachment.isInline == true {
            guard let cid = attachment.contentId, let bytes = attachment.contentBytes else { continue }
            let type = attachment.contentType ?? "image/png"
            result = result.replacingOccurrences(of: "cid:\(cid)", with: "data:\(type);base64,\(bytes)")
        }
        return result
    }

    // MARK: HTTP

    private func token(_ account: String) async throws -> String {
        do { return try await OutlookTokenProvider.shared.accessToken(for: account) }
        catch { throw ClientError.notSignedIn }
    }

    private func get(_ url: String, account: String, extraHeaders: [String: String] = [:]) async throws -> (Data, Int) {
        guard let requestURL = URL(string: url) else { throw ClientError.decodingFailed }
        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(try await token(account))", forHTTPHeaderField: "Authorization")
        request.setValue(extraHeaders["Prefer"] ?? "IdType=\"ImmutableId\", outlook.body-content-type=\"html\"", forHTTPHeaderField: "Prefer")
        // $search needs this on some tenants.
        if url.contains("$search") { request.setValue("eventual", forHTTPHeaderField: "ConsistencyLevel") }
        return try await perform(request, account: account)
    }

    /// Honors Graph's throttling (429 with Retry-After) a few times, and a
    /// stale token once.
    private func perform(_ request: URLRequest, account: String) async throws -> (Data, Int) {
        var request = request
        for attempt in 0..<4 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 401, attempt == 0 {
                await OutlookTokenProvider.shared.invalidateAccessToken(for: account)
                request.setValue("Bearer \(try await token(account))", forHTTPHeaderField: "Authorization")
                continue
            }
            if status == 429 || status == 503 || status == 504, attempt < 3 {
                let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Double(1 << attempt)
                try await Task.sleep(for: .seconds(min(wait, 10)))
                continue
            }
            return (data, status)
        }
        throw ClientError.badResponse(statusCode: 429)
    }

    private func getJSON<T: Decodable>(_ url: String, account: String) async throws -> T {
        let (data, status) = try await get(url, account: account)
        try Self.check(status, data)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ClientError.decodingFailed }
    }

    private func change(_ method: String, _ url: String, body: [String: Any]?, account: String) async throws {
        guard let requestURL = URL(string: url) else { throw ClientError.decodingFailed }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("Bearer \(try await token(account))", forHTTPHeaderField: "Authorization")
        request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, status) = try await perform(request, account: account)
        try Self.check(status, data)
    }

    private func postMIME(_ url: String, raw: String, account: String) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await token(account))", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
        // Corres builds base64url for Gmail; Graph wants plain base64.
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        request.httpBody = Data(base64.utf8)
        let (data, status) = try await perform(request, account: account)
        return (data, status)
    }

    private struct GraphRequest {
        let method: String
        let url: String
        var body: [String: Any]?
    }

    /// Up to 20 at a time, Graph's limit; a failure in one is reported.
    private func batch(_ requests: [GraphRequest], account: String) async throws {
        guard !requests.isEmpty else { return }
        for chunk in requests.chunked(into: Self.batchLimit) {
            let payload: [String: Any] = ["requests": chunk.enumerated().map { index, item -> [String: Any] in
                var entry: [String: Any] = ["id": "\(index)", "method": item.method, "url": item.url,
                                            "headers": ["Content-Type": "application/json", "Prefer": "IdType=\"ImmutableId\""]]
                if let body = item.body { entry["body"] = body }
                return entry
            }]
            var request = URLRequest(url: URL(string: "\(Self.base)/$batch")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(try await token(account))", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, status) = try await perform(request, account: account)
            try Self.check(status, data)
            let responses = (try? JSONDecoder().decode(BatchResponse.self, from: data))?.responses ?? []
            if let failed = responses.first(where: { !(200..<300).contains($0.status) }) {
                throw ClientError.refused(statusCode: failed.status, reason: nil, message: "An Outlook change was refused.")
            }
        }
    }

    private func batchGet(_ ids: [String], fields: String, account: String, expandAttachments: Bool = false) async throws -> (found: [String: GraphMessage], failed: [String]) {
        var found: [String: GraphMessage] = [:]
        var failed: [String] = []
        let expand = expandAttachments ? "&$expand=attachments($select=id,name,contentType,size,isInline)" : ""
        for chunk in ids.chunked(into: Self.batchLimit) {
            let payload: [String: Any] = ["requests": chunk.enumerated().map { index, id in
                ["id": "\(index)", "method": "GET", "url": "/me/messages/\(id)?$select=\(fields)\(expand)",
                 "headers": ["Prefer": "IdType=\"ImmutableId\", outlook.body-content-type=\"html\""]] as [String: Any]
            }]
            var request = URLRequest(url: URL(string: "\(Self.base)/$batch")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(try await token(account))", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, status) = try await perform(request, account: account)
            try Self.check(status, data)
            let responses = (try? JSONDecoder().decode(BatchMessages.self, from: data))?.responses ?? []
            for response in responses {
                guard let index = Int(response.id), chunk.indices.contains(index) else { continue }
                if let message = response.body, (200..<300).contains(response.status) { found[chunk[index]] = message }
                else { failed.append(chunk[index]) }
            }
        }
        return (found, failed)
    }

    private static func check(_ status: Int, _ data: Data) throws {
        guard (200..<300).contains(status) else {
            let error = try? JSONDecoder().decode(GraphErrorEnvelope.self, from: data)
            if status == 401 { throw ClientError.notSignedIn }
            throw ClientError.refused(statusCode: status, reason: error?.error.code, message: error?.error.message)
        }
    }

    // MARK: Small helpers

    private static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func graphDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    /// The Message-ID Corres stamped on the email, read back from the MIME.
    static func messageID(inRaw raw: String) -> String? {
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: String(base64.prefix(8_000 - 8_000 % 4))),
              let head = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let range = head.patternRange(#"(?im)^Message-ID:\s*<([^>]+)>"#) else { return nil }
        let line = String(head[range])
        return line.patternRange(#"<([^>]+)>"#).map { String(line[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
    }
}

/// An account's Outlook notification subscription, kept on this iPhone.
struct OutlookSubscription: Codable, Sendable {
    let id: String
    let secret: String
    var expires: Date

    private static func key(_ account: String) -> String { "corres.outlookSubscription.\(account.lowercased())" }
    static func load(_ account: String) -> OutlookSubscription? {
        UserDefaults.standard.data(forKey: key(account)).flatMap { try? JSONDecoder().decode(OutlookSubscription.self, from: $0) }
    }
    func save(_ account: String) { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(account)) }
    static func clear(_ account: String) { UserDefaults.standard.removeObject(forKey: key(account)) }
}

// MARK: - Graph types

struct GraphPage<T: Decodable>: Decodable {
    let value: [T]
    let nextLink: String?
    let deltaLink: String?
    enum CodingKeys: String, CodingKey { case value, nextLink = "@odata.nextLink", deltaLink = "@odata.deltaLink" }
}

struct GraphRecipient: Decodable, Sendable {
    struct Address: Decodable, Sendable { let name: String?; let address: String? }
    let emailAddress: Address
    /// "Sara Wiltshire <sara@x.com>", as Corres keeps addresses.
    var formatted: String {
        let address = emailAddress.address ?? ""
        guard let name = emailAddress.name, !name.isEmpty, name.lowercased() != address.lowercased() else { return address }
        return name.contains(",") ? "\"\(name)\" <\(address)>" : "\(name) <\(address)>"
    }
}

struct GraphAttachment: Decodable, Sendable {
    let id: String
    let name: String?
    let contentType: String?
    let size: Int?
    let isInline: Bool?
    let contentId: String?
    let contentBytes: String?
}

struct GraphMessage: Decodable, Sendable {
    struct Body: Decodable, Sendable { let contentType: String?; let content: String? }
    struct Flag: Decodable, Sendable { let flagStatus: String? }
    struct Header: Decodable, Sendable { let name: String; let value: String }
    struct Removed: Decodable, Sendable { let reason: String? }

    let id: String
    let conversationId: String?
    let subject: String?
    let bodyPreview: String?
    let body: Body?
    let from: GraphRecipient?
    let sender: GraphRecipient?
    let toRecipients: [GraphRecipient]?
    let ccRecipients: [GraphRecipient]?
    let replyTo: [GraphRecipient]?
    let receivedDateTime: String?
    let isRead: Bool?
    let isDraft: Bool?
    let flag: Flag?
    let internetMessageId: String?
    let internetMessageHeaders: [Header]?
    let parentFolderId: String?
    let inferenceClassification: String?
    let categories: [String]?
    let attachments: [GraphAttachment]?
    let removed: Removed?
    /// The body with its inline images filled in, when there were any.
    var inlinedHTML: String?

    enum CodingKeys: String, CodingKey {
        case id, conversationId, subject, bodyPreview, body, from, sender, toRecipients, ccRecipients, replyTo, receivedDateTime,
             isRead, isDraft, flag, internetMessageId, internetMessageHeaders, parentFolderId, inferenceClassification,
             categories, attachments
        case removed = "@removed"
    }

    var receivedDate: Date? {
        guard let receivedDateTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: receivedDateTime) ?? ISO8601DateFormatter().date(from: receivedDateTime)
    }
}

private struct GraphCategory: Decodable { let displayName: String }
private struct GraphFolder: Decodable { let id: String; let displayName: String; let childFolderCount: Int? }

private struct GraphErrorEnvelope: Decodable {
    struct Inner: Decodable { let code: String?; let message: String? }
    let error: Inner
}

private struct BatchResponse: Decodable {
    struct Item: Decodable { let id: String; let status: Int }
    let responses: [Item]
}

private struct BatchMessages: Decodable {
    struct Item: Decodable { let id: String; let status: Int; let body: GraphMessage? }
    let responses: [Item]
}

private struct AutoReply: Decodable {
    struct When: Decodable {
        let dateTime: String?
        let timeZone: String?
        var date: Date? {
            guard let dateTime else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: timeZone == "UTC" || timeZone == nil ? "UTC" : timeZone!) ?? TimeZone(identifier: "UTC")
            for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: dateTime) { return date }
            }
            return nil
        }
    }
    let status: String?
    let externalAudience: String?
    let internalReplyMessage: String?
    let externalReplyMessage: String?
    let scheduledStartDateTime: When?
    let scheduledEndDateTime: When?
}

private struct AutoReplyEnvelope: Decodable {
    let value: AutoReply?
    let status: String?
    let externalAudience: String?
    let internalReplyMessage: String?
    let externalReplyMessage: String?
    let scheduledStartDateTime: AutoReply.When?
    let scheduledEndDateTime: AutoReply.When?
}

// MARK: - Caches

/// Messages that came with a delta round, kept until the sync asks for
/// them, so most need no second request.
actor OutlookCache {
    static let shared = OutlookCache()
    private var messages: [String: GraphMessage] = [:]

    func keep(_ items: [GraphMessage], account: String) {
        for item in items { messages[account + "|" + item.id] = item }
        if messages.count > 4_000 { messages.removeAll() }
    }

    func take(_ ids: [String], account: String) -> [String: GraphMessage] {
        var found: [String: GraphMessage] = [:]
        for id in ids { if let item = messages.removeValue(forKey: account + "|" + id) { found[id] = item } }
        return found
    }
}

/// Each account's well-known folder ids, asked for once.
actor OutlookFolders {
    static let shared = OutlookFolders()

    struct IDs: Codable, Sendable {
        var inbox: String?
        var sent: String?
        var trash: String?
        var junk: String?
        var drafts: String?
        var archive: String?
    }

    private var known: [String: IDs] = [:]

    func ids(for account: String, client: OutlookClient) async throws -> IDs {
        if let ids = known[account] { return ids }
        let key = "corres.outlookFolders.\(account.lowercased())"
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode(IDs.self, from: data) {
            known[account] = saved
            return saved
        }
        let ids = try await client.wellKnownFolders(account: account)
        known[account] = ids
        UserDefaults.standard.set(try? JSONEncoder().encode(ids), forKey: key)
        return ids
    }

    func forget(_ account: String) {
        known[account] = nil
        UserDefaults.standard.removeObject(forKey: "corres.outlookFolders.\(account.lowercased())")
    }
}

extension OutlookClient {
    fileprivate struct Folder: Decodable { let id: String }

    func wellKnownFolders(account: String) async throws -> OutlookFolders.IDs {
        async let inbox: Folder = getJSON("\(Self.base)/me/mailFolders/inbox?$select=id", account: account)
        async let sent: Folder = getJSON("\(Self.base)/me/mailFolders/sentitems?$select=id", account: account)
        async let trash: Folder = getJSON("\(Self.base)/me/mailFolders/deleteditems?$select=id", account: account)
        async let junk: Folder = getJSON("\(Self.base)/me/mailFolders/junkemail?$select=id", account: account)
        async let drafts: Folder = getJSON("\(Self.base)/me/mailFolders/drafts?$select=id", account: account)
        let archive: Folder? = try? await getJSON("\(Self.base)/me/mailFolders/archive?$select=id", account: account)
        return try await OutlookFolders.IDs(inbox: inbox.id, sent: sent.id, trash: trash.id, junk: junk.id, drafts: drafts.id, archive: archive?.id)
    }
}
