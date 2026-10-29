import Foundation

/// The one door to mail: each call goes to Gmail, Outlook or iCloud by the
/// account's provider (`MailAccounts`), with the same shapes every way,
/// so sync, sorting, sending, drafts and every action work alike.
struct MailClient: Sendable {
    typealias ClientError = GmailAPIClient.ClientError
    typealias SyncPlan = GmailAPIClient.SyncPlan
    typealias SendAs = GmailAPIClient.SendAs
    typealias Vacation = GmailAPIClient.Vacation
    typealias Addressing = GmailAPIClient.Addressing

    static let batchSize = GmailAPIClient.batchSize

    private let gmail = GmailAPIClient()
    private let outlook = OutlookClient()
    private let icloud = IMAPMailClient()

    private func isOutlook(_ account: String) -> Bool { MailAccounts.provider(for: account) == .microsoft }
    /// iCloud and any other IMAP account share one client.
    private func isICloud(_ account: String) -> Bool { MailAccounts.provider(for: account).usesIMAP }

    func planFullListing(account: String) async throws -> SyncPlan {
        isICloud(account) ? try await icloud.planFullListing(account: account) : isOutlook(account) ? try await outlook.planFullListing(account: account) : try await gmail.planFullListing(account: account)
    }

    func planIncremental(account: String, since cursor: String) async throws -> SyncPlan {
        isICloud(account) ? try await icloud.planIncremental(account: account, since: cursor) : isOutlook(account) ? try await outlook.planIncremental(account: account, since: cursor)
            : try await gmail.planIncremental(account: account, since: cursor)
    }

    func listRecentSent(account: String) async throws -> [String] {
        isICloud(account) ? try await icloud.listRecentSent(account: account) : isOutlook(account) ? try await outlook.listRecentSent(account: account) : try await gmail.listRecentSent(account: account)
    }

    func listOlderInbox(account: String, pageToken: String?) async throws -> (ids: [(id: String, threadId: String?)], nextPageToken: String?) {
        isICloud(account) ? try await icloud.listOlderInbox(account: account, pageToken: pageToken) : isOutlook(account) ? try await outlook.listOlderInbox(account: account, pageToken: pageToken)
            : try await gmail.listOlderInbox(account: account, pageToken: pageToken)
    }

    func fetchMetadata(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        isICloud(account) ? try await icloud.fetchMetadata(ids: ids, account: account) : isOutlook(account) ? try await outlook.fetchMetadata(ids: ids, account: account) : try await gmail.fetchMetadata(ids: ids, account: account)
    }

    /// One or a few emails, light, for a notification.
    func fetchSummary(ids: [String], account: String) async throws -> [Correspondence] {
        isICloud(account) ? try await icloud.fetchSummary(ids: ids, account: account) : isOutlook(account) ? try await outlook.fetchSummary(ids: ids, account: account)
            : try await gmail.fetchMetadata(ids: ids, account: account).items
    }

    func fetchFull(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        isICloud(account) ? try await icloud.fetchFull(ids: ids, account: account) : isOutlook(account) ? try await outlook.fetchFull(ids: ids, account: account) : try await gmail.fetchFull(ids: ids, account: account)
    }

    #if DEBUG
    func exportCorpus(account: String, limit: Int) async throws -> (items: [Correspondence], missing: Int) {
        isICloud(account) ? try await icloud.exportCorpus(account: account, limit: limit) : isOutlook(account) ? try await outlook.exportCorpus(account: account, limit: limit) : try await gmail.exportCorpus(account: account, limit: limit)
    }
    #endif

    func fetchThreadMessages(threadId: String, account: String) async throws -> [Correspondence] {
        isICloud(account) ? try await icloud.fetchThreadMessages(threadId: threadId, account: account) : isOutlook(account) ? try await outlook.fetchThreadMessages(threadId: threadId, account: account)
            : try await gmail.fetchThreadMessages(threadId: threadId, account: account)
    }

    func fetchMessages(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        isICloud(account) ? try await icloud.fetchMessages(ids: ids, account: account) : isOutlook(account) ? try await outlook.fetchMessages(ids: ids, account: account) : try await gmail.fetchMessages(ids: ids, account: account)
    }

    func searchMessages(query: String, account: String) async throws -> [Correspondence] {
        try await searchPage(query: query, account: account, pageToken: nil).items
    }

