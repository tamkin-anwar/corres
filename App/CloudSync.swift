import Foundation
import os

/// What you decide in Corres, on every device signed in to your iCloud:
/// conversations you moved yourself (Needs You, Waiting, Handled), snoozed
/// or pinned; senders you allowed or blocked; and your settings, VIPs and
/// lessons. Your mail itself never goes here (Gmail, Outlook and iCloud
/// Mail stay the record); this is only Corres's own state, in your
/// private iCloud key-value store, where no one else can read it.
///
/// Marks and sender decisions merge one by one, the newest of each
/// winning; rules, templates and saved searches merge item by item, with
/// a note of what was deleted so it isn't brought back. Other settings:
/// the last change wins. Kept well under iCloud's 1 MB: each value stays
/// near 60 KB (larger ones have been seen to stop syncing), and marks
/// older than three months drop off.
@MainActor
final class CloudSync {
    static let shared = CloudSync()

    /// One conversation's own state, as you last set it. Absent fields
    /// weren't set here.
    struct Mark: Codable, Equatable {
        var attention: String?
        /// The message the move was made on: a new reply puts the
        /// conversation back in play, and an old move mustn't hide it.
        var messageID: String?
        var snoozedUntil: Date?
        var snoozeCleared: Bool?
        var pinned: Bool?
        var at: Date
    }

    struct Decision: Codable, Equatable {
        var decision: String
        var account: String
        var at: Date
    }

    /// Settings that follow you between devices. Per-device things (which
    /// accounts are signed in, notification permission, the badge's last
    /// seen time) stay put.
    static let syncedSettings: [String] = [
        CorresSettings.vipsKey, CorresSettings.domainRulesKey, CorresSettings.sensitivityKey,
        CorresSettings.screenNewSendersKey, CorresSettings.newSenderModeKey, CorresSettings.followUpDaysKey, CorresSettings.morningHourKey,
        CorresSettings.laterTodayEveningKey, CorresSettings.readingBarKey,
        CorresSettings.rowMenuTopKey, CorresSettings.rowMenuListKey, CorresSettings.undoSendKey,
        CorresSettings.defaultReplyKey, CorresSettings.remoteImagesKey, CorresSettings.confirmTrashKey,
        CorresSettings.markReadOnOpenKey, CorresSettings.openLinksKey, CorresSettings.summariesKey,
        CorresSettings.keyDetailsKey, CorresSettings.previewLinesKey, CorresSettings.tabsAtBottomKey, CorresSettings.tabsPinnedKey, CorresSettings.showAvatarsKey,
        CorresSettings.badgeKey, CorresSettings.briefKey, "corres.lessons", "corres.signatures",
        "corres.trailingShortSwipeAction", "corres.trailingLongSwipeAction",
        "corres.leadingShortSwipeAction", "corres.leadingLongSwipeAction",
        Organizer.rulesKey, Organizer.templatesKey, Organizer.searchesKey, Organizer.mutedKey,
        removedItemsKey, addedItemsKey, ServerRules.madeKey,
    ]

    /// Lists of things with an `id`, merged item by item: a rule added on
    /// your iPad while it was offline isn't lost to one added on your
    /// iPhone meanwhile.
    static let mergedLists: Set<String> = [Organizer.rulesKey, Organizer.templatesKey, Organizer.searchesKey]
    /// Ids of items deleted from those lists, and when, so a merge doesn't
    /// bring one back from a device that still had it.
    nonisolated static let removedItemsKey = "corres.removedItems"

    /// When a VIP was added, so one removed and added back isn't left out
    /// by the earlier removal.
    nonisolated static let addedItemsKey = "corres.addedItems"

    /// Called when a rule, template or saved search is deleted.
    nonisolated static func noteRemoved(_ id: UUID) { note(id.uuidString, in: removedItemsKey) }
    /// A VIP or a muted conversation taken off (`vipToken`, `mutedToken`).
    nonisolated static func noteRemoved(_ token: String) { note(token, in: removedItemsKey) }
    nonisolated static func noteAdded(_ token: String) { note(token, in: addedItemsKey) }
    nonisolated static func vipToken(_ email: String) -> String { "vip:" + email.lowercased() }
    nonisolated static func mutedToken(_ key: String) -> String { "muted:" + key }

