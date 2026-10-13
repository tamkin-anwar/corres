import SwiftUI

struct BriefView: View {
    var scrolls = true
    let store: MailStore
    /// Optional: nil only for the offline preview-render script, which never
    /// exercises the scrolls==true/refreshable path that uses these.
    var sync: GmailSyncService?
    var auth: GoogleAuthService?
    /// For the Needs You rows' swipes (Handled, Archive, and the Mail list's
    /// right-hand swipes).
    var threadActions: ThreadActionService?
    @AppStorage("corres.leadingShortSwipeAction") private var leadingShortRaw = LeadingSwipeAction.pin.rawValue
    @AppStorage("corres.leadingLongSwipeAction") private var leadingLongRaw = LeadingSwipeAction.unread.rawValue
    @Binding var selection: Destination
    @Binding var showingScreener: Bool
    /// See `CorresShell`'s doc comment: nil merges every connected account,
    /// a specific email scopes the whole Brief to just that one.
    var accountFilter: String?
    /// False while another tab is showing: the Brief keeps what it last
    /// showed instead of rebuilding behind the tab you're using, and
    /// catches up the moment it's shown again.
    var isActive = true
    @AppStorage(GoogleAuthService.givenNameKey) private var givenName = ""
    /// Redraws when an account is renamed, recoloured or hidden from All Inboxes.
    @AppStorage(AccountPreferences.revisionKey) private var accountsRevision = 0
    @AppStorage(CorresSettings.showAvatarsKey) private var showAvatars = true
    @Environment(\.conversationSelection) private var splitSelection

    /// What the Brief shows, built once per change to the mail. The Brief
    /// stays alive behind the other tabs, and it read these about fifteen
    /// times per redraw, each a filter and sort of the whole mailbox, so
    /// every archive or pin in Mail paid for it too.
    private final class Digest {
        /// The minute too, so due times and snoozes still move on their own.
        var key: (revision: Int, minute: Int, account: String?, accounts: Int)?
        var snapshot = BriefSnapshot(threads: [], now: .now)
        var priorities: [Correspondence] = []
        var waiting: [Correspondence] = []
        var unread = 0
    }
    @State private var digestCache = Digest()

    private var digest: Digest {
        let cache = digestCache
        if !isActive, cache.key != nil { return cache }
        let minute = Int(Date.now.timeIntervalSince1970 / 60)
        if let key = cache.key, key.revision == store.revision, key.minute == minute, key.account == accountFilter,
           key.accounts == AccountPreferences.revision {
            return cache
        }
        let scoped = AccountPreferences.scope(store.threads, account: accountFilter, all: auth?.accounts.map(\.email) ?? [], by: \.id.account)
        cache.key = (store.revision, minute, accountFilter, AccountPreferences.revision)
        cache.snapshot = BriefSnapshot(threads: scoped, now: .now)
        cache.priorities = MailQuery.prioritized(scoped, attention: .needsYou)
        cache.waiting = MailQuery.prioritized(scoped, attention: .waiting)
        cache.unread = MailQuery.filter(scoped).reduce(0) { $0 + ($1.isUnread ? 1 : 0) }
        return cache
    }
    private var snapshot: BriefSnapshot { digest.snapshot }
    private var priorities: [Correspondence] { digest.priorities }
    private var waiting: [Correspondence] { digest.waiting }
    private var pendingSenderCount: Int {
        let pending = AccountPreferences.scope(store.pendingSenderThreads, account: accountFilter, all: auth?.accounts.map(\.email) ?? [], by: \.id.account)
        return Set(pending.compactMap(\.senderEmail)).count
    }
    /// Real mail on screen counts too: accounts are restored a moment after
    /// launch, and the Brief shouldn't flash "Sample" over your own mail.
    private var isConnected: Bool {
        !(auth?.accounts.isEmpty ?? true) || store.threads.contains { $0.id.account != "sample" }
    }

