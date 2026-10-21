import QuickLook
import SwiftUI

/// The open conversation: subject in New York, who it's from and to, why
/// it's where it is (with one click to change that), the summary when
/// Apple Intelligence is on this Mac, and the email itself, edge to edge,
/// scrolling as one page.
struct ReadingPane: View {
    let thread: Correspondence
    let services: MacServices
    var onReply: (Draft.Kind) -> Void

    @State private var bodyHeight: CGFloat = 1
    @State private var showImages = false
    @State private var showEarlier = false
    @State private var invitation: Invitation?
    @State private var personCard: PersonRef?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    private var intelligence: MailIntelligence { services.intelligence }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 14)
                    .sheet(item: $personCard) { personSheet($0) }
                statusCard
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
                if !thread.isFromAccountOwner, thread.attention != .handled, Scheduling.asksForTime(thread.body) {
                    suggestTimes
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                }
                // An invitation: answered here, as in Calendar.
                if let invitation, !thread.isFromAccountOwner {
                    InvitationCard(invitation: invitation, senderEmail: thread.senderEmail, senderName: thread.sender) { response in
                        Task { await services.outbox.sendNow(InvitationCard.reply(response, to: invitation, in: thread), replyingTo: thread) }
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
                }
                if let earlier = earlierMessages, !earlier.isEmpty {
                    earlierSection(earlier)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 10)
                }
                if blockedImages > 0 && !imagesAllowed {
                    imagesNotice
                        .padding(.horizontal, 28)
                        .padding(.bottom, 10)
                }
                if services.unsubscribeService.canUnsubscribe(thread), !thread.senderUnsubscribed {
                    unsubscribeLine
                        .padding(.horizontal, 28)
                        .padding(.bottom, 10)
                }
                Divider().padding(.horizontal, 28)
                HTMLMessageBody(html: html, height: $bodyHeight, blockRemoteImages: !imagesAllowed)
                    .frame(height: bodyHeight)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                if !thread.isBodyLoaded, services.threadActions.contentFailures.contains(thread.id) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                        Text("Couldn't load the full message.")
                        Button("Try Again") { Task { await services.threadActions.loadContent(for: thread) } }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 10)
                }
                if !thread.attachments.isEmpty {
                    attachments
                        .padding(.horizontal, 28)
                        .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(CorresPalette.canvas)
        .id(thread.id)
        .task(id: thread.id) { await opened() }
        .userActivity(Handoff.conversation) { activity in Handoff.describe(activity, thread) }
    }

    // MARK: Header

    /// "When are you free?": three open times from your calendar, in a
    /// reply to change before sending. Read on this Mac, only on a click.
    private var suggestTimes: some View {
        Button {
            Task {
                let calendar = CalendarAccess.shared
                if !calendar.canRead { await calendar.requestRead() }
                guard calendar.canRead else { return }
                let now = Date.now
                let slots = Scheduling.freeSlots(busy: calendar.busy(from: now, to: now.addingTimeInterval(8 * 86_400)), from: now)
                guard !slots.isEmpty else { return }
                let times = slots.map {
                    "• " + $0.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute().timeZone(.specificName(.short)))
                }.joined(separator: "\n")
                var draft = thread.draft(kind: .reply)
                draft.body = String(localized: "Here are a few times that work for me:\n\n\(times)\n\nDo any of these suit you?") + "\n\n" + draft.body
                let handoff = UUID()
                MacComposeHandoff.drafts[handoff] = draft
                openWindow(value: ComposeRequest(kind: .reply, handoff: handoff))
            }
        } label: {
            Label("Suggest Times from Your Calendar", systemImage: "calendar.badge.clock")
        }
        .buttonStyle(.bordered)
        .help("Three open times from your calendar, in a reply you can change.")
    }

    private func personSheet(_ person: PersonRef) -> some View {
        PersonView(person: person, store: services.store,
                   open: { id in AppRouter.shared.pending = .thread(id) },
                   write: { address in openWindow(value: ComposeRequest(kind: .new, to: address)) })
    }

    private func showPerson() {
        guard !thread.isFromAccountOwner, let email = thread.senderEmail else { return }
        personCard = PersonRef(email: email, name: thread.sender, account: thread.id.account)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(thread.subject.isEmpty ? String(localized: "No subject") : thread.subject)
                .font(.system(size: 24, weight: .regular, design: .serif))
                .foregroundStyle(CorresPalette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                Button { showPerson() } label: {
                    CorrespondentAvatar(initials: thread.initials, email: thread.senderEmail, size: CGSize(width: 38, height: 38))
                }
                .buttonStyle(.plain)
                .help("Show your mail with \(thread.sender)")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button { showPerson() } label: {
                            Text(thread.sender).font(.headline).foregroundStyle(CorresPalette.ink)
                        }
                        .buttonStyle(.plain)
                        .help("Show your mail with \(thread.sender)")
                        if let email = thread.senderEmail, email.lowercased() != thread.sender.lowercased() {
                            Text(email).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if !recipients.isEmpty {
                        Text(recipients).font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(thread.receivedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                        .font(.subheadline).foregroundStyle(CorresPalette.secondary)
                    if services.auth.accounts.count > 1 {
                        Text(AccountPreferences.nickname(for: thread.id.account))
                            .font(.caption).foregroundStyle(CorresPalette.tertiary)
                    }
                }
            }
        }
    }

    private var recipients: String {
        var parts: [String] = []
        let to = thread.recipientNames
        if !to.isEmpty { parts.append(String(localized: "To ") + to.joined(separator: ", ")) }
        if !thread.ccRecipients.isEmpty { parts.append(String(localized: "Cc \(thread.ccRecipients.count)")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Why it's here, and the summary

    private var statusCard: some View {
        let insight = summariesOn ? intelligence.insight(for: thread) : nil
        let preparing = summariesOn && insight?.summary == nil && intelligence.isPreparing(thread)
        return VStack(alignment: .leading, spacing: 10) {
            if let insight, let summary = insight.summary {
                Label("In short", systemImage: "sparkle")
                    .font(.caption.weight(.semibold)).foregroundStyle(CorresPalette.accent)
                Text(summary).font(.body).foregroundStyle(CorresPalette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ForEach(insight.details, id: \.self) { detail in
                    Text("• " + detail).font(.callout).foregroundStyle(CorresPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
            } else if preparing {
                HStack(spacing: 8) {
                    Label("In short", systemImage: "sparkle")
                        .font(.caption.weight(.semibold)).foregroundStyle(CorresPalette.accent)
                    ProgressView().controlSize(.mini)
                }
                Divider()
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(statusLine).font(.callout).foregroundStyle(CorresPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Menu {
                    ForEach(Attention.choices, id: \.self) { attention in
                        Button {
                            Task { await services.threadActions.setAttention(attention, for: thread) }
                        } label: {
                            if attention == thread.attention { Label(attention.title, systemImage: "checkmark") } else { Text(attention.title) }
                        }
                    }
                } label: {
                    Text("Move")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if thread.attention(at: .now) == .needsYou {
                    Button("Handled") {
                        Task { await services.threadActions.setAttention(.handled, for: thread) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CorresPalette.line))
    }

    private var statusLine: String {
        let attention = thread.attention(at: .now)
        let reason = thread.displayReason.trimmingCharacters(in: .whitespacesAndNewlines)
        switch attention {
        case .needsYou: return reason.isEmpty ? String(localized: "In Needs You") : String(localized: "In Needs You: ") + reason
        case .waiting: return reason.isEmpty ? String(localized: "Waiting on a reply") : String(localized: "Waiting: ") + reason
        case .handled: return String(localized: "Handled. It stays in Mail.")
        case .quiet: return reason.isEmpty ? String(localized: "No action needed") : String(localized: "No action needed: ") + reason
        }
    }

    private var summariesOn: Bool { services.entitlements.isPro && CorresSettings.summaries && intelligence.isAvailable }

    // MARK: Earlier messages

    private var earlierMessages: [Correspondence]? {
        guard let all = services.threadActions.messages(in: thread), all.count > 1 else { return nil }
        return Array(all.dropLast())
    }

    private func earlierSection(_ earlier: [Correspondence]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { showEarlier.toggle() }
            } label: {
                Label(earlier.count == 1 ? "1 earlier message" : "\(earlier.count) earlier messages",
                      systemImage: showEarlier ? "chevron.down" : "chevron.right")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CorresPalette.accent)
            if showEarlier {
                ForEach(earlier) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(message.sender).font(.callout.weight(.semibold))
                            Spacer()
                            Text(MacDates.short(message.receivedAt)).font(.caption).foregroundStyle(CorresPalette.secondary)
                        }
                        Text(MailDigest.preview(body: message.body, html: message.htmlBody) ?? message.excerpt)
                            .font(.callout).foregroundStyle(CorresPalette.secondary)
                            .lineLimit(4).textSelection(.enabled)
                    }
                    .padding(10)
                    .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: Images and attachments

    private var blockedImages: Int { thread.htmlBody.map(HTMLMessageBody.remoteImageCount(in:)) ?? 0 }
    private var imagesAllowed: Bool { showImages || thread.imagesTrusted || CorresSettings.remoteImages == .always }

    @State private var unsubscribing = false
    @State private var unsubscribed = false

    /// Mail's banner: a newsletter or list, one click to leave it.
    private var unsubscribeLine: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.badge.shield.half.filled").foregroundStyle(CorresPalette.secondary)
            Text(unsubscribed ? "Unsubscribed. You won't get more from this list."
                              : "This email is from a mailing list.")
                .font(.callout).foregroundStyle(CorresPalette.secondary)
            Spacer()
            if !unsubscribed {
                if unsubscribing { ProgressView().controlSize(.small) }
                Button("Unsubscribe") {
                    unsubscribing = true
                    Task {
                        let outcome = await services.unsubscribeService.unsubscribe(from: thread, store: services.store)
                        unsubscribing = false
                        unsubscribed = outcome == .done
                    }
                }
                .controlSize(.small)
                .disabled(unsubscribing)
            }
        }
        .padding(10)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var imagesNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(CorresPalette.secondary)
            let trackers = thread.htmlBody.map(HTMLMessageBody.trackerCount(in:)) ?? 0
            Text(trackers == 1 ? "Images hidden, and 1 tracker blocked"
                 : trackers > 1 ? "Images hidden, and \(trackers) trackers blocked"
                              : "Images hidden to protect your privacy")
                .font(.callout).foregroundStyle(CorresPalette.secondary)
            Spacer()
            Button("Show Images") { showImages = true }.controlSize(.small)
            if let sender = thread.senderEmail {
                Button("Always from \(thread.sender)") {
                    showImages = true
                    Task { await services.store.trustSenderImages(sender, account: thread.id.account) }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(thread.attachments.count) \(thread.attachments.count == 1 ? "attachment" : "attachments")")
                .font(.caption.weight(.semibold)).foregroundStyle(CorresPalette.secondary)
            FlowRow(spacing: 8) {
                ForEach(thread.attachments) { file in
                    MacAttachmentChip(file: file, thread: thread)
                }
            }
        }
    }

    // MARK: Loading

    private var html: String {
        // Blank for the moment the HTML is read from storage, rather than
        // the plain text flashing first.
        if services.store.needsStoredContent(thread.id) { return "" }
        return thread.htmlBody ?? HTMLMessageBody.page(forPlainText: thread.body)
    }

    private func opened() async {
        HangReporter.start("open")
        await services.store.loadStoredContent(thread.id)
        showImages = false
        showEarlier = false
        invitation = nil
        bodyHeight = 1
        if thread.isUnread && CorresSettings.markReadOnOpen {
            // A beat later, so arrowing quickly through the list doesn't
            // mark everything read on the way past, as in Mail.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await services.threadActions.setUnread(false, for: thread)
        }
        async let content: Void = services.threadActions.loadContent(for: thread)
        async let history: Void = services.threadActions.loadHistory(for: thread)
        _ = await (content, history)
        invitation = await InvitationCard.find(in: services.store.thread(thread.id) ?? thread)
        if summariesOn {
            await intelligence.prepareInsight(for: thread, conversation: services.threadActions.messages(in: thread))
        }
    }
}

/// Lays children out in rows, wrapping as needed.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One attachment: click to open it in its app (Preview, Pages…), or
/// save it anywhere. Downloaded once, then kept in Corres's own cache.
struct MacAttachmentChip: View {
    let file: MailAttachment
    let thread: Correspondence
    @State private var working = false
    @State private var failed = false
    @State private var previewURL: URL?

    var body: some View {
        let kind = AttachmentKind(filename: file.filename, mimeType: file.mimeType)
        // A click looks at it in Quick Look, as in Mail and Finder;
        // Open hands it to its app.
        Button { Task { previewURL = await download() } } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(kind.color)
                    Image(systemName: kind.symbol).font(.caption.weight(.semibold)).foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(file.filename).lineLimit(1).truncationMode(.middle)
                    Text(failed ? String(localized: "Couldn't download") : ByteCountFormatter.string(fromByteCount: Int64(file.sizeBytes), countStyle: .file))
                        .font(.caption).foregroundStyle(failed ? CorresPalette.alert : CorresPalette.secondary)
                }
                if working { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CorresPalette.line))
        }
        .buttonStyle(.plain)
        .help("Quick Look \(file.filename)")
        .quickLookPreview($previewURL)
        .contextMenu {
            Button("Quick Look") { Task { previewURL = await download() } }
            Button("Open") { Task { await open() } }
            Button("Save to Downloads") { Task { await save(toDownloads: true) } }
            Button("Save As…") { Task { await save(toDownloads: false) } }
        }
    }

    private func download() async -> URL? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(thread.latestMessageID ?? thread.id.providerID, isDirectory: true)
        let safeName = file.filename.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let messageID = thread.latestMessageID else { return nil }
        working = true
        defer { working = false }
        guard let data = try? await MailClient().fetchAttachmentData(messageId: messageID, attachmentId: file.id,
                                                                    account: thread.id.account) else {
            failed = true
            return nil
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { failed = true; return nil }
        failed = false
        return url
    }

    private func open() async {
        guard let url = await download() else { return }
        NSWorkspace.shared.open(url)
    }

    private func save(toDownloads: Bool) async {
        guard let url = await download() else { return }
        let destination: URL?
        if toDownloads {
            destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
                .appendingPathComponent(url.lastPathComponent)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url.lastPathComponent
            destination = panel.runModal() == .OK ? panel.url : nil
        }
        guard let destination else { return }
        try? FileManager.default.removeItem(at: destination)
        if (try? FileManager.default.copyItem(at: url, to: destination)) != nil, toDownloads {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }
}
