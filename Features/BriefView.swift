import SwiftUI

struct BriefView: View {
    var scrolls = true
    let store: MailStore
    /// Optional: nil only for the offline preview-render script, which never
    /// exercises the scrolls==true/refreshable path that uses these.
    var sync: GmailSyncService?
    var auth: GoogleAuthService?
    @Binding var selection: Destination
    @Binding var showingScreener: Bool
    /// See `CorresShell`'s doc comment: nil merges every connected account,
    /// a specific email scopes the whole Brief to just that one.
    var accountFilter: String?
    @AppStorage(GoogleAuthService.givenNameKey) private var givenName = ""
    @Environment(\.conversationSelection) private var splitSelection

    private var scopedThreads: [Correspondence] {
        guard let accountFilter else { return store.threads }
        return store.threads.filter { $0.id.account == accountFilter }
    }
    private var snapshot: BriefSnapshot { BriefSnapshot(threads: scopedThreads, now: .now) }
    private var priorities: [Correspondence] { MailQuery.prioritized(scopedThreads, attention: .needsYou) }
    private var waiting: [Correspondence] { MailQuery.prioritized(scopedThreads, attention: .waiting) }
    private var pendingSenderCount: Int {
        let pending = accountFilter == nil ? store.pendingSenderThreads : store.pendingSenderThreads.filter { $0.id.account == accountFilter }
        return Set(pending.compactMap(\.senderEmail)).count
    }
    private var isConnected: Bool { !(auth?.accounts.isEmpty ?? true) }

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
                let name = Self.firstName(thread.sender)
                let reason = thread.reason.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
                // Reasons often already lead with the person ("Maya asked
                // you…"); bold that name in place instead of repeating it.
                if reason.lowercased().hasPrefix(name.lowercased() + " ") {
                    strong(String(reason.prefix(name.count)))
                    plain(String(reason.dropFirst(name.count)) + ".")
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
                strong(Self.firstName(overdue.sender))
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
                    if index < shown.count - 1 { Hairline(leading: 77) }
                }
            }
            .padding(.vertical, 4)
            .corresSurface()
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
                         title: pendingSenderCount == 1 ? "1 new sender to approve" : "\(pendingSenderCount) new senders to approve",
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
        let unread = MailQuery.filter(scopedThreads).filter(\.isUnread).count
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
                          : "Fictional mail. Connect Gmail in Settings when you're ready.",
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
