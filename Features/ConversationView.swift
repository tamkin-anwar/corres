import QuickLook
import Translation
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
    let unsubscribeService: UnsubscribeService
    let orderedIDs: [ThreadID]
    @State private var currentID: ThreadID
    @State private var composeDraft: Draft?
    @State private var htmlHeight: CGFloat = 200
    @State private var showRemoteImages = false
    @State private var showingUnsubscribeConfirmation = false
    @State private var isUnsubscribing = false
    @State private var unsubscribeOpened = false
    @State private var showingSnooze = false
    /// Set when a snooze was chosen; the view leaves only after the sheet
    /// has fully closed, so the pop and the sheet dismissal never race.
    @State private var leaveAfterSnooze = false
    @State private var draftingIntent: String?
    @Environment(\.dismiss) private var systemDismiss
    @Environment(\.conversationSelection) private var splitSelection
    @Environment(\.proUnlocked) private var proUnlocked
    @Environment(MailIntelligence.self) private var intelligence
    @Environment(\.displayScale) private var displayScale
    @AppStorage(GoogleAuthService.givenNameKey) private var givenName = ""

    init(store: MailStore, outbox: OutboxService, threadActions: ThreadActionService,
        labelDirectory: LabelDirectory, unsubscribeService: UnsubscribeService, route: ConversationRoute) {
        self.store = store
        self.outbox = outbox
        self.threadActions = threadActions
        self.labelDirectory = labelDirectory
        self.unsubscribeService = unsubscribeService
        self.orderedIDs = route.orderedIDs
        self._currentID = State(initialValue: route.id)
    }

    var body: some View {
        Group {
            if let thread = store.thread(currentID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(thread.subject)
                            .font(CorresType.title)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.horizontal, CorresSpace.page)
                        if thread.senderDecision == .pending, let email = thread.senderEmail {
                            newSenderCard(thread: thread, email: email)
                                .padding(.horizontal, CorresSpace.page)
                        }
                        inShortCard(for: thread)
                            .padding(.horizontal, CorresSpace.page)
                        if let earlier = earlierMessages(in: thread), !earlier.isEmpty {
                            EarlierMessages(messages: earlier, account: thread.id.account)
                                .padding(.horizontal, CorresSpace.page)
                                .transition(.opacity)
                        }
                        messageHeader(for: thread)
                            .padding(.horizontal, CorresSpace.page)
                        if let calendarEvent, !thread.isFromAccountOwner {
                            CalendarSuggestionCard(event: calendarEvent, sender: thread.sender, threadKey: thread.id.providerID)
                                .padding(.horizontal, CorresSpace.page)
                        }
                        mailboxNotice(for: thread)
                            .padding(.horizontal, CorresSpace.page)
                        privacyLine(for: thread)
                            .padding(.horizontal, CorresSpace.page)
                        if unsubscribeService.canUnsubscribe(thread) && !thread.senderUnsubscribed {
                            VStack(alignment: .leading, spacing: 6) {
                                unsubscribeBanner(for: thread)
                                // No real signal this actually finished (no
                                // one-click POST or mailto send happened,
                                // just a handoff to a webpage), so this
                                // stays a one-time note rather than the
                                // banner disappearing the way it does when
                                // Corres itself could confirm success.
                                if unsubscribeOpened {
                                    Text("Opened in Safari. Finish unsubscribing there.")
                                        .font(.caption).foregroundStyle(CorresPalette.secondary)
                                }
                            }
                            .padding(.horizontal, CorresSpace.page)
                        }
                        let knownLabels = thread.labelIds.compactMap { id in
                            labelDirectory.labels(for: thread.id.account).first { $0.id == id }
                        }
                        if !knownLabels.isEmpty {
                            labelChips(knownLabels).padding(.horizontal, CorresSpace.page)
                        }
                        if let html = thread.htmlBody {
                            // Full width, no card: real HTML mail is a
                            // fixed-width table (often 600pt), and wrapping
                            // it in padding narrow enough to clip that table
                            // is what made images/text run off-screen before
                            // (see Docs/Verification.md). Mail and Spark both
                            // render the body edge to edge for this reason.
                            HTMLMessageBody(html: html, height: $htmlHeight,
                                            blockRemoteImages: !(showRemoteImages || thread.imagesTrusted || loadsImages))
                                .frame(height: htmlHeight)
                        } else {
                            // Plain-text mail reads like the rest: tappable
                            // links and addresses, Dark mode, zoom, and
                            // its quoted history folded.
                            HTMLMessageBody(html: HTMLMessageBody.page(forPlainText: thread.body), height: $htmlHeight,
                                            blockRemoteImages: false)
                                .frame(height: htmlHeight)
                        }
                        if !thread.isBodyLoaded {
                            // Synced metadata-first: the preview is showing
                            // while the full message loads (see `.task` below).
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading the full message…").font(.footnote).foregroundStyle(CorresPalette.secondary)
                            }
                            .padding(.horizontal, CorresSpace.page)
                        }
                        if !thread.attachments.isEmpty, let messageID = thread.latestMessageID {
                            attachmentsList(thread.attachments, messageID: messageID, account: thread.id.account)
                                .padding(.horizontal, CorresSpace.page)
                        }
                    }
                    .padding(.top, 4).padding(.bottom, 24)
                    .readableWidth()
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) { bottomChrome(for: thread) }
                .background { keyboardCommands(for: thread) }
                .sensoryFeedback(.selection, trigger: thread.isFlagged)
                // The reading view owns the whole screen, like Apple Mail's:
                // the main tab bar has no reason to compete with this
                // view's own floating action bar.
                .toolbar(.hidden, for: .tabBar)
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
                .sheet(isPresented: $showingSnooze, onDismiss: {
                    if leaveAfterSnooze { dismiss() }
                }) {
                    SnoozeSheet { date in
                        leaveAfterSnooze = true
                        Task { await store.snooze(thread.id, until: date) }
                    }
                }
                .confirmationDialog("Block \(thread.sender)?",
                                    isPresented: Binding(get: { confirmingBlock != nil }, set: { if !$0 { confirmingBlock = nil } }),
                                    titleVisibility: .visible) {
                    Button("Block", role: .destructive) {
                        if let blocked = confirmingBlock, let email = blocked.senderEmail {
                            Task { await store.blockSender(email, account: blocked.id.account) }
                        }
                        confirmingBlock = nil
                    }
                } message: {
                    Text("Their mail is hidden in Corres from now on, with no notice to them. Your Gmail account isn't changed.")
                }
                .sheet(isPresented: $addingEvent) {
                    if let calendarEvent {
                        NewEventSheet(event: calendarEvent, sender: thread.sender) { _ in }
                            .ignoresSafeArea()
                    }
                }
                .modifier(TranslateSheet(isPresented: $showingTranslation, text: Self.plainText(of: thread)))
                .confirmationDialog("Unsubscribe from \(thread.sender)?", isPresented: $showingUnsubscribeConfirmation, titleVisibility: .visible) {
                    Button("Unsubscribe", role: .destructive) {
                        Task {
                            isUnsubscribing = true
                            let outcome = await unsubscribeService.unsubscribe(from: thread, store: store)
                            isUnsubscribing = false
                            unsubscribeOpened = outcome == .opened
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You won't receive future mail from this sender. This can't be undone from Corres.")
                }
                .alert("Could not unsubscribe", isPresented: Binding(
                    get: { unsubscribeService.errorMessage != nil },
                    set: { if !$0 { unsubscribeService.errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { unsubscribeService.errorMessage = nil }
                } message: { Text(unsubscribeService.errorMessage ?? "Please try again.") }
            } else {
                ContentUnavailableView("Conversation unavailable", systemImage: "text.bubble")
            }
        }
        .background(CorresPalette.canvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $composeDraft) { draft in
            ComposeView(store: store, outbox: outbox, draft: draft,
                        sourceThread: store.thread(currentID))
        }
        .confirmationDialog("Move this conversation to Trash?",
                            isPresented: Binding(get: { confirmingTrash != nil }, set: { if !$0 { confirmingTrash = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let thread = confirmingTrash { Task { await threadActions.trash(thread, animated: false) } }
                confirmingTrash = nil
            }
        }
        .onChange(of: currentID) {
            htmlHeight = 200
            showRemoteImages = false
            calendarEvent = nil
            // Keep the list underneath scrolled to the conversation you're
            // on while it's hidden, so going back shows it already in place.
            router.returnAnchor = currentID
        }
        // Opening a conversation is itself the signal that it's been seen,
        // the same behavior every real mail client already has.
        // Keyed on the latest message too, so a reply landing while the
        // conversation is open loads, is marked read and is summarized.
        .task(id: "\(currentID.account)|\(currentID.providerID)|\(currentThread?.latestMessageID ?? "")") {
            guard let thread = store.thread(currentID) else { return }
            // Loading the body and marking read are independent network
            // calls; neither should wait on the other.
            async let loaded: Void = threadActions.loadContent(for: thread)
            async let conversation: Void = threadActions.loadHistory(for: thread)
            // Settings → Reading → Mark as read when opened.
            if thread.isUnread && markReadOnOpen {
                await threadActions.setUnread(false, for: thread)
            }
            await loaded
            await conversation
            // The event this email is about, once its full text is here.
            if let current = store.thread(currentID) {
                calendarEvent = await Self.findEvent(in: current)
            }
            // Covers the whole conversation once its history is here.
            if proUnlocked, let current = store.thread(currentID) {
                await intelligence.prepareInsight(for: current, conversation: threadActions.messages(in: current))
            }
        }
        .onChange(of: threadExists) { _, stillExists in
            // Archiving or trashing from inside the conversation itself
            // removes it from `store.threads` right under this view; pop
            // back to the list rather than leaving a dead end.
            // Like Mail and Superhuman, the next conversation takes its
            // place, so triage flows one message to the next.
            guard !stillExists else { return }
            let live = Set(orderedIDs.filter { store.thread($0) != nil })
            let index = orderedIDs.firstIndex(of: currentID) ?? 0
            let neighbour = orderedIDs[min(index + 1, orderedIDs.count)...].first(where: live.contains)
                ?? orderedIDs[..<index].last(where: live.contains)
            if afterRemoval == AfterRemoval.nextConversation.rawValue, let neighbour {
                currentID = neighbour
            } else {
                router.returnAnchor = neighbour
                dismiss()
            }
        }
    }

    /// Everything in the conversation before the message shown in full.
    private func earlierMessages(in thread: Correspondence) -> [Correspondence]? {
        threadActions.messages(in: thread)?.filter { $0.latestMessageID != thread.latestMessageID }
    }

    /// Leaves the conversation: pops it on iPhone, clears the detail
    /// column in the split layout.
    private func dismiss() {
        if let splitSelection { splitSelection.wrappedValue = nil } else { systemDismiss() }
    }

    private var threadExists: Bool { store.thread(currentID) != nil }
    private var currentThread: Correspondence? { store.thread(currentID) }
    @AppStorage(CorresSettings.summariesKey) private var summariesOn = true
    @AppStorage(CorresSettings.summaryCollapsedKey) private var summaryCollapsed = false
    @AppStorage(AfterRemoval.key) private var afterRemoval = AfterRemoval.nextConversation.rawValue
    @AppStorage(CorresSettings.remoteImagesKey) private var remoteImages = CorresSettings.RemoteImages.ask.rawValue
    @AppStorage(CorresSettings.markReadOnOpenKey) private var markReadOnOpen = true
    @AppStorage(CorresSettings.confirmTrashKey) private var confirmTrash = false
    @State private var confirmingTrash: Correspondence?
    @State private var calendarEvent: EventSuggestion?
    private var loadsImages: Bool { remoteImages == CorresSettings.RemoteImages.always.rawValue }

    /// Settings → Reading → Ask before moving to Trash.
    private func requestTrash(_ thread: Correspondence) {
        if confirmTrash { confirmingTrash = thread } else { Task { await threadActions.trash(thread, animated: false) } }
    }
    @Environment(AppRouter.self) private var router

    private var currentIndex: Int? { orderedIDs.firstIndex(of: currentID) }
    private var hasPrevious: Bool { (currentIndex ?? 0) > 0 }
    private var hasNext: Bool { let i = currentIndex ?? orderedIDs.count - 1; return i < orderedIDs.count - 1 }
    private func goToPrevious() { if let i = currentIndex, i > 0 { currentID = orderedIDs[i - 1] } }
    private func goToNext() { if let i = currentIndex, i < orderedIDs.count - 1 { currentID = orderedIDs[i + 1] } }

    private func messageHeader(for thread: Correspondence) -> some View {
        HStack(spacing: 12) {
            CorrespondentAvatar(initials: thread.initials, size: CGSize(width: 44, height: 44))
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.sender).font(.body.weight(.semibold))
                Text(recipientLine(for: thread))
                    .font(.subheadline).foregroundStyle(CorresPalette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private func recipientLine(for thread: Correspondence) -> String {
        let when = thread.receivedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        let to = (thread.toRecipients.isEmpty || thread.isDirectRecipient) ? "To you" : "Cc you"
        return thread.senderEmail.map { "\($0) · \(when)" } ?? "\(to) · \(when)"
    }

    /// Opened from Trash or Spam (Mailboxes): says so, with the way back.
    @ViewBuilder
    private func mailboxNotice(for thread: Correspondence) -> some View {
        let inTrash = thread.labelIds.contains("TRASH"), inSpam = thread.labelIds.contains("SPAM")
        if inTrash || inSpam {
            HStack(spacing: 8) {
                Image(systemName: inTrash ? "trash" : "xmark.bin").font(.footnote)
                Text(inTrash ? "In Trash" : "In Spam. Links and images may be unsafe.")
                    .font(.footnote)
                Spacer(minLength: 8)
                Button(inTrash ? "Restore" : "Not Spam") {
                    Task {
                        await threadActions.moveToInbox(thread)
                        dismiss()
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(CorresPalette.accent)
            }
            .foregroundStyle(CorresPalette.secondary)
            .padding(12)
            .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// One quiet line that says what Corres did to protect this read:
    /// remote images (and the tracking pixels among them) are off until
    /// the person chooses otherwise.
    @ViewBuilder
    private func privacyLine(for thread: Correspondence) -> some View {
        if let html = thread.htmlBody, !(showRemoteImages || thread.imagesTrusted || loadsImages) {
            let analysis = HTMLMessageBody.analysis(of: html)
            let blocked = analysis.remoteImages
            if blocked > 0 {
                let trackers = analysis.trackers
                HStack(spacing: 7) {
                    Image(systemName: "shield.lefthalf.filled").font(.caption)
                    Text(trackers > 0
                         ? "\(trackers) \(trackers == 1 ? "tracker" : "trackers") blocked · Remote images off"
                         : "Remote images off · \(blocked) blocked")
                    Spacer(minLength: 8)
                    Button("Show images") {
                        showRemoteImages = true
                        if let senderEmail = thread.senderEmail {
                            Task { await store.trustSenderImages(senderEmail, account: thread.id.account) }
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(CorresPalette.accent)
                }
                .font(.footnote)
                .foregroundStyle(CorresPalette.tertiary)
            }
        }
    }

    /// The summary itself: a heading that folds it away (remembered, like
    /// Gmail's), what it covers, the summary, and any key points it left out.
    private func summaryBlock(_ insight: MailIntelligence.Insight, summary: String) -> some View {
        let isConversation = insight.messageCount > 1
        let title = insight.isExtractive ? "From the email" : (isConversation ? "The conversation so far" : "In short")
        let coverage: String? = isConversation && insight.coversWholeMessage ? "\(insight.messageCount) messages" : nil
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { summaryCollapsed.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Label(title, systemImage: insight.isExtractive ? "text.quote" : "sparkle")
                        .labelStyle(TightLabelStyle()).eyebrow(CorresPalette.accent)
                    Spacer(minLength: 8)
                    if let coverage {
                        Text(coverage).font(.caption).foregroundStyle(CorresPalette.tertiary)
                    }
                    Image(systemName: summaryCollapsed ? "chevron.down" : "chevron.up")
                        .font(.caption2.weight(.semibold)).foregroundStyle(CorresPalette.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summaryCollapsed ? "\(title), collapsed" : title)
            .accessibilityHint(summaryCollapsed ? "Shows the summary" : "Hides the summary")
            if !summaryCollapsed {
                Text(summary)
                    .font(.subheadline).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(insight.isExtractive ? "From the email: \(summary)" : summary)
                if !insight.details.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(insight.details, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(CorresPalette.tertiary).frame(width: 4, height: 4)
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                Text(point)
                                    .font(.footnote).foregroundStyle(CorresPalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if !insight.coversWholeMessage {
                    Text(isConversation ? "A long conversation: this covers its first and most recent messages."
                                        : "A long email: this covers its key sections and its ending.")
                        .font(.caption).foregroundStyle(CorresPalette.tertiary)
                }
            }
        }
    }

    /// The summary (on this iPhone, when Apple Intelligence is available)
    /// plus the reason this conversation is where it is, with a direct way
    /// to correct it.
    private func inShortCard(for thread: Correspondence) -> some View {
        let showsSummaries = proUnlocked && summariesOn
        let insight = showsSummaries ? intelligence.insight(for: thread) : nil
        let isPreparing = showsSummaries && insight?.summary == nil && intelligence.isPreparing(thread)
        return VStack(alignment: .leading, spacing: 10) {
            if let insight, let summary = insight.summary {
                summaryBlock(insight, summary: summary)
                Hairline().padding(.vertical, 2)
            } else if isPreparing {
                HStack(spacing: 8) {
                    Label("In short", systemImage: "sparkle").labelStyle(TightLabelStyle()).eyebrow(CorresPalette.accent)
                    Spacer(minLength: 8)
                    ProgressView().controlSize(.mini)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Summarizing")
                Hairline().padding(.vertical, 2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(thread.attention.title): \(thread.reason)")
                    .font(.footnote)
                    .foregroundStyle(CorresPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Menu {
                    ForEach([Attention.needsYou, .waiting, .quiet, .handled], id: \.self) { attention in
                        Button {
                            Task { await store.update(thread.id, to: attention) }
                        } label: {
                            if thread.attention == attention { Label(attention.title, systemImage: "checkmark") }
                            else { Text(attention.title) }
                        }
                    }
                } label: {
                    Text("Change").font(.footnote.weight(.semibold)).foregroundStyle(CorresPalette.accent)
                        .frame(minHeight: 32)
                }
                .accessibilityLabel("Change where this conversation is sorted")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .corresSurface(radius: 18)
        .animation(.easeOut(duration: 0.25), value: insight)
    }

    private func labelChips(_ labels: [GmailUserLabel]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(labels) { label in
                    Text(label.name).font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(CorresPalette.surfaceRaised, in: Capsule())
                        .overlay(Capsule().strokeBorder(CorresPalette.line, lineWidth: 1 / displayScale))
                }
            }
        }
    }

    private func attachmentsList(_ attachments: [MailAttachment], messageID: String, account: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                AttachmentRow(attachment: attachment, messageID: messageID, account: account)
            }
        }
    }

    /// Shown whenever a message offers a real way to stop hearing from its
    /// sender (`List-Unsubscribe`/`List-Unsubscribe-Post`, RFC 2369/8058).
    /// Disappears for this sender's future mail once acted on.
    private func unsubscribeBanner(for thread: Correspondence) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.badge.shield.half.filled").foregroundStyle(CorresPalette.secondary)
                .accessibilityHidden(true)
            Text("Mailing list").font(.footnote).foregroundStyle(CorresPalette.secondary)
            Spacer()
            if isUnsubscribing {
                ProgressView().controlSize(.small)
            } else {
                Button("Unsubscribe") { showingUnsubscribeConfirmation = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(CorresPalette.accent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .corresSurface(radius: 14)
    }

    /// A reply or forward quotes the original, so it needs the real body,
    /// not the snippet a metadata-first sync stored. Opening the thread
    /// already started loading it; this only waits in the rare case the
    /// person taps Reply before that finishes.
    private func compose(_ kind: Draft.Kind, from thread: Correspondence, prefill: String? = nil) {
        func open(_ source: Correspondence) {
            var draft = source.draft(kind: kind)
            if let prefill { draft.body = prefill + draft.body }
            composeDraft = draft
        }
        guard !thread.isBodyLoaded else { return open(thread) }
        Task {
            await threadActions.loadContent(for: thread)
            open(store.thread(thread.id) ?? thread)
        }
    }

    /// Tapping a suggested direction drafts the full reply in the person's
    /// voice on this iPhone, then opens it in compose to read and edit.
    /// Nothing sends without them.
    private func draftReply(_ intent: String, for thread: Correspondence) {
        guard draftingIntent == nil else { return }
        draftingIntent = intent
        Task {
            if !thread.isBodyLoaded { await threadActions.loadContent(for: thread) }
            let source = store.thread(thread.id) ?? thread
            let drafted = await intelligence.draftReply(to: source, intent: intent,
                                                        signOff: givenName.isEmpty || !CorresSettings.signature(for: source.id.account).isEmpty ? nil : givenName)
            draftingIntent = nil
            compose(.reply, from: source, prefill: drafted ?? "")
        }
    }

    /// Booking data first, then an attached invite (.ics), then the
    /// wording; see EventFinder.
    /// Off the main thread: parsing the HTML and running the date detector
    /// over a long email took long enough to catch the opening animation.
    nonisolated private static func findEvent(in thread: Correspondence) async -> EventSuggestion? {
        if let html = thread.htmlBody, let structured = EventFinder.fromStructuredData(html) { return structured }
        if let invite = thread.attachments.first(where: {
               $0.mimeType.lowercased().hasPrefix("text/calendar") || $0.filename.lowercased().hasSuffix(".ics") }),
           let messageID = thread.latestMessageID, thread.id.account != "sample",
           let data = try? await GmailAPIClient().fetchAttachmentData(messageId: messageID, attachmentId: invite.id,
                                                                       account: thread.id.account),
           let text = String(data: data, encoding: .utf8), let event = EventFinder.fromInvite(text) {
            return event
        }
        return EventFinder.fromWording(thread.body, subject: thread.subject, receivedAt: thread.receivedAt)
    }

    private func hasAnswered(_ thread: Correspondence) -> Bool {
        thread.attention == .waiting || thread.isFromAccountOwner
            || (thread.lastSentAt.map { $0 >= thread.receivedAt } ?? false)
    }

    private func bottomChrome(for thread: Correspondence) -> some View {
        VStack(spacing: 10) {
            // Gone once you've answered: the last word is yours, or it's
            // waiting on them.
            if proUnlocked, !hasAnswered(thread), let intents = intelligence.insight(for: thread)?.replyIntents, !intents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(intents, id: \.self) { intent in
                            Button {
                                draftReply(intent, for: thread)
                            } label: {
                                HStack(spacing: 6) {
                                    if draftingIntent == intent { ProgressView().controlSize(.mini) }
                                    Text(intent)
                                }
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 15).frame(minHeight: 38)
                                .corresGlass(in: Capsule(), interactive: true)
                            }
                            .buttonStyle(.plain)
                            .disabled(draftingIntent != nil)
                            .accessibilityHint("Drafts this reply on your iPhone for you to review")
                        }
                    }
                    .padding(.horizontal, CorresSpace.medium)
                    .padding(.vertical, 4)
                }
                .trailingFade(CorresSpace.medium)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            actionBar(for: thread)
        }
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.25), value: intelligence.insight(for: thread)?.replyIntents)
    }

    /// Opened from a "New sender" notification: decide right here instead
    /// of hunting for them in New senders.
    private func newSenderCard(thread: Correspondence, email: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("First email from \(email). Allow them to see their mail in Corres from now on.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.shield").foregroundStyle(CorresPalette.accent)
            }
            .font(.subheadline)
            // Same pair, same order and styles as the New senders screen.
            HStack(spacing: 10) {
                Button {
                    Task { await store.approveSender(email, account: thread.id.account) }
                } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(CorresMetalCapsuleStyle(minHeight: 44))
                Button {
                    Task {
                        await store.blockSender(email, account: thread.id.account)
                        dismiss()
                    }
                } label: {
                    Text("Block").frame(maxWidth: .infinity)
                }
                .buttonStyle(CorresPillStyle(minHeight: 44))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .corresSurface()
    }

    private func actionBar(for thread: Correspondence) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                // The next conversation opens in its place (see the
                // threadExists observer); the Gmail call happens in the
                // background, the same as a swipe.
                // Settings → Email Toolbar.
                ForEach(readingBar) { action in barButton(action, for: thread) }
                moreMenu(for: thread)
            }
            .frame(height: 56)
            .corresGlass(in: Capsule())
            // Settings → Composing → Default reply, when there's anyone
            // besides the sender to reply to.
            let replyAllFirst = CorresSettings.defaultReply == .replyAll && !thread.replyAllCc.isEmpty
            Menu {
                if replyAllFirst {
                    Button { compose(.reply, from: thread) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                } else {
                    Button { compose(.replyAll, from: thread) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                }
                Button { compose(.forward, from: thread) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            } label: {
                Image(systemName: replyAllFirst ? "arrowshape.turn.up.left.2.fill" : "arrowshape.turn.up.left.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 56, height: 56)
            } primaryAction: {
                compose(replyAllFirst ? .replyAll : .reply, from: thread)
            }
            .foregroundStyle(CorresMetalBackground.ink(scheme))
            .background(CorresMetalBackground(shape: AnyShape(Circle())))
            .accessibilityLabel("Reply")
            .accessibilityHint("Press and hold for Reply All and Forward")
        }
        .disabled(store.pending.contains(thread.id))
        .padding(.horizontal, CorresSpace.medium)
    }

    @Environment(\.colorScheme) private var scheme

    /// Apple Mail's own shortcuts, so they appear in iPadOS's ⌘ overlay and
    /// work from any hardware keyboard: the hands never leave the keys.
    private func keyboardCommands(for thread: Correspondence) -> some View {
        Group {
            Button("Reply") { compose(.reply, from: thread) }.keyboardShortcut("r", modifiers: .command)
            Button("Reply All") { compose(.replyAll, from: thread) }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { compose(.forward, from: thread) }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Archive") {
                Task { await threadActions.archive(thread, animated: false) }
            }.keyboardShortcut("a", modifiers: [.command, .control])
            Button("Move to Trash") {
                requestTrash(thread)
            }.keyboardShortcut(.delete, modifiers: .command)
            Button(thread.isFlagged ? "Unflag" : "Flag") {
                Task { await threadActions.setFlagged(!thread.isFlagged, for: thread) }
            }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") {
                Task { await threadActions.setUnread(!thread.isUnread, for: thread) }
            }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Snooze") { showingSnooze = true }.keyboardShortcut("s", modifiers: [.command, .control])
            Button("Previous Conversation") { goToPrevious() }.keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Button("Next Conversation") { goToNext() }.keyboardShortcut(.downArrow, modifiers: [.command, .control])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    @AppStorage(CorresSettings.readingBarKey) private var readingBarRaw = ""
    private var readingBar: [CorresSettings.ReadingAction] { CorresSettings.readingBar(from: readingBarRaw) }

    /// An action's icon and name as it stands for this conversation
    /// ("Unflag" once flagged).
    private func appearance(of action: CorresSettings.ReadingAction, for thread: Correspondence) -> (icon: String, title: String, tint: Color?) {
        switch action {
        case .flag: thread.isFlagged ? ("flag.fill", "Unflag", CorresPalette.flag) : ("flag", "Flag", nil)
        case .unread: thread.isUnread ? ("envelope.open", "Mark as Read", nil) : ("envelope.badge", "Mark as Unread", nil)
        case .pin: thread.isPinned ? ("pin.fill", "Unpin", nil) : ("pin", "Pin", nil)
        case .trash: ("trash", "Move to Trash", nil)
        case .vip:
            thread.senderEmail.map(InboxClassifier.isVIP) == true
                ? ("star.slash", "Remove from VIPs", nil) : ("star", "Add \(thread.sender) to VIPs", nil)
        case .block: ("hand.raised", "Block \(thread.sender)", nil)
        default: (action.systemImage, action.rawValue, nil)
        }
    }

    /// Whether an action applies to this email. On the bar an action that
    /// doesn't is dimmed, so the bar keeps its shape; in ⋯ it's left out.
    private func isAvailable(_ action: CorresSettings.ReadingAction, for thread: Correspondence) -> Bool {
        let fromSomeoneElse = thread.senderEmail != nil && !thread.isFromAccountOwner
        switch action {
        case .labels: return !labelDirectory.labels(for: thread.id.account).isEmpty
        case .vip, .block: return fromSomeoneElse
        case .unsubscribe: return unsubscribeService.canUnsubscribe(thread) && !thread.senderUnsubscribed
        case .calendar: return calendarEvent != nil && !thread.isFromAccountOwner
        case .spam: return !thread.isFromAccountOwner
        case .translate: if #available(iOS 17.4, *) { return true } else { return false }
        default: return true
        }
    }

    private func perform(_ action: CorresSettings.ReadingAction, on thread: Correspondence) {
        switch action {
        case .archive: Task { await threadActions.archive(thread, animated: false) }
        case .trash: requestTrash(thread)
        case .flag: Task { await threadActions.setFlagged(!thread.isFlagged, for: thread) }
        case .snooze: showingSnooze = true
        case .unread: Task { await threadActions.setUnread(!thread.isUnread, for: thread) }
        case .pin: Task { await store.setPinned(!thread.isPinned, for: thread.id) }
        case .replyAll: compose(.replyAll, from: thread)
        case .forward: compose(.forward, from: thread)
        case .spam: Task { await threadActions.reportSpam(thread, animated: false) }
        case .block: confirmingBlock = thread
        case .unsubscribe: showingUnsubscribeConfirmation = true
        case .vip:
            if let email = thread.senderEmail {
                Task { await store.setVIP(email, account: thread.id.account, isVIP: !InboxClassifier.isVIP(email)) }
            }
        case .calendar: addingEvent = calendarEvent != nil
        case .share: Self.share(thread)
        case .print: Self.print(thread)
        case .translate: showingTranslation = true
        case .moveTo, .labels: break // menus; see `menuContent`
        }
    }

    /// Move to and Labels open a menu wherever they are.
    @ViewBuilder
    private func menuContent(_ action: CorresSettings.ReadingAction, for thread: Correspondence) -> some View {
        if action == .moveTo {
            ForEach(Attention.allCases, id: \.self) { attention in
                Button {
                    Task { await store.update(thread.id, to: attention) }
                } label: {
                    if thread.attention == attention { Label(attention.title, systemImage: "checkmark") }
                    else { Text(attention.title) }
                }
            }
        } else {
            ForEach(labelDirectory.labels(for: thread.id.account)) { label in
                let isOn = thread.labelIds.contains(label.id)
                Button {
                    Task { await threadActions.toggleLabel(label.id, isOn: !isOn, for: thread) }
                } label: {
                    if isOn { Label(label.name, systemImage: "checkmark") } else { Text(label.name) }
                }
            }
        }
    }

    @State private var confirmingBlock: Correspondence?
    @State private var addingEvent = false
    @State private var showingTranslation = false

    /// The email as plain text, for Share and Translate.
    private static func plainText(of thread: Correspondence) -> String {
        MailDigest.readableText(body: thread.body, html: thread.htmlBody)
    }

    private static func share(_ thread: Correspondence) {
        let text = "\(thread.subject)\nFrom: \(thread.sender)\(thread.senderEmail.map { " <\($0)>" } ?? "")\n\n\(plainText(of: thread))"
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        topViewController()?.present(sheet, animated: true)
    }

    /// iOS's own print sheet (AirPrint, or Save to PDF from there).
    private static func print(_ thread: Correspondence) {
        let body = thread.htmlBody ?? "<pre style=\"white-space: pre-wrap; font: -apple-system-body\">"
            + thread.body.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") + "</pre>"
        let header = "<h2 style=\"font-family: -apple-system\">\(thread.subject.replacingOccurrences(of: "<", with: "&lt;"))</h2>"
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = thread.subject
        info.outputType = .general
        controller.printInfo = info
        controller.printFormatter = UIMarkupTextPrintFormatter(markupText: header + body)
        controller.present(animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    @ViewBuilder
    private func barButton(_ action: CorresSettings.ReadingAction, for thread: Correspondence) -> some View {
        let look = appearance(of: action, for: thread)
        let available = isAvailable(action, for: thread)
        if action == .moveTo || action == .labels {
            Menu { menuContent(action, for: thread) } label: {
                Image(systemName: look.icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(CorresPalette.ink)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Rectangle())
            }
            .disabled(!available)
            .opacity(available ? 1 : 0.35)
            .accessibilityLabel(look.title)
        } else {
            barButton(look.icon, look.title, tint: look.tint) { perform(action, on: thread) }
                .disabled(!available)
                .opacity(available ? 1 : 0.35)
        }
    }

    private func barButton(_ systemImage: String, _ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(tint ?? CorresPalette.ink)
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(CorresRowButtonStyle())
        .accessibilityLabel(label)
    }

    private func moreMenu(for thread: Correspondence) -> some View {
        Menu {
            // Whatever isn't on the bar (Settings → Email Toolbar). Pin is
            // Corres-only "keep at top"; Flag syncs with iOS Mail and Gmail.
            ForEach(CorresSettings.ReadingAction.allCases.filter { !readingBar.contains($0) && isAvailable($0, for: thread) }) { action in
                let look = appearance(of: action, for: thread)
                if action == .moveTo || action == .labels {
                    Menu { menuContent(action, for: thread) } label: { Label(look.title, systemImage: look.icon) }
                } else {
                    Button(role: [.trash, .spam, .block].contains(action) ? .destructive : nil) { perform(action, on: thread) } label: {
                        Label(look.title, systemImage: look.icon)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(CorresPalette.ink)
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions")
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
    let account: String
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
        // Each download writes to a fresh, uniquely-named directory (see
        // `download()`) and nothing ever removed the previous one: viewing
        // several attachments in a long session left them all sitting in
        // the temp directory indefinitely rather than only until this row
        // no longer needs them. iOS does eventually reclaim `tmp/` under
        // its own storage pressure, but that's a backstop, not a reason for
        // Corres to litter it freely within a single session.
        .onDisappear { cleanUpDownloadedFile() }
    }

    private func cleanUpDownloadedFile() {
        guard let url = previewURL else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.sizeBytes), countStyle: .file)
    }

    private func download() async {
        // Tapping the same attachment again re-downloads rather than
        // reusing the previous file; nothing else needs that first copy
        // anymore.
        cleanUpDownloadedFile()
        isDownloading = true
        defer { isDownloading = false }
        do {
            let data = try await client.fetchAttachmentData(messageId: messageID, attachmentId: attachment.id, account: account)
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
    case laterToday, tomorrow, thisWeekend, nextWeek

    var title: String {
        switch self {
        case .laterToday: "Later today"
        case .tomorrow: "Tomorrow"
        case .thisWeekend: "This weekend"
        case .nextWeek: "Next week"
        }
    }

    func date(from now: Date = .now) -> Date {
        let phrase = switch self {
        case .laterToday: "later today"
        case .tomorrow: "tomorrow"
        case .thisWeekend: "this weekend"
        case .nextWeek: "next week"
        }
        return TimePhrase.parse(phrase, now: now) ?? now.addingTimeInterval(86_400)
    }
}

/// Apple's on-device translation sheet (iOS 17.4 and later).
private struct TranslateSheet: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        if #available(iOS 17.4, *) {
            content.translationPresentation(isPresented: $isPresented, text: text)
        } else {
            content
        }
    }
}
