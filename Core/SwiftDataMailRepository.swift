import Foundation
import SwiftData

/// Local-first persisted storage. Survives relaunch; holds both the fictional
/// sample data and, once connected, real synced Gmail messages side by side
/// (see PersistedCorrespondence). An actor with its own ModelContext, the
/// safe pattern for SwiftData under Swift 6 strict concurrency: the
/// container is Sendable and crosses actor boundaries, but the context
/// never does.
///
/// Runs on its own serial queue rather than `@ModelActor`'s default
/// executor, which ran each call on the calling thread: every read and
/// write the main-actor store asked for (a pin, a sync's saves, reloading
/// the whole mailbox after each batch) ran on the main thread, measured
/// at 50–150ms a call on a 2,000-conversation inbox, right in the middle
/// of swipes and scrolling.
public actor SwiftDataMailRepository: MailRepository {
    private let modelContext: ModelContext
    private let queue = DispatchSerialQueue(label: "studio.anwarcreative.corres.mailstore", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(modelContainer: ModelContainer) {
        modelContext = ModelContext(modelContainer)
    }

    /// Every conversation, without its HTML: see `listProperties`.
    /// Leaves `changes()` as it is: sync reads everything for its own
    /// checks, and the store must still hear what changed.
    public func threads() throws -> [Correspondence] {
        try modelContext.fetch(PersistedCorrespondence.summaries(withText: true)).map(\.asListCorrespondence)
    }

    /// The newest conversations, for the first screen at launch; the rest
    /// follow with `threads()`.
    public func recentThreads(limit: Int) throws -> [Correspondence] {
        var descriptor = PersistedCorrespondence.summaries(withText: true)
        descriptor.sortBy = [SortDescriptor(\.receivedAt, order: .reverse)]
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.asListCorrespondence)
    }

    public func threads(account: String, receivedFrom start: Date, to end: Date) throws -> [Correspondence] {
        var descriptor = PersistedCorrespondence.summaries(withText: true)
        descriptor.predicate = #Predicate { $0.account == account && $0.receivedAt >= start && $0.receivedAt <= end }
        return try modelContext.fetch(descriptor).map(\.asListCorrespondence)
    }

    public func threadsAwaitingContent(limit: Int) throws -> [Correspondence] {
        var descriptor = PersistedCorrespondence.summaries(withText: true)
        descriptor.predicate = #Predicate { !$0.isBodyLoaded && $0.latestMessageID != nil && $0.account != "sample" }
        descriptor.sortBy = [SortDescriptor(\.receivedAt, order: .reverse)]
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.asListCorrespondence)
    }

    public func threadsWithoutMessageID(account: String) throws -> [Correspondence] {
        var descriptor = PersistedCorrespondence.summaries(withText: true)
        descriptor.predicate = #Predicate { $0.account == account && $0.latestMessageID == nil }
        return try modelContext.fetch(descriptor).map(\.asListCorrespondence)
    }

    public func storedIDs() throws -> Set<String> {
        var descriptor = FetchDescriptor<PersistedCorrespondence>()
        descriptor.propertiesToFetch = [\.compositeID]
        return Set(try modelContext.fetch(descriptor).map(\.compositeID))
    }

    // MARK: Senders

    /// What's known about each sender across every conversation: their
    /// Screener answer, trusted images, unsubscribes, and everyone you've
    /// written to. Read from all conversations once, then kept up to date
    /// as conversations are saved (`save()`): reading every conversation
    /// on each sync took most of a second even on a Mac.
    struct SenderFacts {
        var decisions: [String: SenderDecision] = [:]
        var imageTrust: Set<String> = []
        var unsubscribed: Set<String> = []
        var correspondents: Set<String> = []

        mutating func learn(from model: PersistedCorrespondence) {
            guard let senderEmail = model.senderEmail else { return }
            let key = SwiftDataMailRepository.senderKey(account: model.account, senderEmail: senderEmail)
            decisions[key] = SenderDecision(rawValue: model.senderDecisionRaw) ?? .approved
            if model.imagesTrusted { imageTrust.insert(key) }
            if model.senderUnsubscribed { unsubscribed.insert(key) }
            if senderEmail.lowercased() == model.account.lowercased() {
                for recipient in model.toRecipients + model.ccRecipients {
                    correspondents.insert(SwiftDataMailRepository.senderKey(account: model.account, senderEmail: recipient.lowercased()))
                }
            }
        }
    }

    private var cachedSenderFacts: SenderFacts?

    private func senderFacts() throws -> SenderFacts {
        if let cachedSenderFacts { return cachedSenderFacts }
        var facts = SenderFacts()
        for model in try modelContext.fetch(PersistedCorrespondence.senderFacts()) { facts.learn(from: model) }
        cachedSenderFacts = facts
        return facts
    }

    // MARK: Changes

    /// Conversations written since the store last read the mail. Reading
    /// all 5,000 again after each sync or tap took seconds on a phone;
    /// the store asks for these instead (`changes()`).
    private var changedIDs = Set<String>()
    private var removedIDs = Set<ThreadID>()
    /// Set when what changed isn't known: the next `changes()` says to
    /// read everything.
    private var needsFullRead = false

    private func save() throws {
        for case let model as PersistedCorrespondence in modelContext.insertedModelsArray + modelContext.changedModelsArray {
            changedIDs.insert(model.compositeID)
            cachedSenderFacts?.learn(from: model)
        }
        for case let model as PersistedCorrespondence in modelContext.deletedModelsArray {
            removedIDs.insert(ThreadID(account: model.account, providerID: model.providerID))
        }
        try modelContext.save()
    }

    public func changes() throws -> StoredChanges? {
        let ids = Array(changedIDs), gone = removedIDs
        changedIDs = []
        removedIDs = []
        if needsFullRead {
            needsFullRead = false
            return nil
        }
        guard !ids.isEmpty else { return StoredChanges(updated: [], removed: Array(gone)) }
        var updated: [Correspondence] = []
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            var descriptor = PersistedCorrespondence.summaries(withText: true)
            descriptor.predicate = #Predicate { chunk.contains($0.compositeID) }
            updated += try modelContext.fetch(descriptor).map(\.asListCorrespondence)
        }
        let present = Set(updated.map(\.id))
        return StoredChanges(updated: updated, removed: gone.filter { !present.contains($0) })
    }

    public func thread(_ id: ThreadID) throws -> Correspondence? {
        let compositeID = PersistedCorrespondence.compositeID(account: id.account, providerID: id.providerID)
        var descriptor = FetchDescriptor<PersistedCorrespondence>(predicate: #Predicate { $0.compositeID == compositeID })
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return nil }
        var thread = model.asListCorrespondence
        thread.htmlBody = try content(compositeID)?.html ?? model.htmlBody
        return thread
    }

    // MARK: Message content

    private func content(_ compositeID: String) throws -> PersistedMessageContent? {
        var descriptor = FetchDescriptor<PersistedMessageContent>(predicate: #Predicate { $0.compositeID == compositeID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Keeps a message's HTML apart from its conversation (see
    /// `PersistedMessageContent`), with what the lists need to know about
    /// it saved on the conversation itself. Set the text (`body`) first.
    private func setContent(_ html: String?, on model: PersistedCorrespondence) throws {
        if model.htmlBody != nil { model.htmlBody = nil }
        model.htmlImageOnly = html.map { Correspondence.isRemoteImageOnly(body: model.body, html: $0) } ?? false
        if let existing = try content(model.compositeID) {
            existing.html = html
        } else if html != nil {
            modelContext.insert(PersistedMessageContent(compositeID: model.compositeID, html: html))
        }
    }

    /// Moves HTML saved inside conversations, before it was kept apart, a
    /// batch at a time. Returns how many moved: 0 once there's none left.
    public func moveContent(batch: Int) throws -> Int {
        var descriptor = FetchDescriptor<PersistedCorrespondence>(predicate: #Predicate { $0.htmlBody != nil })
        descriptor.fetchLimit = batch
        let models = try modelContext.fetch(descriptor)
        for model in models { try setContent(model.htmlBody, on: model) }
        if !models.isEmpty { try save() }
        return models.count
    }

    @discardableResult
    public func setAttention(_ attention: Attention, for id: ThreadID) throws -> Correspondence {
        try mutate(id) { model in
            // Moving something into Waiting starts its clock now; moving it
            // anywhere else stops it.
            if attention == .waiting, model.attentionRaw != Attention.waiting.rawValue { model.waitingSince = .now }
            if attention != .waiting { model.waitingSince = nil }
            model.attentionRaw = attention.rawValue
        }
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
                if let reason {
                    model.reason = reason
                } else if result != expected {
                    // Moved without a reason of its own: never keep one
                    // that says the opposite ("Kept out of Needs You.").
                    model.reason = result == .needsYou ? InboxClassifier.promotedReason : InboxClassifier.demotedReason
                }
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
        // Every conversation named, in a few fetches instead of one per
        // change: an iCloud pass can report hundreds at once.
        let compositeIDs = Array(Set(changes.filter { !$0.threadID.providerID.isEmpty }.map {
            PersistedCorrespondence.compositeID(account: $0.threadID.account, providerID: $0.threadID.providerID)
        }))
        var byID: [String: PersistedCorrespondence] = [:]
        for start in stride(from: 0, to: compositeIDs.count, by: 500) {
            let chunk = Array(compositeIDs[start..<min(start + 500, compositeIDs.count)])
            let models = try modelContext.fetch(FetchDescriptor<PersistedCorrespondence>(predicate: #Predicate { chunk.contains($0.compositeID) }))
            for model in models where byID[model.compositeID] == nil { byID[model.compositeID] = model }
        }
        var changed = 0
        for change in changes {
            let found: PersistedCorrespondence?
            if change.threadID.providerID.isEmpty {
                // Known only by the message: Outlook reports a removal
                // with nothing but the message's id. Rare, so one fetch each.
                let account = change.threadID.account
                let messageID: String? = change.messageID
                var descriptor = FetchDescriptor<PersistedCorrespondence>(predicate: #Predicate { $0.account == account && $0.latestMessageID == messageID })
                descriptor.fetchLimit = 1
                found = try modelContext.fetch(descriptor).first
            } else {
                found = byID[PersistedCorrespondence.compositeID(account: change.threadID.account,
                                                                 providerID: change.threadID.providerID)]
            }
            // Removed by an earlier change in this same batch: nothing left to do.
            guard let model = found, !model.isDeleted, model.latestMessageID == change.messageID else { continue }
            if change.removed {
                modelContext.delete(model)
                changed += 1
            } else if let labels = change.currentLabelIds, labels != model.labelIds {
                model.labelIds = labels
                model.isUnread = labels.contains("UNREAD")
                changed += 1
            }
        }
        if changed > 0 { try save() }
        return changed
    }

    @discardableResult
    public func applyLoadedContent(_ items: [Correspondence]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        let correspondents = try senderFacts().correspondents
        var filled = 0
        for item in items {
            let compositeID = PersistedCorrespondence.compositeID(account: item.id.account, providerID: item.id.providerID)
            var descriptor = FetchDescriptor<PersistedCorrespondence>(predicate: #Predicate { $0.compositeID == compositeID })
            descriptor.fetchLimit = 1
            guard let model = try modelContext.fetch(descriptor).first,
                  model.latestMessageID == item.latestMessageID else { continue }
            model.body = item.body
            try setContent(item.htmlBody, on: model)
            if let preview = MailDigest.preview(body: item.body, html: item.htmlBody) { model.excerpt = preview }
            model.attachmentsData = (try? JSONEncoder().encode(item.attachments)) ?? Data()
            model.isBodyLoaded = true
            // Outlook's headers (List-Unsubscribe) come with the full message,
            // not the listing, and with them which of Gmail's categories its
            // "Other" mail belongs to. Gmail's arrive earlier and stay.
            if item.listUnsubscribeMailto != nil || item.listUnsubscribeURL != nil {
                model.listUnsubscribeMailto = item.listUnsubscribeMailto
                model.listUnsubscribeURL = item.listUnsubscribeURL
                model.listUnsubscribeOneClick = item.listUnsubscribeOneClick
                let categories = item.labelIds.filter { $0.hasPrefix("CATEGORY_") }
                if !categories.isEmpty {
                    model.labelIds = model.labelIds.filter { !$0.hasPrefix("CATEGORY_") } + categories
                }
            }
            // The snippet was only the opening; the whole message can hold
            // the question or the deadline.
            Self.applyRules(to: model, correspondents: correspondents, now: .now)
            filled += 1
        }
        if filled > 0 { try save() }
        return filled
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
        // Whole messages: every one goes through the rules, which read the
        // text, and one fetch of everything beats a fetch per conversation.
        let models = try modelContext.fetch(FetchDescriptor<PersistedCorrespondence>())
        let correspondents = Self.correspondents(in: models, plus: [])
        var changed = 0
        for model in models {
            // Promoted into Needs You before promotions always got a
            // matching reason: still saying it was kept out.
            // Promoted into Needs You without a reason that held up (before
            // that stopped): back where the rules put it, still marked as
            // assessed so it isn't promoted the same way again.
            if model.attentionRaw == Attention.needsYou.rawValue, model.triagedMessageID != nil,
               model.reason.hasSuffix("Kept out of Needs You.") || model.reason == InboxClassifier.promotedReason {
                model.attentionRaw = Attention.quiet.rawValue
                // "Kept out of Needs You." is still its own rule's reason.
                if model.reason == InboxClassifier.promotedReason { model.reason = InboxClassifier.BulkKind.updates.reason }
                model.dueAt = nil
                changed += 1
            }
            // An on-device reason that says more than the email does ("fraud
            // alert" for a card-used notice), from before reasons were held
            // to the email's own alarm words: back to the rules, and
            // assessed again.
            if model.triagedMessageID != nil, !InboxClassifier.ruleReasons.contains(model.reason),
               model.reason != InboxClassifier.promotedReason, model.reason != InboxClassifier.demotedReason {
                let source = [model.sender, model.senderEmail ?? "", model.subject, model.excerpt].joined(separator: "\n").lowercased()
                let reason = model.reason.lowercased()
                // "Direct account alert…": the old prompt's own wording, echoed.
                let echoed = reason.hasPrefix("direct ") && !source.contains("direct")
                if echoed || MailDigest.alarmStems.contains(where: { reason.contains($0) && !source.contains($0) }) {
                    model.reason = InboxClassifier.legacyUnreadReason
                    model.triagedMessageID = nil
                    changed += 1
                }
            }
            let decoded = model.excerpt.previewText
            if decoded != model.excerpt { model.excerpt = decoded }
            if model.lastSentAt == nil, model.senderEmail?.lowercased() == model.account.lowercased() {
                model.lastSentAt = model.receivedAt
            }
            if Self.applyRules(to: model, correspondents: correspondents, now: .now) { changed += 1 }
        }
        try save()
        return changed
    }

    /// Re-runs `InboxClassifier` on a thread whose place is still purely a
    /// rule decision (a rule reason, never triaged, never moved by the
    /// person), using everything now known about it. Returns whether its
    /// attention changed. Safe to call whenever the rules improve or a
    /// message's full text arrives.
    @discardableResult
    static func applyRules(to model: PersistedCorrespondence, correspondents: Set<String>, now: Date) -> Bool {
        let movable: Set<String> = [Attention.needsYou.rawValue, Attention.quiet.rawValue, Attention.waiting.rawValue]
        // From another of your own accounts: never Needs You, even if the
        // on-device check thought so. Not if you put it there yourself
        // (that carries no rule reason).
        if model.attentionRaw == Attention.needsYou.rawValue, model.account != "sample",
           InboxClassifier.ruleReasons.contains(model.reason),
           let sender = model.senderEmail?.lowercased(), sender != model.account.lowercased(),
           InboxClassifier.ownAddresses.contains(sender) {
            model.attentionRaw = Attention.quiet.rawValue
            model.reason = InboxClassifier.fromYouReason
            model.dueAt = nil
            return true
        }
        guard movable.contains(model.attentionRaw),
              InboxClassifier.ruleReasons.contains(model.reason),
              model.triagedMessageID == nil,
              model.account != "sample" else { return false }
        // Waiting that the person chose themselves carries no rule reason;
        // only a rule-made Waiting may be re-decided.
        if model.attentionRaw == Attention.waiting.rawValue, model.reason != InboxClassifier.askedReason { return false }
        let text = model.subject + "\n" + (model.body.isEmpty ? model.excerpt : model.body)
        let asks = MailSignals.asksSomething(text)
        let before = model.attentionRaw
        let fromYou = model.senderEmail?.lowercased() == model.account.lowercased()
        var attention: Attention
        var reason: String
        var due: Date?
        if fromYou {
            (attention, reason) = InboxClassifier.afterYouWrote(
                asksSomething: asks,
                toPeople: MailSignals.hasPersonRecipient(model.toRecipients + model.ccRecipients, account: model.account),
                sentAt: model.receivedAt, now: now)
        } else {
            // Relative dates ("by Friday") only mean something for recent mail.
            let recent = now.timeIntervalSince(model.receivedAt) < InboxClassifier.waitingWindow
            let automated = Correspondence.isAutomated(listUnsubscribeMailto: model.listUnsubscribeMailto,
                                                       listUnsubscribeURL: model.listUnsubscribeURL,
                                                       senderEmail: model.senderEmail, senderName: model.sender,
                                                       body: model.isBodyLoaded ? model.body : nil, html: model.htmlBody,
                                                       imageOnly: model.htmlImageOnly)
            let bulk = InboxClassifier.bulkKind(labelIds: model.labelIds, looksAutomated: automated)
            if recent {
                due = bulk?.isPromotable == true ? MailSignals.timeSensitiveDate(in: text, now: now)
                    : bulk == nil ? MailSignals.deadline(in: text, now: now) : nil
            }
            let copied = Correspondence.isCopiedOnly(account: model.account, to: model.toRecipients, cc: model.ccRecipients)
            (attention, reason) = InboxClassifier.initialAttention(
                isUnread: model.isUnread, labelIds: model.labelIds, looksAutomated: automated,
                receivedAt: model.receivedAt, now: now, isCopiedOnly: copied, asksSomething: asks,
                deadline: due, text: text, isVIP: InboxClassifier.isVIP(model.senderEmail))
            if let senderEmail = model.senderEmail?.lowercased(),
               let override = InboxClassifier.correspondentOverride(
                   isUnread: model.isUnread,
                   hasListUnsubscribe: model.listUnsubscribeMailto != nil || model.listUnsubscribeURL != nil,
                   isCorrespondent: correspondents.contains(senderKey(account: model.account, senderEmail: senderEmail)),
                   isStale: InboxClassifier.isStale(receivedAt: model.receivedAt, now: now),
                   isCopiedOnly: copied, currentReason: reason) {
                (attention, reason) = override
            }
            if attention == .needsYou, let senderEmail = model.senderEmail?.lowercased(),
               senderEmail != model.account.lowercased(), InboxClassifier.ownAddresses.contains(senderEmail) {
                (attention, reason) = (.quiet, InboxClassifier.fromYouReason)
            }
        }
        model.attentionRaw = attention.rawValue
        model.reason = reason
        model.dueAt = attention == .needsYou ? due : nil
        if attention == .waiting {
            if model.waitingSince == nil { model.waitingSince = model.receivedAt }
        } else {
            model.waitingSince = nil
        }
        return before != model.attentionRaw
    }

    public func send(_ draft: Draft, sentAt: Date, realThreadID: ThreadID?, sentCopy: Correspondence?) throws -> Correspondence {
        guard let threadID = draft.threadID else {
            // realThreadID is the real Gmail account + thread id when
            // OutboxService already sent this via Gmail; falling back to the
            // local "sample" account only when it stayed local-only (no
            // account connected).
            let (attention, reason) = Self.afterSending(draft, sentAt: sentAt)
            let created = Correspondence.started(
                by: draft, id: realThreadID ?? ThreadID(account: Self.localAccount, providerID: UUID().uuidString),
                sentAt: sentAt, sentCopy: sentCopy, attention: attention, reason: reason)
            let model = PersistedCorrespondence(from: created)
            modelContext.insert(model)
            try setContent(created.htmlBody, on: model)
            try save()
            return created
        }
        let model = try fetchOne(threadID)
        let (attention, reason) = Self.afterSending(draft, sentAt: sentAt)
        model.attentionRaw = attention.rawValue
        model.reason = reason
        model.waitingSince = attention == .waiting ? sentAt : nil
        model.lastSentAt = sentAt
        model.dueAt = nil
        model.snoozedUntil = nil
        try save()
        return model.asCorrespondence
    }

    /// Waiting only if what you sent asks a person for something; a
    /// "Thanks!" or an FYI is simply done.
    private static func afterSending(_ draft: Draft, sentAt: Date) -> (attention: Attention, reason: String) {
        let recipients = (draft.to + "," + (draft.cc ?? "")).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Sample and bare-name recipients have no address to check; treat
        // them as people.
        let toPeople = recipients.isEmpty || MailSignals.hasPersonRecipient(recipients, account: draft.fromAccount ?? "")
        let result = InboxClassifier.afterYouWrote(asksSomething: MailSignals.asksSomething(draft.subject + "\n" + draft.body),
                                                   toPeople: toPeople, sentAt: sentAt, now: sentAt)
        // A new email isn't a reply.
        if draft.kind == .new, result.reason == InboxClassifier.repliedReason {
            return (result.attention, InboxClassifier.startedReason)
        }
        return result
    }

    public func remove(_ id: ThreadID) throws {
        let model = try fetchOne(id)
        if let content = try content(model.compositeID) { modelContext.delete(content) }
        modelContext.delete(model)
        try save()
    }

    public func seedIfNeeded(now: Date) throws {
        guard try modelContext.fetchCount(FetchDescriptor<PersistedCorrespondence>()) == 0 else { return }
        try insertSampleData(now: now)
        try save()
    }

    public func resetToSampleData(now: Date) throws {
        // Deleted all at once, unseen by `save()`: start over.
        cachedSenderFacts = nil
        needsFullRead = true
        try modelContext.delete(model: PersistedCorrespondence.self)
        try modelContext.delete(model: PersistedMessageContent.self)
        try insertSampleData(now: now)
        try save()
    }

    public func deleteSampleData() throws {
        try deleteAccountData(Self.localAccount)
    }

    public func deleteAccountData(_ account: String) throws {
        cachedSenderFacts = nil
        let descriptor = FetchDescriptor<PersistedCorrespondence>(predicate: #Predicate { $0.account == account })
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return }
        let prefix = PersistedCorrespondence.compositeID(account: account, providerID: "")
        try modelContext.delete(model: PersistedMessageContent.self, where: #Predicate { $0.compositeID.starts(with: prefix) })
        for model in matches { modelContext.delete(model) }
        try save()
    }

    @discardableResult
    public func upsert(_ incoming: [Correspondence], isInitialSync: Bool) throws -> Int {
        // What's known about each sender is kept (`senderFacts`); whole
        // conversations are read only for the ones in this batch. Reading
        // every conversation made each sync take seconds on a phone.
        let facts = try senderFacts()
        let incomingIDs = Array(Set(incoming.map { PersistedCorrespondence.compositeID(account: $0.id.account, providerID: $0.id.providerID) }))
        var existingModels: [PersistedCorrespondence] = []
        for start in stride(from: 0, to: incomingIDs.count, by: 500) {
            let chunk = Array(incomingIDs[start..<min(start + 500, incomingIDs.count)])
            existingModels += try modelContext.fetch(FetchDescriptor<PersistedCorrespondence>(predicate: #Predicate { chunk.contains($0.compositeID) }))
        }
        // Never `uniqueKeysWithValues`: it crashes on a duplicate, on every sync.
        var existingByCompositeID = Dictionary(existingModels.map { ($0.compositeID, $0) }, uniquingKeysWith: { first, _ in first })
        var knownSenderDecisions = facts.decisions
        let correspondents = facts.correspondents.union(Self.correspondents(in: [], plus: incoming))
        var inserted = 0
        var changed = false
        for var item in incoming {
            if let senderEmail = item.senderEmail?.lowercased(), senderEmail != item.id.account.lowercased(),
               let override = InboxClassifier.correspondentOverride(
                   isUnread: item.isUnread,
                   hasListUnsubscribe: item.listUnsubscribeMailto != nil || item.listUnsubscribeURL != nil,
                   isCorrespondent: correspondents.contains(Self.senderKey(account: item.id.account, senderEmail: senderEmail)),
                   isStale: InboxClassifier.isStale(receivedAt: item.receivedAt, now: .now),
                   isCopiedOnly: item.isCopiedOnly, currentReason: item.reason) {
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
                // Your own message counts for Sent even when it's older than
                // the reply already shown.
                if let sent = item.lastSentAt, existing.lastSentAt.map({ sent > $0 }) ?? true {
                    existing.lastSentAt = sent
                    changed = true
                }
                // A copy Corres saved itself (no message id yet) always gives
                // way to Gmail's real one. Its time is when Corres saved it,
                // a moment after Gmail's, so comparing times kept the
                // placeholder forever.
                guard let incomingMessageID = item.latestMessageID, incomingMessageID != existing.latestMessageID,
                      item.receivedAt >= existing.receivedAt || existing.latestMessageID == nil else { continue }
                let isFromAccountOwner = item.isFromAccountOwner
                existing.sender = item.sender
                existing.senderEmail = item.senderEmail
                existing.organization = item.organization
                existing.subject = item.subject
                existing.excerpt = item.excerpt
                existing.body = item.body
                try setContent(item.htmlBody, on: existing)
                existing.isBodyLoaded = item.isBodyLoaded
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
                existing.replyTo = item.replyTo
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
                if isFromAccountOwner && existing.attentionRaw == Attention.waiting.rawValue {
                    // Gmail's own record of when you sent it is the truth.
                    existing.waitingSince = item.receivedAt
                } else if isFromAccountOwner {
                    // You wrote in this thread, from Corres or any other app
                    // (Gmail on the web, Apple Mail): your part is done. It
                    // waits on them if you asked something, otherwise it
                    // leaves Needs You.
                    existing.attentionRaw = item.attention.rawValue
                    existing.reason = item.reason
                    existing.dueAt = nil
                    existing.waitingSince = item.attention == .waiting ? item.receivedAt : nil
                }
                if !isFromAccountOwner {
                    // They replied: whatever you were waiting on has arrived.
                    existing.waitingSince = nil
                    // A genuine inbound message: its own unread state should
                    // drive attention/reason/isUnread, same as any new
                    // thread. Our own sent copy showing back up must never
                    // downgrade a thread still legitimately Waiting on a
                    // reply, nor silently mark it read.
                    existing.reason = item.reason
                    existing.attentionRaw = item.attention.rawValue
                    existing.isUnread = item.isUnread
                    existing.dueAt = item.dueAt
                }
                changed = true
                continue
            }
            if let senderEmail = item.senderEmail {
                let key = Self.senderKey(account: item.id.account, senderEmail: senderEmail)
                if let known = knownSenderDecisions[key] {
                    item.senderDecision = known
                } else {
                    // Someone you've written to already has your answer:
                    // you reached out first, so there's nothing to screen.
                    let youWroteFirst = correspondents.contains(key) || item.isFromAccountOwner
                        || InboxClassifier.isVIP(item.senderEmail)
                    item.senderDecision = isInitialSync || youWroteFirst ? .approved
                        : InboxClassifier.domainDecision(for: senderEmail) ?? MailQuery.firstEmailDecision
                    knownSenderDecisions[key] = item.senderDecision
                }
                if facts.imageTrust.contains(key) { item.imagesTrusted = true }
                if facts.unsubscribed.contains(key) { item.senderUnsubscribed = true }
            }
            let model = PersistedCorrespondence(from: item)
            modelContext.insert(model)
            try setContent(item.htmlBody, on: model)
            existingByCompositeID[compositeID] = model
            inserted += 1
            changed = true
        }
        if changed { try save() }
        return inserted
    }

    public func setSenderDecision(_ decision: SenderDecision, forSenderEmail senderEmail: String, account: String) throws {
        let descriptor = FetchDescriptor<PersistedCorrespondence>(
            predicate: #Predicate { $0.account == account && $0.senderEmail == senderEmail })
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return }
        for model in matches { model.senderDecisionRaw = decision.rawValue }
        try save()
    }

    public func trustSenderImages(forSenderEmail senderEmail: String, account: String) throws {
        let descriptor = FetchDescriptor<PersistedCorrespondence>(
            predicate: #Predicate { $0.account == account && $0.senderEmail == senderEmail })
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return }
        for model in matches { model.imagesTrusted = true }
        try save()
    }

    public func markSenderUnsubscribed(forSenderEmail senderEmail: String, account: String) throws {
        let descriptor = FetchDescriptor<PersistedCorrespondence>(
            predicate: #Predicate { $0.account == account && $0.senderEmail == senderEmail })
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return }
        for model in matches { model.senderUnsubscribed = true }
        try save()
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
        try save()
    }

    public func removeOutboxEntry(id: UUID) throws {
        var descriptor = FetchDescriptor<PersistedOutboxEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let existing = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(existing)
        try save()
    }

    static func senderKey(account: String, senderEmail: String) -> String { "\(account)|\(senderEmail)" }

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

    private func insertSampleData(now: Date) throws {
        for item in SampleCorrespondence.make(now: now) {
            let model = PersistedCorrespondence(from: item)
            modelContext.insert(model)
            try setContent(item.htmlBody, on: model)
        }
    }

    @discardableResult
    private func mutate(_ id: ThreadID, _ change: (PersistedCorrespondence) -> Void) throws -> Correspondence {
        let model = try fetchOne(id)
        change(model)
        try save()
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

/// Reads a message's HTML on its own connection to the store, so opening
/// an email never waits behind a sync writing to it
/// (`SwiftDataMailRepository` does one thing at a time). Measured: half a
/// second waiting, for a read that takes a millisecond.
public actor MessageContentReader {
    private let container: ModelContainer
    private let queue = DispatchSerialQueue(label: "studio.anwarcreative.corres.messagereader", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(modelContainer: ModelContainer) {
        container = modelContainer
    }

    /// A fresh context each time, so it never answers from an old copy.
    public func html(for id: ThreadID) -> String? {
        let context = ModelContext(container)
        let compositeID = PersistedCorrespondence.compositeID(account: id.account, providerID: id.providerID)
        var content = FetchDescriptor<PersistedMessageContent>(predicate: #Predicate { $0.compositeID == compositeID })
        content.fetchLimit = 1
        if let html = (try? context.fetch(content))?.first?.html { return html }
        // Saved before HTML was kept apart, and not moved yet.
        var thread = FetchDescriptor<PersistedCorrespondence>(predicate: #Predicate { $0.compositeID == compositeID })
        thread.fetchLimit = 1
        return (try? context.fetch(thread))?.first?.htmlBody
    }
}
