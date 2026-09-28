import AppIntents
import Foundation

/// Siri, Shortcuts, Spotlight and the Action button. Everything here reads
/// the same on-device summary the widgets use; nothing is sent anywhere.

enum CorresList: String, AppEnum {
    case brief, needsYou, waiting, mail

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    static let caseDisplayRepresentations: [CorresList: DisplayRepresentation] = [
        .brief: "Brief", .needsYou: "Needs You", .waiting: "Waiting", .mail: "Mail",
    ]

    var destination: Destination {
        switch self { case .brief: .brief; case .needsYou: .needsYou; case .waiting: .waiting; case .mail: .mail }
    }
}

/// "What needs me in Corres?": answered in a sentence, without opening the app.
struct WhatNeedsMeIntent: AppIntent {
    static let title: LocalizedStringResource = "What Needs Me"
    static let description = IntentDescription("Hear what's in Needs You and who you're waiting on.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = WidgetSnapshot.load() else {
            return .result(dialog: "Open Corres once so it can sort your mail.")
        }
        if snapshot.isLocked == true {
            return .result(dialog: "Needs You is part of Corres Pro. Open Corres to start your free trial.")
        }
        return .result(dialog: IntentDialog(stringLiteral: Self.summary(of: snapshot)))
    }

    static func summary(of snapshot: WidgetSnapshot) -> String {
        var parts: [String] = []
        switch snapshot.needsYouCount {
        case 0: parts.append("Nothing needs you right now.")
        case 1: parts.append("One conversation needs you.")
        default: parts.append("\(snapshot.needsYouCount) conversations need you.")
        }
        let top = snapshot.needsYou.prefix(2).map { item in
            let due = item.dueLabel.map { " Due \($0.lowercased())." } ?? ""
            return "\(item.sender): \(item.reason.trimmingCharacters(in: .punctuationCharacters)).\(due)"
        }
        parts.append(contentsOf: top)
        if snapshot.waitingCount > 0 {
            parts.append(snapshot.waitingCount == 1 ? "You're waiting on one reply." : "You're waiting on \(snapshot.waitingCount) replies.")
        }
        return parts.joined(separator: " ")
    }
}

struct OpenListIntent: AppIntent {
    static let title: LocalizedStringResource = "Open List"
    static let description = IntentDescription("Open Brief, Needs You, Waiting or Mail in Corres.")
    static let openAppWhenRun = true

    @Parameter(title: "List", default: .needsYou)
    var list: CorresList

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pending = .destination(list.destination)
        return .result()
    }
}

struct NewMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "New Message"
    static let description = IntentDescription("Start a new email in Corres.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pending = .compose
        return .result()
    }
}

struct CorresShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhatNeedsMeIntent(), phrases: [
            "What needs me in \(.applicationName)",
            "What's in \(.applicationName)",
            "Brief me with \(.applicationName)",
        ], shortTitle: "What Needs Me", systemImageName: "exclamationmark.circle")
        AppShortcut(intent: OpenListIntent(), phrases: [
            "Open \(\.$list) in \(.applicationName)",
            "Show \(\.$list) in \(.applicationName)",
        ], shortTitle: "Open List", systemImageName: "tray")
        AppShortcut(intent: NewMessageIntent(), phrases: [
            "New email in \(.applicationName)",
            "Write an email with \(.applicationName)",
        ], shortTitle: "New Message", systemImageName: "square.and.pencil")
    }
}

// MARK: - Focus filter

/// A connected account, as offered in a Focus filter.
struct MailAccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static let defaultQuery = MailAccountQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct MailAccountQuery: EntityQuery {
    private var connected: [String] { UserDefaults.standard.stringArray(forKey: "corres.connectedAccounts") ?? [] }
    func entities(for identifiers: [String]) async throws -> [MailAccountEntity] {
        identifiers.filter(connected.contains).map(MailAccountEntity.init)
    }
    func suggestedEntities() async throws -> [MailAccountEntity] { connected.map(MailAccountEntity.init) }
}

/// Settings → Focus → a Focus → Add Filter → Corres: during that Focus,
/// Corres shows and notifies for one account only, the way Mail's own
/// Focus filter does. When the Focus ends, everything comes back.
struct CorresFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Show One Account"
    static let description = IntentDescription("During this Focus, Corres shows and notifies for this account only.")
    static let activeAccountKey = "corres.focus.account"
    static let didChange = Notification.Name("corres.focusFilterChanged")

    @Parameter(title: "Account") var account: MailAccountEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: account.map { "Only \($0.id)" } ?? "All accounts")
    }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(account?.id, forKey: Self.activeAccountKey)
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        return .result()
    }

    /// The account the current Focus limits Corres to, if any.
    static var activeAccount: String? { UserDefaults.standard.string(forKey: activeAccountKey) }
}
