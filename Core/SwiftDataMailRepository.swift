import Foundation
import SwiftData

/// Local-first persisted storage. Survives relaunch; holds both the fictional
/// sample data and, once connected, real synced Gmail messages side by side
/// (see PersistedCorrespondence). @ModelActor gives this its own
/// actor-isolated ModelContext, the documented safe pattern for using
/// SwiftData under Swift 6 strict concurrency: the container is Sendable and
/// crosses actor boundaries, but the context never does.
@ModelActor
public actor SwiftDataMailRepository: MailRepository {
    public func threads() throws -> [Correspondence] {
        try modelContext.fetch(FetchDescriptor<PersistedCorrespondence>()).map(\.asCorrespondence)
    }

    @discardableResult
    public func setAttention(_ attention: Attention, for id: ThreadID) throws -> Correspondence {
        try mutate(id) { $0.attentionRaw = attention.rawValue }
    }

    @discardableResult
    public func setPinned(_ isPinned: Bool, for id: ThreadID) throws -> Correspondence {
        try mutate(id) { $0.isPinned = isPinned }
    }

    @discardableResult
    public func snooze(_ id: ThreadID, until: Date?) throws -> Correspondence {
        try mutate(id) { $0.snoozedUntil = until }
    }

    @discardableResult
    public func setUnread(_ isUnread: Bool, for id: ThreadID) throws -> Correspondence {
        try mutate(id) { $0.isUnread = isUnread }
    }

    @discardableResult
    public func setLabelIds(_ labelIds: [String], for id: ThreadID) throws -> Correspondence {
        try mutate(id) { $0.labelIds = labelIds }
    }

    /// `SemanticTriageService` snapshots a thread's attention before handing
    /// it to the on-device model, and on-device inference is not
    /// instantaneous — real enough latency that the person can act on that
    /// same thread while it's still thinking (mark it Handled, move it to
    /// Waiting, snooze it). `mutate` re-fetches the model fresh from
    /// SwiftData right here, inside this actor's own serialized access, so
    /// `model.attentionRaw` at this point is the true current state, not
    /// the stale snapshot the model was given; the move only applies if the
    /// thread is *still* sitting exactly where triage found it (`expected`),
    /// never overwriting whatever the person decided in the meantime.
    /// `triagedMessageID` still updates unconditionally, so this message
    /// isn't re-triaged forever just because its result arrived too late.
    @discardableResult
    public func applySemanticTriage(_ id: ThreadID, from expected: Attention, to result: Attention,
                                    reason: String?, messageID: String) throws -> Correspondence {
        try mutate(id) { model in
            if model.attentionRaw == expected.rawValue {
                model.attentionRaw = result.rawValue
                if let reason { model.reason = reason }
            }
            model.triagedMessageID = messageID
        }
    }

    /// Reading a message elsewhere updates `isUnread` but not attention,
    /// the same as opening it in Corres does: read isn't the same as
    /// handled, and Needs You only empties when the person acts.
    @discardableResult
    public func applyRemoteChanges(_ changes: [RemoteMessageChange]) throws -> Int {
        guard !changes.isEmpty else { return 0 }
        var changed = 0
        for change in changes {
            let compositeID = PersistedCorrespondence.compositeID(account: change.threadID.account,
                                                                 providerID: change.threadID.providerID)
            var descriptor = FetchDescriptor<PersistedCorrespondence>(predicate: #Predicate { $0.compositeID == compositeID })
            descriptor.fetchLimit = 1
            guard let model = try modelContext.fetch(descriptor).first,
                  model.latestMessageID == change.messageID else { continue }
            if change.removed {
                modelContext.delete(model)
                changed += 1
            } else if let labels = change.currentLabelIds, labels != model.labelIds {
                model.labelIds = labels
                model.isUnread = labels.contains("UNREAD")
                changed += 1
            }
        }
        if changed > 0 { try modelContext.save() }
        return changed
    }

    /// Only touches threads whose attention is still a pure rule decision:
    /// `.needsYou`/`.quiet` with one of `InboxClassifier.ruleReasons`
    /// (including the old "every unread message" default), never triaged.
    /// A thread the person moved themselves, or that the AI already
    /// refined, has a different attention or reason and is left alone, so
    /// this is safe to re-run whenever the rules improve. Stored previews
    /// are decoded too, since they came from Gmail's HTML-escaped `snippet`.
    @discardableResult
    public func reclassifyLegacySyncDefaults() throws -> Int {
        let models = try modelContext.fetch(FetchDescriptor<PersistedCorrespondence>())
        let correspondents = Self.correspondents(in: models, plus: [])
        var changed = 0
        for model in models {
            let decoded = model.excerpt.decodingHTMLEntities
            if decoded != model.excerpt { model.excerpt = decoded }
            guard model.attentionRaw == Attention.needsYou.rawValue || model.attentionRaw == Attention.quiet.rawValue,
                  InboxClassifier.ruleReasons.contains(model.reason),
                  model.triagedMessageID == nil else { continue }
            let automated = Correspondence.isAutomated(listUnsubscribeMailto: model.listUnsubscribeMailto,
                                                       listUnsubscribeURL: model.listUnsubscribeURL,
                                                       senderEmail: model.senderEmail)
            var (attention, reason) = InboxClassifier.initialAttention(isUnread: model.isUnread,
                                                                      labelIds: model.labelIds,
                                                                      looksAutomated: automated)
            if let senderEmail = model.senderEmail?.lowercased(), senderEmail != model.account.lowercased(),
               let override = InboxClassifier.correspondentOverride(
                   isUnread: model.isUnread,
                   hasListUnsubscribe: model.listUnsubscribeMailto != nil || model.listUnsubscribeURL != nil,
                   isCorrespondent: correspondents.contains(Self.senderKey(account: model.account, senderEmail: senderEmail))) {
                (attention, reason) = override
            }
            if attention.rawValue != model.attentionRaw { changed += 1 }
            model.attentionRaw = attention.rawValue
            model.reason = reason
        }
        try modelContext.save()
        return changed
    }

    public func send(_ draft: Draft, sentAt: Date, realThreadID: ThreadID?) throws -> Correspondence {
        guard let threadID = draft.threadID else {
            let sender = draft.to.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            // realThreadID is the real Gmail account + thread id when
            // OutboxService already sent this via Gmail; falling back to the
            // local "sample" account only when it stayed local-only (no
            // account connected).
            let created = Correspondence(
                id: realThreadID ?? ThreadID(account: Self.localAccount, providerID: UUID().uuidString),
                sender: sender, organization: "", subject: subject,
                excerpt: draft.body, body: draft.body, receivedAt: sentAt, dueAt: nil,
                reason: "You started this conversation. Waiting for a response.",
                attention: .waiting)
            modelContext.insert(PersistedCorrespondence(from: created))
            try modelContext.save()
            return created
        }
        let model = try fetchOne(threadID)
        model.attentionRaw = Attention.waiting.rawValue
        model.snoozedUntil = nil
        let verb = draft.kind == .forward ? "forwarded this" : "replied"
        model.reason = "You \(verb) just now. Waiting for their response."
        try modelContext.save()
        return model.asCorrespondence
    }

    public func remove(_ id: ThreadID) throws {
        let model = try fetchOne(id)
        modelContext.delete(model)
        try modelContext.save()
    }

    public func seedIfNeeded(now: Date) throws {
        guard try modelContext.fetchCount(FetchDescriptor<PersistedCorrespondence>()) == 0 else { return }
        insertSampleData(now: now)
        try modelContext.save()
    }

    public func resetToSampleData(now: Date) throws {
        try modelContext.delete(model: PersistedCorrespondence.self)
        insertSampleData(now: now)
        try modelContext.save()
    }

    public func deleteSampleData() throws {
        let account = Self.localAccount
        let descriptor = FetchDescriptor<PersistedCorrespondence>(predicate: #Predicate { $0.account == account })
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return }
        for model in matches { modelContext.delete(model) }
        try modelContext.save()
    }

    @discardableResult
    public func upsert(_ incoming: [Correspondence], isInitialSync: Bool) throws -> Int {
        let existingModels = try modelContext.fetch(FetchDescriptor<PersistedCorrespondence>())
        var existingByCompositeID = Dictionary(uniqueKeysWithValues: existingModels.map { ($0.compositeID, $0) })
        var knownSenderDecisions = Self.senderDecisions(in: existingModels)
        let knownImageTrust = Self.imageTrust(in: existingModels)
        let knownUnsubscribed = Self.unsubscribed(in: existingModels)
        let correspondents = Self.correspondents(in: existingModels, plus: incoming)
        var inserted = 0
        var changed = false
        for var item in incoming {
            if let senderEmail = item.senderEmail?.lowercased(), senderEmail != item.id.account.lowercased(),
               let override = InboxClassifier.correspondentOverride(
                   isUnread: item.isUnread,
                   hasListUnsubscribe: item.listUnsubscribeMailto != nil || item.listUnsubscribeURL != nil,
                   isCorrespondent: correspondents.contains(Self.senderKey(account: item.id.account, senderEmail: senderEmail))) {
                item.attention = override.attention
                item.reason = override.reason
            }
            let compositeID = PersistedCorrespondence.compositeID(account: item.id.account, providerID: item.id.providerID)
            if let existing = existingByCompositeID[compositeID] {
                // Same thread already known. Only a genuinely new message
                // (a real reply, or the first real sync of a message a local
                // placeholder was only guessing at) should touch it; a mere
                // re-fetch of the same message (same latestMessageID) is a
                // no-op, and `receivedAt` breaks ties when this very batch
                // contains more than one new message for the same thread
                // (e.g. our own sent copy and the recipient's reply both
                // showed up since the last sync), so the thread always ends
                // up reflecting whichever message is actually newest
                // regardless of fetch order.
                guard let incomingMessageID = item.latestMessageID, incomingMessageID != existing.latestMessageID,
                      item.receivedAt >= existing.receivedAt else { continue }
                let isFromAccountOwner = item.senderEmail != nil && item.senderEmail == item.id.account
                existing.sender = item.sender
                existing.senderEmail = item.senderEmail
                existing.organization = item.organization
                existing.subject = item.subject
                existing.excerpt = item.excerpt
                existing.body = item.body
                existing.htmlBody = item.htmlBody
                existing.messageIdHeader = item.messageIdHeader
                existing.latestMessageID = incomingMessageID
                existing.receivedAt = item.receivedAt
                existing.attachmentsData = (try? JSONEncoder().encode(item.attachments)) ?? Data()
                // Per-message, like attachments: whatever the latest
                // message actually offers, not frozen from an earlier one.
                existing.listUnsubscribeMailto = item.listUnsubscribeMailto
                existing.listUnsubscribeURL = item.listUnsubscribeURL
                existing.listUnsubscribeOneClick = item.listUnsubscribeOneClick
                existing.toRecipients = item.toRecipients
                existing.ccRecipients = item.ccRecipients
                // A genuinely new message means whatever triage ran against
                // the old one no longer applies; nil signals "needs triage
                // again" to SemanticTriageService, the same as a brand-new
                // thread. `item.triagedMessageID` is always already nil here
                // (only local triage itself ever sets it, never a
                // freshly-mapped Gmail item), so this is really just making
                // that explicit for this hand-rolled update path, which
                // doesn't go through `Correspondence.updatingContent`
                // (where the same reset already happens implicitly).
                existing.triagedMessageID = nil
                // Labels reflect genuine Gmail mailbox-organization state,
                // not a triage decision Corres invented (unlike
                // attention/reason below): always take the freshest known
                // value, regardless of which side sent the triggering message.
                existing.labelIds = item.labelIds
                if !isFromAccountOwner {
                    // A genuine inbound message: its own unread state should
                    // drive attention/reason/isUnread, same as any new
                    // thread. Our own sent copy showing back up must never
                    // downgrade a thread still legitimately Waiting on a
                    // reply, nor silently mark it read.
                    existing.reason = item.reason
                    existing.attentionRaw = item.attention.rawValue
                    existing.isUnread = item.isUnread
                }
                changed = true
                continue
            }
            if let senderEmail = item.senderEmail {
                let key = Self.senderKey(account: item.id.account, senderEmail: senderEmail)
                if let known = knownSenderDecisions[key] {
                    item.senderDecision = known
                } else {
                    item.senderDecision = isInitialSync ? .approved : .pending
                    knownSenderDecisions[key] = item.senderDecision
                }
                if knownImageTrust[key] == true { item.imagesTrusted = true }
                if knownUnsubscribed[key] == true { item.senderUnsubscribed = true }
            }
            let model = PersistedCorrespondence(from: item)
            modelContext.insert(model)
            existingByCompositeID[compositeID] = model
            inserted += 1
            changed = true
        }
        if changed { try modelContext.save() }
        return inserted
    }

    public func setSenderDecision(_ decision: SenderDecision, forSenderEmail senderEmail: String, account: String) throws {
        let descriptor = FetchDescriptor<PersistedCorrespondence>(
            predicate: #Predicate { $0.account == account && $0.senderEmail == senderEmail })
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return }
        for model in matches { model.senderDecisionRaw = decision.rawValue }
        try modelContext.save()
    }

    public func trustSenderImages(forSenderEmail senderEmail: String, account: String) throws {
        let descriptor = FetchDescriptor<PersistedCorrespondence>(
            predicate: #Predicate { $0.account == account && $0.senderEmail == senderEmail })
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return }
        for model in matches { model.imagesTrusted = true }
        try modelContext.save()
    }

    public func markSenderUnsubscribed(forSenderEmail senderEmail: String, account: String) throws {
        let descriptor = FetchDescriptor<PersistedCorrespondence>(
            predicate: #Predicate { $0.account == account && $0.senderEmail == senderEmail })
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return }
        for model in matches { model.senderUnsubscribed = true }
        try modelContext.save()
    }

    public func outboxEntries() throws -> [OutboxRecord] {
        try modelContext.fetch(FetchDescriptor<PersistedOutboxEntry>()).compactMap(\.asRecord)
    }

    public func saveOutboxEntry(_ entry: OutboxRecord) throws {
        var descriptor = FetchDescriptor<PersistedOutboxEntry>(predicate: #Predicate { $0.id == entry.id })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.statusRaw = entry.status.rawValue
        } else {
            modelContext.insert(PersistedOutboxEntry(from: entry))
        }
        try modelContext.save()
    }

    public func removeOutboxEntry(id: UUID) throws {
        var descriptor = FetchDescriptor<PersistedOutboxEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let existing = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    private static func senderKey(account: String, senderEmail: String) -> String { "\(account)|\(senderEmail)" }

    private static func senderDecisions(in models: [PersistedCorrespondence]) -> [String: SenderDecision] {
        var map: [String: SenderDecision] = [:]
        for model in models {
            guard let senderEmail = model.senderEmail else { continue }
            map[senderKey(account: model.account, senderEmail: senderEmail)] = SenderDecision(rawValue: model.senderDecisionRaw) ?? .approved
        }
        return map
    }

    private static func imageTrust(in models: [PersistedCorrespondence]) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for model in models {
            guard let senderEmail = model.senderEmail, model.imagesTrusted else { continue }
            map[senderKey(account: model.account, senderEmail: senderEmail)] = true
        }
        return map
    }

    /// Everyone this account has written to, keyed like `senderKey` (with
    /// the address lowercased), from threads whose latest message is the
    /// account owner's own, plus any of the owner's messages in the batch
    /// being synced. Only a thread's latest message is stored, so a
    /// conversation where the other person replied last no longer
    /// contributes on its own — but it's computed *before* that reply is
    /// applied, which is exactly the moment it matters. A known limitation,
    /// not a full correspondent history.
    private static func correspondents(in models: [PersistedCorrespondence], plus incoming: [Correspondence]) -> Set<String> {
        var keys = Set<String>()
        for model in models where model.senderEmail?.lowercased() == model.account.lowercased() {
            for recipient in model.toRecipients + model.ccRecipients {
                keys.insert(senderKey(account: model.account, senderEmail: recipient.lowercased()))
            }
        }
        for item in incoming where item.senderEmail?.lowercased() == item.id.account.lowercased() {
            for recipient in item.toRecipients + item.ccRecipients {
                keys.insert(senderKey(account: item.id.account, senderEmail: recipient.lowercased()))
            }
        }
        return keys
    }

    private static func unsubscribed(in models: [PersistedCorrespondence]) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for model in models {
            guard let senderEmail = model.senderEmail, model.senderUnsubscribed else { continue }
            map[senderKey(account: model.account, senderEmail: senderEmail)] = true
        }
        return map
    }

    private func insertSampleData(now: Date) {
        for item in SampleCorrespondence.make(now: now) {
            modelContext.insert(PersistedCorrespondence(from: item))
        }
    }

    @discardableResult
    private func mutate(_ id: ThreadID, _ change: (PersistedCorrespondence) -> Void) throws -> Correspondence {
        let model = try fetchOne(id)
        change(model)
        try modelContext.save()
        return model.asCorrespondence
    }

    private func fetchOne(_ id: ThreadID) throws -> PersistedCorrespondence {
        let compositeID = PersistedCorrespondence.compositeID(account: id.account, providerID: id.providerID)
        var descriptor = FetchDescriptor<PersistedCorrespondence>(
            predicate: #Predicate { $0.compositeID == compositeID })
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.threadNotFound
        }
        return model
    }

    private static let localAccount = "sample"
}
