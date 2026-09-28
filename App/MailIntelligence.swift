import Foundation
import FoundationModels
import Observation

/// Reading and writing help, entirely on this iPhone: a short summary of a
/// conversation, a few one-tap reply directions, a drafted reply in the
/// person's own voice, and tone rewrites of whatever they've written.
///
/// Built on Apple's Foundation Models framework (the on-device model behind
/// Apple Intelligence), like `SemanticTriageService`. There is deliberately
/// no cloud fallback: on an iPhone without Apple Intelligence these
/// features simply don't appear, and mail never leaves the device to make
/// them work.
///
/// Everything is advisory. A drafted reply lands in the compose sheet for
/// the person to read and edit; nothing here ever sends, files, or changes
/// a message on its own.
@MainActor @Observable
final class MailIntelligence {
    struct Insight: Equatable {
        /// Nil for messages short enough that a summary would only repeat them.
        let summary: String?
        /// Up to three short reply directions ("Count me in"), empty when
        /// the message doesn't call for a reply.
        let replyIntents: [String]
        /// False when the email was too long for the on-device model to
        /// read whole, so the summary covers its opening and closing only.
        /// The conversation says so rather than implying it read it all.
        var coversWholeMessage = true
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

    /// Keyed by the message id the insight was computed for, so a new
    /// reply landing in the thread gets a fresh read.
    private(set) var insights: [String: Insight] = [:]
    private var inFlight: Set<String> = []

    /// Checked on every call: Apple Intelligence can finish downloading, or
    /// be switched on, while Corres is already running.
    var isAvailable: Bool {
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
    }

    /// Below this, the preview already is the summary.
    private static let summaryThreshold = 320
    /// The on-device model's context is small (about 4k tokens including
    /// instructions and output), so a long body keeps its opening and its
    /// closing, where asks and deadlines almost always are, and drops the
    /// middle with a marker the model is told about.
    nonisolated private static let maxBodyCharacters = 2_800
    nonisolated private static let tailCharacters = 900

    func insight(for thread: Correspondence) -> Insight? {
        insights[Self.key(for: thread)]
    }

    /// The latest message's id when known, so a new reply gets a fresh
    /// read; the thread id otherwise.
    private static func key(for thread: Correspondence) -> String {
        thread.latestMessageID ?? "thread:\(thread.id.account)|\(thread.id.providerID)"
    }

    /// Computes (once per message) a summary and reply directions. Safe to
    /// call repeatedly from `.task`; concurrent calls for the same message
    /// coalesce.
    func prepareInsight(for thread: Correspondence) async {
        let messageID = Self.key(for: thread)
        guard isAvailable, thread.isBodyLoaded, insights[messageID] == nil,
              !inFlight.contains(messageID) else { return }
        inFlight.insert(messageID)
        defer { inFlight.remove(messageID) }
        let wantsSummary = thread.body.count >= Self.summaryThreshold
        // Nothing to answer when the last word is yours.
        // Only a person writing to you gets reply suggestions: never
        // automated or Gmail-categorized mail.
        let wantsReplies = InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) == nil
            && thread.attention != .waiting && !thread.isFromAccountOwner
        guard wantsSummary || wantsReplies else {
            insights[messageID] = Insight(summary: nil, replyIntents: [])
            return
        }
        guard let result = await generateInsight(for: thread) else { return }
        insights[messageID] = Insight(summary: wantsSummary ? result.summary : nil,
                                      replyIntents: wantsReplies ? Array(result.replies.prefix(3)) : [],
                                      coversWholeMessage: !Self.prepared(thread.body).wasShortened)
    }

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
        \(Self.trimmed(thread.body))

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

    // MARK: - Model calls

