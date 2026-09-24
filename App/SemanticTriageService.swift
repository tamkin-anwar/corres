import FoundationModels
import Observation

/// Refines "Needs You" with a real, on-device understanding of whether a
/// message actually expects a personal reply, decision, or action — not
/// just "Gmail says this is unread" (the only signal `Attention` had until
/// this). Built on Apple's Foundation Models framework: the same ~3B
/// parameter model powering Apple Intelligence, running entirely on-device.
/// No API key, no network request, no ongoing cost, and nothing about a
/// message ever leaves the device or reaches a server Corres runs — chosen
/// deliberately over a cloud model for exactly that reason, requested
/// directly ("I love this idea of using Apple Intelligence").
///
/// Strictly a *refinement*, never an invention: this only ever runs against
/// a thread Gmail's own unread state already put in `.needsYou`, and can
/// only downgrade it to `.quiet` when the model is confident it doesn't
/// need a reply (a newsletter, a receipt, an automated notification). It
/// never promotes an already-read thread into `.needsYou` — that's a
/// meaningfully bigger claim (finding something the person forgot to reply
/// to) deliberately left for a later, separate feature.
///
/// `reason` is always a real, short, human-readable sentence the model
/// itself produces, matching `Correspondence.reason`'s existing rule
/// ("human-readable evidence, never an unexplained importance score") —
/// this was already true for the Gmail-unread-state reason it replaces,
/// and stays true here, not a new promise.
@MainActor @Observable
final class SemanticTriageService {
    /// Whether Apple Intelligence is actually usable on this device right
    /// now (device eligible, feature enabled in Settings, model finished
    /// downloading). Checked once at launch; `triageIfNeeded` no-ops
    /// entirely when false, so every caller can call it unconditionally
    /// without its own availability check.
    private(set) var isAvailable: Bool

    /// Bounded, not unlimited: an on-device model call has real latency,
    /// and firing dozens at once would compete with whatever else is
    /// running on the device without making the batch meaningfully faster,
    /// the same reasoning `GmailAPIClient.messageFetchConcurrency` already
    /// applied to network fetches.
    private static let concurrency = 3
    private static let sampleAccount = "sample"

    init() {
        if #available(iOS 26.0, *) {
            isAvailable = SystemLanguageModel.default.availability == .available
        } else {
            isAvailable = false
        }
    }

    /// Finds every real, currently-`.needsYou` thread this hasn't already
    /// assessed the latest message of, and refines each one. Called after a
    /// sync brings in new mail (launch, a push-triggered background sync);
    /// safe to call as often as that, since anything already triaged is
    /// skipped immediately rather than re-assessed.
    func triageIfNeeded(store: MailStore) async {
        guard isAvailable else { return }
        let candidates = store.threads.filter { thread in
            thread.id.account != Self.sampleAccount &&
            thread.attention == .needsYou &&
            thread.latestMessageID != nil &&
            thread.triagedMessageID != thread.latestMessageID
        }
        guard !candidates.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var pending = candidates[...]
            func addNext() {
                guard let thread = pending.popFirst() else { return }
                group.addTask { await self.triage(thread, store: store) }
            }
            for _ in 0..<Self.concurrency { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    private func triage(_ thread: Correspondence, store: MailStore) async {
        guard let messageID = thread.latestMessageID,
              let assessment = await assess(thread) else { return }
        await store.applySemanticTriage(thread.id, needsReply: assessment.needsReply,
                                        reason: assessment.reason, messageID: messageID)
    }

    private func assess(_ thread: Correspondence) async -> (needsReply: Bool, reason: String)? {
        guard #available(iOS 26.0, *) else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(to: Self.prompt(for: thread), generating: TriageAssessment.self)
            return (response.content.needsReply, response.content.reason)
        } catch {
            // Fails closed: `triagedMessageID` is only ever set by
            // `applySemanticTriage`, which this simply never calls on
            // failure, so the thread keeps its existing Gmail-unread-state
            // reason (already correct, just not yet refined) and gets
            // retried the next time `triageIfNeeded` runs, exactly like a
            // thread that hasn't been looked at yet.
            return nil
        }
    }

    @available(iOS 26.0, *)
    private static let instructions = """
    You triage a person's email inbox. For one message at a time, decide only \
    whether it genuinely needs a personal reply, decision, or action from the \
    recipient — not whether it is generically "important." Newsletters, \
    marketing, receipts, automated notifications, and FYI-only messages do not \
    need a reply even when they are relevant or worth reading. Be decisive. \
    Keep the reason short, specific, and in plain language, as if explaining \
    the decision to the recipient in one breath.
    """

    private static func prompt(for thread: Correspondence) -> String {
        """
        Sender: \(thread.sender)
        Subject: \(thread.subject)
        Message preview: \(thread.excerpt)
        The recipient was \(thread.isDirectRecipient ? "addressed directly (To)" : "only copied (Cc)") on this message.
        \(thread.looksAutomated ? "This message shows signs of being automated or bulk mail (it includes an unsubscribe link, or comes from a no-reply address)." : "")

        Does this message genuinely need a personal reply, decision, or action from the recipient?
        """
    }
}

@available(iOS 26.0, *)
@Generable
struct TriageAssessment {
    @Guide(description: "True only if this message genuinely expects a personal reply, decision, or action from the recipient. False for newsletters, receipts, notifications, automated mail, or messages that are informational only.")
    let needsReply: Bool
    @Guide(description: "One short, specific, human-readable reason for the decision, under 12 words, e.g. 'Asks a direct question' or 'Marketing newsletter, no action needed'.")
    let reason: String
}
