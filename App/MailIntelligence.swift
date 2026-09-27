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
    /// instructions and output), so long bodies are trimmed to their start,
    /// which is where the ask almost always is.
    private static let maxBodyCharacters = 2_800

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
        let wantsReplies = !thread.looksAutomated && thread.attention != .waiting
        guard wantsSummary || wantsReplies else {
            insights[messageID] = Insight(summary: nil, replyIntents: [])
            return
        }
        guard let result = await generateInsight(for: thread) else { return }
        insights[messageID] = Insight(summary: wantsSummary ? result.summary : nil,
                                      replyIntents: wantsReplies ? Array(result.replies.prefix(3)) : [])
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
        From: \(thread.sender)
        Subject: \(thread.subject)
        \(Self.trimmed(thread.body))
        """
        do {
            let session = LanguageModelSession(instructions: Self.readingInstructions)
            let response = try await session.respond(to: prompt, generating: ThreadInsight.self)
            let replies = response.content.replyIntents
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\".")))}
                .filter { !$0.isEmpty && $0.count <= 32 }
            return (response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines), replies)
        } catch {
            return nil
        }
    }

    @available(iOS 26.0, *)
    private static let readingInstructions = """
    You help a busy person read email. Summarize what the message says and, \
    above all, what it asks of the reader, in one or two plain sentences, \
    under 35 words. Name people and dates exactly as written. Never invent \
    facts. If the message needs a personal reply, suggest up to three short, \
    distinct reply directions the reader might choose, each two to four \
    words, written as the reader's own answer in first person (for example \
    "Count me in", "Can't make it", "Go with option A", "Ask for Tuesday"). \
    Never phrase them as advice to the reader, like "Share your thoughts" or \
    "Reply soon". When the message offers a choice, suggest the choices \
    themselves. Suggest no replies for newsletters, receipts, \
    notifications, or anything that doesn't expect an answer.
    """

    @available(iOS 26.0, *)
    private static let writingInstructions = """
    You write emails on behalf of the person using this app. Write in a \
    natural, concise, human voice: no filler, no clichés like "I hope this \
    email finds you well," no subject line, no placeholders in brackets. \
    Never invent facts, dates, prices, or commitments the person didn't \
    give. Output only the email text.
    """

    private static func trimmed(_ body: String) -> String {
        // Quoted history ("On … wrote:" and "> " lines) adds length, not meaning.
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        for line in lines {
            if line.hasPrefix(">") { continue }
            if line.range(of: #"^On .+ wrote:$"#, options: .regularExpression) != nil { break }
            kept.append(line)
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > maxBodyCharacters ? String(text.prefix(maxBodyCharacters)) + "…" : text
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
    @Guide(description: "One or two plain sentences, under 35 words, saying what the message is about and what, if anything, it asks of the reader.")
    let summary: String
    @Guide(description: "Zero to three short reply directions, two to four words each, phrased as the reader would say them. Empty if no reply is expected.")
    let replyIntents: [String]
}
