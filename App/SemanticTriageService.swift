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
/// only downgrade it to `.quiet` when the model reports it's confident it
/// doesn't need a reply (a newsletter, a receipt, an automated
/// notification) — `TriageAssessment.confidence`, a real field the model
/// fills in, not just a doc comment's claim about behavior the type
/// couldn't actually express (found and fixed in a review sweep: the
/// confidence language existed here before the field backing it did). It
/// never promotes an already-read thread into `.needsYou` — that's a
/// meaningfully bigger claim (finding something the person forgot to reply
/// to) deliberately left for a later, separate feature.
///
/// Worth being honest about what "confident" means here: this is the
/// on-device model's own self-reported assessment, constrained to three
/// discrete levels rather than a continuous score (a forced numeric
/// 0.0–1.0 self-rating from a generative model tends to cluster at round
/// numbers and isn't a calibrated probability regardless), not a measured
/// property of the underlying generation the way token log-probabilities
/// would be — Foundation Models' structured generation doesn't expose
/// those. It's a real signal worth gating on, not a decoration, but it's
/// the model grading its own judgment, not an independent check on it.
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
        // A downgrade only ever applies once the model both says it
        // doesn't need a reply AND reports being confident about it;
        // `needsReply == false` at low confidence leaves the thread
        // exactly where it was (still `.needsYou`) rather than acting on a
        // guess. `applySemanticTriage` itself still records the reason and
        // `triagedMessageID` either way, so this message isn't re-assessed
        // every single time just because confidence was too low to act on.
        await store.applySemanticTriage(thread.id, needsReply: assessment.needsReply || !assessment.confidentEnough,
                                        reason: assessment.reason, messageID: messageID)
    }

    /// A plain, non-`@available` tuple, deliberately: `TriageAssessment`
    /// (and its `Confidence` enum) is `@available(iOS 26.0, *)`, and
    /// putting that type directly in this method's own signature would
    /// force the whole method to carry that availability annotation too,
    /// leaking the same requirement out to `triage(_:store:)`'s call site
    /// for no reason — the `#available` check right below already confines
    /// where that actually matters to this one method's body.
    private func assess(_ thread: Correspondence) async -> (needsReply: Bool, reason: String, confidentEnough: Bool)? {
        guard #available(iOS 26.0, *) else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(to: Self.prompt(for: thread), generating: TriageAssessment.self)
            return (response.content.needsReply, response.content.reason, response.content.confidence != .low)
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

    Also rate your own confidence honestly. Only report "high" or "medium" \
    confidence when the message's purpose is genuinely clear from the sender, \
    subject, and preview alone. Report "low" confidence whenever the preview \
    is too short or ambiguous to be sure, the message could plausibly need a \
    reply despite looking automated, or you are otherwise guessing rather \
    than reading a clear signal. A wrong "low" costs nothing; a wrong \
    "high" or "medium" means a message that actually needed a reply gets \
    hidden from the person who needed to see it.
    """

    private static func prompt(for thread: Correspondence) -> String {
        """
        Sender: \(thread.sender)
        Subject: \(thread.subject)
        Message preview: \(thread.excerpt)
        The recipient was \(thread.isDirectRecipient ? "addressed directly (To)" : "only copied (Cc)") on this message.
        \(thread.looksAutomated ? "This message shows signs of being automated or bulk mail (it includes an unsubscribe link, or comes from a no-reply address)." : "")

        Does this message genuinely need a personal reply, decision, or action from the recipient? How confident are you?
        """
    }
}

@available(iOS 26.0, *)
@Generable
struct TriageAssessment {
    /// Three discrete levels, not a continuous score: a forced numeric
    /// self-rating from a generative model tends to cluster at round
    /// numbers and isn't meaningfully more calibrated than a category the
    /// model actually has a clear basis for choosing between. `.low` is the
    /// one that matters operationally — `SemanticTriageService.triage`
    /// treats anything below `.medium` as "don't act on this," since a
    /// missed downgrade costs nothing and a wrong one hides a message that
    /// needed a reply.
    @Generable
    enum Confidence: String { case low, medium, high }

    @Guide(description: "True only if this message genuinely expects a personal reply, decision, or action from the recipient. False for newsletters, receipts, notifications, automated mail, or messages that are informational only.")
    let needsReply: Bool
    @Guide(description: "One short, specific, human-readable reason for the decision, under 12 words, e.g. 'Asks a direct question' or 'Marketing newsletter, no action needed'.")
    let reason: String
    @Guide(description: "How confident you are in this specific assessment, honestly. Low whenever the preview is too short or ambiguous to be sure, or the message could plausibly need a reply despite looking automated.")
    let confidence: Confidence
}
