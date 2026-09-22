import Foundation

/// Builds the raw RFC 5322 message Gmail's `users.messages.send` expects in
/// its `raw` field, base64url-encoded. Deliberately minimal: plain text
/// only, no attachments or HTML, matching what ComposeView can actually
/// produce today.
enum GmailMessageComposer {
    /// `inReplyTo` is the parent message's `Message-ID` header value
    /// (without `<...>`, as `Correspondence.messageIdHeader` stores it).
    /// Gmail threads a reply into its existing conversation only when the
    /// threadId, the In-Reply-To/References headers, and the Subject all
    /// agree (see ADR 005); the threadId itself is passed separately to
    /// `GmailAPIClient.send`, not part of this message.
    static func compose(from: String, to: String, subject: String, body: String, inReplyTo: String?) -> String {
        var headers = [
            "From: \(from)",
            "To: \(to)",
            "Subject: \(encodedSubject(subject))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
        ]
        if let inReplyTo {
            let reference = "<\(inReplyTo)>"
            headers.append("In-Reply-To: \(reference)")
            headers.append("References: \(reference)")
        }
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + body
        return base64URLEncode(Data(message.utf8))
    }

    /// RFC 2047 encoding for a non-ASCII subject; left untouched otherwise,
    /// since most real subjects are plain ASCII and don't need it.
    private static func encodedSubject(_ subject: String) -> String {
        guard !subject.allSatisfy(\.isASCII) else { return subject }
        let base64 = Data(subject.utf8).base64EncodedString()
        return "=?UTF-8?B?\(base64)?="
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
