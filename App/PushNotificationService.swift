import Foundation
import Security
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UserNotifications

/// The client half of Batch 25's push relay (see Server/push-relay). This
/// never sends or receives message content: it only (a) asks Gmail to
/// notify the relay's Pub/Sub topic when the mailbox changes
/// (`GmailAPIClient.watch`, using the token this device already holds, so
/// no credential ever reaches the relay), and (b) tells the relay which
/// device token belongs to which Gmail address, so a later contentless
/// ping can be routed to the right device. The actual subject/sender/body
/// a person ends up seeing is fetched by an ordinary sync, on-device, the
/// same as any other sync; nothing here ever touches it.
@MainActor @Observable
final class PushNotificationService {
    /// The studio's real deployment (see Server/push-relay/README.md):
    /// `corres-509320` on GCP, `corres-push-relay` Cloud Function region
    /// us-central1, `gmail-push` Pub/Sub topic. Every call here still fails
    /// closed on any network/auth error rather than crashing, the same
    /// "no-op rather than crash on unconfigured infrastructure" choice
    /// already made elsewhere in this app, which now just also covers a
    /// real but temporarily unreachable relay.
    static let relayBaseURL = URL(string: "https://us-central1-corres-509320.cloudfunctions.net/corres-push-relay")!
    static let pubsubTopicName = "projects/corres-509320/topics/gmail-push"
    /// Where Microsoft Graph sends Outlook's new-mail notifications.
    static let graphNotificationURL = URL(string: "https://us-central1-corres-509320.cloudfunctions.net/corres-push-relay-graph")!

    private(set) var isEnabled: Bool
    var errorMessage: String?

    private let client = MailClient()
    private let defaults = UserDefaults.standard
    private static let enabledKey = "corres.push.enabled"
    private static let deviceTokenKey = "corres.push.deviceTokenHex"

