import Network
import QuickLookThumbnailing
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorSchemeForPage
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
    /// True while a forward's attachments download, so the button shows
    /// it's working instead of seeming to do nothing.
    @State private var preparingForward = false
    /// A forward whose attachments didn't all download: said before it
    /// opens, rather than sent on short without a word.
    @State private var forwardMissing: (draft: Draft, missing: [String])?
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
                        // Who, then one quiet line for images, trackers and
                        // unsubscribing, then the email: what used to be two
                        // more bars between you and the message.
                        VStack(alignment: .leading, spacing: 8) {
                            messageHeader(for: thread)
                            utilityLine(for: thread)
                        }
                        .padding(.horizontal, CorresSpace.page)
                        // An invitation: answer it here, as Gmail's Yes /
                        // Maybe / No; the organizer's calendar shows it.
                        if let invitation, !thread.isFromAccountOwner {
                            InvitationCard(invitation: invitation, senderEmail: thread.senderEmail, senderName: thread.sender) { response in
                                Task { await outbox.sendNow(InvitationCard.reply(response, to: invitation, in: thread), replyingTo: thread) }
                            }
                            .padding(.horizontal, CorresSpace.page)
                        } else if let calendarEvent, !thread.isFromAccountOwner {
                            CalendarSuggestionCard(event: calendarEvent, sender: thread.sender, threadKey: thread.id.providerID)
                                .padding(.horizontal, CorresSpace.page)
                        }
                        mailboxNotice(for: thread)
                            .padding(.horizontal, CorresSpace.page)
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
                        let later = laterMessages(in: thread)
                        if !later.isEmpty {
                            EarlierMessages(messages: later, account: thread.id.account)
                                .padding(.horizontal, CorresSpace.page)
                                .transition(.opacity)
                        }
                    }
                    .padding(.top, 4).padding(.bottom, 24)
                    .readableWidth()
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                // Scrolled, the email passes under a clear frosted band, not
                // straight under the back and next buttons (tester feedback:
                // a signature overlapping them).
                .modifier(HardTopEdge())
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
                    SnoozeSheet(kind: thread.mailKind) { date in
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
                    Text("Their mail is hidden in Corres from now on, with no notice to them. Your email account isn't changed.")
                }
                .sheet(isPresented: $addingEvent) {
                    if let calendarEvent {
                        NewEventSheet(event: calendarEvent, sender: thread.sender) { _ in }
                            .ignoresSafeArea()
                    }
                }
                .modifier(TranslateSheet(isPresented: $showingTranslation, text: showingTranslation ? Self.plainText(of: thread) : ""))
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
                .alert("Couldn't Unsubscribe", isPresented: Binding(
                    get: { unsubscribeService.errorMessage != nil },
                    set: { if !$0 { unsubscribeService.errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { unsubscribeService.errorMessage = nil }
                } message: { Text(unsubscribeService.errorMessage ?? "Try again.") }
            } else {
                ContentUnavailableView("Conversation unavailable", systemImage: "text.bubble")
            }
        }
        .background(CorresPalette.readingPage(colorSchemeForPage))
        .environment(\.onReadingPage, true)
        .overlay(alignment: .top) {
            if preparingForward {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Adding attachments…").font(.footnote.weight(.medium))
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityLabel("Adding attachments to the forward")
            }
        }
        .animation(.snappy(duration: 0.25), value: preparingForward)
        .alert(forwardMissing.map { $0.missing.count == 1 ? "One attachment couldn't be added" : "\($0.missing.count) attachments couldn't be added" } ?? "",
               isPresented: Binding(get: { forwardMissing != nil }, set: { if !$0 { forwardMissing = nil } })) {
            Button("Forward Without Them") {
                if let pending = forwardMissing { composeDraft = pending.draft }
                forwardMissing = nil
            }
            Button("Cancel", role: .cancel) { forwardMissing = nil }
        } message: {
            Text((forwardMissing?.missing.joined(separator: ", ") ?? "")
                 + ". They may be too large to send on, or the connection dropped.")
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .userActivity(Handoff.conversation, isActive: store.thread(currentID) != nil) { activity in
            if let thread = store.thread(currentID) { Handoff.describe(activity, thread) }
        }
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
            invitation = nil
            nextStep = nil
            glance = nil
            buriedAsk = nil
            // Keep the list underneath scrolled to the conversation you're
            // on while it's hidden, so going back shows it already in place.
            router.returnAnchor = currentID
        }
        // Opening a conversation is itself the signal that it's been seen,
        // the same behavior every real mail client already has.
        // Keyed on the latest message too, so a reply landing while the
        // conversation is open loads, is marked read and is summarized.
        .categoryMoveDialog($categoryChoice, threadActions: threadActions)
        .onAppear { HangReporter.start("open") }
        .onChange(of: currentID) { HangReporter.start("open") }
        .task(id: "\(currentID.account)|\(currentID.providerID)|\(currentThread?.latestMessageID ?? "")|\(currentThread?.lastSentAt?.timeIntervalSince1970 ?? 0)") {
            guard let thread = store.thread(currentID) else { return }
            // Loading the body and marking read are independent network
            // calls; neither should wait on the other.
            async let loaded: Void = threadActions.loadContent(for: thread)
            async let conversation: Void = threadActions.loadHistory(for: thread)
            HabitWatcher.shared.opened(thread)
            // Settings → Reading → Mark as read when opened.
            if thread.isUnread && markReadOnOpen {
                await threadActions.setUnread(false, for: thread)
            }
            await loaded
            await conversation
            // The event this email is about, once its full text is here.
            if let current = store.thread(currentID) {
                calendarEvent = await Self.findEvent(in: current)
                invitation = await InvitationCard.find(in: current)
                let aids = await Self.readingAids(in: current)
                nextStep = aids.nextStep
                glance = aids.glance
                buriedAsk = aids.ask
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
            // One pass over the mailbox, not one lookup per row: on a long
            // inbox that was seconds of work on the main thread.
            let live = Set(store.threads.map(\.id)).union(store.browsed.keys.filter { !store.hiddenIDs.contains($0) })
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
        threadActions.messages(in: thread)?.filter {
            $0.latestMessageID != thread.latestMessageID && !isSameSend($0, as: thread) && $0.receivedAt <= thread.receivedAt
        }
    }

    /// Messages newer than the one shown (a reply you just sent, before
    /// Gmail's copy makes it the conversation's latest): below it, in order,
    /// not above it as if it came first.
    private func laterMessages(in thread: Correspondence) -> [Correspondence] {
        (threadActions.messages(in: thread) ?? []).filter {
            $0.latestMessageID != thread.latestMessageID && !isSameSend($0, as: thread) && $0.receivedAt > thread.receivedAt
        }
    }

    /// Gmail's copy of the very message shown, when the shown one is the
    /// copy Corres saved as it sent (no message id yet): the same message,
    /// never listed twice.
    private func isSameSend(_ message: Correspondence, as thread: Correspondence) -> Bool {
        thread.latestMessageID == nil && message.isFromAccountOwner && thread.isFromAccountOwner
            && abs(message.receivedAt.timeIntervalSince(thread.receivedAt)) < 600
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
    @State private var invitation: Invitation?
    /// What the email asks you to do, with its link (`MailDigest.nextStep`).
    @State private var nextStep: NextStep?
    @State private var categoryChoice: CategoryChoice?
    /// A receipt's or bill's status and figures, and what a long email asks
    /// of you, read from the email itself.
    @State private var glance: Glance?
    @State private var buriedAsk: String?
    @AppStorage(CorresSettings.keyDetailsKey) private var keyDetailsOn = true
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
            CorrespondentAvatar(initials: thread.isFromAccountOwner ? "Y" : thread.initials,
                                email: thread.isFromAccountOwner ? nil : thread.senderEmail, size: CGSize(width: 44, height: 44))
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.isFromAccountOwner ? String(localized: "You") : thread.sender).font(.body.weight(.semibold))
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
        // Something you sent: who it went to. Never "To you".
        if thread.isFromAccountOwner {
            let names = thread.recipientNames
            let to = names.isEmpty ? String(localized: "Sent") : String(localized: "To ") + (names.count > 2 ? names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
                                                                          : names.joined(separator: ", "))
            return "\(to) · \(when)"
        }
        let to = (thread.toRecipients.isEmpty || thread.isDirectRecipient) ? String(localized: "To you") : String(localized: "Cc you")
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
            .corresCardFill(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// One quiet line under the sender: what Corres blocked to protect this
    /// read (remote images and the trackers among them) with the way to
    /// show them, and Unsubscribe for a mailing list.
    @ViewBuilder
    private func utilityLine(for thread: Correspondence) -> some View {
        let blocked: (images: Int, trackers: Int)? = {
            guard let html = thread.htmlBody, !(showRemoteImages || thread.imagesTrusted || loadsImages) else { return nil }
            let analysis = HTMLMessageBody.analysis(of: html)
            return analysis.remoteImages > 0 ? (analysis.remoteImages, analysis.trackers) : nil
        }()
        let canUnsubscribe = unsubscribeService.canUnsubscribe(thread) && !thread.senderUnsubscribed
        if blocked != nil || canUnsubscribe {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    if let blocked {
                        Image(systemName: "shield.lefthalf.filled").font(.caption)
                        Text(blocked.trackers > 0
                             ? (blocked.trackers == 1 ? "1 tracker blocked" : "\(blocked.trackers) trackers blocked")
                             : "Images off")
                            .lineLimit(1)
                        Button("Show Images") {
                            showRemoteImages = true
                            if let senderEmail = thread.senderEmail {
                                Task { await store.trustSenderImages(senderEmail, account: thread.id.account) }
                            }
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CorresPalette.accent)
                        .fixedSize()
                    } else {
                        Image(systemName: "envelope.badge.shield.half.filled").font(.caption)
                        Text("Mailing list").lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if canUnsubscribe {
                        if isUnsubscribing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Unsubscribe") { showingUnsubscribeConfirmation = true }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(CorresPalette.accent)
                                .fixedSize()
                        }
                    }
                }
                .font(.footnote)
                .foregroundStyle(CorresPalette.tertiary)
                // No signal this finished (a handoff to a webpage, not a
                // one-click request), so a one-time note.
                if unsubscribeOpened {
                    Text("Opened in Safari. Finish unsubscribing there.")
                        .font(.caption).foregroundStyle(CorresPalette.secondary)
                }
            }
        }
    }

    /// The summary itself: a heading that folds it away (remembered, like
    /// Gmail's), what it covers, the summary, and any key points it left out.
    private func summaryBlock(_ insight: MailIntelligence.Insight, summary: String) -> some View {
        let isConversation = insight.messageCount > 1
        let title = isConversation ? "The conversation so far" : "In short"
        let coverage: String? = isConversation && insight.coversWholeMessage ? "\(insight.messageCount) messages" : nil
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { summaryCollapsed.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Label(title, systemImage: "sparkle")
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
            .accessibilityLabel(summaryCollapsed ? String(localized: "\(title), collapsed") : title)
            .accessibilityHint(summaryCollapsed ? "Shows the summary" : "Hides the summary")
            if !summaryCollapsed {
                Text(summary)
                    .font(.subheadline).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(summary)
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
        // Only the status to say ("No action needed: …")? Then a line, not a card.
        let hasMore = insight?.summary != nil || isPreparing || (keyDetailsOn && (glance != nil || buriedAsk != nil))
            || (nextStep != nil && !thread.isFromAccountOwner)
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
            if keyDetailsOn, let glance {
                glanceBlock(glance)
                Hairline().padding(.vertical, 2)
            } else if keyDetailsOn, insight?.summary == nil, !isPreparing, let buriedAsk, !thread.isFromAccountOwner {
                // A written summary already leads with the ask.
                askBlock(buriedAsk, due: thread.attention == .needsYou ? thread.dueAt : nil)
                Hairline().padding(.vertical, 2)
            }
            if let nextStep, !thread.isFromAccountOwner {
                nextStepRow(nextStep)
                Hairline().padding(.vertical, 2)
            }
            // At the largest text sizes the line gets the full width and
            // its buttons go under it; side by side, both broke mid-word.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text(statusLine(for: thread))
                        .font(.footnote)
                        .foregroundStyle(CorresPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { statusActions(for: thread) }
                        VStack(alignment: .leading, spacing: 4) { statusActions(for: thread) }
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(statusLine(for: thread))
                        .font(.footnote)
                        .foregroundStyle(CorresPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    statusActions(for: thread)
                }
            }
        }
        .padding(.horizontal, hasMore ? 16 : 0).padding(.vertical, hasMore ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if hasMore { Color.clear.corresSurface(radius: 18) } }
        .animation(.easeOut(duration: 0.25), value: insight)
    }

    /// Handled and Change, beside or under the status line.
    @ViewBuilder
    private func statusActions(for thread: Correspondence) -> some View {
        // One tap to take it out of Needs You (it stays in Mail);
        // under Change alone, testers didn't find it.
        if thread.attention(at: .now) == .needsYou {
            Button {
                Task { await threadActions.setAttention(.handled, for: thread) }
            } label: {
                Label("Handled", systemImage: "checkmark.circle")
                    .font(.footnote.weight(.semibold)).foregroundStyle(CorresPalette.accent)
                    .frame(minHeight: 32)
            }
            .accessibilityHint("Takes this out of Needs You. It stays in Mail.")
        }
        Menu {
            Section("Move To") {
                AttentionChoices(current: thread.attention) { attention in
                    Task { await threadActions.setAttention(attention, for: thread) }
                }
            }
            CategoryMenuItems(thread: thread) { categoryChoice = $0 }
        } label: {
            Text("Change").font(.footnote.weight(.semibold)).foregroundStyle(CorresPalette.accent)
                .frame(minHeight: 32)
        }
        .accessibilityLabel("Change where this conversation is sorted")
    }

    /// Where this conversation sits and why. Handled says where it went
    /// rather than the reason it once needed you.
    private func statusLine(for thread: Correspondence) -> String {
        if thread.isPastEvent(), let due = thread.dueAt {
            return String(localized: "Was on \(due.formatted(.dateTime.weekday(.wide).month(.wide).day())), so it's out of Needs You. It stays in Mail.")
        }
        switch thread.attention {
        case .handled: return String(localized: "Handled. It's off your lists and stays in Mail and in Mailboxes \u{2192} Handled.")
        case .quiet:
            // The reason often ends by saying so itself ("Marketing
            // newsletter, no action needed"); say it once.
            // "Kept out of Needs You" says the same again; once is enough.
            let reason = thread.reason.replacingPattern(#"(?i)[\s,;.—–-]*no action (is )?needed[.!]?"#, with: "")
                .replacingPattern(#"(?i)\s*kept out of needs you\.?"#, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? String(localized: "No action needed.")
                : String(localized: "No action needed: \(InboxClassifier.displayReason(reason))")
        default: return thread.reason.isEmpty ? thread.attention.title : "\(thread.attention.title): \(thread.displayReason)"
        }
    }

    /// A receipt's, delivery's or bill's status and key figures, the way
    /// Wallet lays out a pass: the status first, then label and value.
    private func glanceBlock(_ glance: Glance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = glance.status {
                Label(status, systemImage: glance.isAlert ? "exclamationmark.circle.fill" : "checkmark.circle")
                    .labelStyle(TightLabelStyle())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(glance.isAlert ? CorresPalette.alert : CorresPalette.ink)
            } else {
                Label("At a glance", systemImage: "list.bullet.rectangle").labelStyle(TightLabelStyle()).eyebrow(CorresPalette.accent)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 22) { glanceFacts(glance) }
                VStack(alignment: .leading, spacing: 8) { glanceFacts(glance) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func glanceFacts(_ glance: Glance) -> some View {
        ForEach(glance.facts, id: \.self) { fact in
            VStack(alignment: .leading, spacing: 1) {
                Text(fact.label).font(.caption).foregroundStyle(CorresPalette.secondary)
                Text(fact.value).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(CorresPalette.ink)
                    .textSelection(.enabled)
            }
            .fixedSize()
        }
    }

    /// What a long email asks of you, in the sender's words, so it isn't
    /// missed halfway down.
    private func askBlock(_ ask: String, due: Date?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("Asks you", systemImage: "questionmark.bubble").labelStyle(TightLabelStyle()).eyebrow(CorresPalette.accent)
                Spacer(minLength: 8)
                if let due { DueChip(date: due) }
            }
            Text("\u{201C}\(ask)\u{201D}")
                .font(.subheadline).lineSpacing(3).foregroundStyle(CorresPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The email's one call to action, opened where links open.
    private func nextStepRow(_ step: NextStep) -> some View {
        Button { LinkOpener.open(step.url) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Next step", systemImage: "arrow.turn.down.right")
                        .labelStyle(TightLabelStyle()).eyebrow(CorresPalette.accent)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(step.label).font(.body.weight(.semibold)).foregroundStyle(CorresPalette.ink)
                        if !step.host.isEmpty {
                            Text(step.host).font(.footnote).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(CorresPalette.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Next step: \(step.label)")
        .accessibilityHint("Opens \(step.host)")
    }

    /// Off the main thread: reading a designed email's links is a full pass
    /// over its HTML.
    private static func readingAids(in thread: Correspondence) async -> (nextStep: NextStep?, glance: Glance?, ask: String?) {
        guard thread.isBodyLoaded else { return (nil, nil, nil) }
        let isBulk = InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) != nil
        let isPromotion = InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) == .promotions
        let body = thread.body, html = thread.htmlBody, subject = thread.subject, sender = thread.senderEmail
        let automated = thread.looksAutomated, labelIds = thread.labelIds
        return await Task.detached(priority: .utility) {
            // The whole text, not the cleaned one: cleaning drops what
            // follows a sign-off, which is often exactly where the link is.
            let whole = MailDigest.readableText(body: body, html: html)
            let kind = isPromotion ? .newsletter
                : MailDigest.kind(subject: subject, text: MailDigest.clean(whole), senderEmail: sender, isBulk: isBulk,
                                  looksAutomated: automated, hasEvent: false, labelIds: labelIds)
            let cleaned = MailDigest.clean(whole)
            return (MailDigest.nextStep(text: whole, html: html, kind: kind),
                    MailDigest.glance(text: cleaned, subject: subject, kind: kind),
                    kind == .personal ? MailDigest.buriedAsk(text: cleaned) : nil)
        }.value
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
    /// A reply or forward quotes the original, so it needs the real body,
    /// not the snippet a metadata-first sync stored. Opening the thread
    /// already started loading it; this only waits in the rare case the
    /// person taps Reply before that finishes.
    private func compose(_ kind: Draft.Kind, from thread: Correspondence, prefill: String? = nil) {
        func open(_ source: Correspondence, attachments: [PendingAttachment] = []) {
            var draft = source.draft(kind: kind)
            if let prefill { draft.body = prefill + draft.body }
            draft.attachments = attachments
            composeDraft = draft
        }
        // A forward carries the email's attachments, as in Mail and Gmail;
        // it used to drop them without a word.
        if kind == .forward, !thread.attachments.isEmpty {
            guard !preparingForward else { return }
            preparingForward = true
            Task {
                defer { preparingForward = false }
                if !thread.isBodyLoaded { await threadActions.loadContent(for: thread) }
                let source = store.thread(thread.id) ?? thread
                let (files, missing) = await Self.downloadForForward(source)
                if missing.isEmpty {
                    open(source, attachments: files)
                } else {
                    var draft = source.draft(kind: kind)
                    if let prefill { draft.body = prefill + draft.body }
                    draft.attachments = files
                    forwardMissing = (draft, missing)
                }
            }
            return
        }
        guard !thread.isBodyLoaded else { return open(thread) }
        Task {
            await threadActions.loadContent(for: thread)
            open(store.thread(thread.id) ?? thread)
        }
    }

    /// The email's attachments as files to send on, up to Gmail's limit.
    /// The email's attachments as files to send on, up to Gmail's limit,
    /// and the names of any that couldn't come along.
    private static func downloadForForward(_ thread: Correspondence) async -> (files: [PendingAttachment], missing: [String]) {
        guard let messageID = thread.latestMessageID else { return ([], thread.attachments.map(\.filename)) }
        let client = MailClient()
        var files: [PendingAttachment] = []
        var missing: [String] = []
        var total = 0
        for attachment in thread.attachments {
            guard total + attachment.sizeBytes <= MailAccounts.provider(for: thread.id.account).attachmentLimit,
                  let data = try? await client.fetchAttachmentData(messageId: messageID, attachmentId: attachment.id,
                                                                   account: thread.id.account) else {
                missing.append(attachment.filename)
                continue
            }
            total += data.count
            files.append(PendingAttachment(filename: attachment.filename, mimeType: attachment.mimeType, data: data))
        }
        return (files, missing)
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
                                                        signOff: givenName.isEmpty || !CorresSettings.signature(for: source.id.account, reply: true).isEmpty ? nil : givenName)
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
           let data = try? await MailClient().fetchAttachmentData(messageId: messageID, attachmentId: invite.id,
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
                            .accessibilityHint("Drafts this reply on your \(Device.name) for you to review")
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
    /// A first email from someone: one line with the choice, not a card in
    /// front of the message. The address is right below, by the sender.
    private func newSenderCard(thread: Correspondence, email: String) -> some View {
        HStack(spacing: 10) {
            Label("First email from them", systemImage: "checkmark.shield")
                .labelStyle(TightLabelStyle())
                .font(.subheadline)
                .foregroundStyle(CorresPalette.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Same pair and styles as the New Senders screen, smaller.
            Button("Block") {
                Task {
                    await store.blockSender(email, account: thread.id.account)
                    dismiss()
                }
            }
            .buttonStyle(CorresPillStyle(minHeight: 34))
            .fixedSize()
            Button("Allow") {
                Task { await store.approveSender(email, account: thread.id.account) }
            }
            .buttonStyle(CorresMetalCapsuleStyle(minHeight: 34))
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("First email from \(email)")
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
            .accessibilityShowsLargeContentViewer {
                Image(systemName: "arrowshape.turn.up.left.fill")
                Text("Reply")
            }
        }
        .disabled(store.pending.contains(thread.id))
        .padding(.horizontal, CorresSpace.medium)
        // The bar keeps its size at the largest text sizes, as the system
        // bars do; press and hold shows an action large instead.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
                Task { await threadActions.toggleFlagged(!thread.isFlagged, for: [thread]) }
            }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") {
                Task { await threadActions.toggleUnread(!thread.isUnread, for: [thread]) }
            }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Snooze") { if store.isInLists(thread.id) { showingSnooze = true } }.keyboardShortcut("s", modifiers: [.command, .control])
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
        case .flag: thread.isFlagged ? ("flag.fill", String(localized: "Unflag"), CorresPalette.flag) : ("flag", String(localized: "Flag"), nil)
        case .unread: thread.isUnread ? ("envelope.open", String(localized: "Mark as Read"), nil) : ("envelope.badge", String(localized: "Mark as Unread"), nil)
        case .pin: thread.isPinned ? ("pin.fill", String(localized: "Unpin"), nil) : ("pin", String(localized: "Pin"), nil)
        case .trash: ("trash", String(localized: "Move to Trash"), nil)
        case .vip:
            thread.senderEmail.map(InboxClassifier.isVIP) == true
                ? ("star.slash", String(localized: "Remove from VIPs"), nil) : ("star", String(localized: "Add \(thread.sender) to VIPs"), nil)
        case .block: ("hand.raised", String(localized: "Block \(thread.sender)"), nil)
        default: (action.systemImage, action.title, nil)
        }
    }

    /// Whether an action applies to this email. On the bar an action that
    /// doesn't is dimmed, so the bar keeps its shape; in ⋯ it's left out.
    private func isAvailable(_ action: CorresSettings.ReadingAction, for thread: Correspondence) -> Bool {
        let fromSomeoneElse = thread.senderEmail != nil && !thread.isFromAccountOwner
        switch action {
        case .labels: return labelDirectory.labels(for: thread.id.account).contains { !$0.isFolder }
        case .vip, .block: return fromSomeoneElse
        case .unsubscribe: return unsubscribeService.canUnsubscribe(thread) && !thread.senderUnsubscribed
        case .calendar: return calendarEvent != nil && !thread.isFromAccountOwner
        case .spam: return !thread.isFromAccountOwner
        // Snooze and Pin keep mail in your lists; mail opened from a
        // mailbox (Trash, a folder) isn't in them, and saying "couldn't be
        // saved" afterwards was the only answer.
        case .snooze, .pin: return store.isInLists(thread.id)
        case .translate:
            #if targetEnvironment(macCatalyst)
            return false // the translation sheet is iPhone and iPad only
            #else
            if #available(iOS 17.4, *) { return true } else { return false }
            #endif
        default: return true
        }
    }

    private func perform(_ action: CorresSettings.ReadingAction, on thread: Correspondence) {
        switch action {
        case .archive: Task { await threadActions.archive(thread, animated: false) }
        case .trash: requestTrash(thread)
        case .flag: Task { await threadActions.toggleFlagged(!thread.isFlagged, for: [thread]) }
        case .snooze: showingSnooze = true
        case .unread: Task { await threadActions.toggleUnread(!thread.isUnread, for: [thread]) }
        case .pin: Task { await threadActions.togglePinned(thread) }
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
            // Where Mail and Gmail move mail: out of the Inbox, into a
            // label. Corres's own sorting is a section of its own below; on
            // its own it read as a broken "Move to".
            Section {
                Button { Task { await threadActions.archive(thread, animated: false) } } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                Button(role: .destructive) { requestTrash(thread) } label: {
                    Label("Trash", systemImage: "trash")
                }
                if !thread.isFromAccountOwner {
                    Button { Task { await threadActions.reportSpam(thread, animated: false) } } label: {
                        Label("Spam", systemImage: "xmark.bin")
                    }
                }
            }
            // Places to move it: Gmail's labels, Outlook's folders (an
            // Outlook category is a tag, not a place).
            let labels = labelDirectory.labels(for: thread.id.account).filter { !$0.isCategory }
            if !labels.isEmpty {
                Section(labels.contains(where: \.isFolder) ? "Folders" : "Labels") {
                    ForEach(labels) { label in
                        Button {
                            Task { await threadActions.moveToLabel(label.id, named: label.name.components(separatedBy: "/").last ?? label.name, thread) }
                        } label: {
                            Label(label.name, systemImage: label.isFolder ? "folder" : "tag")
                        }
                    }
                }
            }
            Section("Sort Into") {
                AttentionChoices(current: thread.attention) { attention in
                    Task { await threadActions.setAttention(attention, for: thread) }
                }
            }
        } else {
            // Tags to put on and take off: Gmail's labels, Outlook's
            // categories (a folder is a place, under Move to).
            ForEach(labelDirectory.labels(for: thread.id.account).filter { !$0.isFolder }) { label in
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
        guard let top = topViewController() else { return }
        // iPad shows it as a popover, which must point at something or it
        // crashes: anchored at the bottom centre, where the toolbar is.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
            popover.permittedArrowDirections = [.down]
        }
        top.present(sheet, animated: true)
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
        // The bar keeps its size at the largest text sizes, as the system
        // bars do; press and hold shows the action large instead.
        .accessibilityShowsLargeContentViewer {
            Image(systemName: systemImage)
            Text(label)
        }
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

/// An attachment, marked by what it is: a red PDF, a blue Word file, a
/// green spreadsheet, as Gmail and Outlook mark them, and a real preview
/// (the photo, a document's first page) once it's small enough to fetch
/// as the email opens. Raised off the page so it reads as something to
/// tap (tester feedback: it melted into the background, and every type
/// looked the same).
///
/// A tap downloads it on demand (never during sync, see
/// `Correspondence.attachments`) and opens iOS's own QuickLook, as Mail
/// does, with saving and sharing in its toolbar.
private struct AttachmentRow: View {
    let attachment: MailAttachment
    let messageID: String
    let account: String
    @State private var isDownloading = false
    @State private var previewURL: URL?
    @State private var downloadFailed = false
    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    private let client = MailClient()

    private var kind: AttachmentKind { AttachmentKind(filename: attachment.filename, mimeType: attachment.mimeType) }

    /// Fetched just to draw the preview: small files only, and never in
    /// Low Data Mode.
    private static let previewLimit = 3_000_000

    var body: some View {
        Button {
            Task { await download() }
        } label: {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(CorresPalette.ink)
                        .lineLimit(2).truncationMode(.middle)
                    Text("\(kind.label(filename: attachment.filename)) \u{00B7} \(formattedSize)")
                        .font(.caption).foregroundStyle(CorresPalette.secondary)
                }
                Spacer(minLength: 8)
                if isDownloading {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(CorresPalette.accent)
                }
            }
            .padding(12)
            // A card in either appearance: white with a real edge and a soft
            // shadow on Ivory (the near-white surface melted into the page
            // in light mode), raised gray with a light edge on Obsidian,
            // where shadows don't show.
            .background(colorScheme == .dark ? Color(uiColor: .secondarySystemBackground) : .white,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.12), lineWidth: 1))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.08), radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(isDownloading)
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.label(filename: attachment.filename)), \(attachment.filename), \(formattedSize)")
        .accessibilityHint("Opens the attachment")
        .quickLookPreview($previewURL)
        .alert("Couldn't Download Attachment", isPresented: $downloadFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("Try again.") }
        .task(id: attachment.id) { await loadThumbnail() }
        // Each download writes to a fresh, uniquely-named directory (see
        // `download()`); it goes when this row does, rather than piling up
        // in tmp/ for the rest of the session.
        .onDisappear { cleanUpDownloadedFile() }
    }

    /// The preview when there is one; otherwise the type's own color and
    /// symbol.
    private var badge: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()

            } else {
                kind.color
                Image(systemName: kind.symbol).font(.title3.weight(.semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // On a preview, the type stays marked: "PDF" in red, a play button
        // on a video.
        .overlay(alignment: .bottomLeading) {
            if thumbnail != nil, let tag = kind.tag {
                Text(tag)
                    .font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(kind.color, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .padding(3)
            }
        }
        .overlay {
            if thumbnail != nil, kind == .video {
                Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(.white).shadow(radius: 2)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CorresPalette.line, lineWidth: thumbnail == nil ? 0 : 0.5))
        .accessibilityHidden(true)
    }

    private func loadThumbnail() async {
        guard thumbnail == nil, kind.hasPreview, attachment.sizeBytes <= Self.previewLimit, account != "sample" else { return }
        if let cached = AttachmentThumbnails.cache.object(forKey: attachment.id as NSString) {
            thumbnail = cached
            return
        }
        guard !AttachmentThumbnails.isLowData,
              let data = try? await client.fetchAttachmentData(messageId: messageID, attachmentId: attachment.id, account: account) else { return }
        let size = CGSize(width: 48, height: 48)
        let scale = displayScale
        let filename = attachment.filename
        let image = await AttachmentThumbnails.make(from: data, filename: filename, size: size, scale: scale)
        guard let image, !Task.isCancelled else { return }
        AttachmentThumbnails.cache.setObject(image, forKey: attachment.id as NSString)
        withAnimation(.easeOut(duration: 0.2)) { thumbnail = image }
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

/// Attachment previews, made once per attachment and kept while Corres
/// runs.
enum AttachmentThumbnails {
    nonisolated(unsafe) static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    /// Low Data Mode is on: no fetching just to draw a preview.
    nonisolated(unsafe) private static var constrained = false
    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { constrained = $0.isConstrained }
        monitor.start(queue: DispatchQueue(label: "corres.attachments.path"))
        return monitor
    }()
    static var isLowData: Bool {
        _ = monitor
        return constrained
    }

    /// QuickLook's own preview: a photo, a PDF's or document's first page,
    /// a video's frame.
    static func make(from data: Data, filename: String, size: CGSize, scale: CGFloat) async -> UIImage? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        let url = directory.appendingPathComponent(filename)
        guard (try? data.write(to: url)) != nil else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size.width * 2, height: size.height * 2),
                                                   scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }
}


/// Apple's on-device translation sheet (iOS 17.4 and later).
private struct TranslateSheet: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        if #available(iOS 17.4, *) {
            content.translationPresentation(isPresented: $isPresented, text: text)
        } else {
            content
        }
        #endif
    }
}

/// iOS 26's hard scroll edge: the content goes under a frosted band.
private struct HardTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}