    var body: some View {
        if scrolls {
            ScrollView { content }
                .scrollIndicators(.hidden)
                .refreshable {
                    _ = await sync?.syncAll(accounts: auth?.accounts.map(\.email) ?? [])
                    await store.load()
                }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            briefCard
            if !priorities.isEmpty { needsYouSection }
            followUpCard
            privacyNote
        }
        .padding(.horizontal, CorresSpace.page).padding(.top, 8).padding(.bottom, 32)
        .readableWidth()
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day()).eyebrow()
                if !isConnected {
                    Text("Sample").eyebrow(CorresPalette.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(CorresPalette.accent.opacity(0.5), lineWidth: 1))
                }
            }
            Text(greeting)
                .font(CorresType.display)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 2)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        return givenName.isEmpty ? "\(part)." : "\(part), \(givenName)."
    }

    // MARK: - Brief

    private var briefCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Your brief", systemImage: "sparkle")
                    .labelStyle(TightLabelStyle())
                    .eyebrow(CorresPalette.accent)
                Spacer(minLength: 8)
                Text(isConnected ? "On this iPhone" : "Sample mail")
                    .font(.caption).foregroundStyle(CorresPalette.tertiary)
            }
            Text(briefSentence)
                .font(CorresType.brief)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .corresSurface()
    }

    /// Built from the same counts and reasons the lists use, so the Brief
    /// can never claim something the Needs You list doesn't show.
    private var briefSentence: AttributedString {
        var text = AttributedString()
        func plain(_ string: String) { text += AttributedString(string) }
        func strong(_ string: String) {
            var part = AttributedString(string)
            part.font = .system(.title3, design: .serif, weight: .semibold)
            text += part
        }
        let count = snapshot.needsYou
        if count == 0 {
            plain("Nothing is in Needs You right now.")
        } else {
            plain("\(Self.spelled(count).capitalized) \(count == 1 ? "conversation needs" : "conversations need") you")
            plain(snapshot.upcoming > 0 ? ", \(Self.spelled(snapshot.upcoming)) due within a day. " : ". ")
            let top = Array(priorities.prefix(2))
            for (index, thread) in top.enumerated() {
                if index == 1 { plain(" ") }
                // The full name: a first name alone is ambiguous at any
                // workplace with several Jacks (tester feedback).
                let name = thread.sender
                let first = Self.firstName(thread.sender)
                let reason = thread.reason.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
                // Reasons often already lead with the person ("Maya asked
                // you…"): the full name in its place, not said twice.
                if reason.lowercased().hasPrefix(name.lowercased() + " ") {
                    strong(name)
                    plain(String(reason.dropFirst(name.count)) + ".")
                } else if reason.lowercased().hasPrefix(first.lowercased() + " ") {
                    strong(name)
                    plain(String(reason.dropFirst(first.count)) + ".")
                } else {
                    strong(name)
                    plain(": \(Self.sentenceCase(reason)).")
                }
            }
        }
        if !waiting.isEmpty {
            plain(" You're waiting on \(Self.spelled(waiting.count)) \(waiting.count == 1 ? "reply" : "replies")")
            // Name whoever has gone quiet longest, once it's worth a nudge.
            if let overdue = waiting.min(by: { $0.waitingReference < $1.waitingReference }),
               let days = Calendar.current.dateComponents([.day], from: overdue.waitingReference, to: .now).day,
               days >= WaitChip.followUpAfterDays {
                plain("; ")
                // Who you're waiting on, not the sender of your own message.
                strong(overdue.counterpartName(knownNames: Correspondence.knownSenderNames(store.threads)))
                plain(" hasn't replied in \(Self.spelled(days)) days.")
            } else {
                plain(".")
            }
        }
        return text
    }

    // MARK: - Needs You

    private var needsYouSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Needs You").eyebrow()
                Spacer(minLength: 8)
                if priorities.count > 3 {
                    Button("All \(priorities.count)") { selection = .needsYou }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CorresPalette.accent)
                        .frame(minHeight: 44)
                } else {
                    Color.clear.frame(width: 1, height: 30)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, -8)
            VStack(spacing: 0) {
                let shown = Array(priorities.prefix(3))
                let orderedIDs = shown.map(\.id)
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, thread in
                    let route = ConversationRoute(id: thread.id, orderedIDs: orderedIDs)
                    // Real swipes, like the Mail list: a sideways drag on a
                    // plain button ended as a tap and opened the email.
                    // Left: Handled (out of Needs You, still in Mail), or
                    // Archive further; right: the Mail list's own swipes.
                    PremiumSwipeRow(
                        leadingShort: leadingVisual(for: leadingShort, thread: thread),
                        leadingLong: leadingVisual(for: leadingLong, thread: thread),
                        trailingShort: SwipeVisual(title: "Handled", systemImage: "checkmark.circle.fill",
                                                   tint: CorresPalette.swipeHandled, removesRow: true),
                        trailingLong: SwipeVisual(title: "Archive", systemImage: "archivebox.fill",
                                                  tint: CorresPalette.swipeArchive, removesRow: true),
                        onLeadingShort: { perform(leadingShort, on: thread) },
                        onLeadingLong: { perform(leadingLong, on: thread) },
                        onTrailingShort: { markHandled(thread) },
                        onTrailingLong: { Task { await threadActions?.archive(thread) } }
                    ) {
                        if let splitSelection {
                            Button { splitSelection.wrappedValue = route } label: {
                                CorrespondenceRow(thread: thread, showsReason: true)
                                    .background(splitSelection.wrappedValue == route ? CorresPalette.accent.opacity(0.12) : .clear)
                            }
                            .buttonStyle(CorresRowButtonStyle())
                        } else {
                            NavigationLink(value: route) {
                                CorrespondenceRow(thread: thread, showsReason: true)
                            }
                            .buttonStyle(CorresRowButtonStyle())
                        }
                    }
                    .contextMenu {
                        Button { markHandled(thread) } label: { Label("Handled", systemImage: "checkmark.circle") }
                        Button { Task { await threadActions?.archive(thread) } } label: { Label("Archive", systemImage: "archivebox") }
                    }
                    if index < shown.count - 1 { Hairline(leading: showAvatars ? 77 : 25) }
                }
            }
            .padding(.vertical, 4)
            // A swipe's colour stays inside the card's corners, start to finish.
            .clipShape(RoundedRectangle(cornerRadius: CorresSpace.radius, style: .continuous))
            .corresSurface()
        }
    }

    private var leadingShort: LeadingSwipeAction { LeadingSwipeAction(rawValue: leadingShortRaw) ?? .pin }
    private var leadingLong: LeadingSwipeAction { LeadingSwipeAction(rawValue: leadingLongRaw) ?? .unread }

    /// Out of Needs You, still in Mail: for what you've dealt with or
    /// decided to leave. The row leaves as the swipe lands.
    private func markHandled(_ thread: Correspondence) {
        withAnimation(.snappy(duration: 0.3)) { store.hide(thread.id) }
        Task {
            await threadActions?.setAttention(.handled, for: thread)
            store.unhide(thread.id)
        }
    }

    private func leadingVisual(for action: LeadingSwipeAction, thread: Correspondence) -> SwipeVisual {
        switch action {
        case .pin:
            SwipeVisual(title: thread.isPinned ? "Unpin" : "Pin",
                        systemImage: thread.isPinned ? "pin.slash.fill" : "pin.fill", tint: CorresPalette.swipePin)
        case .unread:
            SwipeVisual(title: thread.isUnread ? "Read" : "Unread",
                        systemImage: thread.isUnread ? "envelope.open.fill" : "envelope.badge.fill",
                        tint: CorresPalette.swipeUnread)
        case .flag:
            SwipeVisual(title: thread.isFlagged ? "Unflag" : "Flag",
                        systemImage: thread.isFlagged ? "flag.slash.fill" : "flag.fill", tint: CorresPalette.swipeFlag)
        }
    }

    private func perform(_ action: LeadingSwipeAction, on thread: Correspondence) {
        switch action {
        case .pin: Task { await threadActions?.togglePinned(thread) }
        case .unread: Task { await threadActions?.toggleUnread(!thread.isUnread, for: [thread]) }
        case .flag: Task { await threadActions?.toggleFlagged(!thread.isFlagged, for: [thread]) }
        }
    }

    // MARK: - Follow-ups

    private var followUpCard: some View {
        VStack(spacing: 0) {
            briefRow(icon: "clock",
                     title: waiting.isEmpty ? "Nothing in Waiting" : "\(waiting.count) waiting on a reply",
                     detail: longestWait) { selection = .waiting }
            if pendingSenderCount > 0 {
                Hairline(leading: 52)
                briefRow(icon: "checkmark.shield",
                         title: "\(pendingSenderCount == 1 ? "1 new sender" : "\(pendingSenderCount) new senders") \(MailQuery.holdsNewSenders ? "to approve" : "to review")",
                         detail: nil) { showingScreener = true }
            }
            Hairline(leading: 52)
            briefRow(icon: "tray", title: "All mail", detail: unreadDetail) { selection = .mail }
        }
        .corresSurface()
    }

    private var longestWait: String? {
        guard let oldest = waiting.map(\.waitingReference).min() else { return nil }
        let days = Calendar.current.dateComponents([.day], from: oldest, to: .now).day ?? 0
        return days < 1 ? "Since today" : "Longest \(days) \(days == 1 ? "day" : "days")"
    }

    private var unreadDetail: String? {
        let unread = digest.unread
        return unread == 0 ? nil : "\(unread) unread"
    }

    private func briefRow(icon: String, title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(CorresPalette.secondary)
                    .frame(width: 24)
                Text(title).foregroundStyle(CorresPalette.ink)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CorresPalette.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(CorresRowButtonStyle())
    }

    private var privacyNote: some View {
        Label(isConnected ? "Sorted on this iPhone. Corres doesn't send your mail to its own servers or to an AI service."
                          : "Fictional mail. Connect Gmail or Outlook in Settings when you're ready.",
              systemImage: "lock")
            .labelStyle(TightLabelStyle())
            .font(.footnote)
            .foregroundStyle(CorresPalette.tertiary)
            .padding(.horizontal, 4)
    }

    // MARK: - Language

    private static func spelled(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        return number <= 10 ? (formatter.string(from: NSNumber(value: number)) ?? "\(number)") : "\(number)"
    }

    private static func firstName(_ sender: String) -> String {
        let name = sender.trimmingCharacters(in: .whitespaces)
        // Organizations ("American Express") read better whole.
        guard let first = name.split(separator: " ").first, name.split(separator: " ").count == 2 else { return name }
        return String(first)
    }

    private static func sentenceCase(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        guard let first = trimmed.first else { return trimmed }
        return first.lowercased() + trimmed.dropFirst()
    }
}
