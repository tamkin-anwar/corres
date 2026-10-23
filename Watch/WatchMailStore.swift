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
    /// Done on the wrist, gone from the list before the iPhone confirms.
    private(set) var done: Set<String> = []
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
    static let sample = WatchLink.Snapshot(
        needsYou: [
            WatchLink.Mail(key: "s|1", sender: "Maya Chen", subject: "The next chapter", reason: "Asks you to approve the direction",
                           preview: "Hello,\n\nYour approval on the final direction is the last piece. Everything you need is here.\n\nWarmly,\nMaya",
                           receivedAt: .now.addingTimeInterval(-3600), isUnread: true),
            WatchLink.Mail(key: "s|2", sender: "Sofia Laurent", subject: "A place at the table", reason: "Asks you to confirm Thursday",
                           preview: "Could you confirm Thursday's conversation?", receivedAt: .now.addingTimeInterval(-7200), isUnread: false),
        ],
        waiting: [
            WatchLink.Mail(key: "s|3", sender: "James Okafor", subject: "Partnership proposal", reason: "",
                           preview: "I will send the revised scope once our team has reviewed it.", receivedAt: .now.addingTimeInterval(-86_400), isUnread: false),
        ],
        isSample: true, updatedAt: .now)
    #endif

    var needsYou: [WatchLink.Mail] { snapshot.needsYou.filter { !done.contains($0.key) } }
    var waiting: [WatchLink.Mail] { snapshot.waiting.filter { !done.contains($0.key) } }
    var hasHeardFromPhone: Bool { snapshot.updatedAt != .distantPast }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func apply(_ snapshot: WatchLink.Snapshot) {
        // A watch-face update and the regular one can carry the same list.
        guard snapshot.updatedAt >= self.snapshot.updatedAt || !hasHeardFromPhone else { return }
        self.snapshot = snapshot
        done = []
        if let data = WatchLink.encode(snapshot) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
        updateFace()
    }

    /// The watch face, drawn again only when what it shows changed.
    private func updateFace() {
        let face = WatchFace(needsYou: needsYou.count, waiting: waiting.count,
                             firstSender: needsYou.first.map { WatchFace.firstName($0.sender) }, updatedAt: snapshot.updatedAt)
        if face.save() { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Straight to the iPhone when it's near; otherwise queued until it is.
    func send(_ command: WatchLink.Command) {
        switch command {
        case .handled, .archive:
            done.insert(command.key)
            updateFace()
        case .markRead, .reply: break
        }
        guard let data = WatchLink.encode(command) else { return }
        let session = WCSession.default
        if session.activationState == .activated, session.isReachable {
            session.sendMessage([WatchLink.commandKey: data], replyHandler: nil) { _ in
                session.transferUserInfo([WatchLink.commandKey: data])
            }
        } else {
            session.transferUserInfo([WatchLink.commandKey: data])
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
