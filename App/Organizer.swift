import Foundation
import Observation

/// Your rules, templates, saved searches and muted conversations: kept on
/// this device, followed to your others through iCloud (CloudSync syncs
/// these keys like your settings), and put to work as mail arrives.
///
/// Rules and mute act only on mail that arrives after they're set (and on
/// older mail only when you ask), and only once per message: a change you
/// make yourself afterwards stays made.
@MainActor @Observable
final class Organizer {
    static let shared = Organizer()

    static let rulesKey = "corres.rules"
    static let templatesKey = "corres.templates"
    static let searchesKey = "corres.savedSearches"
    static let mutedKey = "corres.muted"
    /// Per conversation, the newest message already looked at. On this
    /// device only: each device decides for itself what it has seen.
    private static let seenKey = "corres.organized"
    private static let maxSeen = 4_000

    private(set) var rules: [MailRule] = []
    private(set) var templates: [MailTemplate] = []
    private(set) var savedSearches: [SavedSearch] = []
    /// "account|id" → when it was muted.
    private(set) var muted: [String: Date] = [:]
    @ObservationIgnored private var seen: [String: String] = [:]
    /// The app's mail and actions, for Siri and Shortcuts as well.
    @ObservationIgnored private(set) weak var store: MailStore?
    @ObservationIgnored private(set) weak var actions: ThreadActionService?
    /// Sending and Drafts, for an email Siri writes.
    @ObservationIgnored private(set) weak var outbox: OutboxService?
    @ObservationIgnored private var isOrganizing = false

