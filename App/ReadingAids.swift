import Foundation

/// What Corres reads out of an email to put above it, on every device: its
/// one call to action, a receipt's or delivery's key figures, and what a
/// long personal email asks of you. Read from the email itself, no model.
struct ReadingAids: Equatable {
    var nextStep: NextStep?
    var glance: Glance?
    var ask: String?

    /// Off the main thread: reading a designed email's links is a full pass
    /// over its HTML.
    static func find(in thread: Correspondence) async -> ReadingAids {
        guard thread.isBodyLoaded else { return ReadingAids() }
        let bulk = InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated)
        let isBulk = bulk != nil, isPromotion = bulk == .promotions
        let body = thread.body, html = thread.htmlBody, subject = thread.subject, sender = thread.senderEmail
        let automated = thread.looksAutomated, labelIds = thread.labelIds
        return await Task.detached(priority: .utility) {
            // The whole text, not the cleaned one: cleaning drops what
            // follows a sign-off, which is often exactly where the link is.
            let whole = MailDigest.readableText(body: body, html: html)
            let cleaned = MailDigest.clean(whole)
            let kind = isPromotion ? .newsletter
                : MailDigest.kind(subject: subject, text: cleaned, senderEmail: sender, isBulk: isBulk,
                                  looksAutomated: automated, hasEvent: false, labelIds: labelIds)
            return ReadingAids(nextStep: MailDigest.nextStep(text: whole, html: html, kind: kind),
                               glance: MailDigest.glance(text: cleaned, subject: subject, kind: kind),
                               ask: kind == .personal ? MailDigest.buriedAsk(text: cleaned) : nil)
        }.value
    }
}

/// A suggested reply ("Count me in") written out in full, in the person's
/// own greeting, sign-off and length, ready to read and change in compose.
@MainActor
enum ReplyDrafting {
    /// The finished reply body, or nil if the model is unavailable or
    /// declines (compose then opens empty, as if Reply was chosen).
    static func draft(_ intent: String, replyingTo thread: Correspondence, with intelligence: MailIntelligence) async -> String? {
        let style = WritingStyleBook.shared.style(for: thread.id.account, recipient: thread.senderEmail)?
            .instructions(recipientName: thread.sender, replyLanguage: WritingStyleBook.language(of: thread.body))
        // A signature already signs it; otherwise the person's first name does.
        let givenName = UserDefaults.standard.string(forKey: GoogleAuthService.givenNameKey) ?? ""
        let signOff = givenName.isEmpty || !CorresSettings.signature(for: thread.id.account, reply: true).isEmpty ? nil : givenName
        return await intelligence.draftReply(to: thread, intent: intent, signOff: signOff, style: style)
    }

    /// Gone once you've answered: the last word is yours, or it's waiting
    /// on them.
    static func hasAnswered(_ thread: Correspondence) -> Bool {
        thread.attention == .waiting || thread.isFromAccountOwner
            || (thread.lastSentAt.map { $0 >= thread.receivedAt } ?? false)
    }
}
