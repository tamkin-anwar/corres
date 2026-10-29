import NaturalLanguage
import QuickLook
import SwiftUI
import Translation

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
    /// Earlier messages opened to their full text, by message id.
    @State private var openEarlier: Set<String> = []
    @State private var invitation: Invitation?
    @State private var personCard: PersonRef?
    @State private var aids = ReadingAids()
    @State private var draftingIntent: String?
    /// The email's language, when it isn't one you read (Mail's Translate banner).
    @State private var foreignLanguage: Locale.Language?
    @State private var showingTranslation = false
    @AppStorage(CorresSettings.keyDetailsKey) private var keyDetailsOn = true
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
                if thread.senderDecision == .pending, MailQuery.newSenderMode != .acceptAll, let email = thread.senderEmail {
                    newSenderBar(email: email)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                }
                statusCard
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
                if let intents = replyIntents {
                    replyChips(intents)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                }
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
                if let foreignLanguage {
                    translateLine(foreignLanguage)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 10)
                }
                if services.unsubscribeService.canUnsubscribe(thread), !thread.senderUnsubscribed {
                    unsubscribeLine
                        .padding(.horizontal, 28)
                        .padding(.bottom, 10)
                }
                Divider().padding(.horizontal, 28)
                HTMLMessageBody(html: html, height: $bodyHeight, heightKey: MessageHeights.key(thread),
                                expectedHeight: MessageHeights.expected(for: thread), blockRemoteImages: !imagesAllowed)
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
                    .macFont(.callout)
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
        .translationPresentation(isPresented: $showingTranslation,
                                 text: showingTranslation ? MailDigest.readableText(body: thread.body, html: thread.htmlBody) : "")
        .id(thread.id)
        .task(id: thread.id) { await opened() }
        .onChange(of: showImages) { _, shown in
            if shown { MacPrinter.imagesShown.insert(thread.id) }
        }
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
                openReply(prefill: String(localized: "Here are a few times that work for me:\n\n\(times)\n\nDo any of these suit you?"))
            }
        } label: {
            Label("Suggest Times from Your Calendar", systemImage: "calendar.badge.clock").macTextSize()
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
                .macFont(size: 24, weight: .regular, design: .serif)
                .foregroundStyle(CorresPalette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                Button { showPerson() } label: {
                    CorrespondentAvatar(initials: thread.initials, email: thread.senderEmail, size: CGSize(width: 38, height: 38),
                                        companyLogo: thread.showsCompanyLogo)
                }
                .buttonStyle(.plain)
                .help("Show your mail with \(thread.sender)")
                // The picture has no words of its own; the name beside it
                // is the same button for VoiceOver.
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button { showPerson() } label: {
                            Text(thread.sender).macFont(.headline).foregroundStyle(CorresPalette.ink)
                        }
                        .buttonStyle(.plain)
                        .help("Show your mail with \(thread.sender)")
                        if let email = thread.senderEmail, email.lowercased() != thread.sender.lowercased() {
                            Text(email).macFont(.subheadline).foregroundStyle(CorresPalette.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if !recipients.isEmpty {
                        Text(recipients).macFont(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(thread.receivedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                        .macFont(.subheadline).foregroundStyle(CorresPalette.secondary)
                    if services.auth.accounts.count > 1 {
                        Text(AccountPreferences.nickname(for: thread.id.account))
                            .macFont(.caption).foregroundStyle(CorresPalette.tertiary)
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
        // Corres's own line from the email stands in for a written summary;
        // a quoted sentence gives way to one (as on the iPhone).
        let card = keyDetailsOn ? aids.card : nil
        let hasHeadline = card?.headline != nil
        let insight = summariesOn && !hasHeadline ? intelligence.insight(for: thread) : nil
        let preparing = summariesOn && !hasHeadline && insight?.summary == nil && intelligence.isPreparing(thread)
        let showsGist = insight?.summary == nil && !preparing && (card?.headline ?? card?.quote) != nil
        let details = aids.glance == nil ? card?.details ?? [] : []
        return VStack(alignment: .leading, spacing: 10) {
            if showsGist, let card {
                let text = card.headline ?? card.quote.map { "\u{201C}\($0)\u{201D}" } ?? ""
                Label(card.topic.title, systemImage: card.topic.symbol)
                    .macFont(.caption, weight: .semibold).foregroundStyle(CorresPalette.accent)
                Text(text).macFont(.body).foregroundStyle(CorresPalette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(card.topic.title): \(text)")
            }
            if !details.isEmpty {
                FlowRow(spacing: 22) {
                    ForEach(details, id: \.self) { fact in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Glance.display(fact.label)).macFont(.caption).foregroundStyle(CorresPalette.secondary)
                            Text(fact.value).macFont(.body, weight: .semibold).foregroundStyle(CorresPalette.ink)
                                .textSelection(.enabled)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if showsGist || !details.isEmpty { Divider() }
            if let insight, let summary = insight.summary {
                Label("In short", systemImage: "sparkle")
                    .macFont(.caption, weight: .semibold).foregroundStyle(CorresPalette.accent)
                Text(summary).macFont(.body).foregroundStyle(CorresPalette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ForEach(insight.details, id: \.self) { detail in
                    Text("• " + detail).macFont(.callout).foregroundStyle(CorresPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
            } else if preparing {
                HStack(spacing: 8) {
                    Label("In short", systemImage: "sparkle")
                        .macFont(.caption, weight: .semibold).foregroundStyle(CorresPalette.accent)
                    ProgressView().controlSize(.mini)
                }
                Divider()
            }
            if keyDetailsOn, let glance = aids.glance {
                glanceBlock(glance)
                Divider()
            } else if keyDetailsOn, insight?.summary == nil, !preparing, let ask = aids.ask, !thread.isFromAccountOwner {
                // A written summary already leads with the ask.
                askBlock(ask)
                Divider()
            }
            if let step = aids.nextStep, !thread.isFromAccountOwner {
                nextStepRow(step)
                Divider()
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(statusLine).macFont(.callout).foregroundStyle(CorresPalette.secondary)
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
                    Text("Move").macTextSize()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if thread.attention(at: .now) == .needsYou {
                    Button {
                        Task { await services.threadActions.setAttention(.handled, for: thread) }
                    } label: {
                        Text("Handled").macTextSize()
                    }
                    .buttonStyle(.bordered)
                    .macControlSize(.small)
                }
            }
        }
        .padding(14)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CorresPalette.line))
    }

    /// A receipt's, delivery's or bill's status and key figures, the way
    /// Wallet lays out a pass.
    private func glanceBlock(_ glance: Glance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = glance.status {
                Label(Glance.display(status), systemImage: glance.isAlert ? "exclamationmark.circle.fill" : "checkmark.circle")
                    .macFont(.callout, weight: .semibold)
                    .foregroundStyle(glance.isAlert ? CorresPalette.alert : CorresPalette.ink)
            } else {
                Label("At a glance", systemImage: "list.bullet.rectangle")
                    .macFont(.caption, weight: .semibold).foregroundStyle(CorresPalette.accent)
            }
            FlowRow(spacing: 22) {
                ForEach(glance.facts, id: \.self) { fact in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Glance.display(fact.label)).macFont(.caption).foregroundStyle(CorresPalette.secondary)
                        Text(fact.value).macFont(.body, weight: .semibold).monospacedDigit().foregroundStyle(CorresPalette.ink)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What a long email asks of you, in the sender's words, so it isn't
    /// missed halfway down.
    private func askBlock(_ ask: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("Asks you", systemImage: "questionmark.bubble")
                    .macFont(.caption, weight: .semibold).foregroundStyle(CorresPalette.accent)
                Spacer(minLength: 8)
                if thread.attention == .needsYou, let due = thread.dueAt { DueChip(date: due) }
            }
            Text("\u{201C}\(ask)\u{201D}").macFont(.body).foregroundStyle(CorresPalette.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The email's one call to action, opened where links open.
    private func nextStepRow(_ step: NextStep) -> some View {
        Button { LinkOpener.open(step.url) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Next step", systemImage: "arrow.turn.down.right")
                        .macFont(.caption, weight: .semibold).foregroundStyle(CorresPalette.accent)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Glance.display(step.label)).macFont(.body, weight: .semibold).foregroundStyle(CorresPalette.ink)
                        if !step.host.isEmpty {
                            Text(step.host).macFont(.callout).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").macFont(.callout, weight: .semibold).foregroundStyle(CorresPalette.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(step.host.isEmpty ? Glance.display(step.label) : String(localized: "Opens \(step.host)"))
        .accessibilityLabel("Next step: \(Glance.display(step.label))")
    }

    // MARK: New senders and suggested replies

    /// A first email from someone, as on the iPhone: Allow or Block it
    /// here instead of hunting for them in New Senders.
    private func newSenderBar(email: String) -> some View {
        HStack(spacing: 10) {
            Label("First email from them. Allow them into your inbox?", systemImage: "checkmark.shield")
                .macFont(.callout).foregroundStyle(CorresPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { Task { await services.store.blockSender(email, account: thread.id.account) } } label: { Text("Block").macTextSize() }
                .help("Their mail stays out of every list, and they're never told.")
            Button { Task { await services.store.approveSender(email, account: thread.id.account) } } label: { Text("Allow").macTextSize() }
                .buttonStyle(.borderedProminent)
                .help("Their mail comes to your inbox from now on.")
        }
        .padding(12)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CorresPalette.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("First email from \(email)")
    }

    /// Apple Intelligence's suggested answers, once it has read the email,
    /// and only until you've answered.
    private var replyIntents: [String]? {
        guard summariesOn, !ReplyDrafting.hasAnswered(thread),
              let intents = intelligence.insight(for: thread)?.replyIntents, !intents.isEmpty else { return nil }
        return intents
    }

    /// Clicking one writes the whole reply in your own words, then opens it
    /// to read and change. Nothing sends without you.
    private func replyChips(_ intents: [String]) -> some View {
        FlowRow(spacing: 8) {
            ForEach(intents, id: \.self) { intent in
                Button {
                    draftReply(intent)
                } label: {
                    HStack(spacing: 6) {
                        if draftingIntent == intent { ProgressView().controlSize(.small) }
                        // A bordered button sets its own font; this one is read.
                        Text(intent).macTextSize()
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(draftingIntent != nil)
                .help("Writes this reply for you to read and change")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested replies")
    }

    private func draftReply(_ intent: String) {
        guard draftingIntent == nil else { return }
        draftingIntent = intent
        let id = thread.id
        Task {
            let source = services.store.thread(id) ?? thread
            let drafted = await ReplyDrafting.draft(intent, replyingTo: source, with: intelligence)
            // Moved on to another email meanwhile: opening it cleared this,
            // and a reply to the one left behind would be a surprise.
            guard draftingIntent == intent else { return }
            draftingIntent = nil
            openReply(prefill: drafted ?? "")
        }
    }

    /// A reply that starts with `prefill`, above your signature and the
    /// quoted email.
    private func openReply(prefill: String) {
        let source = services.store.thread(thread.id) ?? thread
        var draft = source.draft(kind: .reply)
        draft.body = Draft.adding(signature: CorresSettings.signature(for: source.id.account, reply: true), to: prefill + draft.body)
        let handoff = UUID()
        MacComposeHandoff.drafts[handoff] = draft
        // A new reply, as Reply makes: from the address of yours it was sent to.
        MacComposeHandoff.fresh.insert(handoff)
        openWindow(value: ComposeRequest(kind: .reply, handoff: handoff))
    }

    /// Where it's sorted and why, in the same words as on the iPhone
    /// (`InShort.statusLine`): what the email is, not only how it was sent.
    private var statusLine: String {
        InShort.statusLine(for: thread, topic: aids.card?.topic)
    }

    /// With Pro, or on sample mail before any account is connected, as on
    /// the iPhone (`proUnlocked`): summaries used to need Pro even there.
    private var summariesOn: Bool { !services.requiresPro && CorresSettings.summaries && intelligence.isAvailable }

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
                    .macFont(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CorresPalette.accent)
            if showEarlier {
                ForEach(earlier) { message in
                    earlierMessage(message)
                }
            }
        }
    }

    /// One earlier message: a few lines, or, clicked, all of its own words
    /// without the history it quotes, as on the iPhone (`EarlierMessages`).
    private func earlierMessage(_ message: Correspondence) -> some View {
        let key = message.latestMessageID ?? message.id.providerID
        let isOpen = openEarlier.contains(key)
        // The text sits outside the button, so it can be selected.
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) {
                    if isOpen { openEarlier.remove(key) } else { openEarlier.insert(key) }
                }
            } label: {
                HStack {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .macFont(.caption, weight: .semibold).foregroundStyle(CorresPalette.tertiary)
                    Text(message.sender).macFont(.callout, weight: .semibold)
                    Spacer()
                    Text(MacDates.short(message.receivedAt)).macFont(.caption).foregroundStyle(CorresPalette.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Collapses this message" : "Shows the full message")
            if isOpen {
                Text(Self.ownWords(of: message))
                    .macFont(.body).foregroundStyle(CorresPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(MailDigest.preview(body: message.body, html: message.htmlBody) ?? message.excerpt)
                    .macFont(.callout).foregroundStyle(CorresPalette.secondary)
                    .lineLimit(4).textSelection(.enabled)
            }
        }
        .padding(10)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    /// The message's own words, in full: without the quoted history every
    /// reply repeats, in any language (`QuoteDetector.ownPart`).
    private static func ownWords(of message: Correspondence) -> String {
        let text = MailDigest.readableText(body: message.body, html: message.htmlBody)
        let own = QuoteDetector.ownPart(of: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? message.excerpt : own
    }

    // MARK: Images and attachments

    private var blockedImages: Int { thread.htmlBody.map { HTMLMessageBody.analysis(of: $0).remoteImages } ?? 0 }
    private var imagesAllowed: Bool { showImages || thread.imagesTrusted || CorresSettings.remoteImages == .always }

    @State private var unsubscribing = false
    @State private var unsubscribed = false

    /// Mail's banner: a newsletter or list, one click to leave it.
    private var unsubscribeLine: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.badge.shield.half.filled").foregroundStyle(CorresPalette.secondary)
            Text(unsubscribed ? "Unsubscribed. You won't get more from this list."
                              : "This email is from a mailing list.")
                .macFont(.callout).foregroundStyle(CorresPalette.secondary)
            Spacer()
            if !unsubscribed {
                if unsubscribing { ProgressView().controlSize(.small) }
                Button {
                    unsubscribing = true
                    Task {
                        let outcome = await services.unsubscribeService.unsubscribe(from: thread, store: services.store)
                        unsubscribing = false
                        unsubscribed = outcome == .done
                    }
                } label: {
                    Text("Unsubscribe").macTextSize()
                }
                .macControlSize(.small)
                .disabled(unsubscribing)
            }
        }
        .padding(10)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    /// "This email is in Japanese. Translate", as Mail and Safari offer.
    private func translateLine(_ language: Locale.Language) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "translate").foregroundStyle(CorresPalette.secondary)
            let name = Locale.current.localizedString(forLanguageCode: language.languageCode?.identifier ?? "") ?? ""
            Text(name.isEmpty ? String(localized: "This email is in another language.") : String(localized: "This email is in \(name)."))
                .macFont(.callout).foregroundStyle(CorresPalette.secondary)
            Spacer()
            Button { showingTranslation = true } label: { Text("Translate").macTextSize() }
                .macControlSize(.small)
                .help("Translates it on this Mac with Apple's Translate")
        }
        .padding(10)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    /// The email's language when you don't read it: none of your preferred
    /// languages, and clear enough to say.
    nonisolated private static func foreignLanguage(of thread: Correspondence) async -> Locale.Language? {
        guard thread.isBodyLoaded else { return nil }
        let body = thread.body, html = thread.htmlBody, subject = thread.subject
        return await Task.detached(priority: .utility) {
            let text = subject + "\n" + MailDigest.readableText(body: body, html: html)
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(String(text.prefix(2_000)))
            guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
                  confidence > 0.8, language != .undetermined else { return nil }
            let found = Locale.Language(identifier: language.rawValue)
            let yours = Locale.preferredLanguages.map { Locale.Language(identifier: $0).languageCode }
            return yours.contains(found.languageCode) ? nil : found
        }.value
    }

    private var imagesNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(CorresPalette.secondary)
            // Worked out once per message, not on every redraw.
            let trackers = thread.htmlBody.map { HTMLMessageBody.analysis(of: $0).trackers } ?? 0
            Text(trackers == 1 ? "Images hidden, and 1 tracker blocked"
                 : trackers > 1 ? "Images hidden, and \(trackers) trackers blocked"
                              : "Images hidden")
                .macFont(.callout).foregroundStyle(CorresPalette.secondary)
            Spacer()
            Button { showImages = true } label: { Text("Show Images").macTextSize() }.macControlSize(.small)
            if let sender = thread.senderEmail {
                Button {
                    showImages = true
                    Task { await services.store.trustSenderImages(sender, account: thread.id.account) }
                } label: {
                    Text("Always from \(thread.sender)").macTextSize()
                }
                .macControlSize(.small)
            }
        }
        .padding(10)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(thread.attachments.count == 1 ? String(localized: "1 attachment") : String(localized: "\(thread.attachments.count) attachments"))
                .macFont(.caption, weight: .semibold).foregroundStyle(CorresPalette.secondary)
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
        // The pane stays as you move between emails: the last one's
        // Unsubscribe doesn't carry over to the next newsletter.
        unsubscribed = false
        unsubscribing = false
        await services.store.loadStoredContent(thread.id)
        showImages = false
        // Hidden again on screen, so hidden again on paper.
        MacPrinter.imagesShown.remove(thread.id)
        showEarlier = false
        openEarlier = []
        invitation = nil
        aids = ReadingAids()
        foreignLanguage = nil
        showingTranslation = false
        draftingIntent = nil
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
        let current = services.store.thread(thread.id) ?? thread
        invitation = await InvitationCard.find(in: current)
        aids = await ReadingAids.find(in: current)
        foreignLanguage = await Self.foreignLanguage(of: current)
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
    @State private var saveFailed = false

    var body: some View {
        let kind = AttachmentKind(filename: file.filename, mimeType: file.mimeType)
        // A click looks at it in Quick Look, as in Mail and Finder;
        // Open hands it to its app.
        Button { Task { previewURL = await download() } } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(kind.color)
                    Image(systemName: kind.symbol).macFont(.caption, weight: .semibold).foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(file.filename).lineLimit(1).truncationMode(.middle)
                    Text(failed ? String(localized: "Couldn't download") : ByteCountFormatter.string(fromByteCount: Int64(file.sizeBytes), countStyle: .file))
                        .macFont(.caption).foregroundStyle(failed ? CorresPalette.alert : CorresPalette.secondary)
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
        .alert("Couldn't Save", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Couldn't save. Try again.")
        }
    }

    private func download() async -> URL? {
        // A folder of its own for each attachment in the message: two with
        // the same name ("image.png", twice) opened the first for both.
        let position = thread.attachments.firstIndex { $0.id == file.id } ?? 0
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(thread.latestMessageID ?? thread.id.providerID, isDirectory: true)
            .appendingPathComponent(String(position), isDirectory: true)
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
            destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                .map { Self.unusedName(url.lastPathComponent, in: $0) }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url.lastPathComponent
            destination = panel.runModal() == .OK ? panel.url : nil
        }
        guard let destination else { return }
        // Save As has asked about replacing; Downloads never replaces.
        if !toDownloads { try? FileManager.default.removeItem(at: destination) }
        // Said, not silent: a save that didn't land looked like it had.
        guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { saveFailed = true; return }
        if toDownloads { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
    }

    /// "invoice.pdf", or "invoice 2.pdf" when that's taken, as Safari
    /// names a second download of the same file.
    private static func unusedName(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name), number = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            number += 1
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
        }
        return candidate
    }
}