    /// A page of server search results, and where the next one starts
    /// (nil when there's no more), for "Show More Results".
    func searchPage(query: String, account: String, pageToken: String?) async throws -> (items: [Correspondence], nextPageToken: String?) {
        isICloud(account) ? try await icloud.searchPage(query: query, account: account, pageToken: pageToken)
            : isOutlook(account) ? try await outlook.searchPage(query: query, account: account, pageToken: pageToken)
            : try await gmail.searchPage(query: query, account: account, pageToken: pageToken)
    }

    func sentAddressing(account: String, limit: Int) async throws -> [Addressing] {
        isICloud(account) ? try await icloud.sentAddressing(account: account, limit: limit) : isOutlook(account) ? try await outlook.sentAddressing(account: account, limit: limit) : try await gmail.sentAddressing(account: account, limit: limit)
    }

    func addressing(matching name: String, account: String) async throws -> [Addressing] {
        isICloud(account) ? try await icloud.addressing(matching: name, account: account) : isOutlook(account) ? try await outlook.addressing(matching: name, account: account) : try await gmail.addressing(matching: name, account: account)
    }

    func findMessage(rfc822MessageID: String, account: String) async throws -> ThreadID? {
        isICloud(account) ? try await icloud.findMessage(rfc822MessageID: rfc822MessageID, account: account) : isOutlook(account) ? try await outlook.findMessage(rfc822MessageID: rfc822MessageID, account: account)
            : try await gmail.findMessage(rfc822MessageID: rfc822MessageID, account: account)
    }

    /// Retry tapped on a send whose server never said whether it took it
    /// (SMTP): you've chosen to send it again. Gmail and Outlook keep their
    /// sent copy, so asking them is answer enough (a large Outlook send
    /// still waits for Graph to settle an earlier try, `sendLarge`).
    func allowSendingAgain(rfc822MessageID: String, account: String) {
        if isICloud(account) { icloud.allowSendingAgain(rfc822MessageID: rfc822MessageID, account: account) }
    }

    /// The server may have taken this email without saying so (SMTP), so
    /// sending it again could send it twice.
    func mayHaveSent(rfc822MessageID: String, account: String) -> Bool {
        isICloud(account) && icloud.mayHaveSent(rfc822MessageID: rfc822MessageID, account: account)
    }

    @discardableResult
    func send(raw: String, threadId: String?, account: String) async throws -> String {
        isICloud(account) ? try await icloud.send(raw: raw, threadId: threadId, account: account) : isOutlook(account) ? try await outlook.send(raw: raw, threadId: threadId, account: account)
            : try await gmail.send(raw: raw, threadId: threadId, account: account)
    }

    /// Sends an email, built by `compose` with or without its attachments:
    /// Outlook takes big attachments separately (`OutlookClient.sendLarge`).
    @discardableResult
    func send(attachments: [PendingAttachment], threadId: String?, account: String,
              compose: @Sendable (_ withAttachments: Bool) -> String) async throws -> String {
        if isOutlook(account), attachments.reduce(0, { $0 + $1.data.count }) >= OutlookClient.singleRequestLimit {
            return try await outlook.sendLarge(rawWithout: compose(false), attachments: attachments, threadId: threadId, account: account)
        }
        return try await send(raw: compose(true), threadId: threadId, account: account)
    }

    /// Saves a draft, the same way.
    func saveDraft(attachments: [PendingAttachment], threadId: String?, existingID: String?, account: String,
                   compose: @Sendable (_ withAttachments: Bool) -> String) async throws -> String {
        if isOutlook(account), attachments.reduce(0, { $0 + $1.data.count }) >= OutlookClient.singleRequestLimit {
            return try await outlook.draftWithAttachments(rawWithout: compose(false), attachments: attachments, existingID: existingID, account: account)
        }
        return try await saveDraft(raw: compose(true), threadId: threadId, existingID: existingID, account: account)
    }

    func modifyThread(threadId: String, addLabelIds: [String] = [], removeLabelIds: [String] = [], account: String) async throws {
        if isICloud(account) {
            try await icloud.modifyThread(threadId: threadId, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds, account: account)
        } else if isOutlook(account) {
            try await outlook.modifyThread(threadId: threadId, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds, account: account)
        } else {
            try await gmail.modifyThread(threadId: threadId, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds, account: account)
        }
    }

    func trashThread(threadId: String, account: String) async throws {
        isICloud(account) ? try await icloud.trashThread(threadId: threadId, account: account) : isOutlook(account) ? try await outlook.trashThread(threadId: threadId, account: account) : try await gmail.trashThread(threadId: threadId, account: account)
    }

    /// Whether a change can go to some of a conversation's messages
    /// (`modifyMessages`, `trashMessages`): Gmail's.
    func changesSingleMessages(account: String) -> Bool { !isICloud(account) && !isOutlook(account) }

