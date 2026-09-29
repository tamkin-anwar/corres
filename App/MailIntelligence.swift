import Foundation
import FoundationModels
import Observation

/// Reading and writing help, entirely on this iPhone: a short summary of an
/// email or a whole conversation, a few one-tap reply directions, a drafted
/// reply in the person's own voice, and tone rewrites of whatever they've
/// written.
///
/// Built on Apple's Foundation Models framework (the on-device model behind
/// Apple Intelligence), like `SemanticTriageService`. There is deliberately
/// no cloud fallback: mail never leaves the device. On an iPhone without
/// Apple Intelligence, summaries are taken word for word from the email
/// instead (see `MailDigest.extractiveSummary`).
///
/// Summaries are held to the email: every number, date, name and code in
/// one must be in the email itself (`MailDigest.unsupportedClaims`). One
/// that isn't gets one stricter retry, then the word-for-word summary; a
/// wrong summary is never shown.
///
/// Everything is advisory. A drafted reply lands in the compose sheet for
/// the person to read and edit; nothing here ever sends, files, or changes
/// a message on its own.
@MainActor @Observable
final class MailIntelligence {
    struct Insight: Equatable, Codable {
        /// Nil for messages short enough that a summary would only repeat them.
        let summary: String?
        /// A few more points worth knowing that the summary leaves out,
        /// shown when the card is expanded.
        var details: [String] = []
        /// Up to three short reply directions ("Count me in"), empty when
        /// the message doesn't call for a reply.
        let replyIntents: [String]
        /// False when the email or conversation was too long for the
        /// on-device model to read whole; the card says so.
        var coversWholeMessage = true
        /// Taken word for word from the email rather than written by the
        /// model (no Apple Intelligence, or the model's summary failed the
        /// accuracy check).
        var isExtractive = false
        /// How many messages it covers; more than one is a conversation
        /// summary.
        var messageCount = 1
        var createdAt = Date.now
    }

    enum Tone: String, CaseIterable, Identifiable {
        case shorter = "Shorter", warmer = "Warmer", formal = "More formal", proofread = "Proofread"
        var id: String { rawValue }
        var instruction: String {
            switch self {
            case .shorter: "Make it noticeably shorter and more direct. Keep every fact, date, and commitment."
            case .warmer: "Make it warmer and friendlier without adding new facts or commitments."
            case .formal: "Make it more formal and polished, suitable for a professional contact."
            case .proofread: "Fix spelling, grammar, and punctuation only. Change nothing else."
            }
        }
    }

    /// Keyed by account and latest message id, so a new reply landing in
    /// the thread gets a fresh read. Saved to disk, so an email opened
    /// before shows its summary instantly, even after a relaunch.
    private(set) var insights: [String: Insight] = [:]
    private(set) var inFlight: Set<String> = []
    private var isPrewarming = false
    private var saveTask: Task<Void, Never>?

    init() {
        loadCache()
    }

    /// Checked on every call: Apple Intelligence can finish downloading, or
    /// be switched on, while Corres is already running.
    var isAvailable: Bool {
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
    }

    /// Characters of email the model reads in one go. The on-device model's
    /// window is about 4k tokens including instructions and output; this
    /// leaves room for both.
    nonisolated private static let promptBudget = 6_000
    /// A long email is read in sections of this size, then summarized from
    /// its sections' key points.
    nonisolated private static let sectionSize = 5_000
    nonisolated private static let maxSections = 4
    /// Bumped whenever what a summary contains changes, so old ones are
    /// recomputed rather than shown.
    private static let cacheVersion = 2
    private static let cacheLimit = 1_500
    private static let sampleAccount = "sample"

    func insight(for thread: Correspondence) -> Insight? {
        insights[Self.key(for: thread)]
    }

    func isPreparing(_ thread: Correspondence) -> Bool {
        inFlight.contains(Self.key(for: thread))
    }

    private static func key(for thread: Correspondence) -> String {
        thread.id.account + "|" + (thread.latestMessageID ?? "thread:\(thread.id.providerID)")
    }

    // MARK: - Summaries

