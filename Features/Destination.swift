import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case brief = "Brief", needsYou = "Needs You", waiting = "Waiting", mail = "Mail", ask = "Ask"
    var id: String { rawValue }
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

/// Set only in the iPad/wide layout: which conversation the detail column
/// shows. Lists and the Brief select into it instead of pushing, and a
/// conversation closes by clearing it instead of popping.
private struct ConversationSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<ConversationRoute?>? = nil
}

extension EnvironmentValues {
    var conversationSelection: Binding<ConversationRoute?>? {
        get { self[ConversationSelectionKey.self] }
        set { self[ConversationSelectionKey.self] = newValue }
    }
}
