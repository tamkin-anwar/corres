import Foundation
import Observation
import WatchConnectivity
import WidgetKit

/// The Watch's copy of what the iPhone sent (see `WatchLink`), kept for
/// when the iPhone is out of reach, and the way back to it.
@MainActor @Observable
final class WatchMailStore: NSObject {
    static let shared = WatchMailStore()

    private(set) var snapshot: WatchLink.Snapshot
    /// Done on the wrist, gone from the list before the iPhone confirms:
    /// kept until a snapshot no longer has it, or for ten minutes, so one
    /// the iPhone made before it heard doesn't bring it back.
    private(set) var done: [String: Date] = [:]
    private static let doneLimit: TimeInterval = 10 * 60
    private static let savedKey = "corres.watchSnapshot"

    override init() {
        snapshot = WatchLink.decode(WatchLink.Snapshot.self, from: UserDefaults.standard.data(forKey: Self.savedKey)) ?? .empty
        super.init()
        #if DEBUG
        // Screenshots and checks without an iPhone nearby.
        if ProcessInfo.processInfo.arguments.contains("-SampleSnapshot") {
            snapshot = Self.sample
            updateFace()
        }
        #endif
    }

    #if DEBUG
    /// The same people as the iPhone's sample mail, at fixed times this
    /// morning, so screenshots read the same on every run.
    static let sample: WatchLink.Snapshot = {
        let morning = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: .now) ?? .now
        func ago(_ minutes: Double) -> Date { morning.addingTimeInterval(-minutes * 60) }
        return WatchLink.Snapshot(
            needsYou: [
                WatchLink.Mail(key: "s|1", sender: "Maya Chen", subject: "The next chapter", reason: "Asks you to approve the direction",
                               preview: "Hello,\n\nYour approval on the final direction is the last piece. Everything you need is here.\n\nWarmly,\nMaya",
                               receivedAt: ago(12), isUnread: true),
                WatchLink.Mail(key: "s|2", sender: "Oliver Grant", subject: "A moment before we move forward", reason: "Waiting for your choice",
                               preview: "Two options for the launch. One decision to make.", receivedAt: ago(38), isUnread: true),
                WatchLink.Mail(key: "s|3", sender: "Sofia Laurent", subject: "A place at the table", reason: "Asks you to confirm Thursday",
                               preview: "Could you confirm Thursday's conversation?", receivedAt: ago(64), isUnread: false),
            ],
            waiting: [
                WatchLink.Mail(key: "s|4", sender: "James Okafor", subject: "Partnership proposal", reason: "",
                               preview: "I will send the revised scope once our team has reviewed it.", receivedAt: ago(140), isUnread: false),
            ],
            isSample: true, updatedAt: .now)
    }()

    /// `-WatchScreen detail` or `-WatchScreen reply`: opens the first email,
    /// or its reply, for screenshots.
    static var screenshotScreen: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-WatchScreen"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    #endif

    var needsYou: [WatchLink.Mail] { snapshot.needsYou.filter { done[$0.key] == nil } }
    var waiting: [WatchLink.Mail] { snapshot.waiting.filter { done[$0.key] == nil } }
    var hasHeardFromPhone: Bool { snapshot.updatedAt != .distantPast }

    /// Not heard from the iPhone for a few hours (`WatchFace.staleAfter`).
    func isStale(at date: Date) -> Bool {
        hasHeardFromPhone && date.timeIntervalSince(snapshot.updatedAt) > WatchFace.staleAfter
    }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func apply(_ snapshot: WatchLink.Snapshot) {
        // A watch-face update and the regular one can carry the same list.
        // Only a newer one: the same one again would bring back what was
        // just handled here.
        guard snapshot.updatedAt > self.snapshot.updatedAt || !hasHeardFromPhone else { return }
        self.snapshot = snapshot
        let listed = Set((snapshot.needsYou + snapshot.waiting).map(\.key))
        done = done.filter { key, at in listed.contains(key) && Date.now.timeIntervalSince(at) < Self.doneLimit }
        if let data = WatchLink.encode(snapshot) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
        updateFace()
    }

    /// The watch face, drawn again only when what it shows changed.
    private func updateFace() {
        // The lists stop at 25 and 10; the counts are the whole of each,
        // less what was handled here since.
        let handledNeedsYou = snapshot.needsYou.count - needsYou.count
        let handledWaiting = snapshot.waiting.count - waiting.count
        let face = WatchFace(needsYou: max(0, (snapshot.needsYouCount ?? snapshot.needsYou.count) - handledNeedsYou),
                             waiting: max(0, (snapshot.waitingCount ?? snapshot.waiting.count) - handledWaiting),
                             firstSender: needsYou.first.map { WatchFace.firstName($0.sender) }, updatedAt: snapshot.updatedAt)
        if face.save() { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Straight to the iPhone when it's near; otherwise queued until it is.
    /// False when it was only queued, so a reply doesn't claim it went.
    @discardableResult
    func send(_ command: WatchLink.Command) -> Bool {
        switch command {
        case .handled, .archive:
            done[command.key] = .now
            updateFace()
        case .markRead, .reply: break
        }
        guard let data = WatchLink.encode(command) else { return false }
        let session = WCSession.default
        if session.activationState == .activated, session.isReachable {
            session.sendMessage([WatchLink.commandKey: data], replyHandler: nil) { _ in
                session.transferUserInfo([WatchLink.commandKey: data])
            }
            return true
        } else {
            session.transferUserInfo([WatchLink.commandKey: data])
            return false
        }
    }
}

extension WatchMailStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext[WatchLink.snapshotKey] as? Data
        guard let snapshot = WatchLink.decode(WatchLink.Snapshot.self, from: context) else { return }
        Task { @MainActor in self.apply(snapshot) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = WatchLink.decode(WatchLink.Snapshot.self, from: applicationContext[WatchLink.snapshotKey] as? Data) else { return }
        Task { @MainActor in self.apply(snapshot) }
    }

    /// Sent for the watch face: wakes Corres on the Watch even when it's
    /// closed, so the count is right when you raise your wrist.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let snapshot = WatchLink.decode(WatchLink.Snapshot.self, from: userInfo[WatchLink.snapshotKey] as? Data) else { return }
        Task { @MainActor in self.apply(snapshot) }
    }
}
