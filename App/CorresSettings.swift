import Foundation

/// Every personal preference in Settings, in one place, with the defaults
/// researched against Apple Mail, Gmail and Spark. Read from anywhere
/// (views use `@AppStorage` with the same keys); stored on this iPhone.
enum CorresSettings {
    private static var defaults: UserDefaults { .standard }

    // MARK: Composing

    /// 5 seconds by default: long enough to catch a mistake, short enough
    /// not to wait on. Off sends at once.
    static let undoSendKey = "corres.undoSendSeconds"
    static let undoSendChoices = [0, 5, 10, 20, 30]
    static var undoSendSeconds: Int { defaults.object(forKey: undoSendKey) as? Int ?? 5 }

    static let defaultReplyKey = "corres.defaultReply"
    enum DefaultReply: String, CaseIterable, Identifiable {
        case reply, replyAll
        var id: String { rawValue }
        var title: String { self == .reply ? String(localized: "Reply") : String(localized: "Reply All") }
    }
    static var defaultReply: DefaultReply {
        defaults.string(forKey: defaultReplyKey).flatMap(DefaultReply.init) ?? .reply
    }

    static let defaultFromKey = "corres.defaultFromAccount"
    static var defaultFromAccount: String? { defaults.string(forKey: defaultFromKey) }

    /// The account's signature for new mail, or for a reply (see `Signatures`).
    static func signature(for account: String?, reply: Bool = false) -> String {
        Signatures.text(for: account, reply: reply)
    }

    // MARK: Reading

    static let remoteImagesKey = "corres.remoteImages"
    enum RemoteImages: String, CaseIterable, Identifiable {
        case ask, always
        var id: String { rawValue }
        var title: String { self == .ask ? String(localized: "Ask First") : String(localized: "Always Load") }
    }
    static var remoteImages: RemoteImages {
        defaults.string(forKey: remoteImagesKey).flatMap(RemoteImages.init) ?? .ask
    }

    static let confirmTrashKey = "corres.confirmTrash"
    static var confirmTrash: Bool { defaults.bool(forKey: confirmTrashKey) }

    static let markReadOnOpenKey = "corres.markReadOnOpen"
    static var markReadOnOpen: Bool { defaults.object(forKey: markReadOnOpenKey) as? Bool ?? true }

    static let openLinksKey = "corres.openLinks"
    enum OpenLinks: String, CaseIterable, Identifiable {
        case inCorres, browser
        var id: String { rawValue }
        var title: String { self == .inCorres ? String(localized: "In Corres") : String(localized: "Default Browser") }
    }
    static var openLinks: OpenLinks {
        defaults.string(forKey: openLinksKey).flatMap(OpenLinks.init) ?? .inCorres
    }

    // MARK: People

    /// Settings → Composing → Suggest from Contacts (once allowed).
    static let suggestContactsKey = "corres.suggestContacts"
    static var suggestContacts: Bool { defaults.object(forKey: suggestContactsKey) as? Bool ?? true }

    // MARK: Summaries