    private init() {
        reload()
        seen = (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: String]) ?? [:]
        // A change from another device lands in UserDefaults (CloudSync).
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Organizer.shared.reloadIfChanged() }
        }
    }

    /// Called once at launch: after each reload of the mail, what's new is
    /// organized.
    func attach(store: MailStore, actions: ThreadActionService, outbox: OutboxService) {
        self.store = store
        self.actions = actions
        self.outbox = outbox
        WidgetHandoff.open = { destination in
            if let url = URL(string: "\(WidgetSnapshot.urlScheme)://\(destination)") { _ = AppRouter.shared.open(url) }
        }
        WidgetHandoff.applyHandled = { Organizer.shared.applyWidgetHandoffs() }
        store.afterRefresh = { [weak self] in
            Task { await self?.organizeNow() }
        }
    }

    /// What a widget or a Control Center button left for the app: a place
    /// to open, and conversations marked Handled.
    func applyWidgetHandoffs() {
        if let route = WidgetHandoff.takePendingRoute(), let url = URL(string: "\(WidgetSnapshot.urlScheme)://\(route)") {
            _ = AppRouter.shared.open(url)
        }
        // Not ready yet (still launching), or already applying: the taps
        // stay where they are for the next call. Each one is removed only
        // once its conversation has moved, so none is lost and none is
        // applied twice.
        guard !isApplyingHandled, let store, let actions else { return }
        let taps = WidgetHandoff.pendingHandled()
        guard !taps.isEmpty else { return }
        isApplyingHandled = true
        Task {
            defer { isApplyingHandled = false }
            // Opened from the widget with Corres closed: the mail isn't read
            // yet, and without it every tap would be dropped.
            if store.state != .loaded { await store.load() }
            guard store.state == .loaded else { return }
            var threads: [Correspondence] = []
            for tap in taps {
                let parts = tap.id.split(separator: "|", maxSplits: 1).map(String.init)
                // A conversation no longer here (deleted or moved on another
                // device) has nothing left to move.
                guard parts.count == 2, let thread = store.thread(ThreadID(account: parts[0], providerID: parts[1])),
                      !threads.contains(where: { $0.id == thread.id }) else { continue }
                threads.append(thread)
            }
            await actions.setAttention(.handled, for: threads)
            WidgetHandoff.finishHandled(taps)
            // Taps made while these were applied.
            if !WidgetHandoff.pendingHandled().isEmpty { Task { applyWidgetHandoffs() } }
        }
    }

    @ObservationIgnored private var isApplyingHandled = false

    private func organizeNow() async {
        guard let store, let actions else { return }
        await organize(store: store, actions: actions)
    }

    // MARK: Stored

    private func reload() {
        rules = Self.decode([MailRule].self, Self.rulesKey) ?? []
        templates = Self.decode([MailTemplate].self, Self.templatesKey) ?? []
        savedSearches = Self.decode([SavedSearch].self, Self.searchesKey) ?? []
        muted = Self.decode([String: Date].self, Self.mutedKey) ?? [:]
    }

    private func reloadIfChanged() {
        let fresh = (Self.decode([MailRule].self, Self.rulesKey) ?? [], Self.decode([MailTemplate].self, Self.templatesKey) ?? [],
                     Self.decode([SavedSearch].self, Self.searchesKey) ?? [], Self.decode([String: Date].self, Self.mutedKey) ?? [:])
        if fresh.0 != rules {
            rules = fresh.0
            ServerRules.shared.schedule()
        }
        if fresh.1 != templates { templates = fresh.1 }
        if fresh.2 != savedSearches { savedSearches = fresh.2 }
        if fresh.3 != muted { muted = fresh.3 }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    // MARK: Rules

    func save(_ rule: MailRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        Self.store(rules, Self.rulesKey)
        ServerRules.shared.schedule()
    }

    func delete(rule id: UUID) {
        CloudSync.noteRemoved(id)
        rules.removeAll { $0.id == id }
        Self.store(rules, Self.rulesKey)
        ServerRules.shared.schedule()
    }

    func moveRules(from: IndexSet, to: Int) {
        rules.move(fromOffsets: from, toOffset: to)
        Self.store(rules, Self.rulesKey)
    }

    /// Runs one rule over the mail already in your lists. Returns how many
    /// conversations it changed.
    @discardableResult
    func applyToExisting(_ rule: MailRule) async -> Int {
        guard rule.isUsable, let store, let actions else { return 0 }
        let matching = store.threads.filter { $0.id.account != "sample" && !$0.isFromAccountOwner && rule.matches($0) }
        var toArchive: [Correspondence] = []
        for thread in matching {
            if await perform(rule, on: thread, store: store, actions: actions) { toArchive.append(thread) }
        }
        actions.archiveQuietly(toArchive)
        return matching.count
    }

    // MARK: Templates

    func save(_ template: MailTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) { templates[index] = template } else { templates.append(template) }
        Self.store(templates, Self.templatesKey)
    }

    func delete(template id: UUID) {
        CloudSync.noteRemoved(id)
        templates.removeAll { $0.id == id }
        Self.store(templates, Self.templatesKey)
    }

    func moveTemplates(from: IndexSet, to: Int) {
        templates.move(fromOffsets: from, toOffset: to)
        Self.store(templates, Self.templatesKey)
    }

    // MARK: Saved searches

    func save(_ search: SavedSearch) {
        if let index = savedSearches.firstIndex(where: { $0.id == search.id }) { savedSearches[index] = search } else { savedSearches.append(search) }
        Self.store(savedSearches, Self.searchesKey)
    }

    func delete(search id: UUID) {
        CloudSync.noteRemoved(id)
        savedSearches.removeAll { $0.id == id }
        Self.store(savedSearches, Self.searchesKey)
    }

    func moveSearches(from: IndexSet, to: Int) {
        savedSearches.move(fromOffsets: from, toOffset: to)
        Self.store(savedSearches, Self.searchesKey)
    }

    func isSaved(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return savedSearches.contains { $0.query.lowercased() == trimmed }
    }

    // MARK: Mute

    private static func key(_ id: ThreadID) -> String { id.account + "|" + id.providerID }

    func isMuted(_ id: ThreadID) -> Bool { muted[Self.key(id)] != nil }

    /// For the notification extension, which knows a conversation only by
    /// its id at the service.
    var mutedProviderIDs: [String] { muted.keys.compactMap { $0.split(separator: "|", maxSplits: 1).last.map(String.init) } }

    /// Out of your lists now, and new replies stay out and silent, as in
    /// Gmail, unless one is written to you alone.
    func mute(_ thread: Correspondence) {
        muted[Self.key(thread.id)] = .now
        if let messageID = thread.latestMessageID { seen[Self.key(thread.id)] = messageID; saveSeen() }
        saveMuted()
        actions?.archiveQuietly([thread])
    }

    func unmute(_ id: ThreadID) {
        CloudSync.noteRemoved(CloudSync.mutedToken(Self.key(id)))
        muted[Self.key(id)] = nil
        saveMuted()
    }

    private func saveMuted() {
        // A year is plenty: a conversation that quiet has stopped.
        let cutoff = Date.now.addingTimeInterval(-365 * 86_400)
        muted = muted.filter { $0.value > cutoff }
        Self.store(muted, Self.mutedKey)
    }

    // MARK: As mail arrives

    /// Looks at what's new since last time: mail in a muted conversation is
    /// archived quietly (or brings it back, if written to you alone), and
    /// each rule that matches does what it says. The first time ever, it
    /// only notes what's already here, so turning Corres on never sweeps
    /// through a whole mailbox.
    func organize(store: MailStore, actions: ThreadActionService) async {
        guard !isOrganizing, store.state == .loaded else { return }
        isOrganizing = true
        defer { isOrganizing = false }
        let threads = store.threads.filter { $0.id.account != "sample" }
        if seen.isEmpty {
            for thread in threads { if let id = thread.latestMessageID { seen[Self.key(thread.id)] = id } }
            saveSeen(keeping: threads)
            return
        }
        let active = rules.filter(\.isUsable)
        var toArchive: [Correspondence] = []
        var changed = false
        for thread in threads {
            let key = Self.key(thread.id)
            guard let messageID = thread.latestMessageID, seen[key] != messageID else { continue }
            seen[key] = messageID
            changed = true
            if thread.isFromAccountOwner { continue }
            if muted[key] != nil {
                if MuteRule.breaksMute(thread, accountAddresses: [thread.id.account.lowercased()]) {
                    unmute(thread.id)
                } else {
                    toArchive.append(thread)
                    continue
                }
            }
            for rule in active where thread.receivedAt >= rule.createdAt.addingTimeInterval(-60) && rule.matches(thread) {
                if await perform(rule, on: thread, store: store, actions: actions) { toArchive.append(thread) }
            }
        }
        if changed { saveSeen(keeping: threads) }
        actions.archiveQuietly(toArchive)
    }

    /// Does what a rule says, except archiving, which the caller does for
    /// everything at once. Returns whether it should be archived.
    private func perform(_ rule: MailRule, on thread: Correspondence, store: MailStore, actions: ThreadActionService) async -> Bool {
        if let attention = rule.attention, thread.attention != attention, let messageID = thread.latestMessageID {
            await store.applySemanticTriage(thread.id, from: thread.attention, to: attention,
                                            reason: InboxClassifier.ruleReason, messageID: messageID)
        }
        if let category = rule.category { await actions.applyCategoryQuietly(category, to: thread) }
        if rule.markRead, thread.isUnread { await actions.setUnread(false, for: thread) }
        if rule.flag, !thread.isFlagged { await actions.setFlagged(true, for: thread) }
        return rule.archive
    }

    /// `current`: the mail the lists hold now. Past the limit, what's
    /// gone from them is forgotten first; what's still here is kept, or
    /// a mailbox bigger than the limit had its excess looked at again as
    /// new on every reload (rules run again, the record saved again),
    /// several times a second through a sync.
    private func saveSeen(keeping current: [Correspondence]? = nil) {
        if seen.count > Self.maxSeen {
            if let current {
                let here = Set(current.map { Self.key($0.id) })
                seen = seen.filter { here.contains($0.key) }
            }
            // Oldest-looking first isn't knowable from a key; dropping any
            // excess only means a long-quiet conversation is looked at once
            // more, which a rule handles the same way.
            let limit = max(Self.maxSeen, current?.count ?? 0)
            if seen.count > limit {
                seen = Dictionary(uniqueKeysWithValues: seen.prefix(limit).map { ($0.key, $0.value) })
            }
        }
        UserDefaults.standard.set(seen, forKey: Self.seenKey)
    }
}