    private func generateInsight(for thread: Correspondence) async -> (summary: String, replies: [String])? {
        guard #available(iOS 26.0, *) else { return nil }
        let prompt = """
        From: \(thread.sender)\(thread.senderEmail.map { " <\($0)>" } ?? "")
        Subject: \(thread.subject)
        \(Self.trimmed(thread.body))
        """
        do {
            let session = LanguageModelSession(instructions: Self.readingInstructions)
            let response = try await session.respond(to: prompt, generating: ThreadInsight.self)
            let content = response.content
            // The model decides whether a reply is expected before it
            // suggests any; stock answers that aren't about this email
            // are dropped.
            let source = (thread.subject + " " + thread.body).lowercased()
            let replies = (content.expectsReply ? content.replyIntents : [])
                .filter { !Self.isGenericReply($0) && Self.isGrounded($0, in: source) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\".")))}
                .filter { !$0.isEmpty && $0.count <= 32 }
            // The model occasionally repeats itself; one chip per idea.
            var seen = Set<String>()
            let distinct = replies.filter { seen.insert($0.lowercased()).inserted }
            return (content.summary.trimmingCharacters(in: .whitespacesAndNewlines), distinct)
        } catch {
            return nil
        }
    }

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

    @available(iOS 26.0, *)
    private static let readingInstructions = """
    You help a busy person read their email. Write to them as "you", never \
    by their name or in the third person. A very long email may arrive with \
    its middle omitted and marked; use only what you can see and never \
    guess at the missing part. Never invent facts.

    Summary: one or two plain sentences, under 35 words. Lead with what \
    matters to the reader: what they need to do and by when, or, if \
    nothing, what happened (a charge, a delivery, a change). Keep names, \
    amounts and dates exactly as written. Say plainly when nothing is \
    needed, for example "Nothing to do; it renews automatically on Oct 28."

    Replies: first decide whether a real person is waiting for this reader \
    to answer. Automated mail, receipts, welcomes, notifications, \
    newsletters, marketing and anything from a no-reply address never \
    expect a reply: set expectsReply to false and give no replies. When a \
    reply is expected, give up to three short answers, two to five words, \
    each written as the reader's own first-person reply to the specific \
    question or request in this email, using its own names, dates, times \
    and options (for example, for "Can you do Thursday at 3?": "Thursday \
    at 3 works", "Could we do Friday?"). Make them real, different \
    answers: one that agrees or says yes, one that declines or proposes an \
    alternative, and, only if something is unclear, one next step. Never \
    ask the sender to confirm what they just said. Never mention a date, \
    time, number or name that isn't in the email. Never write generic \
    replies that would fit any email, and never advice to the reader.
    """

    @available(iOS 26.0, *)
    private static let writingInstructions = """
    You write emails on behalf of the person using this app. Write in a \
    natural, concise, human voice: no filler, no clichés like "I hope this \
    email finds you well," no subject line, no placeholders in brackets. \
    Never invent facts, dates, prices, or commitments the person didn't \
    give. Output only the email text.
    """

    private static func trimmed(_ body: String) -> String { prepared(body).text }

    /// The body as the model sees it: quoted history removed, then, if still
    /// too long, the opening and the closing joined by a marker.
    nonisolated static func prepared(_ body: String) -> (text: String, wasShortened: Bool) {
        // Quoted history ("On … wrote:" and "> " lines) adds length, not meaning.
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        for line in lines {
            if line.hasPrefix(">") { continue }
            if line.range(of: #"^On .+ wrote:$"#, options: .regularExpression) != nil { break }
            kept.append(line)
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxBodyCharacters else { return (text, false) }
        let head = text.prefix(maxBodyCharacters - tailCharacters)
        let tail = text.suffix(tailCharacters)
        return (head + "\n\n[… middle of the email omitted …]\n\n" + tail, true)
    }

    private static func clean(_ output: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("subject:"), let newline = text.firstIndex(of: "\n") {
            text = String(text[newline...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }
}

@available(iOS 26.0, *)
@Generable
struct ThreadInsight {
    @Guide(description: "One or two plain sentences to the reader as \"you\", under 35 words: what they need to do and by when, or what happened if nothing is needed.")
    let summary: String
    @Guide(description: "True only if a real person wrote this and is waiting for the reader's answer. False for automated mail, receipts, welcomes, notifications, newsletters and no-reply senders.")
    let expectsReply: Bool
    @Guide(description: "If expectsReply, up to three different first-person answers, two to five words, to this email's specific question, using its own names, dates and options. Otherwise empty.")
    let replyIntents: [String]
}