    /// Computes (once per message, and again when a conversation grows) a
    /// summary and reply directions. `conversation` is every message in the
    /// thread, oldest first, when known; with more than one, the summary
    /// covers where the whole conversation stands. Safe to call repeatedly
    /// from `.task`; concurrent calls for the same message coalesce.
    func prepareInsight(for thread: Correspondence, conversation: [Correspondence]? = nil) async {
        let key = Self.key(for: thread)
        let messages = (conversation?.isEmpty == false ? conversation : nil) ?? [thread]
        if let existing = insights[key], existing.messageCount >= messages.count { return }
        guard thread.isBodyLoaded, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let readable = await Self.readableMessages(messages, reader: thread.id.account.lowercased())
        guard let latest = readable.last else {
            store(Insight(summary: nil, replyIntents: []), for: key)
            return
        }
        let isConversation = readable.count > 1
        let words = readable.reduce(0) { $0 + MailDigest.wordCount($1.text) }
        let wantsSummary = words >= MailDigest.minimumWords
        // Nothing to answer when the last word is yours.
        // Only a person writing to you gets reply suggestions: never
        // automated or Gmail-categorized mail.
        let isBulk = InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) != nil
        let wantsReplies = !isBulk && thread.attention != .waiting && !thread.isFromAccountOwner && isAvailable
        guard wantsSummary || wantsReplies else {
            store(Insight(summary: nil, replyIntents: [], messageCount: messages.count), for: key)
            return
        }
        let kind = MailDigest.kind(subject: thread.subject, text: latest.text, senderEmail: thread.senderEmail,
                                   isBulk: isBulk, looksAutomated: thread.looksAutomated, hasEvent: false)
        let source = thread.subject + "\n" + readable.map { $0.sender + "\n" + $0.text }.joined(separator: "\n")
        let fallback = wantsSummary ? MailDigest.extractiveSummary(text: latest.text, kind: kind) : nil

