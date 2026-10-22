import Foundation
import os

/// What you decide in Corres, on every device signed in to your iCloud:
/// conversations you moved yourself (Needs You, Waiting, Handled), snoozed
/// or pinned; senders you allowed or blocked; and your settings, VIPs and
/// lessons. Your mail itself never goes here (Gmail, Outlook and iCloud
/// Mail stay the record); this is only Corres's own state, in your
/// private iCloud key-value store, where no one else can read it.
///
/// Last change wins. Kept well under iCloud's 1 MB: each value stays near
/// 60 KB (larger ones have been seen to stop syncing), and marks older
/// than three months drop off.
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
        CorresSettings.screenNewSendersKey, CorresSettings.followUpDaysKey, CorresSettings.morningHourKey,
        CorresSettings.laterTodayEveningKey, CorresSettings.readingBarKey, CorresSettings.undoSendKey,
        CorresSettings.defaultReplyKey, CorresSettings.remoteImagesKey, CorresSettings.confirmTrashKey,
        CorresSettings.markReadOnOpenKey, CorresSettings.openLinksKey, CorresSettings.summariesKey,
        CorresSettings.keyDetailsKey, CorresSettings.previewLinesKey, CorresSettings.tabsAtBottomKey, CorresSettings.tabsPinnedKey, CorresSettings.showAvatarsKey,
        CorresSettings.badgeKey, "corres.lessons", "corres.signatures",
        "corres.trailingShortSwipeAction", "corres.trailingLongSwipeAction",
        "corres.leadingShortSwipeAction", "corres.leadingLongSwipeAction",
        Organizer.rulesKey, Organizer.templatesKey, Organizer.searchesKey, Organizer.mutedKey,
    ]

    private let cloud = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private(set) var marks: [String: Mark] = [:]
    private(set) var decisions: [String: Decision] = [:]
    /// While a change from another device is being applied here, so it
    /// isn't recorded again as a change of this device's own.
    private(set) var isApplying = false
    private weak var store: MailStore?
    private static let log = Logger(subsystem: "studio.anwarcreative.corres", category: "cloud")
    private static let markChunk = 600
    private static let keepFor: TimeInterval = 90 * 86_400

    func start(store: MailStore) {
        self.store = store
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: cloud, queue: .main) { _ in
            Task { @MainActor in await CloudSync.shared.pull() }
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

    func recordDecision(_ decision: SenderDecision, sender: String, account: String) {
        guard !isApplying, account != "sample" else { return }
        decisions[sender.lowercased()] = Decision(decision: decision.rawValue, account: account, at: .now)
        save("decisions", decisions)
    }

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
        var changed = false
        for key in Self.syncedSettings {
            let local = defaults.object(forKey: key)
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
        defer { isApplying = false }
        for key in Self.syncedSettings {
            guard let remote = cloud.object(forKey: "setting." + key),
                  !Self.same(remote, defaults.object(forKey: key)) else { continue }
            defaults.set(remote, forKey: key)
        }
        CorresSettings.applyToCore()
        let remoteMarks: [String: Mark] = loadMarks()
        for (key, mark) in remoteMarks where (marks[key]?.at ?? .distantPast) < mark.at { marks[key] = mark }
        if let remote: [String: Decision] = load("decisions") {
            for (sender, decision) in remote where (decisions[sender]?.at ?? .distantPast) < decision.at { decisions[sender] = decision }
        }
        await apply()
    }

    /// Brings the conversations and senders here in line with the marks.
    func apply() async {
        guard let store else { return }
        isApplying = true
        defer { isApplying = false }
        var changed = 0
        for thread in store.threadsIncludingHidden {
            guard let mark = marks[Self.key(thread.id)] else { continue }
            if let raw = mark.attention, let attention = Attention(rawValue: raw), thread.attention != attention,
               mark.messageID == nil || mark.messageID == thread.latestMessageID {
                await store.update(thread.id, to: attention); changed += 1
            }
            if let pinned = mark.pinned, thread.isPinned != pinned {
                await store.setPinned(pinned, for: thread.id); changed += 1
            }
            if let until = mark.snoozedUntil, thread.snoozedUntil != until, until > .now {
                await store.snooze(thread.id, until: until); changed += 1
            } else if mark.snoozeCleared == true, thread.snoozedUntil != nil {
                await store.snooze(thread.id, until: nil); changed += 1
            }
        }
        let pendingBySender = Dictionary(grouping: store.threadsIncludingHidden.compactMap { thread in
            thread.senderEmail.map { ($0.lowercased(), thread.senderDecision) }
        }, by: \.0)
        for (sender, decision) in decisions {
            guard let wanted = SenderDecision(rawValue: decision.decision),
                  let current = pendingBySender[sender]?.first?.1, current != wanted else { continue }
            await store.approveOrBlock(wanted, sender: sender, account: decision.account); changed += 1
        }
        if changed > 0 { Self.log.info("Applied \(changed) changes from your other devices") }
    }

    // MARK: Storage

    private static func key(_ id: ThreadID) -> String { "\(id.account)|\(id.providerID)" }

    private func saveMarks() {
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
