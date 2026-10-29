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
                       store: MailStore, push: PushNotificationService, intelligence: MailIntelligence,
                       people: PeopleDirectory?) async {
        if everywhere { await ServerRules.shared.removeAll(for: email) }
        // This device's records at the relay (and a sealed iCloud password)
        // and its own Outlook subscription go, before the sign-in does.
        // Gmail's watch is the account's, shared by your devices, so
        // `disable` leaves it to lapse on its own.
        await push.disable(account: email)
        await auth.signOut(email, everywhere: everywhere)
        await forgetHere(email, sync: sync, store: store, intelligence: intelligence, people: people)
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
    /// still waiting to reach the server, summaries, and who it wrote to.
    static func forgetHere(_ email: String, sync: GmailSyncService, store: MailStore, intelligence: MailIntelligence,
                           people: PeopleDirectory?) async {
        sync.clearCursor(for: email)
        people?.forget(account: email)
        ActionQueue.shared.forget(account: email)
        Organizer.shared.actions?.forget(account: email)
        Organizer.shared.outbox?.forget(account: email)
        ScheduledSends.shared.forget(account: email)
        ServerRules.shared.forget(account: email)
        await store.removeAccountData(email)
        intelligence.forget(account: email)
        #if os(macOS)
        // Attachments opened on the Mac (Quick Look, Open) are kept by
        // message, not by account (`MacAttachmentChip`): all of them go, and
        // come from the server again when next opened.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent("Attachments", isDirectory: true))
        }
        #endif
    }
}
