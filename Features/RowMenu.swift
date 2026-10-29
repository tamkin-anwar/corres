import SwiftUI

/// What the press-and-hold menu asked for that needs an answer first
/// (Block, Unsubscribe) or says how it went. The list keeps one and shows
/// them with `rowMenuDialogs`.
@MainActor @Observable
final class RowMenuRequests {
    var blocking: Correspondence?
    var unsubscribing: Correspondence?
    var unsubscribeFailed = false
    /// A forward whose attachments didn't all download, as in the
    /// conversation: said before Compose opens.
    var forwardMissing: (draft: Draft, missing: [String])?
    var reminderOutcome: MailReminders.Outcome?
}

/// Press and hold on an email in a list (Settings → Customize → Press and
/// Hold): a row of icons, then a short list, most used first, as Apple's
/// guidelines ask of a context menu and as Mail's own does. Select and
/// Open in New Window close it; Report Spam and Block Sender, when chosen,
/// sit apart in red.
struct RowMenu: View {
    let thread: Correspondence
    let layout: RowMenuLayout
    let store: MailStore
    let threadActions: ThreadActionService?
    var labelDirectory: LabelDirectory?
    var unsubscribeService: UnsubscribeService?
    let requests: RowMenuRequests
    /// Settings → Reading → Ask before moving to Trash, the list's own.
    let onTrash: (Correspondence) -> Void
    let onSnooze: (Correspondence) -> Void
    let onCategory: (CategoryChoice) -> Void
    let onSelect: () -> Void
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let top = layout.top.filter(applies)
        let list = layout.list.filter { applies($0) && !$0.isDestructive }
        let destructive = layout.list.filter { applies($0) && $0.isDestructive }
        if !top.isEmpty {
            // A row of icons across the top of the menu, as Mail's is. As a
            // plain group iOS fits three with names and moves a fourth to a
            // line of its own; as a palette all four fit, named for VoiceOver.
            if top.count > 3 {
                ControlGroup {
                    ForEach(top) { item($0) }
                }
                .controlGroupStyle(.palette)
            } else {
                ControlGroup {
                    ForEach(top) { item($0) }
                }
            }
        }
        if !list.isEmpty {
            Section {
                ForEach(list) { item($0) }
            }
        }
        if !destructive.isEmpty {
            Section {
                ForEach(destructive) { item($0) }
            }
        }
        Section {
            // Mail's "Select": starts Select with this conversation checked.
            Button(action: onSelect) {
                Label("Select", systemImage: "checkmark.circle")
            }
            // iPad: beside your mail, in a window of its own.
            if supportsMultipleWindows && sizeClass == .regular {
                Button {
                    openWindow(id: ConversationWindow.id, value: thread.id)
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }
        }
    }

    /// Whether it applies to this email; one that doesn't is left out.
    private func applies(_ action: RowMenuAction) -> Bool {
        let fromSomeoneElse = thread.senderEmail != nil && !thread.isFromAccountOwner
        switch action {
        case .vip, .block: return fromSomeoneElse
        case .spam: return !thread.isFromAccountOwner
        case .unsubscribe: return unsubscribeService?.canUnsubscribe(thread) == true && !thread.senderUnsubscribed
        // Only mail in Corres's own lists can be snoozed or pinned (an
        // archived search result can't), as in the conversation. Asked
        // here, as the menu opens, not each time a row is drawn.
        case .snooze, .pin: return store.isInLists(thread.id)
        default: return true
        }
    }

    @ViewBuilder
    private func item(_ action: RowMenuAction) -> some View {
        switch action {
        case .moveTo:
            Menu {
                moveToChoices
            } label: {
                Label("Move To", systemImage: action.systemImage)
            }
        case .reminder:
            // When to be reminded, as Mail's Remind Me offers.
            Menu {
                ForEach(Array(MailReminders.choices(for: thread).enumerated()), id: \.offset) { _, choice in
                    Button(choice.title) {
                        let thread = store.thread(thread.id) ?? thread
                        Task { requests.reminderOutcome = await MailReminders.add(thread, due: choice.date) }
                    }
                }
            } label: {
                Label("Add to Reminders", systemImage: action.systemImage)
            }
            .menuOrder(.fixed)
        default:
            let look = appearance(of: action)
            Button(role: action.isDestructive || action == .trash ? .destructive : nil) {
                perform(action)
            } label: {
                Label(look.title, systemImage: look.icon)
            }
        }
    }

