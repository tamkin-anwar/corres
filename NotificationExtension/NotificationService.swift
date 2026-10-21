import UserNotifications

/// New mail, shown the instant it arrives. The relay sends a visible push
/// naming only the account and the message (it never sees the email);
/// this fetches that one email on the iPhone, with the account's own
/// sign-in, and writes the notification: who it's from, the subject, the
/// opening words, grouped with its conversation. iOS runs this for every
/// visible push, even with Corres closed, unlike the background wake-ups
/// it throttles, which is what lets Corres notify as fast as the mail
/// service's own app.
///
/// What the person chose still holds: mail their setting leaves out
/// (newsletters under "People and Time-Sensitive", say) arrives silently,
/// in Notification Center only, as Settings promises.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var task: Task<Void, Never>?

    /// What the email says and how it should arrive, worked out off the
    /// notification's own object.
    private struct Filled: Sendable {
        let title: String
        let subtitle: String
        let body: String
        let account: String
        let threadID: String
        let quiet: Bool
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        lock.withLock {
            self.contentHandler = contentHandler
            bestAttempt = content
        }
        if let account = content.userInfo["account"] as? String, let history = content.userInfo["gmailHistory"] as? String {
            task = Task { [self] in
                let found = await Self.newGmail(account: account, history: history)
                if let found { finish(found) } else { stayQuiet() }
            }
            return
        }
        guard let account = content.userInfo["account"] as? String,
              let messageID = content.userInfo["message"] as? String else {
            finish(nil)
            return
        }
        task = Task { [self] in
            finish(await Self.fill(account: account, messageID: messageID))
        }
    }

    /// Out of time (about 30 seconds): what the relay sent, a plain "New
    /// email", rather than nothing.
    override func serviceExtensionTimeWillExpire() {
        task?.cancel()
        finish(nil)
    }

    /// Hands iOS the notification once, whichever of the fetch or the
    /// deadline gets here first.
    private func finish(_ filled: Filled?) {
        let (handler, content): (((UNNotificationContent) -> Void)?, UNMutableNotificationContent?) = lock.withLock {
            defer { contentHandler = nil }
            return (contentHandler, bestAttempt)
        }
        guard let handler, let content else { return }
        if let filled {
            content.title = filled.title
            content.subtitle = filled.subtitle
            content.body = filled.body
            content.categoryIdentifier = "corres.message"
            content.threadIdentifier = "\(filled.account)|\(filled.threadID)"
            content.userInfo = ["account": filled.account, "thread": filled.threadID]
            if filled.quiet {
                // Kept quiet: no sound, no banner, only in Notification Center.
                content.sound = nil
                content.interruptionLevel = .passive
            } else {
                content.sound = .default
                content.interruptionLevel = .active
            }
        }
        handler(content)
    }

    /// A Gmail change that wasn't new mail (a read, an archive), or new
    /// mail Corres already showed: nothing on screen. Apple's notification
    /// filtering entitlement makes an empty notification silent; builds
    /// without it never ask the relay for these pushes.
    private func stayQuiet() {
        let handler: ((UNNotificationContent) -> Void)? = lock.withLock {
            defer { contentHandler = nil }
            return contentHandler
        }
        handler?(UNNotificationContent())
    }

    /// What's new in the Inbox since the last Gmail push this device saw:
    /// the newest of it, filled in like any other email.
    private static func newGmail(account: String, history: String) async -> Filled? {
        guard let since = NotifyPolicy.gmailCursor(for: account) else {
            // The first push only sets where to look from.
            NotifyPolicy.setGmailCursor(history, for: account)
            return nil
        }
        guard let found = try? await GmailAPIClient().newInboxMessageIDs(since: since, account: account) else {
            NotifyPolicy.setGmailCursor(history, for: account)
            return nil
        }
        NotifyPolicy.setGmailCursor(found.historyId ?? history, for: account)
        let fresh = found.ids.filter { !NotifyPolicy.wasShown($0) }
        // Gmail ids grow with time: the last is the newest.
        guard let newest = fresh.max() else { return nil }
        for id in fresh where id != newest { NotifyPolicy.markShown(id) }
        return await fill(account: account, messageID: newest)
    }

    private static func fill(account: String, messageID: String) async -> Filled? {
        let policy = NotifyPolicy.load()
        InboxClassifier.vipAddresses = Set(policy.vips)
        guard let thread = try? await MailClient().fetchSummary(ids: [messageID], account: account).first else { return nil }
        let sender = thread.senderEmail?.lowercased() ?? ""
        let blockedCompany = InboxClassifier.companyDomain(of: sender).map { (policy.blockedDomains ?? []).contains($0) } ?? false
        let muted = (policy.mutedThreads ?? []).contains(thread.id.providerID)
        let quiet = muted || policy.blocked.contains(sender) || blockedCompany || !includes(thread, level: policy.level(for: account))
        NotifyPolicy.markShown(messageID)
        return Filled(title: thread.sender, subtitle: thread.subject, body: thread.excerpt,
                      account: account, threadID: thread.id.providerID, quiet: quiet)
    }

    /// The same choice as Settings → Notifications
    /// (`PushNotificationService.Level.includes`).
    private static func includes(_ thread: Correspondence, level: String) -> Bool {
        switch level {
        case "everything": true
        case "needsYou": thread.attention == .needsYou
        case "off": false
        default: thread.attention == .needsYou
            || InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) == nil
        }
    }
}