    func modifyMessages(ids: [String], addLabelIds: [String], removeLabelIds: [String], account: String) async throws {
        try await gmail.modifyMessages(ids: ids, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds, account: account)
    }

    func trashMessages(ids: [String], account: String) async throws {
        try await gmail.trashMessages(ids: ids, account: account)
    }

    func untrashThread(threadId: String, account: String) async throws {
        isICloud(account) ? try await icloud.untrashThread(threadId: threadId, account: account) : isOutlook(account) ? try await outlook.untrashThread(threadId: threadId, account: account) : try await gmail.untrashThread(threadId: threadId, account: account)
    }

    func sendAs(account: String) async throws -> [SendAs] {
        isICloud(account) ? try await icloud.sendAs(account: account) : isOutlook(account) ? try await outlook.sendAs(account: account) : try await gmail.sendAs(account: account)
    }

    func vacation(account: String) async throws -> Vacation {
        isICloud(account) ? try await icloud.vacation(account: account) : isOutlook(account) ? try await outlook.vacation(account: account) : try await gmail.vacation(account: account)
    }

    func setVacation(_ vacation: Vacation, account: String) async throws {
        isICloud(account) ? try await icloud.setVacation(vacation, account: account) : isOutlook(account) ? try await outlook.setVacation(vacation, account: account) : try await gmail.setVacation(vacation, account: account)
    }

    func saveDraft(raw: String, threadId: String?, existingID: String?, account: String) async throws -> String {
        isICloud(account) ? try await icloud.saveDraft(raw: raw, threadId: threadId, existingID: existingID, account: account) : isOutlook(account) ? try await outlook.saveDraft(raw: raw, threadId: threadId, existingID: existingID, account: account)
            : try await gmail.saveDraft(raw: raw, threadId: threadId, existingID: existingID, account: account)
    }

    func deleteDraft(id: String, account: String) async throws {
        isICloud(account) ? try await icloud.deleteDraft(id: id, account: account) : isOutlook(account) ? try await outlook.deleteDraft(id: id, account: account) : try await gmail.deleteDraft(id: id, account: account)
    }

    func listMailbox(labelId: String?, account: String, pageToken: String?, pageSize: Int = 25) async throws -> (items: [Correspondence], nextPageToken: String?) {
        isICloud(account) ? try await icloud.listMailbox(labelId: labelId, account: account, pageToken: pageToken, pageSize: pageSize) : isOutlook(account) ? try await outlook.listMailbox(labelId: labelId, account: account, pageToken: pageToken, pageSize: pageSize)
            : try await gmail.listMailbox(labelId: labelId, account: account, pageToken: pageToken, pageSize: pageSize)
    }

    func listDrafts(account: String, pageToken: String?, pageSize: Int = 25) async throws -> (items: [(draftID: String, message: Correspondence)], nextPageToken: String?) {
        isICloud(account) ? try await icloud.listDrafts(account: account, pageToken: pageToken, pageSize: pageSize) : isOutlook(account) ? try await outlook.listDrafts(account: account, pageToken: pageToken, pageSize: pageSize)
            : try await gmail.listDrafts(account: account, pageToken: pageToken, pageSize: pageSize)
    }

    func watch(topicName: String, account: String) async throws -> String? {
        isICloud(account) ? try await icloud.watch(topicName: topicName, account: account) : isOutlook(account) ? try await outlook.watch(topicName: topicName, account: account) : try await gmail.watch(topicName: topicName, account: account)
    }

    func stopWatching(account: String) async throws {
        isICloud(account) ? try await icloud.stopWatching(account: account) : isOutlook(account) ? try await outlook.stopWatching(account: account) : try await gmail.stopWatching(account: account)
    }

    func fetchUserLabels(account: String) async throws -> [GmailUserLabel] {
        isICloud(account) ? try await icloud.fetchUserLabels(account: account) : isOutlook(account) ? try await outlook.fetchUserLabels(account: account) : try await gmail.fetchUserLabels(account: account)
    }

    func fetchAttachmentData(messageId: String, attachmentId: String, account: String) async throws -> Data {
        isICloud(account) ? try await icloud.fetchAttachmentData(messageId: messageId, attachmentId: attachmentId, account: account) : isOutlook(account) ? try await outlook.fetchAttachmentData(messageId: messageId, attachmentId: attachmentId, account: account)
            : try await gmail.fetchAttachmentData(messageId: messageId, attachmentId: attachmentId, account: account)
    }
}