    /// Its name and icon as it stands for this email ("Unflag" once flagged).
    private func appearance(of action: RowMenuAction) -> (title: String, icon: String) {
        switch action {
        case .read:
            thread.isUnread ? (String(localized: "Mark as Read"), "envelope.open") : (String(localized: "Mark as Unread"), "envelope.badge")
        case .flag:
            thread.isFlagged ? (String(localized: "Unflag"), "flag.slash") : (String(localized: "Flag"), "flag")
        case .pin:
            thread.isPinned ? (String(localized: "Unpin"), "pin.slash") : (String(localized: "Pin"), "pin")
        case .snooze:
            (String(localized: "Snooze…"), action.systemImage)
        case .mute:
            Organizer.shared.isMuted(thread.id) ? (String(localized: "Unmute"), "bell") : (String(localized: "Mute"), "bell.slash")
        case .vip:
            thread.senderEmail.map(InboxClassifier.isVIP) == true
                ? (String(localized: "Remove from VIPs"), "star.slash") : (String(localized: "Add to VIPs"), "star")
        default:
            (action.title, action.systemImage)
        }
    }

    private func perform(_ action: RowMenuAction) {
        // As it is now, not as it was when the row was drawn: read, flagged
        // or pinned may have changed since (opened, synced, swiped).
        let thread = store.thread(thread.id) ?? thread
        switch action {
        case .reply: compose(.reply, from: thread)
        case .replyAll: compose(.replyAll, from: thread)
        case .forward: compose(.forward, from: thread)
        case .archive: Task { await threadActions?.archive(thread) }
        case .trash: onTrash(thread)
        case .read: Task { await threadActions?.toggleUnread(!thread.isUnread, for: [thread]) }
        case .flag: Task { await threadActions?.toggleFlagged(!thread.isFlagged, for: [thread]) }
        case .snooze: onSnooze(thread)
        case .pin: Task { await threadActions?.togglePinned(thread) }
        case .mute:
            if Organizer.shared.isMuted(thread.id) { Organizer.shared.unmute(thread.id) } else { Organizer.shared.mute(thread) }
        case .vip:
            if let email = thread.senderEmail {
                Task { await store.setVIP(email, account: thread.id.account, isVIP: !InboxClassifier.isVIP(email)) }
            }
        case .unsubscribe: requests.unsubscribing = thread
        case .share:
            // The whole email, not the preview line.
            Task {
                if !thread.isBodyLoaded { await threadActions?.loadContent(for: thread) }
                ConversationView.share(store.thread(thread.id) ?? thread)
            }
        case .spam: Task { await threadActions?.reportSpam(thread) }
        case .block: requests.blocking = thread
        case .moveTo, .reminder: break // menus; see `item`
        }
    }

    /// Reply and Forward from the list open the same Compose a reply from
    /// Siri does (`AppRouter.Target.draft`), quoting the whole email.
    private func compose(_ kind: Draft.Kind, from thread: Correspondence) {
        Task {
            if !thread.isBodyLoaded { await threadActions?.loadContent(for: thread) }
            let source = store.thread(thread.id) ?? thread
            var draft = source.draft(kind: kind)
            // A forward carries the email's attachments, as in the conversation.
            if kind == .forward, !source.attachments.isEmpty {
                let (files, missing) = await source.attachmentsToForward()
                draft.attachments = files
                guard missing.isEmpty else {
                    requests.forwardMissing = (draft, missing)
                    return
                }
            }
            router.pending = .draft(draft)
        }
    }

    /// One level, as Apple asks of a context menu: Corres's own lists, the
    /// categories, then the account's Gmail labels or Outlook folders.
    @ViewBuilder
    private var moveToChoices: some View {
        Section {
            AttentionChoices(current: thread.attention) { attention in
                let thread = store.thread(thread.id) ?? thread
                Task { await threadActions?.setAttention(attention, for: thread) }
            }
        }
        Section {
            CategoryChoices(thread: thread, choose: onCategory)
        }
        // Places to move it: Gmail's labels, Outlook's folders (an Outlook
        // category is a tag, not a place).
        let labels = labelDirectory?.labels(for: thread.id.account).filter { !$0.isCategory } ?? []
        if !labels.isEmpty {
            Section(labels.contains(where: \.isFolder) ? "Folders" : "Labels") {
                ForEach(labels) { label in
                    Button {
                        let thread = store.thread(thread.id) ?? thread
                        Task { await threadActions?.moveToLabel(label.id, named: label.name.components(separatedBy: "/").last ?? label.name, thread) }
                    } label: {
                        Label(label.name, systemImage: label.isFolder ? "folder" : "tag")
                    }
                }
            }
        }
    }
}

