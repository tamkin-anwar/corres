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

/// Whether Corres Pro features (AI reading and writing help) are available
/// here: with Pro, or on sample mail before any account is connected.
private struct ProUnlockedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var proUnlocked: Bool {
        get { self[ProUnlockedKey.self] }
        set { self[ProUnlockedKey.self] = newValue }
    }

    var conversationSelection: Binding<ConversationRoute?>? {
        get { self[ConversationSelectionKey.self] }
        set { self[ConversationSelectionKey.self] = newValue }
    }
}
