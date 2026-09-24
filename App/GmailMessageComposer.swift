import Foundation

/// Builds the raw RFC 5322 message Gmail's `users.messages.send` expects in
/// its `raw` field, base64url-encoded. Plain text, HTML is never composed
/// (matching what ComposeView can produce), with an optional set of
/// attachments as separate `multipart/mixed` parts.
enum GmailMessageComposer {
    /// `inReplyTo` is the parent message's `Message-ID` header value
    /// (without `<...>`, as `Correspondence.messageIdHeader` stores it).
    /// Gmail threads a reply into its existing conversation only when the
    /// threadId, the In-Reply-To/References headers, and the Subject all
    /// agree (see ADR 005); the threadId itself is passed separately to
    /// `GmailAPIClient.send`, not part of this message.
    static func compose(from: String, to: String, cc: String? = nil, subject: String, body: String, inReplyTo: String?,
                        attachments: [PendingAttachment] = []) -> String {
        var headers = [
            "From: \(from)",
            "To: \(to)",
        ]
        if let cc, !cc.trimmingCharacters(in: .whitespaces).isEmpty {
            headers.append("Cc: \(cc)")
        }
        headers.append("Subject: \(encodedSubject(subject))")
        headers.append("MIME-Version: 1.0")
        if let inReplyTo {
            let reference = "<\(inReplyTo)>"
            headers.append("In-Reply-To: \(reference)")
            headers.append("References: \(reference)")
        }
        guard !attachments.isEmpty else {
            headers.append("Content-Type: text/plain; charset=UTF-8")
            headers.append("Content-Transfer-Encoding: 8bit")
            let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + body
            return base64URLEncode(Data(message.utf8))
        }
        let boundary = "corres-\(UUID().uuidString)"
        headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        var parts = "--\(boundary)\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(body)\r\n"
        for attachment in attachments {
            // `.lineLength76Characters` alone inserts no line breaks at all
            // (per Foundation's own docs); both end-line options together
            // are what actually produce a real CRLF, RFC 2045's line ending.
            let base64 = attachment.data.base64EncodedString(
                options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            parts += "--\(boundary)\r\n"
                + "Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"\r\n"
                + "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n"
                + "Content-Transfer-Encoding: base64\r\n\r\n"
                + base64 + "\r\n"
        }
        parts += "--\(boundary)--"
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + parts
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