/// The email lifted above the menu: who, what, a few lines of it, and
/// why Corres put it where it is.
struct RowMenuPreview: View {
    let thread: Correspondence
    var showsReason = false
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                if thread.isFromAccountOwner {
                    CorrespondentAvatar(initials: CorrespondenceRow.initials(of: thread.counterpartName()),
                                        email: thread.toRecipients.first, size: CGSize(width: 34, height: 34))
                } else {
                    CorrespondentAvatar(initials: thread.initials, email: thread.senderEmail,
                                        size: CGSize(width: 34, height: 34), companyLogo: thread.showsCompanyLogo)
                }
                Text(thread.isFromAccountOwner ? String(localized: "To: \(thread.counterpartName())") : thread.sender)
                    .font(.headline)
                    .foregroundStyle(CorresPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(CorrespondenceRow.timestamp(thread.receivedAt))
                    .font(.footnote).monospacedDigit()
                    .foregroundStyle(CorresPalette.tertiary)
            }
            Text(thread.subject)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CorresPalette.ink)
                .lineLimit(2)
                .padding(.top, 2)
            if showsReason, !thread.reason.isEmpty {
                ReasonLine(text: thread.displayReason, isIntelligence: thread.isIntelligenceReason)
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(CorresPalette.secondary)
                .lineLimit(5)
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(CorresPalette.surface)
    }

    /// More of the email than the row's line when it's loaded; the
    /// preview line when it isn't, rather than wait on the network.
    private var text: String {
        guard thread.isBodyLoaded, !thread.body.isEmpty else { return thread.excerpt }
        let lines = thread.body.prefix(700).split(separator: "\n").filter { !$0.hasPrefix(">") }
        let words = lines.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? thread.excerpt : words
    }
}

extension View {
    /// What the press-and-hold menu waits on an answer for, and how Add to
    /// Reminders went.
    func rowMenuDialogs(_ requests: RowMenuRequests, store: MailStore, unsubscribeService: UnsubscribeService?) -> some View {
        modifier(RowMenuDialogs(requests: requests, store: store, unsubscribeService: unsubscribeService))
    }
}

private struct RowMenuDialogs: ViewModifier {
    @Bindable var requests: RowMenuRequests
    let store: MailStore
    let unsubscribeService: UnsubscribeService?
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content
            .confirmationDialog(requests.blocking.map { String(localized: "Block \($0.sender)?") } ?? "",
                                isPresented: Binding(get: { requests.blocking != nil }, set: { if !$0 { requests.blocking = nil } }),
                                titleVisibility: .visible) {
                Button("Block", role: .destructive) {
                    if let blocked = requests.blocking, let email = blocked.senderEmail {
                        Task { await store.blockSender(email, account: blocked.id.account) }
                    }
                    requests.blocking = nil
                }
            } message: {
                Text("Their mail is hidden in Corres from now on, with no notice to them. Your email account isn't changed.")
            }
            .confirmationDialog(requests.unsubscribing.map { String(localized: "Unsubscribe from \($0.sender)?") } ?? "",
                                isPresented: Binding(get: { requests.unsubscribing != nil }, set: { if !$0 { requests.unsubscribing = nil } }),
                                titleVisibility: .visible) {
                Button("Unsubscribe", role: .destructive) {
                    if let thread = requests.unsubscribing, let unsubscribeService {
                        Task {
                            let outcome = await unsubscribeService.unsubscribe(from: thread, store: store)
                            // Said here, once, not also by a conversation
                            // open beside the list.
                            if outcome == .failed {
                                unsubscribeService.errorMessage = nil
                                requests.unsubscribeFailed = true
                            }
                        }
                    }
                    requests.unsubscribing = nil
                }
                Button("Cancel", role: .cancel) { requests.unsubscribing = nil }
            } message: {
                Text("You won't receive future mail from this sender. This can't be undone from Corres.")
            }
            .alert("Couldn't Unsubscribe", isPresented: $requests.unsubscribeFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Couldn't unsubscribe. Try again.")
            }
            .alert(requests.forwardMissing.map { $0.missing.count == 1 ? String(localized: "One attachment couldn't be added")
                       : String(localized: "\($0.missing.count) attachments couldn't be added") } ?? "",
                   isPresented: Binding(get: { requests.forwardMissing != nil }, set: { if !$0 { requests.forwardMissing = nil } })) {
                Button("Forward Without Them") {
                    if let pending = requests.forwardMissing { router.pending = .draft(pending.draft) }
                    requests.forwardMissing = nil
                }
                Button("Cancel", role: .cancel) { requests.forwardMissing = nil }
            } message: {
                Text(String(localized: "\(requests.forwardMissing?.missing.joined(separator: ", ") ?? ""). They may be too large to send on, or the connection dropped."))
            }
            .alert(requests.reminderOutcome == .added ? "Added to Reminders" : "Couldn't Add to Reminders",
                   isPresented: Binding(get: { requests.reminderOutcome != nil }, set: { if !$0 { requests.reminderOutcome = nil } })) {
                Button("OK", role: .cancel) { requests.reminderOutcome = nil }
            } message: {
                switch requests.reminderOutcome {
                case .notAllowed: Text("Corres doesn't have access to Reminders. You can allow it in Settings > Apps > Corres.")
                case .failed: Text("Reminders didn't save it. Try again.")
                default: Text("Tap the link in the reminder to come back to this email.")
                }
            }
            .sensoryFeedback(.success, trigger: requests.reminderOutcome) { _, new in new == .added }
    }
}
