#if os(iOS)
import Foundation
import WatchConnectivity
import os

/// The iPhone's side of Corres for Apple Watch (see `WatchLink`): sends
/// Needs You and Waiting whenever they change, and carries out what you
/// choose on your wrist: Handled, Archive, Mark as Read, or a reply, sent
/// from this iPhone the way every email from Corres is.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()
    private var lastSent: WatchLink.Snapshot?
    /// What the watch face last showed, so its daily budget of wake-ups
    /// is spent only when the count or the first sender changes.
    private var lastFace: (count: Int, first: String?, locked: Bool)?
    private var pendingUpdate: Task<Void, Never>?
    private static let log = Logger(subsystem: "studio.anwarcreative.corres", category: "watch")

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private var isWatchReady: Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else {
            Self.log.debug("Watch not ready: activated \(WCSession.default.activationState == .activated), paired \(WCSession.default.isPaired), installed \(WCSession.default.isWatchAppInstalled)")
            return false
        }
        return true
    }

    /// After the mail changes; a burst of changes sends once.
    func scheduleUpdate(_ threads: @escaping @MainActor () -> [Correspondence]) {
        guard isWatchReady else { return }
        pendingUpdate?.cancel()
        pendingUpdate = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            send(Self.snapshot(from: threads(), locked: WidgetBridge.isLocked))
        }
    }

    /// Straight away, for a push or background refresh: woken in the
    /// background, Corres could be stopped before a delayed update ran.
    /// Sends even unchanged mail once the last send is an hour old.
    func update(from threads: [Correspondence]) {
        guard isWatchReady else { return }
        pendingUpdate?.cancel()
        send(Self.snapshot(from: threads, locked: WidgetBridge.isLocked))
    }

    /// Unchanged mail is sent again after this long, so the Watch and its
    /// face know the iPhone is still in touch and don't show "Updated 3 hr.
    /// ago" over a Needs You that is simply quiet. Through the app's context
    /// only, never the face's daily budget.
    static let resendAfter: TimeInterval = 3600

    private func send(_ snapshot: WatchLink.Snapshot) {
        let changed = snapshot.needsYou != lastSent?.needsYou || snapshot.waiting != lastSent?.waiting
            || snapshot.needsYouCount != lastSent?.needsYouCount || snapshot.waitingCount != lastSent?.waitingCount
            || snapshot.isLocked != lastSent?.isLocked
        let isOld = lastSent.map { snapshot.updatedAt.timeIntervalSince($0.updatedAt) > Self.resendAfter } ?? true
        guard changed || isOld, let data = WatchLink.encode(snapshot) else { return }
        do {
            try WCSession.default.updateApplicationContext([WatchLink.snapshotKey: data])
            lastSent = snapshot
            Self.log.info("Sent the Watch \(snapshot.needsYou.count) in Needs You")
            updateFace(snapshot, data: data)
        } catch {
            // Not reachable yet; the next change tries again.
            Self.log.error("Couldn't update the Watch: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }

    /// With Corres on the watch face, a change there goes straight away,
    /// waking the Watch app (Apple allows about 50 a day).
    private func updateFace(_ snapshot: WatchLink.Snapshot, data: Data) {
        let session = WCSession.default
        // The lock too: free with nothing in Needs You looked unchanged, so
        // the face kept its last answer until the Watch app next ran.
        let face = (count: snapshot.needsYouCount ?? snapshot.needsYou.count, first: snapshot.needsYou.first?.sender,
                    locked: snapshot.isLocked == true)
        guard session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0,
              lastFace.map({ $0.count != face.count || $0.first != face.first || $0.locked != face.locked }) ?? true else { return }
        session.transferCurrentComplicationUserInfo([WatchLink.snapshotKey: data])
        lastFace = face
        Self.log.info("Sent the watch face \(face.count)")
    }

    /// `locked`: free, or Pro has lapsed, with a real account connected
    /// (the widgets' rule, `WidgetBridge.locks`). Sample mail still shows.
    static func snapshot(from threads: [Correspondence], locked: Bool = false, now: Date = .now) -> WatchLink.Snapshot {
        let isSample = threads.allSatisfy { $0.id.account == "sample" }
        if locked && !isSample {
            return WatchLink.Snapshot(needsYou: [], waiting: [], isSample: false, updatedAt: now,
                                      needsYouCount: 0, waitingCount: 0, isLocked: true)
        }
        func mail(_ thread: Correspondence) -> WatchLink.Mail {
            let words = WritingStyle.ownWords(in: thread.body.isEmpty ? thread.excerpt : thread.body)
            return WatchLink.Mail(key: thread.id.entityKey, sender: thread.isFromAccountOwner ? thread.counterpartName() : thread.sender,
                                  subject: thread.subject, reason: thread.displayReason,
                                  preview: String(words.prefix(600)), receivedAt: thread.receivedAt, isUnread: thread.isUnread)
        }
        let allNeedsYou = MailQuery.prioritized(threads, attention: .needsYou)
        let allWaiting = MailQuery.prioritized(threads, attention: .waiting)
        return WatchLink.Snapshot(needsYou: allNeedsYou.prefix(25).map(mail), waiting: allWaiting.prefix(10).map(mail),
                                  isSample: isSample, updatedAt: now,
                                  needsYouCount: allNeedsYou.count, waitingCount: allWaiting.count)
    }

    /// What the Watch asked for.
    func perform(_ command: WatchLink.Command) async {
        let parts = command.key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let store = Organizer.shared.store, let actions = Organizer.shared.actions else { return }
        // Delivered as Corres launches: mail and accounts first, or the
        // command (and a reply's text) would be dropped.
        if store.state != .loaded { await store.load() }
        await Organizer.shared.outbox?.waitForAccounts()
        let id = ThreadID(account: parts[0], providerID: parts[1])
        // Archived or moved since the Watch last heard: still known here.
        guard let thread = store.thread(id) ?? store.threadsIncludingHidden.first(where: { $0.id == id }) else {
            // Gone altogether: a reply's words are kept as a draft, in Drafts
            // and on the undo pill, to finish and address here.
            if case .reply(_, let text) = command, id.account != "sample", let outbox = Organizer.shared.outbox {
                var draft = Draft(kind: .new, fromAccount: id.account, to: "",
                                  subject: String(localized: "Reply from your Apple Watch"))
                draft.body = Draft.adding(signature: CorresSettings.signature(for: id.account, reply: true), to: text)
                outbox.shelve(draft, replyingTo: nil)
            }
            return
        }
        switch command {
        case .handled:
            await actions.setAttention(.handled, for: thread)
        case .archive:
            await actions.archive(thread, animated: false)
            await actions.commitPendingRemoval()
        case .markRead:
            await actions.setUnread(false, for: thread)
        case .reply(_, let text):
            guard let outbox = Organizer.shared.outbox, thread.id.account != "sample" else { return }
            // A few seconds at most, as from a notification: woken in the
            // background, Corres could be stopped before the reply was saved.
            if !thread.isBodyLoaded { _ = await waitBriefly(for: Task { await actions.loadContent(for: thread) }, upTo: .seconds(8)) }
            let source = store.thread(thread.id) ?? thread
            var draft = source.draft(kind: .reply)
            draft.body = Draft.adding(signature: CorresSettings.signature(for: source.id.account, reply: true), to: text + draft.body)
            // From the address it was sent to, as a reply from a notification goes.
            if let address = SendAsDirectory.shared.address(for: source.id.account, answering: source), !address.isPrimary {
                draft.fromAddress = address.email
                draft.fromName = address.name.isEmpty ? nil : address.name
            }
            await outbox.sendNow(draft, replyingTo: source)
        }
        // Locked as before: this used to send the whole of Needs You to a
        // free user's Watch after any action there.
        send(Self.snapshot(from: store.threads, locked: WidgetBridge.isLocked))
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let store = Organizer.shared.store { self.send(Self.snapshot(from: store.threads, locked: WidgetBridge.isLocked)) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Corres was just put on the Watch, or a Watch was paired.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastSent = nil
            if let store = Organizer.shared.store { self.send(Self.snapshot(from: store.threads, locked: WidgetBridge.isLocked)) }
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switched to another Watch: talk to that one.
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let command = WatchLink.decode(WatchLink.Command.self, from: message[WatchLink.commandKey] as? Data)
        // Received; the Watch has already shown it done.
        replyHandler(["received": command != nil])
        Task { @MainActor in
            if let command { await self.perform(command) }
        }
    }

    /// Sent without asking for a reply (as the Watch does).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let command = WatchLink.decode(WatchLink.Command.self, from: message[WatchLink.commandKey] as? Data)
        Task { @MainActor in
            if let command { await self.perform(command) }
        }
    }

    /// Queued while the iPhone was out of reach.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let command = WatchLink.decode(WatchLink.Command.self, from: userInfo[WatchLink.commandKey] as? Data)
        Task { @MainActor in
            if let command { await self.perform(command) }
        }
    }
}
#endif
