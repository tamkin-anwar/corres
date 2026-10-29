import Foundation

/// What Corres reads out of an email to put above it, on every device: what
/// it is and the line worth knowing (`InShort`), its one call to action, a
/// receipt's or delivery's key figures, and what a long personal email asks
/// of you. Read from the email itself, no model.
struct ReadingAids: Equatable {
    var card: InShort?
    var nextStep: NextStep? { card?.nextStep }
    var glance: Glance? { card?.glance }
    var ask: String? { card?.ask }

    /// Off the main thread: reading a designed email's links is a full pass
    /// over its HTML.
    static func find(in thread: Correspondence) async -> ReadingAids {
        guard thread.isBodyLoaded else { return ReadingAids() }
        return await Task.detached(priority: .utility) {
            ReadingAids(card: InShort.make(for: thread))
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
