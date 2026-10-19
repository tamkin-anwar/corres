import SwiftUI

/// Needs You, Waiting and Handled, each with what it means, for every
/// "Move to" menu. The current one is ticked.
struct AttentionChoices: View {
    let current: Attention?
    let choose: (Attention) -> Void

    var body: some View {
        ForEach(Attention.choices, id: \.self) { attention in
            Button { choose(attention) } label: {
                Text(attention.title)
                Text(attention.explanation)
                if attention == current { Image(systemName: "checkmark") }
            }
        }
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
