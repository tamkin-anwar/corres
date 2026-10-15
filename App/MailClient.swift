import Foundation

/// The one door to mail: each call goes to Gmail or Outlook by the
/// account's provider (`MailAccounts`), with the same shapes either way,
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

    private func isOutlook(_ account: String) -> Bool { MailAccounts.provider(for: account) == .microsoft }

    func planFullListing(account: String) async throws -> SyncPlan {
        isOutlook(account) ? try await outlook.planFullListing(account: account) : try await gmail.planFullListing(account: account)
    }

    func planIncremental(account: String, since cursor: String) async throws -> SyncPlan {
        isOutlook(account) ? try await outlook.planIncremental(account: account, since: cursor)
            : try await gmail.planIncremental(account: account, since: cursor)
    }

    func listRecentSent(account: String) async throws -> [String] {
        isOutlook(account) ? try await outlook.listRecentSent(account: account) : try await gmail.listRecentSent(account: account)
    }

    func listOlderInbox(account: String, pageToken: String?) async throws -> (ids: [(id: String, threadId: String?)], nextPageToken: String?) {
        isOutlook(account) ? try await outlook.listOlderInbox(account: account, pageToken: pageToken)
            : try await gmail.listOlderInbox(account: account, pageToken: pageToken)
    }

    func fetchMetadata(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        isOutlook(account) ? try await outlook.fetchMetadata(ids: ids, account: account) : try await gmail.fetchMetadata(ids: ids, account: account)
    }

    func fetchFull(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        isOutlook(account) ? try await outlook.fetchFull(ids: ids, account: account) : try await gmail.fetchFull(ids: ids, account: account)
    }

    #if DEBUG
    func exportCorpus(account: String, limit: Int) async throws -> (items: [Correspondence], missing: Int) {
        isOutlook(account) ? try await outlook.exportCorpus(account: account, limit: limit) : try await gmail.exportCorpus(account: account, limit: limit)
    }
    #endif

    func fetchThreadMessages(threadId: String, account: String) async throws -> [Correspondence] {
        isOutlook(account) ? try await outlook.fetchThreadMessages(threadId: threadId, account: account)
            : try await gmail.fetchThreadMessages(threadId: threadId, account: account)
    }

    func fetchMessages(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        isOutlook(account) ? try await outlook.fetchMessages(ids: ids, account: account) : try await gmail.fetchMessages(ids: ids, account: account)
    }

    func searchMessages(query: String, account: String) async throws -> [Correspondence] {
        isOutlook(account) ? try await outlook.searchMessages(query: query, account: account) : try await gmail.searchMessages(query: query, account: account)
    }

    func sentAddressing(account: String, limit: Int) async throws -> [Addressing] {
        isOutlook(account) ? try await outlook.sentAddressing(account: account, limit: limit) : try await gmail.sentAddressing(account: account, limit: limit)
    }

    func addressing(matching name: String, account: String) async throws -> [Addressing] {
        isOutlook(account) ? try await outlook.addressing(matching: name, account: account) : try await gmail.addressing(matching: name, account: account)
    }

    func findMessage(rfc822MessageID: String, account: String) async throws -> ThreadID? {
        isOutlook(account) ? try await outlook.findMessage(rfc822MessageID: rfc822MessageID, account: account)
            : try await gmail.findMessage(rfc822MessageID: rfc822MessageID, account: account)
    }

    @discardableResult
    func send(raw: String, threadId: String?, account: String) async throws -> String {
        isOutlook(account) ? try await outlook.send(raw: raw, threadId: threadId, account: account)
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
        if isOutlook(account) {
            try await outlook.modifyThread(threadId: threadId, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds, account: account)
        } else {
            try await gmail.modifyThread(threadId: threadId, addLabelIds: addLabelIds, removeLabelIds: removeLabelIds, account: account)
        }
    }

    func trashThread(threadId: String, account: String) async throws {
        isOutlook(account) ? try await outlook.trashThread(threadId: threadId, account: account) : try await gmail.trashThread(threadId: threadId, account: account)
    }

    func untrashThread(threadId: String, account: String) async throws {
        isOutlook(account) ? try await outlook.untrashThread(threadId: threadId, account: account) : try await gmail.untrashThread(threadId: threadId, account: account)
    }

    func sendAs(account: String) async throws -> [SendAs] {
        isOutlook(account) ? try await outlook.sendAs(account: account) : try await gmail.sendAs(account: account)
    }

    func vacation(account: String) async throws -> Vacation {
        isOutlook(account) ? try await outlook.vacation(account: account) : try await gmail.vacation(account: account)
    }

    func setVacation(_ vacation: Vacation, account: String) async throws {
        isOutlook(account) ? try await outlook.setVacation(vacation, account: account) : try await gmail.setVacation(vacation, account: account)
    }

    func saveDraft(raw: String, threadId: String?, existingID: String?, account: String) async throws -> String {
        isOutlook(account) ? try await outlook.saveDraft(raw: raw, threadId: threadId, existingID: existingID, account: account)
            : try await gmail.saveDraft(raw: raw, threadId: threadId, existingID: existingID, account: account)
    }

    func deleteDraft(id: String, account: String) async throws {
        isOutlook(account) ? try await outlook.deleteDraft(id: id, account: account) : try await gmail.deleteDraft(id: id, account: account)
    }

    func listMailbox(labelId: String?, account: String, pageToken: String?, pageSize: Int = 25) async throws -> (items: [Correspondence], nextPageToken: String?) {
        isOutlook(account) ? try await outlook.listMailbox(labelId: labelId, account: account, pageToken: pageToken, pageSize: pageSize)
            : try await gmail.listMailbox(labelId: labelId, account: account, pageToken: pageToken, pageSize: pageSize)
    }

    func listDrafts(account: String, pageToken: String?, pageSize: Int = 25) async throws -> (items: [(draftID: String, message: Correspondence)], nextPageToken: String?) {
        isOutlook(account) ? try await outlook.listDrafts(account: account, pageToken: pageToken, pageSize: pageSize)
            : try await gmail.listDrafts(account: account, pageToken: pageToken, pageSize: pageSize)
    }

    func watch(topicName: String, account: String) async throws -> String? {
        isOutlook(account) ? try await outlook.watch(topicName: topicName, account: account) : try await gmail.watch(topicName: topicName, account: account)
    }

    func stopWatching(account: String) async throws {
        isOutlook(account) ? try await outlook.stopWatching(account: account) : try await gmail.stopWatching(account: account)
    }

    func fetchUserLabels(account: String) async throws -> [GmailUserLabel] {
        isOutlook(account) ? try await outlook.fetchUserLabels(account: account) : try await gmail.fetchUserLabels(account: account)
    }

    func fetchAttachmentData(messageId: String, attachmentId: String, account: String) async throws -> Data {
        isOutlook(account) ? try await outlook.fetchAttachmentData(messageId: messageId, attachmentId: attachmentId, account: account)
            : try await gmail.fetchAttachmentData(messageId: messageId, attachmentId: attachmentId, account: account)
    }
}
