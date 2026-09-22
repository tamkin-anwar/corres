import SwiftUI

/// A conversation plus the ordered list of ids it was opened from (a Brief
/// card, a filtered Mail list, a search result), so paging to the next/
/// previous message stays inside whatever the person was actually looking
/// at rather than jumping into an unrelated global order.
struct ConversationRoute: Hashable {
    let id: ThreadID
    let orderedIDs: [ThreadID]
}

struct ConversationView: View {
    let store: MailStore
    let outbox: OutboxService
    let orderedIDs: [ThreadID]
    @State private var currentID: ThreadID
    @State private var composeDraft: Draft?
    @State private var htmlHeight: CGFloat = 200
    @State private var showRemoteImages = false

    init(store: MailStore, outbox: OutboxService, route: ConversationRoute) {
        self.store = store
        self.outbox = outbox
        self.orderedIDs = route.orderedIDs
        self._currentID = State(initialValue: route.id)
    }

    var body: some View {
        Group {
            if let thread = store.threads.first(where: { $0.id == currentID }) {
                let isSample = thread.id.account == "sample"
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(thread.subject).font(.system(.title2, design: .serif).weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, CorresSpace.page)
                        messageHeader(for: thread, isSample: isSample)
                            .padding(.horizontal, CorresSpace.page)
                        if let html = thread.htmlBody {
                            let blockedCount = HTMLMessageBody.remoteImageCount(in: html)
                            if blockedCount > 0 && !showRemoteImages {
                                remoteImagesBanner(count: blockedCount).padding(.horizontal, CorresSpace.page)
                            }
                            // Full width, no card: real HTML mail is a
                            // fixed-width table (often 600pt), and wrapping
                            // it in padding narrow enough to clip that table
                            // is what made images/text run off-screen before
                            // (see Docs/Verification.md). Mail and Spark both
                            // render the body edge to edge for this reason.
                            HTMLMessageBody(html: html, height: $htmlHeight, blockRemoteImages: !showRemoteImages)
                                .frame(height: htmlHeight)
                        } else {
                            Text(thread.body).font(.body).lineSpacing(8).textSelection(.enabled)
                                .padding(.horizontal, CorresSpace.page)
                        }
                        Text(isSample ? "No AI processing. Replying, forwarding, and sending stay on this device until Gmail is connected."
                                      : "No AI processing. Replying, replying all, and forwarding send for real through Gmail.")
                            .font(.caption).foregroundStyle(CorresPalette.secondary)
                            .padding(.horizontal, CorresSpace.page).padding(.top, 4)
                    }
                    .padding(.vertical, CorresSpace.page)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom) { actionBar(for: thread) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 4) {
                            Button { goToPrevious() } label: { Image(systemName: "chevron.up") }
                                .disabled(!hasPrevious)
                                .accessibilityLabel("Previous conversation")
                            Button { goToNext() } label: { Image(systemName: "chevron.down") }
                                .disabled(!hasNext)
                                .accessibilityLabel("Next conversation")
                        }
                        .frame(minHeight: 44)
                    }
                }
            } else {
                ContentUnavailableView("Conversation unavailable", systemImage: "text.bubble")
            }
        }
        .background(CorresPalette.canvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $composeDraft) { draft in
            ComposeView(store: store, outbox: outbox, draft: draft,
                        sourceThread: store.threads.first(where: { $0.id == currentID }))
        }
        .onChange(of: currentID) { htmlHeight = 200 }
    }

    private var currentIndex: Int? { orderedIDs.firstIndex(of: currentID) }
    private var hasPrevious: Bool { (currentIndex ?? 0) > 0 }
    private var hasNext: Bool { let i = currentIndex ?? orderedIDs.count - 1; return i < orderedIDs.count - 1 }
    private func goToPrevious() { if let i = currentIndex, i > 0 { currentID = orderedIDs[i - 1] } }
    private func goToNext() { if let i = currentIndex, i < orderedIDs.count - 1 { currentID = orderedIDs[i + 1] } }

    /// A single compact row (avatar, sender, time) instead of the previous
    /// stacked avatar/name/organization/date block, matching how Mail packs
    /// this information into one line above the body.
    private func messageHeader(for thread: Correspondence, isSample: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                CorrespondentAvatar(initials: thread.initials).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.sender).font(.subheadline.weight(.semibold))
                    Text(thread.organization).font(.caption).foregroundStyle(CorresPalette.secondary)
                }
                Spacer(minLength: 8)
                Text(thread.receivedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(CorresPalette.secondary)
            }
            Label(evidenceLine(for: thread), systemImage: "text.bubble")
                .font(.caption).foregroundStyle(CorresPalette.secondary)
        }
    }

    private func evidenceLine(for thread: Correspondence) -> String {
        "\(thread.attention.title): \(thread.reason)"
    }

    private func remoteImagesBanner(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").accessibilityHidden(true)
            Text(count == 1 ? "1 image blocked" : "\(count) images blocked")
                .font(.footnote).foregroundStyle(CorresPalette.secondary)
            Spacer()
            Button("Show Images") { showRemoteImages = true }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CorresPalette.line, lineWidth: 0.5))
    }

    /// Icon-only, matching Mail/Spark's compact bottom toolbar rather than a
    /// full-width labeled button bar. Mark-as/pin/snooze (previously a large
    /// standalone card in the scrolling body) move here as menus; they are
    /// also always reachable via swipe actions on the Mail list, so nothing
    /// here is the only way to reach them.
    private func actionBar(for thread: Correspondence) -> some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(Attention.allCases, id: \.self) { attention in
                    Button {
                        Task { await store.update(thread.id, to: attention) }
                    } label: {
                        if thread.attention == attention {
                            Label(attention.title, systemImage: "checkmark")
                        } else {
                            Text(attention.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "tag").frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Mark as")
            Button {
                Task { await store.setPinned(!thread.isPinned, for: thread.id) }
            } label: {
                Image(systemName: thread.isPinned ? "pin.fill" : "pin").frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel(thread.isPinned ? "Unpin" : "Pin")
            Menu {
                ForEach(SnoozeOption.allCases, id: \.self) { option in
                    Button(option.title) { Task { await store.snooze(thread.id, until: option.date()) } }
                }
            } label: {
                Image(systemName: "moon").frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Snooze")
            Divider().frame(height: 24)
            Button { composeDraft = thread.draft(kind: .reply) } label: {
                Image(systemName: "arrowshape.turn.up.left").frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Reply")
            Button { composeDraft = thread.draft(kind: .replyAll) } label: {
                Image(systemName: "arrowshape.turn.up.left.2").frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Reply All")
            Button { composeDraft = thread.draft(kind: .forward) } label: {
                Image(systemName: "arrowshape.turn.up.right").frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Forward")
        }
        .font(.body)
        .disabled(store.pending.contains(thread.id))
        .padding(.horizontal, CorresSpace.medium)
        .background(.bar)
    }
}

enum SnoozeOption: CaseIterable {
    case laterToday, tomorrow, nextWeek

    var title: String {
        switch self {
        case .laterToday: "Later today"
        case .tomorrow: "Tomorrow morning"
        case .nextWeek: "Next week"
        }
    }

    func date(from now: Date = .now) -> Date {
        let calendar = Calendar.current
        switch self {
        case .laterToday:
            return calendar.date(byAdding: .hour, value: 3, to: now) ?? now
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .nextWeek:
            return calendar.date(byAdding: .day, value: 7, to: now) ?? now
        }
    }
}
