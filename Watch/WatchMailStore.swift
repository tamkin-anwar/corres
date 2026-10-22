import Foundation
import Observation
import WatchConnectivity

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
        if ProcessInfo.processInfo.arguments.contains("-SampleSnapshot") { snapshot = Self.sample }
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
        self.snapshot = snapshot
        done = []
        if let data = WatchLink.encode(snapshot) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
    }

    /// Straight to the iPhone when it's near; otherwise queued until it is.
    func send(_ command: WatchLink.Command) {
        switch command {
        case .handled, .archive: done.insert(command.key)
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
}
