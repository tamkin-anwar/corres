import Foundation

/// Replies, reply-alls and forwards, built the same way on iPhone, iPad
/// and Mac: the right people, "Re:" or "Fwd:", and the email quoted below
/// with the attribution Gmail and Mail write.
extension Correspondence {
    func draft(kind: Draft.Kind) -> Draft {
        // Blank lines stay as ">" so the quoted email keeps its paragraphs.
        let quotedLines = body.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \($0)" }
        // The standard attribution Gmail and Mail write, which is also what
        // Corres itself looks for when hiding quoted history in a thread.
        let when = receivedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
        let who = senderEmail.map { "\(sender) <\($0)>" } ?? sender
        let quoted = "\n\nOn \(when), \(who) wrote:\n\(quotedLines.joined(separator: "\n"))"
        switch kind {
        case .new:
            return Draft(kind: .new, to: "", subject: "")
        case .reply:
            return Draft(kind: kind, threadID: id, fromAccount: id.account, to: replyAddresses.joined(separator: ", "),
                         subject: subject.hasPrefix("Re: ") ? subject : "Re: \(subject)",
                         body: quoted)
        case .replyAll:
            return Draft(kind: kind, threadID: id, fromAccount: id.account, to: replyAddresses.joined(separator: ", "),
                         cc: replyAllCc.isEmpty ? nil : replyAllCc.joined(separator: ", "),
                         subject: subject.hasPrefix("Re: ") ? subject : "Re: \(subject)",
                         body: quoted)
        case .forward:
            return Draft(kind: .forward, threadID: id, fromAccount: id.account, to: "",
                         subject: subject.hasPrefix("Fwd: ") ? subject : "Fwd: \(subject)",
                         body: quoted)
        }
    }
}

extension Correspondence {
    /// The email's attachments as files to send on, up to the account's
    /// limit, and the names of any that couldn't come along. Forwards on
    /// iPhone, iPad, Mac and from Siri all carry them, as in Mail and Gmail.
    func attachmentsToForward() async -> (files: [PendingAttachment], missing: [String]) {
        guard let messageID = latestMessageID else { return ([], attachments.map(\.filename)) }
        let client = MailClient()
        var files: [PendingAttachment] = []
        var missing: [String] = []
        var total = 0
        for attachment in attachments {
            guard total + attachment.sizeBytes <= MailAccounts.provider(for: id.account).attachmentLimit,
                  let data = try? await client.fetchAttachmentData(messageId: messageID, attachmentId: attachment.id,
                                                                   account: id.account) else {
                missing.append(attachment.filename)
                continue
            }
            total += data.count
            files.append(PendingAttachment(filename: attachment.filename, mimeType: attachment.mimeType, data: data))
        }
        return (files, missing)
    }
}

extension Draft {
    /// The signature above the quoted email, or at the end of a new one.
    static func adding(signature: String, to body: String) -> String {
        guard !signature.isEmpty, !body.contains(signature) else { return body }
        if let quote = body.patternRange(#"\n\nOn .+ wrote:\n"#) {
            var result = body
            result.insert(contentsOf: "\n\n" + signature, at: quote.lowerBound)
            return result
        }
        return body + "\n\n" + signature
    }
}
