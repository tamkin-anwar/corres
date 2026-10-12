import SwiftUI

/// The email and the category it's going to, waiting on how far to apply
/// it.
struct CategoryChoice: Identifiable {
    let thread: Correspondence
    let category: InboxCategory
    var id: String { thread.id.providerID + category.rawValue }
}

/// "Move to Primary, Promotions, Social or Updates" for a menu: every
/// category but the one it's in.
struct CategoryMenuItems: View {
    let thread: Correspondence
    let choose: (CategoryChoice) -> Void

    var body: some View {
        let current = InboxCategory.of(thread, override: SenderLessons.category(for: thread))
        Menu {
            ForEach(InboxCategory.allCases.filter { $0 != current }, id: \.self) { category in
                Button { choose(CategoryChoice(thread: thread, category: category)) } label: {
                    Label(category.title, systemImage: category.systemImage)
                }
            }
        } label: {
            Label("Move to Category", systemImage: "tray.2")
        }
    }
}

extension InboxCategory {
    var systemImage: String {
        switch self {
        case .primary: "person"
        case .promotions: "tag"
        case .social: "bubble.left.and.bubble.right"
        case .updates: "bell"
        }
    }
}

extension View {
    /// How far a category move goes: this email, this kind of the sender's
    /// mail ("All of Uber's Receipts"), or everything they send. Gmail and
    /// Mail offer only the sender, which moves a shop's receipts with its
    /// ads.
    func categoryMoveDialog(_ choice: Binding<CategoryChoice?>, threadActions: ThreadActionService?) -> some View {
        confirmationDialog(choice.wrappedValue.map { "Move to \($0.category.title)" } ?? "",
                           isPresented: Binding(get: { choice.wrappedValue != nil }, set: { if !$0 { choice.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: choice.wrappedValue) { pick in
            let sender = pick.thread.sender
            let kind = pick.thread.mailKind
            if kind != .personal {
                Button("All of \(sender)\u{2019}s \(kind.plural.capitalized)") {
                    Task { await threadActions?.setCategory(pick.category, for: pick.thread, scope: .thisKind) }
                }
            }
            Button("Everything from \(sender)") {
                Task { await threadActions?.setCategory(pick.category, for: pick.thread, scope: .sender) }
            }
            Button("Just This Email") {
                Task { await threadActions?.setCategory(pick.category, for: pick.thread, scope: .thisEmail) }
            }
        } message: { pick in
            Text("Corres remembers this for the mail you choose, and Gmail learns it too. Change it any time in Settings > Sorting > What Corres Has Learned.")
        }
    }
}
