import Foundation
import Network
import Observation

/// Whether this device can reach the internet, and the moment it can
/// again: mail is checked straight away and live connections (iCloud's
/// IDLE) are opened afresh, instead of waiting out a back-off. While
/// offline, the regular checks rest rather than piling up failures.
@MainActor @Observable
final class NetworkWatch {
    static let shared = NetworkWatch()

    private(set) var isOnline = true
    @ObservationIgnored var cameBack: (@MainActor () -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in NetworkWatch.shared.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "studio.anwarcreative.corres.network"))
    }

    private func update(_ online: Bool) {
        let wasOnline = isOnline
        isOnline = online
        if online, !wasOnline { cameBack?() }
    }
}