    nonisolated private static func note(_ token: String, in key: String) {
        var notes = UserDefaults.standard.dictionary(forKey: key) as? [String: Date] ?? [:]
        notes[token] = .now
        UserDefaults.standard.set(notes.filter { $0.value > .now.addingTimeInterval(-keepFor) }, forKey: key)
    }

    private let cloud = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private(set) var marks: [String: Mark] = [:]
    private(set) var decisions: [String: Decision] = [:]
    /// While settings from another device are being applied here, so they
    /// aren't recorded again as a change of this device's own.
    private(set) var isApplying = false
    private weak var store: MailStore?
    private static let log = Logger(subsystem: "studio.anwarcreative.corres", category: "cloud")
    private static let markChunk = 600
    nonisolated private static let keepFor: TimeInterval = 90 * 86_400
    /// Until iCloud has delivered what your other devices saved, marks
    /// aren't written: a new device would otherwise replace them all with
    /// its own one or two.
    private var hasRemote = false
    private var marksWaiting = false

    func start(store: MailStore) {
        #if DEBUG
        // Screenshot and test runs: nothing from sample mail reaches iCloud.
        if ProcessInfo.processInfo.arguments.contains("-SampleMailOnly") { return }
        #endif
        self.store = store
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: cloud, queue: .main) { _ in
            Task { @MainActor in
                CloudSync.shared.remoteArrived()
                await CloudSync.shared.pull()
            }
        }
        // Already synced on an earlier launch: what's here is what iCloud
        // had. A first launch waits for iCloud, or a minute (offline).
        if cloud.object(forKey: "marks.0") != nil || cloud.object(forKey: "decisions") != nil { hasRemote = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            CloudSync.shared.remoteArrived()
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in CloudSync.shared.pushSettings() }
        }
        cloud.synchronize()
        Task { await pull() }
    }

    // MARK: This device's changes

    func recordAttention(_ attention: Attention, for id: ThreadID, messageID: String?) {
        update(id) { mark in
            mark.attention = attention.rawValue
            mark.messageID = messageID
        }
    }

    func recordPinned(_ pinned: Bool, for id: ThreadID) {
        update(id) { $0.pinned = pinned }
    }

    func recordSnooze(until: Date?, for id: ThreadID) {
        update(id) { mark in
            mark.snoozedUntil = until
            mark.snoozeCleared = until == nil ? true : nil
        }
    }

    /// Kept by account and sender: one sender allowed in one account and
    /// blocked in another used to share a single entry, the later one
    /// taking over both.
    func recordDecision(_ decision: SenderDecision, sender: String, account: String) {
        guard !isApplying, account != "sample" else { return }
        decisions[SyncMerge.decisionKey(account: account, sender: sender)] = Decision(decision: decision.rawValue, account: account, at: .now)
        for (other, decision) in loadDecisions() where (decisions[other]?.at ?? .distantPast) < decision.at { decisions[other] = decision }
        save("decisions", decisions)
    }

    /// What another device decided is applied here without coming back
    /// through this (`MailStore`'s `recording: false`), so a move you make
    /// here while it's being applied is still recorded as yours.
    private func update(_ id: ThreadID, _ change: (inout Mark) -> Void) {
        guard !isApplying, id.account != "sample" else { return }
        let key = Self.key(id)
        var mark = marks[key] ?? Mark(at: .now)
        change(&mark)
        mark.at = .now
        marks[key] = mark
        saveMarks()
    }

    private func pushSettings() {
        guard !isApplying else { return }
        // Only what's saved on this device: `object(forKey:)` also returns a
        // value given at launch (`-corres.tabsAtBottom YES` in a screenshot
        // run), which would otherwise go to every device.
        let saved = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        var changed = false
        for key in Self.syncedSettings {
            let local = saved[key]
            let remote = cloud.object(forKey: "setting." + key)
            if let local, !Self.same(local, remote) {
                cloud.set(local, forKey: "setting." + key)
                changed = true
            }
        }
        if changed { cloud.synchronize() }
    }

    // MARK: Other devices' changes

    /// Applies what other devices decided, newest wins. Run when iCloud
    /// says something changed, at launch, and after each sync (mail that
    /// just arrived may have a mark waiting for it).
    func pull() async {
        isApplying = true
        var pushBack = false
        // The notes of what was added and removed first, so the lists below
        // merge with them.
        func mergedNotes(_ key: String) -> [String: Date] {
            let local = defaults.dictionary(forKey: key) as? [String: Date] ?? [:]
            let remote = cloud.object(forKey: "setting." + key) as? [String: Date] ?? [:]
            let merged = local.merging(remote) { max($0, $1) }
            if merged != local { defaults.set(merged, forKey: key) }
            if merged != remote { pushBack = true }
            return merged
        }
        let removed = mergedNotes(Self.removedItemsKey)
        let added = mergedNotes(Self.addedItemsKey)
        for key in Self.syncedSettings where key != Self.removedItemsKey && key != Self.addedItemsKey {
            guard let remote = cloud.object(forKey: "setting." + key),
                  !Self.same(remote, defaults.object(forKey: key)) else { continue }
            if Self.mergedLists.contains(key), let remoteData = remote as? Data,
               let merged = SyncMerge.list(local: defaults.data(forKey: key), remote: remoteData, removed: Set(removed.keys)) {
                defaults.set(merged, forKey: key)
                if merged != remoteData { pushBack = true }
            } else if key == ServerRules.madeKey, let remoteIDs = remote as? [String] {
                // Only ever grows: every device's filters together.
                let merged = Set(remoteIDs).union(defaults.stringArray(forKey: key) ?? []).sorted()
                defaults.set(merged, forKey: key)
                if merged != remoteIDs.sorted() { pushBack = true }
            } else if key == CorresSettings.vipsKey, let remoteVIPs = remote as? [String] {
                let merged = SyncMerge.strings(local: defaults.stringArray(forKey: key) ?? [], remote: remoteVIPs,
                                               added: added, removed: removed, token: Self.vipToken)
                defaults.set(merged, forKey: key)
                if merged != remoteVIPs.sorted() { pushBack = true }
            } else if key == Organizer.mutedKey, let remoteData = remote as? Data,
                      let remoteMuted = try? JSONDecoder().decode([String: Date].self, from: remoteData) {
                let localMuted = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
                let merged = SyncMerge.dated(local: localMuted, remote: remoteMuted, removed: removed, token: Self.mutedToken)
                if merged != localMuted { defaults.set(try? JSONEncoder().encode(merged), forKey: key) }
                if merged != remoteMuted { pushBack = true }
            } else {
                defaults.set(remote, forKey: key)
            }
        }
        CorresSettings.applyToCore()
        let remoteMarks: [String: Mark] = loadMarks()
        for (key, mark) in remoteMarks where (marks[key]?.at ?? .distantPast) < mark.at { marks[key] = mark }
        // Newer here than in iCloud (a write that lost a race): sent again.
        let marksNewerHere = marks.contains { key, mark in (remoteMarks[key]?.at ?? .distantPast) < mark.at }
        let remoteDecisions = loadDecisions()
        decisions = Self.accountKeyed(decisions)
        for (sender, decision) in remoteDecisions where (decisions[sender]?.at ?? .distantPast) < decision.at { decisions[sender] = decision }
        let decisionsNewerHere = decisions.contains { sender, decision in (remoteDecisions[sender]?.at ?? .distantPast) < decision.at }
        isApplying = false
        if pushBack { pushSettings() }
        if marksNewerHere { saveMarks() }
        if decisionsNewerHere, hasRemote { save("decisions", decisions) }
        await apply()
    }

    /// Brings the conversations and senders here in line with the marks.
    func apply() async {
        guard let store else { return }
        HangReporter.note("apply iCloud marks")
        var changed = 0
        for thread in store.threadsIncludingHidden {
            guard let mark = marks[Self.key(thread.id)] else { continue }
            if let raw = mark.attention, let attention = Attention(rawValue: raw), thread.attention != attention,
               SyncMerge.moveApplies(madeOn: mark.messageID, latest: thread.latestMessageID) {
                await store.update(thread.id, to: attention, recording: false); changed += 1
            }
            if let pinned = mark.pinned, thread.isPinned != pinned {
                await store.setPinned(pinned, for: thread.id, recording: false); changed += 1
            }
            if let until = mark.snoozedUntil, thread.snoozedUntil != until, until > .now {
                await store.snooze(thread.id, until: until, recording: false); changed += 1
            } else if mark.snoozeCleared == true, thread.snoozedUntil != nil {
                await store.snooze(thread.id, until: nil, recording: false); changed += 1
            }
        }
        // Each sender's mail in the account the decision was made in, with
        // the address as it's stored: Gmail keeps its capitals
        // ("Sara.Lee@Firm.com"), and a decision given the lowercased key
        // matched none of it, so it never took on this device and was
        // tried again, with a full reload, after every sync.
        var byAccountSender: [String: [(email: String, account: String, decision: SenderDecision)]] = [:]
        for thread in store.threadsIncludingHidden {
            guard let email = thread.senderEmail else { continue }
            byAccountSender[thread.id.account.lowercased() + "|" + email.lowercased(), default: []]
                .append((email, thread.id.account, thread.senderDecision))
        }
        for (key, decision) in decisions {
            guard let wanted = SenderDecision(rawValue: decision.decision), let theirs = byAccountSender[key] else { continue }
            var seen = Set<String>()
            for mail in theirs where mail.decision != wanted && seen.insert(mail.email).inserted {
                await store.approveOrBlock(wanted, sender: mail.email, account: mail.account); changed += 1
            }
        }
        if changed > 0 { Self.log.info("Applied \(changed) changes from your other devices") }
    }

    // MARK: Storage

    private static func key(_ id: ThreadID) -> String { "\(id.account)|\(id.providerID)" }

    /// iCloud has delivered (or a minute went by offline): marks held back
    /// meanwhile go now, merged with what's there.
    private func remoteArrived() {
        guard !hasRemote else { return }
        hasRemote = true
        if marksWaiting { saveMarks() }
    }

    /// Merged with what's in iCloud before writing, the newest of each
    /// winning, so this device never writes over another's marks.
    private func saveMarks() {
        guard hasRemote else { marksWaiting = true; return }
        marksWaiting = false
        for (key, mark) in loadMarks() where (marks[key]?.at ?? .distantPast) < mark.at { marks[key] = mark }
        let cutoff = Date.now.addingTimeInterval(-Self.keepFor)
        marks = marks.filter { $0.value.at > cutoff }
        let sorted = marks.sorted { $0.value.at > $1.value.at }
        let chunks = stride(from: 0, to: sorted.count, by: Self.markChunk).map {
            Dictionary(uniqueKeysWithValues: sorted[$0..<min($0 + Self.markChunk, sorted.count)].map { ($0.key, $0.value) })
        }
        for (index, chunk) in chunks.enumerated() { save("marks.\(index)", chunk) }
        // Chunks no longer needed.
        var index = chunks.count
        while cloud.object(forKey: "marks.\(index)") != nil { cloud.removeObject(forKey: "marks.\(index)"); index += 1 }
        cloud.synchronize()
    }

    /// Every device's decisions, older ones (kept by sender alone, and
    /// still written so by an older Corres) moved under their account.
    private func loadDecisions() -> [String: Decision] {
        Self.accountKeyed(load("decisions") ?? [:])
    }

    private static func accountKeyed(_ decisions: [String: Decision]) -> [String: Decision] {
        SyncMerge.accountKeyed(decisions, account: \.account, at: \.at)
    }

    private func loadMarks() -> [String: Mark] {
        var all: [String: Mark] = [:]
        var index = 0
        while let chunk: [String: Mark] = load("marks.\(index)") {
            all.merge(chunk) { $0.at > $1.at ? $0 : $1 }
            index += 1
        }
        return all
    }

    private func save<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        if data.count > 60_000 { Self.log.error("\(key, privacy: .public) is \(data.count) bytes; iCloud may not sync it") }
        cloud.set(data, forKey: key)
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        cloud.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a as NSObject, b as NSObject): a.isEqual(b)
        default: false
        }
    }
}
