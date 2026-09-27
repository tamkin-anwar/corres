import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case brief = "Brief", needsYou = "Needs You", waiting = "Waiting", mail = "Mail"
    var id: String { rawValue }
    /// SF Symbols: vector, weight-matched to the tab label, and rendered by
    /// the system at the display's native scale.
    var systemImage: String {
        switch self {
        case .brief: "text.alignleft"
        case .needsYou: "exclamationmark.circle"
        case .waiting: "clock"
        case .mail: "tray"
        }
    }
    var attention: Attention? {
        switch self { case .needsYou: .needsYou; case .waiting: .waiting; default: nil }
    }
}
