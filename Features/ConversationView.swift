import QuickLook
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
    let threadActions: ThreadActionService
    let labelDirectory: LabelDirectory
    let orderedIDs: [ThreadID]
    @State private var currentID: ThreadID
    @State private var composeDraft: Draft?
    @State private var htmlHeight: CGFloat = 200
    @State private var showRemoteImages = false
    @Environment(\.dismiss) private var dismiss

    init(store: MailStore, outbox: OutboxService, threadActions: ThreadActionService,
        labelDirectory: LabelDirectory, route: ConversationRoute) {
        self.store = store
        self.outbox = outbox
        self.threadActions = threadActions
        self.labelDirectory = labelDirectory
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
                        let knownLabels = thread.labelIds.compactMap { id in
                            labelDirectory.labels.first { $0.id == id }
                        }
                        if !knownLabels.isEmpty {
                            labelChips(knownLabels).padding(.horizontal, CorresSpace.page)
                        }
                        if let html = thread.htmlBody {
                            let blockedCount = HTMLMessageBody.remoteImageCount(in: html)
                            if blockedCount > 0 && !showRemoteImages && !thread.imagesTrusted {
                                remoteImagesBanner(count: blockedCount, thread: thread).padding(.horizontal, CorresSpace.page)
                            }
                            // Full width, no card: real HTML mail is a
                            // fixed-width table (often 600pt), and wrapping
                            // it in padding narrow enough to clip that table
                            // is what made images/text run off-screen before
                            // (see Docs/Verification.md). Mail and Spark both
                            // render the body edge to edge for this reason.
                            HTMLMessageBody(html: html, height: $htmlHeight,
                                            blockRemoteImages: !(showRemoteImages || thread.imagesTrusted))
                                .frame(height: htmlHeight)
                        } else {
                            Text(thread.body).font(.body).lineSpacing(8).textSelection(.enabled)
                                .padding(.horizontal, CorresSpace.page)
                        }
                        if !thread.attachments.isEmpty, let messageID = thread.latestMessageID {
                            attachmentsList(thread.attachments, messageID: messageID)
                                .padding(.horizontal, CorresSpace.page)
                        }
                        Text(isSample ? "No AI processing. Replying, forwarding, and sending stay on this device until Gmail is connected."
                                      : "No AI processing. Replying, replying all, and forwarding send for real through Gmail.")
                            .font(.caption).foregroundStyle(CorresPalette.secondary)
                            .padding(.horizontal, CorresSpace.page).padding(.top, 4)
                    }
                    .padding(.vertical, CorresSpace.page)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(maxWidth: 680)
                }
                .safeAreaInset(edge: .bottom) { actionBar(for: thread) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 4) {
                            Button { goToPrevious() } label: {
                                Image(systemName: "chevron.up").frame(minWidth: 44, minHeight: 44)
                            }
                            .disabled(!hasPrevious)
                            .accessibilityLabel("Previous conversation")
                            Button { goToNext() } label: {
                                Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 44)
                            }
                            .disabled(!hasNext)
                            .accessibilityLabel("Next conversation")
                        }
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
        // Opening a conversation is itself the signal that it's been seen,
        // the same behavior every real mail client already has; without
        // this, isUnread would only ever change via an explicit swipe/tap,
        // which is not what "mark as read" means to anyone using a mail app.
        .task(id: currentID) {
            if let thread = store.threads.first(where: { $0.id == currentID }), thread.isUnread {
                await threadActions.setUnread(false, for: thread)
            }
        }
        .onChange(of: threadExists) { _, stillExists in
            // Archiving or trashing from inside the conversation itself
            // removes it from `store.threads` right under this view; pop
            // back to the list rather than leaving "Conversation
            // unavailable" as a dead end the person has to back out of
            // manually.
            if !stillExists { dismiss() }
        }
    }

    private var threadExists: Bool { store.threads.contains { $0.id == currentID } }

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
                CorrespondentAvatar(initials: thread.initials, size: CGSize(width: 34, height: 34))
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

    private func labelChips(_ labels: [GmailUserLabel]) -> some View {
        // A flowing wrap would be nicer for many labels, but a horizontal
        // scroll matches what's already the established pattern elsewhere in
        // this view (the action bar itself) and is simpler than SwiftUI's
        // lack of a built-in flow layout pre-iOS 17's own primitives.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(labels) { label in
                    Text(label.name).font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(CorresPalette.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(CorresPalette.line, lineWidth: 0.5))
                }
            }
        }
    }

    private func attachmentsList(_ attachments: [MailAttachment], messageID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                AttachmentRow(attachment: attachment, messageID: messageID)
            }
        }
    }

    /// Showing images also remembers the sender (`MailStore.trustSenderImages`),
    /// so a newsletter you've already decided to trust never needs a repeat
    /// tap: the smaller, no-infrastructure alternative to Apple's own Mail
    /// Privacy Protection relay (see Docs/Architecture.md). One tap, not a
    /// separate "always" affordance, matching what was actually proposed and
    /// agreed on rather than adding a second control nobody asked for.
    private func remoteImagesBanner(count: Int, thread: Correspondence) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").accessibilityHidden(true)
            Text(count == 1 ? "1 image blocked" : "\(count) images blocked")
                .font(.footnote).foregroundStyle(CorresPalette.secondary)
            Spacer()
            Button("Show Images") {
                showRemoteImages = true
                if let senderEmail = thread.senderEmail {
                    Task { await store.trustSenderImages(senderEmail, account: thread.id.account) }
                }
            }
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
            if !labelDirectory.labels.isEmpty {
                Menu {
                    ForEach(labelDirectory.labels) { label in
                        let isOn = thread.labelIds.contains(label.id)
                        Button {
                            Task { await threadActions.toggleLabel(label.id, isOn: !isOn, for: thread) }
                        } label: {
                            if isOn {
                                Label(label.name, systemImage: "checkmark")
                            } else {
                                Text(label.name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "bookmark").frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Labels")
            }
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
            Button { Task { await threadActions.setUnread(!thread.isUnread, for: thread) } } label: {
                Image(systemName: thread.isUnread ? "envelope.open" : "envelope.badge")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel(thread.isUnread ? "Mark as Read" : "Mark as Unread")
            Button { Task { await threadActions.archive(thread) } } label: {
                Image(systemName: "archivebox").frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Archive")
            Button(role: .destructive) { Task { await threadActions.trash(thread) } } label: {
                Image(systemName: "trash").frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Move to Trash")
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

/// A tap downloads the attachment's bytes on demand (they are never fetched
/// during sync, see `Correspondence.attachments`) and hands them to iOS's
/// own QuickLook preview, matching Mail.app's own attachment-tap behavior:
/// preview inline, with saving/sharing already built into that preview's
/// own toolbar, rather than Corres inventing a separate save/share flow.
private struct AttachmentRow: View {
    let attachment: MailAttachment
    let messageID: String
    @State private var isDownloading = false
    @State private var previewURL: URL?
    @State private var downloadFailed = false
    private let client = GmailAPIClient()

    var body: some View {
        Button {
            Task { await download() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "paperclip").foregroundStyle(CorresPalette.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename).font(.footnote.weight(.medium)).lineLimit(1)
                    Text(formattedSize).font(.caption2).foregroundStyle(CorresPalette.secondary)
                }
                Spacer(minLength: 8)
                if isDownloading {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(CorresPalette.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(CorresPalette.line, lineWidth: 0.5))
        }
        .disabled(isDownloading)
        .buttonStyle(.plain)
        .quickLookPreview($previewURL)
        .alert("Could not download this attachment", isPresented: $downloadFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("Please try again.") }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.sizeBytes), countStyle: .file)
    }

    private func download() async {
        isDownloading = true
        defer { isDownloading = false }
        do {
            let data = try await client.fetchAttachmentData(messageId: messageID, attachmentId: attachment.id)
            // A fresh, uniquely-named subdirectory per download: two
            // attachments sharing a filename (common with "image.png") must
            // not silently overwrite each other's temp file.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(attachment.filename)
            try data.write(to: url)
            previewURL = url
        } catch {
            downloadFailed = true
        }
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