    /// Settings → Reading → Summarize emails.
    static let summariesKey = "corres.summaries"
    static var summaries: Bool { defaults.object(forKey: summariesKey) as? Bool ?? true }
    /// Whether the summary card is folded down to its heading; remembered,
    /// the way Gmail remembers a collapsed summary.
    static let summaryCollapsedKey = "corres.summaryCollapsed"
    /// Settings → Reading → Key details: a receipt's or bill's status and
    /// figures, and what a long email asks of you, read from the email
    /// itself (no Apple Intelligence needed).
    static let keyDetailsKey = "corres.keyDetails"
    /// The Mac's View › Bigger and Smaller (⌘+, ⌘−): email text this much
    /// larger than usual. macOS gives apps no system text size to follow.
    static let textScaleKey = "corres.textScale"
    static let textScales: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]
    static var textScale: Double {
        get { (defaults.object(forKey: textScaleKey) as? Double).map { min(max($0, textScales[0]), textScales.last!) } ?? 1 }
        set { defaults.set(newValue, forKey: textScaleKey) }
    }

    // MARK: Lists

    static let previewLinesKey = "corres.previewLines"
    /// Settings › Customize › Lists › Tabs: Needs You, Primary, Everything
    /// and the rest above the mail (pinned while it scrolls), or along the
    /// bottom within thumb reach. Top by default, as in Apple Mail.
    static let tabsAtBottomKey = "corres.tabsAtBottom"
    /// With the tabs on top: kept in view while the mail scrolls (the
    /// default), or scrolled away with it for more room.
    static let tabsPinnedKey = "corres.tabsPinned"
    static var previewLines: Int { defaults.object(forKey: previewLinesKey) as? Int ?? 2 }

    static let showAvatarsKey = "corres.showAvatars"
    /// The Mac list's View › Show Sender Pictures, kept on the Mac alone:
    /// a denser list on the iPhone shouldn't take the Mac's pictures away.
    static let macSenderPicturesKey = "corres.mac.senderPictures"
    static var showAvatars: Bool { defaults.object(forKey: showAvatarsKey) as? Bool ?? true }

    static let badgeKey = "corres.badge"
    enum Badge: String, CaseIterable, Identifiable {
        case needsYou, primary, unread, new, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .needsYou: String(localized: "Needs You")
            case .primary: String(localized: "Unread in Primary")
            case .unread: String(localized: "All Unread")
            case .new: String(localized: "New Since Last Opened")
            case .off: String(localized: "Off")
            }
        }
        var detail: String {
            switch self {
            case .needsYou: String(localized: "Only what asks something of you, so the number means something.")
            case .primary: String(localized: "Unread mail from people and anything urgent. Promotions, Social and Updates aren't counted.")
            case .unread: String(localized: "Every unread email in your inbox, newsletters included.")
            case .new: String(localized: "Mail that arrived since you last left Corres. Opening Corres clears it.")
            case .off: String(localized: "No number on the icon.")
            }
        }
    }
    /// When Corres last went to the background, for the New badge.
    static let lastLeftKey = "corres.lastLeft"
    static var badge: Badge { defaults.string(forKey: badgeKey).flatMap(Badge.init) ?? .needsYou }

    // MARK: Sorting

    static let vipsKey = "corres.vips"
    /// Lowercased addresses of people who always land in Needs You and
    /// always notify.
    static var vips: Set<String> { Set(defaults.stringArray(forKey: vipsKey) ?? []) }
    static func setVIP(_ email: String, _ isVIP: Bool) {
        var all = vips
        if isVIP { all.insert(email.lowercased()) } else { all.remove(email.lowercased()) }
        // So your other devices follow, rather than adding them back.
        if isVIP { CloudSync.noteAdded(CloudSync.vipToken(email)) } else { CloudSync.noteRemoved(CloudSync.vipToken(email)) }
        defaults.set(all.sorted(), forKey: vipsKey)
    }

    static let domainRulesKey = "corres.screener.domainRules"
    /// Screener company rules: lowercased domain → "approved" or "blocked".
    static var domainRules: [String: SenderDecision] {
        ((defaults.dictionary(forKey: domainRulesKey) as? [String: String]) ?? [:])
            .compactMapValues(SenderDecision.init(rawValue:))
    }
    static func setDomainRule(_ domain: String, _ decision: SenderDecision?) {
        var all = domainRules
        all[domain.lowercased()] = decision
        defaults.set(all.mapValues(\.rawValue), forKey: domainRulesKey)
    }

    static let sensitivityKey = "corres.sensitivity"
    static var sensitivity: InboxClassifier.Sensitivity {
        defaults.string(forKey: sensitivityKey).flatMap(InboxClassifier.Sensitivity.init) ?? .balanced
    }

    static let morningHourKey = "corres.snooze.morningHour"
    static let laterTodayEveningKey = "corres.snooze.laterTodayEvening"

    /// Hands the sorting and snooze choices to Core, which has no access
    /// to Settings itself. Called at launch and whenever one changes.
    /// Settings → Sorting → Screen new senders. Off by default: holding a
    /// stranger's first email back made Corres feel like it was losing
    /// mail (Spark's Gatekeeper is off by default for the same reason).
    /// Mailboxes → Edit: the order of mailboxes and labels, and which are hidden.
    static let mailboxOrderKey = "corres.mailboxes.order"
    static let mailboxHiddenKey = "corres.mailboxes.hidden"
    /// Before the four modes, a switch: on held everyone, off showed them
    /// marked New. Read once to choose the mode.
    static let screenNewSendersKey = "corres.screenNewSenders"
    static let newSenderModeKey = "corres.newSenderMode"
    static var newSenderMode: NewSenderMode {
        if let raw = defaults.string(forKey: newSenderModeKey), let mode = NewSenderMode(rawValue: raw) { return mode }
        return defaults.bool(forKey: screenNewSendersKey) ? .reviewEveryone : .inMail
    }

    @MainActor static func applyToCore() {
        // Mail became the one home screen, opening on Needs You (it was the
        // Brief and four tabs): once, every install starts there.
        if !defaults.bool(forKey: "corres.migration.home.v1") {
            defaults.set("Needs You", forKey: "corres.mailFilter")
            defaults.set(true, forKey: "corres.migration.home.v1")
        }
        // The Unread tab became Unread Only, a filter on any split: someone
        // who was on Unread sees the same mail.
        if defaults.string(forKey: "corres.mailFilter") == MailFilter.unread.rawValue {
            defaults.set(MailFilter.everything.rawValue, forKey: "corres.mailFilter")
            defaults.set(true, forKey: MailFilter.unreadOnlyKey)
        }
        MailQuery.newSenderMode = newSenderMode
        InboxClassifier.vipAddresses = vips
        InboxClassifier.domainDecisions = domainRules
        InboxClassifier.sensitivity = sensitivity
        TimePhrase.morningHour = defaults.object(forKey: morningHourKey) as? Int ?? 8
        TimePhrase.laterTodayIsEvening = defaults.bool(forKey: laterTodayEveningKey)
    }

    // MARK: Tab bar

    /// Settings → Email Toolbar: the actions on the bar under an email, in
    /// order. The rest are in its ⋯ menu; Reply stays beside the bar.
    enum ReadingAction: String, CaseIterable, Identifiable {
        case archive = "Archive", trash = "Trash", flag = "Flag", snooze = "Snooze",
             unread = "Mark Unread", pin = "Pin", replyAll = "Reply All", forward = "Forward",
             moveTo = "Move to", labels = "Labels", spam = "Report Spam", block = "Block Sender",
             unsubscribe = "Unsubscribe", vip = "VIP", calendar = "Add to Calendar",
             share = "Share", print = "Print", translate = "Translate", mute = "Mute",
             reminder = "Add to Reminders"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .archive: "archivebox"
            case .trash: "trash"
            case .flag: "flag"
            case .snooze: "clock"
            case .unread: "envelope.badge"
            case .pin: "pin"
            case .replyAll: "arrowshape.turn.up.left.2"
            case .forward: "arrowshape.turn.up.right"
            case .moveTo: "arrow.up.and.down.text.horizontal"
            case .labels: "tag"
            case .spam: "xmark.bin"
            case .block: "hand.raised"
            case .unsubscribe: "envelope.badge.shield.half.filled"
            case .vip: "star"
            case .calendar: "calendar.badge.plus"
            case .share: "square.and.arrow.up"
            case .print: "printer"
            case .translate: "translate"
            case .mute: "bell.slash"
            case .reminder: "checklist"
            }
        }

        /// The name shown for it (rawValue is what's saved).
        var title: String {
            switch self {
            case .archive: String(localized: "Archive")
            case .trash: String(localized: "Trash")
            case .flag: String(localized: "Flag")
            case .snooze: String(localized: "Snooze")
            case .unread: String(localized: "Mark Unread")
            case .pin: String(localized: "Pin")
            case .replyAll: String(localized: "Reply All")
            case .forward: String(localized: "Forward")
            case .moveTo: String(localized: "Move to")
            case .labels: String(localized: "Labels")
            case .spam: String(localized: "Report Spam")
            case .block: String(localized: "Block Sender")
            case .unsubscribe: String(localized: "Unsubscribe")
            case .vip: String(localized: "VIP")
            case .calendar: String(localized: "Add to Calendar")
            case .share: String(localized: "Share")
            case .print: String(localized: "Print")
            case .translate: String(localized: "Translate")
            case .mute: String(localized: "Mute")
            case .reminder: String(localized: "Add to Reminders")
            }
        }

        /// What Voice Control answers to: the name shown, and the other
        /// words people say for it ("Delete" for Trash).
        func spokenNames(_ shown: String) -> [String] {
            let more: [String] = switch self {
            case .trash: [String(localized: "Trash"), String(localized: "Delete")]
            case .unread: [String(localized: "Unread"), String(localized: "Read")]
            case .snooze: [String(localized: "Snooze"), String(localized: "Later")]
            case .moveTo: [String(localized: "Move")]
            case .reminder: [String(localized: "Remind Me"), String(localized: "Reminder")]
            case .flag: [String(localized: "Flag")]
            default: []
            }
            return [shown] + more.filter { $0 != shown }
        }

        /// Grouped in Settings so the long list reads as kinds of action.
        var group: String {
            switch self {
            case .archive, .trash, .flag, .snooze, .unread, .pin: String(localized: "Everyday")
            case .replyAll, .forward, .share, .print: String(localized: "Send and Share")
            case .moveTo, .labels, .vip, .calendar, .translate, .mute, .reminder: String(localized: "Organize")
            case .spam, .block, .unsubscribe: String(localized: "Unwanted Mail")
            }
        }
    }

    static let readingBarKey = "corres.readingBar"
    static let defaultReadingBar: [ReadingAction] = [.archive, .trash, .flag, .snooze]
    /// More than this crowds the bar on the smallest iPhones.
    static let readingBarLimit = 5

    static func readingBar(from raw: String) -> [ReadingAction] {
        guard !raw.isEmpty else { return defaultReadingBar }
        if raw == "-" { return [] }
        var seen = Set<ReadingAction>()
        return Array(raw.split(separator: ",").compactMap { ReadingAction(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }.prefix(readingBarLimit))
    }

    /// "-" stands for an empty bar, so it isn't mistaken for the default.
    static func raw(for actions: [ReadingAction]) -> String {
        actions.isEmpty ? "-" : actions.map(\.rawValue).joined(separator: ",")
    }

    /// Settings → Customize → Press and Hold: the menu on an email in a
    /// list, saved as `RowMenuLayout` raw strings ("" is the default).
    static let rowMenuTopKey = "corres.rowMenu.top"
    static let rowMenuListKey = "corres.rowMenu.list"
    static func rowMenu(top: String, list: String) -> RowMenuLayout { RowMenuLayout(topRaw: top, listRaw: list) }
    static var rowMenu: RowMenuLayout {
        rowMenu(top: defaults.string(forKey: rowMenuTopKey) ?? "", list: defaults.string(forKey: rowMenuListKey) ?? "")
    }

    static let followUpDaysKey = "corres.followUpDays"
    static let followUpChoices = [1, 2, 3, 5, 7]
    static var followUpDays: Int { defaults.object(forKey: followUpDaysKey) as? Int ?? 3 }

    static func accountNotificationsKey(for account: String) -> String { "corres.notify.\(account.lowercased())" }
    static func notifies(for account: String) -> Bool {
        defaults.object(forKey: accountNotificationsKey(for: account)) as? Bool ?? true
    }

    /// Settings → Sorting → Daily Brief: the Today card at the top of Needs
    /// You. Off until turned on; follows you to your other devices.
    static let briefKey = "corres.dailyBrief"
    static var brief: Bool { defaults.bool(forKey: briefKey) }
    /// The day "Done for today" was tapped ("2026-10-25", this device's
    /// calendar): the card stays away until the next day.
    static let briefDoneDayKey = "corres.dailyBrief.doneDay"
    /// The card folded down to its header, on this device.
    static let briefCollapsedKey = "corres.dailyBrief.collapsed"

    /// Today as the Brief's done-day stamp, in this device's time zone.
    static func briefDay(_ date: Date = .now, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