        guard isAvailable, #available(iOS 26.0, *),
              let result = await generate(thread: thread, messages: readable, kind: kind, isConversation: isConversation,
                                          source: source, wantsSummary: wantsSummary) else {
            store(Insight(summary: fallback, replyIntents: [], isExtractive: true, messageCount: messages.count), for: key)
            return
        }
        let summary = wantsSummary ? (result.summary ?? fallback) : nil
        store(Insight(summary: summary,
                      details: summary == nil || result.summary == nil ? [] : result.details,
                      replyIntents: wantsReplies ? Array(result.replies.prefix(3)) : [],
                      coversWholeMessage: result.covered,
                      isExtractive: wantsSummary && result.summary == nil,
                      messageCount: messages.count), for: key)
    }

    /// Each message as plain, cleaned text. Off the main thread: turning a
    /// long designed email's HTML into text is the heaviest step before the
    /// model runs, and on the main thread it hitched scrolling whenever
    /// background summaries ran after a sync, and the opening of an email.
    nonisolated private static func readableMessages(_ messages: [Correspondence], reader: String) async -> [MailDigest.Message] {
        messages.map { message in
            MailDigest.Message(sender: message.sender,
                               isFromReader: message.senderEmail?.lowercased() == reader,
                               date: message.receivedAt,
                               text: MailDigest.clean(MailDigest.readableText(body: message.body, html: message.htmlBody)))
        }.filter { !$0.text.isEmpty }
    }

    /// Readies summaries for the mail most likely to be opened next (new,
    /// unread, or needing a reply, from the last few days), one at a time,
    /// so opening it shows the summary instantly. Foreground only; called
    /// after a sync has filled in bodies.
    /// With `includeRead` (summaries shown in the list), recent read mail
    /// is readied too, so the top of the list reads as summaries.
    func prewarm(_ threads: [Correspondence], includeRead: Bool = false) async {
        guard isAvailable, !isPrewarming else { return }
        isPrewarming = true
        defer { isPrewarming = false }
        let recent = Date.now.addingTimeInterval(-3 * 86_400)
        let candidates = threads.filter { thread in
            thread.isBodyLoaded && thread.id.account != Self.sampleAccount && thread.senderDecision == .approved
                && thread.receivedAt > recent && (includeRead || thread.isUnread || thread.attention == .needsYou)
                && !thread.isSnoozed(at: .now) && insights[Self.key(for: thread)] == nil
        }.sorted { $0.receivedAt > $1.receivedAt }.prefix(includeRead ? 40 : 15)
        for thread in candidates {
            guard !Task.isCancelled else { return }
            await prepareInsight(for: thread)
        }
    }

    /// Drops saved summaries for an account that's been removed.
    func forget(account: String) {
        insights = insights.filter { !$0.key.hasPrefix(account + "|") }
        scheduleSave()
    }

    private func store(_ insight: Insight, for key: String) {
        insights[key] = insight
        scheduleSave()
    }

    // MARK: - Model calls

    private struct Generated {
        let summary: String?
        let details: [String]
        let replies: [String]
        let covered: Bool
    }

    @available(iOS 26.0, *)
    private func generate(thread: Correspondence, messages: [MailDigest.Message], kind: MailDigest.Kind,
                          isConversation: Bool, source: String, wantsSummary: Bool) async -> Generated? {
        guard let latest = messages.last else { return nil }
        // What the model reads: the conversation, the email, or, for a long
        // email, the key points of each section plus its closing.
        var body: String
        var covered = true
        if isConversation {
            let transcript = MailDigest.transcript(messages, budget: Self.promptBudget)
            body = "Conversation, oldest first:\n" + transcript.text
            covered = !transcript.wasShortened
        } else if latest.text.count <= Self.promptBudget {
            body = "Email:\n" + latest.text
        } else {
            var sections = MailDigest.sections(of: latest.text, size: Self.sectionSize)
            if sections.count > Self.maxSections {
                sections = Array(sections.prefix(Self.maxSections - 1)) + [sections.last!]
                covered = false
            }
            var notes: [String] = []
            for (index, section) in sections.enumerated() {
                if let points = await sectionNotes(section, index: index, of: sections.count) {
                    notes += points.map { "- \($0)" }
                }
            }
            body = "A long email, read in sections. Key points, in order:\n" + notes.joined(separator: "\n")
                + "\n\nThe email's closing:\n" + latest.text.suffix(800)
        }
        let facts = MailDigest.facts(in: latest.text)
        // Who "you" is, so an email that names the reader ("pending
        // Tamkin's approval") still reads as "your approval".
        let readerName = UserDefaults.standard.string(forKey: "corres.givenName").map { " (\($0))" } ?? ""
        let prompt = """
        The reader, always called "you": \(thread.id.account)\(readerName)
        From: \(thread.sender)\(thread.senderEmail.map { " <\($0)>" } ?? "")
        Subject: \(thread.subject)
        What matters for this kind of email: \(kind.guidance)
        \(facts.isEmpty ? "" : "Facts in the email, exactly as written (copy them exactly if you mention them): " + facts.joined(separator: "; "))

        \(body)
        """

        guard var digest = await respond(prompt, instructions: isConversation ? Self.conversationInstructions : Self.readingInstructions) else {
            return nil
        }
        let readerNames = Self.readerNames(for: thread.id.account)
        var summary = digest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = MailDigest.addressingReader(summary, names: readerNames) ?? summary
        if wantsSummary, let repaired = MailDigest.repairingRelativeDays(summary, source: source) {
            summary = repaired
        }
        if wantsSummary {
            var unsupported = MailDigest.unsupportedClaims(in: summary, source: source)
            let wrongVoice = MailDigest.speaksAsSender(summary)
            #if DEBUG
            if !unsupported.isEmpty || wrongVoice { print("[Summary] retrying \(thread.subject): \(summary) — unsupported \(unsupported) voice \(wrongVoice)") }
            #endif
            if !unsupported.isEmpty || wrongVoice {
                // One stricter try, told exactly what it got wrong.
                var problems: [String] = []
                if !unsupported.isEmpty {
                    problems.append("These are not in the email: \(unsupported.joined(separator: ", ")). Use only names, numbers and dates that appear above.")
                }
                if wrongVoice {
                    problems.append("It spoke as the sender (\"I\", \"we\"). Describe what the sender says, to the reader as \"you\".")
                }
                unsupported.removeAll()
                let retry = prompt + """


                A first summary said: "\(summary)". \(problems.joined(separator: " ")) Write the summary again.
                """
                if let second = await respond(retry, instructions: isConversation ? Self.conversationInstructions : Self.readingInstructions) {
                    digest = second
                    summary = second.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    summary = MailDigest.addressingReader(summary, names: readerNames) ?? summary
                    summary = MailDigest.repairingRelativeDays(summary, source: source) ?? summary
                }
            }
        }
        let faithful = wantsSummary && !summary.isEmpty && MailDigest.isFaithful(summary, source: source)
            && !MailDigest.speaksAsSender(summary)
        #if DEBUG
        if wantsSummary && !faithful {
            print("[Summary] word-for-word fallback for \(thread.subject): \(summary) — \(MailDigest.unsupportedClaims(in: summary, source: source))")
        }
        #endif
        let details = digest.keyPoints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "-•"))) }
            .compactMap { MailDigest.addressingReader($0, names: readerNames) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .filter { point in
                // A code's email has nothing worth a second line.
                kind != .code && MailDigest.isFaithful(point, source: source)
                    && !MailDigest.speaksAsSender(point) && MailDigest.isUsefulPoint(point, summary: summary)
            }
        // The model decides whether a reply is expected before it suggests
        // any; stock answers that aren't about this email are dropped.
        let replySource = (thread.subject + " " + latest.text).lowercased()
        let replies = (digest.expectsReply ? digest.replyIntents : [])
            .filter { !Self.isGenericReply($0) && Self.isGrounded($0, in: replySource) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"."))) }
            .filter { !$0.isEmpty && $0.count <= 32 }
        // The model occasionally repeats itself; one chip per idea.
        var seen = Set<String>()
        return Generated(summary: faithful ? summary : nil,
                         details: Array(details.prefix(3)),
                         replies: replies.filter { seen.insert($0.lowercased()).inserted },
                         covered: covered)
    }

    /// The reader's first name and their address's name part ("tamkin"
    /// from tamkin@…), capitalized, so a summary that names them can be
    /// turned back to "you".
    private static func readerNames(for account: String) -> [String] {
        var names: [String] = []
        if let given = UserDefaults.standard.string(forKey: "corres.givenName"), !given.isEmpty { names.append(given) }
        let local = account.split(separator: "@").first.map(String.init) ?? ""
        if let first = local.split(whereSeparator: { !$0.isLetter }).first, first.count >= 3 {
            let name = first.prefix(1).uppercased() + first.dropFirst().lowercased()
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// One model call, retried once with a shorter email if it overflows
    /// the context window.
    @available(iOS 26.0, *)
    private func respond(_ prompt: String, instructions: String) async -> EmailDigest? {
        do {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt, generating: EmailDigest.self).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            let shorter = String(prompt.prefix(prompt.count * 3 / 5))
            let session = LanguageModelSession(instructions: instructions)
            return try? await session.respond(to: shorter, generating: EmailDigest.self).content
        } catch {
            return nil
        }
    }

    @available(iOS 26.0, *)
    private func sectionNotes(_ section: String, index: Int, of count: Int) async -> [String]? {
        let prompt = "Section \(index + 1) of \(count) of a long email:\n\(section)"
        do {
            let session = LanguageModelSession(instructions: Self.sectionInstructions)
            return try await session.respond(to: prompt, generating: SectionNotes.self).content.points
        } catch {
            return nil
        }
    }

    // MARK: - Writing help

    /// A complete reply body for `intent` ("Count me in"), in a plain,
    /// natural voice, signed with `signOff`. Nil if the model is unavailable
    /// or declines.
    func draftReply(to thread: Correspondence, intent: String, signOff: String?) async -> String? {
        guard isAvailable, #available(iOS 26.0, *) else { return nil }
        let prompt = """
        Write the body of a reply email.
        The message being replied to:
        From: \(thread.sender)
        Subject: \(thread.subject)
        \(Self.trimmed(thread))

        I am the recipient, replying in first person. My answer, in short: \(intent)
        Write my reply so it gives that answer directly. Do not ask the sender to decide something I was asked to decide.
        \(signOff.map { "Sign it: \($0)" } ?? "Do not add a signature.")
        """
        do {
            let session = LanguageModelSession(instructions: Self.writingInstructions)
            let response = try await session.respond(to: prompt)
            return Self.clean(response.content)
        } catch {
            return nil
        }
    }

    /// Rewrites the person's own text in `tone`, preserving meaning.
    func rewrite(_ text: String, tone: Tone) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, !trimmed.isEmpty, #available(iOS 26.0, *) else { return nil }
        let prompt = """
        \(tone.instruction)
        Return only the rewritten email text, nothing before or after it.

        Email text:
        \(trimmed)
        """
        do {
            let session = LanguageModelSession(instructions: Self.writingInstructions)
            let response = try await session.respond(to: prompt)
            return Self.clean(response.content)
        } catch {
            return nil
        }
    }

    // MARK: - Checks

    /// Replies that could answer any email say nothing about this one.
    private static func isGenericReply(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let stock: Set<String> = ["count me in", "can't make it", "cant make it", "go with option a", "go with option b",
                                  "ask for tuesday", "sounds good", "thanks", "thank you", "got it", "ok", "okay",
                                  "will do", "noted", "reply later", "share your thoughts", "reply soon", "let me check"]
        return stock.contains(lower)
    }

    /// A suggested reply may only mention dates, times, numbers and months
    /// the email itself contains; the model sometimes invents them
    /// ("Clarify by Oct 10?" for an email with no date).
    static func isGrounded(_ reply: String, in source: String) -> Bool {
        let lower = reply.lowercased()
        let numbers = lower.matches(of: /\d+/).map { String($0.output) }
        guard numbers.allSatisfy(source.contains) else { return false }
        // Whole words only, so "mark" or "may I" never count as months.
        let calendarWords: [String: String] = [
            "jan": "jan", "january": "jan", "feb": "feb", "february": "feb", "march": "mar",
            "apr": "apr", "april": "apr", "june": "jun", "july": "jul", "aug": "aug", "august": "aug",
            "sep": "sep", "sept": "sep", "september": "sep", "oct": "oct", "october": "oct",
            "nov": "nov", "november": "nov", "dec": "dec", "december": "dec",
            "monday": "mon", "tuesday": "tue", "wednesday": "wed", "thursday": "thu",
            "friday": "fri", "saturday": "sat", "sunday": "sun",
        ]
        for word in lower.split(whereSeparator: { !$0.isLetter }) {
            if let stem = calendarWords[String(word)], !source.contains(stem) { return false }
        }
        return true
    }

    // MARK: - Instructions

    @available(iOS 26.0, *)
    private static let sharedRules = """
    Write to the reader as "you", never by their name or in the third \
    person, even where the email uses their name. Use only what the email says: never guess, never add a date, \
    time, amount, name, code or place it doesn't contain, and copy numbers, \
    amounts, codes and dates exactly as written. Say "today" or "tomorrow" \
    only if the email does. Some text may be marked as omitted; never guess \
    at it.
    """

    @available(iOS 26.0, *)
    private static let replyRules = """
    Replies: first decide whether a real person is waiting for this reader \
    to answer. Automated mail, receipts, welcomes, notifications, \
    newsletters, marketing and anything from a no-reply address never \
    expect a reply: set expectsReply to false and give no replies. When a \
    reply is expected, give up to three short answers, two to five words, \
    each written as the reader's own first-person reply to the specific \
    question or request, using its own names, dates, times and options \
    (for example, for "Can you do Thursday at 3?": "Thursday at 3 works", \
    "Could we do Friday?"). Make them real, different answers: one that \
    agrees, one that declines or proposes an alternative, and, only if \
    something is unclear, one next step. Never ask the sender to confirm \
    what they just said. Never write generic replies that would fit any \
    email.
    """

    @available(iOS 26.0, *)
    private static let readingInstructions = """
    You help a busy person read their email. \(sharedRules)

    Summary: one or two plain sentences, under 35 words. If the email asks \
    the reader to do, answer or decide something, lead with that and when \
    it's due. Otherwise say what happened or what the email offers (a \
    charge, a shipment, a code, a change, the main news), in plain words, \
    and never start with "You need to". Mention that nothing is needed \
    only when the email says so.

    Key points: up to three more specific facts the summary leaves out, \
    each an ask, decision, date, amount, place or next step from the \
    email, written as a short phrase that makes sense on its own \
    ("Minimum payment $40.00 due Oct 22"), not a bare number or date. Never a vague line like "progress was reviewed", never a \
    question written as if it were decided, and never repeating the \
    summary. Leave it empty when there's nothing more worth knowing.

    \(replyRules)
    """

    @available(iOS 26.0, *)
    private static let conversationInstructions = """
    You help a busy person catch up on an email conversation, given oldest \
    first; lines from "You" are the reader's own messages. \(sharedRules)

    Summary: one or two plain sentences, under 40 words, on where the \
    conversation stands now: what has been decided, what is still open, \
    and who is waiting on whom. If the latest message asks the reader \
    something, lead with that.

    Key points: up to three more specific facts, such as decisions made, \
    dates, amounts or next steps agreed earlier. A question still open is \
    not a decision. Leave it empty when there's nothing more worth knowing.

    \(replyRules) Answer the latest message only.
    """

    @available(iOS 26.0, *)
    private static let sectionInstructions = """
    You take notes on one section of a long email. List up to four short \
    points: asks, decisions, dates, amounts, names and changes. Copy \
    numbers and dates exactly. Use only what the section says.
    """

    @available(iOS 26.0, *)
    private static let writingInstructions = """
    You write emails on behalf of the person using this app. Write in a \
    natural, concise, human voice: no filler, no clichés like "I hope this \
    email finds you well," no subject line, no placeholders in brackets. \
    Never invent facts, dates, prices, or commitments the person didn't \
    give. Output only the email text.
    """

    // MARK: - Text

    private static func trimmed(_ thread: Correspondence) -> String {
        let readable = MailDigest.clean(MailDigest.readableText(body: thread.body, html: thread.htmlBody))
        return MailDigest.shortened(readable.isEmpty ? thread.body : readable, to: promptBudget / 2).text
    }

    /// The body as the model sees it: quoted history, signatures and
    /// footers removed, then, if still too long, the opening and the
    /// closing joined by a marker.
    nonisolated static func prepared(_ body: String) -> (text: String, wasShortened: Bool) {
        MailDigest.shortened(MailDigest.clean(body), to: promptBudget / 2)
    }

    private static func clean(_ output: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("subject:"), let newline = text.firstIndex(of: "\n") {
            text = String(text[newline...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    // MARK: - Saved summaries

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("summaries-v\(cacheVersion).json")
    }

    private func loadCache() {
        guard let url = Self.cacheURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: Insight].self, from: data) else { return }
        insights = saved
    }

    /// Written a moment after the last change, newest kept when over the
    /// limit, protected like the rest of Corres's on-device mail.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, let url = Self.cacheURL else { return }
            var toSave = insights
            if toSave.count > Self.cacheLimit {
                let keep = toSave.sorted { $0.value.createdAt > $1.value.createdAt }.prefix(Self.cacheLimit)
                toSave = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            guard let data = try? JSONEncoder().encode(toSave) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

@available(iOS 26.0, *)
@Generable
struct EmailDigest {
    @Guide(description: "One or two plain sentences to the reader as \"you\", under 40 words: what they're asked to do and by when, or else what happened or what the email offers. Only facts from the email.")
    let summary: String
    @Guide(description: "Up to three more specific facts the summary leaves out (an ask, decision, date, amount, place or next step), each under 16 words, only from the email. Empty if there's nothing more worth knowing.")
    let keyPoints: [String]
    @Guide(description: "True only if a real person wrote the latest message and is waiting for the reader's answer. False for automated mail, receipts, welcomes, notifications, newsletters and no-reply senders.")
    let expectsReply: Bool
    @Guide(description: "If expectsReply, up to three different first-person answers, two to five words, to the latest message's specific question, using its own names, dates and options. Otherwise empty.")
    let replyIntents: [String]
}

@available(iOS 26.0, *)
@Generable
struct SectionNotes {
    @Guide(description: "Up to four short points from this section: asks, decisions, dates, amounts, names. Numbers and dates copied exactly.")
    let points: [String]
}
