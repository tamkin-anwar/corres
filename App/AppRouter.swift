import Foundation
import Observation

/// Where the app has been asked to go from outside it: a widget, a Siri or
/// Shortcuts action, or a `corres://` link. The shell consumes `pending`
/// and clears it.
@MainActor @Observable
final class AppRouter {
    enum Target: Equatable {
        case destination(Destination)
        case thread(ThreadID)
        case compose
    }

    static let shared = AppRouter()
    var pending: Target?

    /// Returns false for URLs that aren't Corres's (Google sign-in callbacks).
    func open(_ url: URL) -> Bool {
        guard url.scheme == WidgetSnapshot.urlScheme else { return false }
        switch url.host {
        case "thread":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let account = items.first(where: { $0.name == "account" })?.value,
               let id = items.first(where: { $0.name == "id" })?.value, !account.isEmpty {
                pending = .thread(ThreadID(account: account, providerID: id))
            } else {
                pending = .destination(.needsYou)
            }
        case "needs-you": pending = .destination(.needsYou)
        case "waiting": pending = .destination(.waiting)
        case "mail": pending = .destination(.mail)
        case "compose": pending = .compose
        default: pending = .destination(.brief)
        }
        return true
    }
}
