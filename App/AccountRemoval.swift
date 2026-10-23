import Foundation

/// Removing an account, the same on iPhone, iPad and Mac.
///
/// From this device only (as in Mail and Spark): your other devices keep
/// it, so its filters in Gmail and rules in Outlook keep running for them.
/// From all your devices: Corres's filters and rules are taken out first,
/// while it can still reach the account, since nothing would be left to
/// look after them; each other device signs out when it next opens.
@MainActor
enum AccountRemoval {
    static func remove(_ email: String, everywhere: Bool, auth: GoogleAuthService, sync: GmailSyncService,
                       store: MailStore, push: PushNotificationService, intelligence: MailIntelligence) async {
        if everywhere { await ServerRules.shared.removeAll(for: email) }
        // Gmail's watch is the account's, not this device's: stopping it
        // would silence new-mail alerts on your other devices too, so only
        // when the account leaves all of them.
        if everywhere { await push.disable(account: email) }
        await auth.signOut(email, everywhere: everywhere)
        await forgetHere(email, sync: sync, store: store, intelligence: intelligence)
    }

    /// What removing it does, said before you choose.
    static func explanation(for email: String) -> String {
        let service = MailAccounts.serviceTitle(for: email)
        let kept = ServerRules.shared.keptCount(for: email)
        var parts = [String(localized: "Your other devices keep it unless you remove it from all of them. Nothing is deleted from \(service).")]
        if kept > 0 {
            parts.append(String(localized: "Removing it from all devices also takes out the \(kept) rules Corres made in \(service)."))
        }
        return parts.joined(separator: " ")
    }

    /// What this device kept for it: its mail, its place in sync, changes
    /// still waiting to reach the server, and summaries.
    static func forgetHere(_ email: String, sync: GmailSyncService, store: MailStore, intelligence: MailIntelligence) async {
        sync.clearCursor(for: email)
        ActionQueue.shared.forget(account: email)
        Organizer.shared.outbox?.forget(account: email)
        ServerRules.shared.forget(account: email)
        await store.removeAccountData(email)
        intelligence.forget(account: email)
    }
}