    init() {
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Explicit, Preferences-toggle-driven, not asked for at launch: a
    /// permission prompt the person didn't ask for yet is the kind of thing
    /// that erodes trust in exactly the app this session has been trying to
    /// build trust in. One toggle covers every connected account (Batch 29):
    /// there is no real reason to want new-mail pushes from one connected
    /// account but not another.
    func enableAll(accounts: [String]) async {
        let center = UNUserNotificationCenter.current()
        guard let granted = try? await center.requestAuthorization(options: [.alert, .badge, .sound]), granted else {
            errorMessage = "Notifications need permission in \(Device.settingsName) to turn on."
            return
        }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        PushNotificationService.application.registerForRemoteNotifications()
        await renewWatch(accounts: accounts)
    }

    func disableAll(accounts: [String]) async {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        PushNotificationService.application.unregisterForRemoteNotifications()
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { try? await self.client.stopWatching(account: account) }
            }
        }
        if let deviceTokenHex = defaults.string(forKey: Self.deviceTokenKey) {
            try? await post(path: "unregister", body: ["deviceToken": deviceTokenHex])
        }
        defaults.removeObject(forKey: Self.deviceTokenKey)
    }

    /// Disconnecting a single account (Preferences' own per-row Disconnect)
    /// only needs that one account's watch/registration torn down, not every
    /// account's; `disableAll` remains the "turn notifications off entirely"
    /// path.
    func disable(account: String) async {
        try? await client.stopWatching(account: account)
        if let deviceTokenHex = defaults.string(forKey: Self.deviceTokenKey) {
            try? await post(path: "unregister", body: ["deviceToken": deviceTokenHex, "emailAddress": account])
        }
    }

    /// Called from `AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken`
    /// once APNs actually hands back a real token (arrives asynchronously
    /// after `registerForRemoteNotifications()`, never synchronously).
    func didRegister(deviceToken: Data, accounts: [String]) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        defaults.set(hex, forKey: Self.deviceTokenKey)
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { try? await self.post(path: "register", body: ["emailAddress": account, "deviceToken": hex]) }
            }
        }
    }

    /// Outlook's subscriptions last under three days, so every push also
    /// renews any that is due (a local check; no request until one is).
    /// `renewWatch`, at most twice a day: on coming back to Corres, so push
    /// never lapses for someone who keeps it open for days.
    func renewWatchIfDue(accounts: [String]) async {
        let key = "corres.push.lastRenewed"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard !accounts.isEmpty, Date.now.timeIntervalSince(last) > 12 * 3_600 else { return }
        UserDefaults.standard.set(Date.now, forKey: key)
        await renewWatch(accounts: accounts)
    }

    func renewOutlookSubscriptions(accounts: [String]) async {
        await renewWatch(accounts: accounts.filter { MailAccounts.provider(for: $0) == .microsoft })
    }

    /// Gmail's watch subscription expires after about 7 days; this is the
    /// app's only renewal mechanism (called at every launch), so an account
    /// left unopened for a week silently stops getting push until the next
    /// launch. A background-refresh-driven renewal would close that gap;
    /// deliberately not built here, a known and accepted limitation for v1
    /// (see Server/push-relay/README.md). Covers every connected account:
    /// the relay's `devices` record now maps one device token to a list of
    /// accounts (see Server/push-relay's own doc comment), so each account
    /// needs its own `watch` call and its own `register` post. Fired
    /// concurrently, not one after another: this runs on every launch (see
    /// `AppDelegate.performLaunchWork`) and inside a capped-duration
    /// `BGAppRefreshTask`, so N accounts waiting on each other's network
    /// round trip in turn is real, avoidable time either way.
    func renewWatch(accounts: [String]) async {
        guard isEnabled else { return }
        // Read once, on the main actor, before spawning concurrent child
        // tasks: `UserDefaults` isn't `Sendable`, so a task-group closure
        // can't reach back across the actor boundary to read `self.defaults`
        // directly without forcing an await on every access anyway.
        let deviceTokenHex = defaults.string(forKey: Self.deviceTokenKey)
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask {
                    // iCloud has no push for apps: with Instant Notifications
                    // on, Corres's watcher holds its Inbox open instead.
                    if MailAccounts.provider(for: account).usesIMAP {
                        if await MainActor.run(body: { AccountPreferences.icloudInstant(for: account) }), let deviceTokenHex {
                            try? await self.registerICloud(account: account, deviceToken: deviceTokenHex)
                        }
                        return
                    }
                    // Outlook: a Graph subscription, its secret handed to
                    // the relay, so only Microsoft's real notifications wake
                    // this device.
                    if MailAccounts.provider(for: account) == .microsoft {
                        guard let deviceTokenHex,
                              let subscription = try? await OutlookClient().subscribe(account: account, notificationURL: Self.graphNotificationURL) else { return }
                        // "alerts": this build's notification extension shows
                        // the email itself, the moment it arrives, unless the
                        // account's notifications are off.
                        let alerts = await MainActor.run { Self.showsPushAlerts && AccountPreferences.level(for: account) != nil }
                        try? await self.post(path: "register-graph", body: ["subscriptionId": subscription.id, "clientState": subscription.secret,
                                                                            "emailAddress": account, "deviceToken": deviceTokenHex,
                                                                            "alerts": alerts ? "1" : "0"])
                        return
                    }
                    // `watch` is `@discardableResult` on its own
                    // declaration, but that doesn't propagate through
                    // `try?`, which still warns its own result is unused;
                    // discard it explicitly.
                    _ = try? await self.client.watch(topicName: Self.pubsubTopicName, account: account)
                    if let deviceTokenHex {
                        // Visible Gmail pushes only where the extension can stay
                        // silent about changes that aren't new mail.
                        let alerts = await MainActor.run {
                            NotifyPolicy.gmailAlerts && Self.showsPushAlerts && AccountPreferences.level(for: account) != nil
                        }
                        try? await self.post(path: "register", body: ["emailAddress": account, "deviceToken": deviceTokenHex,
                                                                      "gmailAlerts": alerts ? "1" : "0"])
                    }
                }
            }
        }
    }

    /// What the notification extension needs to judge an email the way
    /// Settings says (`NotifyPolicy`): each account's choice, VIPs, blocked
    /// senders. Written at launch and whenever Corres goes to the
    /// background, so any change made in Settings is there for the next email.
    static func publishPolicy(accounts: [String], threads: [Correspondence]) {
        var policy = NotifyPolicy()
        for account in accounts {
            policy.levels[account.lowercased()] = AccountPreferences.level(for: account)?.rawValue ?? "off"
        }
        policy.vips = Array(CorresSettings.vips)
        policy.blocked = Array(Set(threads.filter { $0.senderDecision == .blocked }.compactMap { $0.senderEmail?.lowercased() }))
        policy.blockedDomains = CorresSettings.domainRules.filter { $0.value == .blocked }.map(\.key)
        policy.mutedThreads = Organizer.shared.mutedProviderIDs
        policy.save()
    }

    /// The other half of "push" that was missing: until this, a silent
    /// wake-up notification synced new mail into local storage without ever
    /// telling the person it arrived, which defeated the entire point of
    /// turning notifications on. `threads` should already be filtered to
    /// genuinely newly-unread, Screener-approved threads (see
    /// `CorresApp`'s `onRemoteNotification`); this only decides how to
    /// present them. Capped at one notification per wake, not one per
    /// message: a person who hasn't opened Corres in a while could have
    /// dozens of newly-unread threads land in a single sync, and spamming a
    /// notification per message is exactly the kind of thing that gets a
    /// mail app's notifications turned back off.
    /// Structured `title`/`subtitle`/`body` (Apple's own documented pattern:
    /// title is who, subtitle is what, body is a preview), not subject
    /// squeezed into `body` alone with nothing else: reported directly
    /// against a side-by-side comparison with Apple Mail's own notification
    /// for the identical email, which showed sender, subject, *and* several
    /// lines of body preview, next to Corres's showing only sender and
    /// subject with nothing else — "not enough info to be useful." A single
    /// notification's `body` still has to fit in a few lines on the lock
    /// screen regardless of how much text is passed to it, so `excerpt`
    /// (Gmail's own short snippet, already computed at sync time, not the
    /// full message body) is exactly the right length for this, the same
    /// value `CorrespondenceRow`'s list preview already uses.
    /// Which new mail buzzes the phone. The default follows Spark's Smart
    /// notifications and Superhuman's Important split: anything from a real
    /// person, plus automated mail that's time-sensitive for you. It keys
    /// off who sent it, which rules decide reliably, rather than whether
    /// it "needs a reply", which is a judgment that can be wrong, so an FYI
    /// from a colleague still arrives.
    enum Level: String, CaseIterable, Identifiable {
        case everything, people, needsYou
        var id: String { rawValue }
        static let key = "corres.notifyLevel"

        var title: String {
            switch self {
            case .everything: String(localized: "All New Mail")
            case .people: String(localized: "People and Time-Sensitive")
            case .needsYou: String(localized: "Only What Needs Me")
            }
        }

        var detail: String {
            switch self {
            case .everything: String(localized: "Every new email in your inbox, newsletters and promotions included.")
            case .people: String(localized: "Anything from a real person, plus bills, appointments and other mail with a date that matters. Newsletters, promotions and social updates arrive silently.")
            case .needsYou: String(localized: "Only what Corres files in Needs You. The quietest option; an FYI from a person arrives silently.")
            }
        }

        /// The saved choice; the older on/off switch carries over.
        static var current: Level {
            let defaults = UserDefaults.standard
            if let raw = defaults.string(forKey: key), let level = Level(rawValue: raw) { return level }
            return defaults.bool(forKey: "corres.notifyOnlyNeedsYou") ? .needsYou : .people
        }

        func includes(_ thread: Correspondence) -> Bool {
            switch self {
            case .everything: true
            case .people: thread.attention == .needsYou
                || InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) == nil
            case .needsYou: thread.attention == .needsYou
            }
        }
    }

    /// First emails from someone not yet allowed wait in New senders.
    /// Which of them still notify, modelled on iOS 26 Messages' "Screen
    /// Unknown Senders" (Allow Notifications: Time Sensitive, Personal,
    /// Transactions, Promotions). Apple turns on only Time Sensitive;
    /// Corres also turns on people, so a first email from a landlord or
    /// recruiter isn't missed. Blocked senders never notify.
    enum NewSenderAlerts {
        static let timeSensitiveKey = "corres.newSenders.timeSensitive"
        static let peopleKey = "corres.newSenders.people"
        static let otherKey = "corres.newSenders.other"

        static func includes(_ thread: Correspondence) -> Bool {
            // Only while new senders are held; otherwise their mail
            // notifies like anyone else's.
            guard thread.senderDecision == .pending, MailQuery.holdsNewSenders else { return false }
            let defaults = UserDefaults.standard
            func on(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
            let timeSensitive = thread.dueAt != nil
                || [InboxClassifier.obligationReason, InboxClassifier.deadlineReason].contains(thread.reason)
            if timeSensitive { return on(timeSensitiveKey, true) }
            if InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) == nil {
                return on(peopleKey, true)
            }
            return on(otherKey, false)
        }
    }

    static let messageCategory = "corres.message"
    static let archiveAction = "corres.archive"
    static let markReadAction = "corres.markRead"
    static let replyAction = "corres.reply"

    /// A device token only works on the APNs server for the build it came
    /// from: "development" for a build run from Xcode, "production" for
    /// TestFlight and the App Store, where Xcode signs the app for
    /// production (Apple's "Sending notification requests to APNs").
    /// Read from the build's own provisioning profile; TestFlight and App
    /// Store builds carry none, and are always production.
    static let apnsEnvironment: String = {
        #if targetEnvironment(simulator)
        return "development"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
              let profile = try? PropertyListSerialization.propertyList(
                  from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String else { return "production" }
        return environment == "development" ? "development" : "production"
        #endif
    }()

    /// Registered every launch; iOS shows these under a long-press on any
    /// single-conversation notification, without opening Corres.
    static func registerNotificationActions() {
        let archive = UNNotificationAction(identifier: archiveAction, title: String(localized: "Archive"),
                                           options: [], icon: UNNotificationActionIcon(systemImageName: "archivebox"))
        let markRead = UNNotificationAction(identifier: markReadAction, title: String(localized: "Mark as Read"),
                                            options: [], icon: UNNotificationActionIcon(systemImageName: "envelope.open"))
        // Mail's and Gmail's quick reply: typed in the notification, sent
        // from it.
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: String(localized: "Reply"), options: [],
                                                  icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                                                  textInputButtonTitle: String(localized: "Send"), textInputPlaceholder: String(localized: "Reply"))
        let category = UNNotificationCategory(identifier: messageCategory, actions: [reply, archive, markRead],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func notifyAboutNewMail(_ threads: [Correspondence]) {
        // Already on screen from the notification extension, the instant
        // it arrived: never twice.
        let threads = threads.filter { !NotifyPolicy.wasShown($0.latestMessageID) && !Organizer.shared.isMuted($0.id) }
        guard !threads.isEmpty else { return }
        let content = UNMutableNotificationContent()
        if threads.count == 1, let thread = threads.first {
            content.title = thread.sender
            content.subtitle = thread.senderDecision == .pending ? String(localized: "New sender · \(thread.subject)") : thread.subject
            content.body = thread.excerpt
        } else {
            content.title = String(localized: "\(threads.count) new messages")
            let senders = threads.prefix(3).map(\.sender).joined(separator: ", ")
            content.body = threads.count > 3 ? String(localized: "\(senders), and more") : senders
        }
        content.sound = .default
        if threads.count == 1, let thread = threads.first {
            // One conversation: Archive and Mark as Read right on the
            // notification, and grouped with that conversation's others.
            content.categoryIdentifier = Self.messageCategory
            content.threadIdentifier = "\(thread.id.account)|\(thread.id.providerID)"
            content.userInfo = ["account": thread.id.account, "thread": thread.id.providerID]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Instant iCloud notifications

    enum ICloudInstantError: Error { case notificationsOff, unavailable, noPassword }

    /// Turns instant alerts on or off for one iCloud account. On: the
    /// app-specific password is sealed here, on this device, to the
    /// watcher's public key, so only the watcher can open it. Off: the
    /// relay deletes it.
    func setICloudInstant(_ on: Bool, account: String) async throws {
        guard let deviceTokenHex = defaults.string(forKey: Self.deviceTokenKey) else {
            if on { throw ICloudInstantError.notificationsOff }
            return
        }
        if on {
            try await registerICloud(account: account, deviceToken: deviceTokenHex)
        } else {
            try await post(path: "unregister-icloud", body: ["deviceToken": deviceTokenHex, "emailAddress": account])
        }
    }

    private func registerICloud(account: String, deviceToken: String) async throws {
        guard let password = IMAPCredentials.password(for: account) else { throw ICloudInstantError.noPassword }
        let sealed = try await Self.seal(password)
        let alerts = await MainActor.run { Self.showsPushAlerts && AccountPreferences.level(for: account) != nil }
        let server = IMAPServer.for(account)
        try await post(path: "register-icloud", body: ["emailAddress": account, "deviceToken": deviceToken,
                                                       "sealedPassword": sealed, "alerts": alerts ? "1" : "0",
                                                       "imapHost": server.imapHost, "imapPort": String(server.imapPort),
                                                       "username": server.username ?? account])
    }

    /// RSA-OAEP (SHA-256) to the watcher's KMS key, fetched from the relay.
    private static func seal(_ password: String) async throws -> String {
        var request = URLRequest(url: relayBaseURL.appendingPathComponent("icloud-key"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keyBase64 = json["key"] as? String, let keyData = Data(base64Encoded: keyBase64) else {
            throw ICloudInstantError.unavailable
        }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil),
              let sealed = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA256, Data(password.utf8) as CFData, nil) as Data? else {
            throw ICloudInstantError.unavailable
        }
        return sealed.base64EncodedString()
    }

    private func post(path: String, body: [String: String]) async throws {
        var request = URLRequest(url: Self.relayBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = body
        // Which of Apple's two push servers this phone's token belongs to,
        // so the relay wakes it through the right one.
        if path.hasPrefix("register") { body["apnsEnvironment"] = Self.apnsEnvironment }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        if path.hasSuffix("icloud"), let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw ICloudInstantError.unavailable
        }
    }
}

extension PushNotificationService {
    #if canImport(UIKit)
    @MainActor static var application: UIApplication { .shared }
    #else
    @MainActor static var application: NSApplication { .shared }
    #endif

    /// Visible alert pushes need the notification extension that fills
    /// them in, which only the iPhone and iPad have. The Mac gets silent
    /// wake-ups, syncs, and posts its own notification.
    #if os(iOS)
    static let showsPushAlerts = true
    #else
    static let showsPushAlerts = false
    #endif
}
