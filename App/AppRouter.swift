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
        /// A `mailto:` link, tapped inside an email or anywhere on the
        /// iPhone once Corres is the default mail app.
        case composeTo(to: String, subject: String, body: String)
    }

    static let shared = AppRouter()
    var pending: Target?
    /// The row a list should bring back into view when you return to it
    /// from a conversation: the one you were reading, or, if it was just
    /// archived, its neighbour, so you land where you left off instead of
    /// at the top.
    var returnAnchor: ThreadID?
    /// A list is in Select mode: the shell clears its toolbar for it.
    var isSelecting = false

    /// Returns false for URLs that aren't Corres's (Google sign-in callbacks).
    func open(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "mailto" {
            pending = Self.compose(mailto: url)
            return true
        }
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
        case "ask": pending = .destination(.ask)
        default: pending = .destination(.needsYou)
        }
        return true
    }

    /// A new message from a `mailto:` link: the addresses in the link and
    /// any `to=` field, plus its subject and body.
    static func compose(mailto url: URL) -> Target {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        let to = [components?.path ?? "", query["to"] ?? ""].filter { !$0.isEmpty }.joined(separator: ",")
        return .composeTo(to: to, subject: query["subject"] ?? "", body: query["body"] ?? "")
    }
}

/// The places Corres can open to: from a widget, Siri, a notification
/// or a link.
enum Destination: String, CaseIterable, Identifiable {
    case brief = "Brief", needsYou = "Needs You", waiting = "Waiting", mail = "Mail", ask = "Ask"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brief: String(localized: "Brief")
        case .needsYou: String(localized: "Needs You")
        case .waiting: String(localized: "Waiting")
        case .mail: String(localized: "Mail")
        case .ask: String(localized: "Ask")
        }
    }
    /// SF Symbols: vector, weight-matched to the tab label, and rendered by
    /// the system at the display's native scale.
    var systemImage: String {
        switch self {
        case .brief: "text.alignleft"
        case .needsYou: "exclamationmark.circle"
        case .waiting: "clock"
        case .mail: "tray"
        case .ask: "sparkle.magnifyingglass"
        }
    }
    var attention: Attention? {
        switch self { case .needsYou: .needsYou; case .waiting: .waiting; default: nil }
    }
}
