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
    ///
    /// `messageID` (without `<...>`, same convention as `inReplyTo`) is
    /// `OutboxService`'s own stable, deterministic id for this specific
    /// outbox entry, not something Gmail assigns — stamping it into the
    /// outgoing `Message-ID` header ourselves is what lets
    /// `GmailAPIClient.findMessage` later look this exact send up by it, to
    /// tell "never sent" apart from "sent, but the response was lost"
    /// before a retry.
    /// `rootReference` is the conversation's first message, when known,
    /// so References names the whole chain: IMAP mail (and other people's
    /// mail apps) group a conversation by it.
    static func compose(from: String, to: String, cc: String? = nil, bcc: String? = nil, subject: String, body: String, inReplyTo: String?,
                        rootReference: String? = nil,
                        messageID: String, attachments: [PendingAttachment] = [], html: String? = nil,
                        calendar: String? = nil) -> String {
        var headers = [
            // "Tamkin Anwar <hello@studio.com>": the send-as address and
            // its name, encoded like To and Cc.
            "From: \(addressList(from))",
        ]
        // Bcc alone leaves no To header at all, as Gmail and Mail send it.
        if !to.trimmingCharacters(in: .whitespaces).isEmpty { headers.append("To: \(addressList(to))") }
        if let cc, !cc.trimmingCharacters(in: .whitespaces).isEmpty {
            headers.append("Cc: \(addressList(cc))")
        }
        // Gmail delivers to Bcc and takes the header out of what anyone
        // receives; only your own Sent copy keeps it.
        if let bcc, !bcc.trimmingCharacters(in: .whitespaces).isEmpty {
            headers.append("Bcc: \(addressList(bcc))")
        }
        headers.append("Subject: \(encodedSubject(subject))")
        headers.append("Message-ID: <\(messageID)>")
        headers.append("MIME-Version: 1.0")
        if let inReplyTo {
            let reference = "<\(inReplyTo)>"
            headers.append("In-Reply-To: \(reference)")
            if let rootReference, !rootReference.isEmpty, rootReference != inReplyTo {
                headers.append("References: <\(rootReference)> \(reference)")
            } else {
                headers.append("References: \(reference)")
            }
        }
        // The words: plain text, or, when formatted (bold, a list, a link),
        // plain and HTML together, so every mail app shows its best version.
        // An answer to an invitation adds its calendar part, which the
        // organizer's calendar reads (RFC 6047).
        let text: (headers: String, content: String)
        if html != nil || calendar != nil {
            let alternative = "corres-alt-\(UUID().uuidString)"
            func base64(_ string: String) -> String {
                Data(string.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            }
            var content = "--\(alternative)\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n\(MailEncoding.quotedPrintable(body))\r\n"
            if let html {
                content += "--\(alternative)\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64(html))\r\n"
            }
            if let calendar {
                content += "--\(alternative)\r\nContent-Type: text/calendar; charset=UTF-8; method=REPLY\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64(calendar))\r\n"
            }
            text = ("Content-Type: multipart/alternative; boundary=\"\(alternative)\"", content + "--\(alternative)--")
        } else {
            // Quoted-printable, not 8bit: a long paragraph went past SMTP's
            // 998-byte line limit and arrived broken.
            text = ("Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable", MailEncoding.quotedPrintable(body))
        }
        guard !attachments.isEmpty else {
            headers.append(text.headers)
            let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + text.content
            return base64URLEncode(Data(message.utf8))
        }
        let boundary = "corres-\(UUID().uuidString)"
        headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        var parts = "--\(boundary)\r\n\(text.headers)\r\n\r\n\(text.content)\r\n"
        for attachment in attachments {
            // `.lineLength76Characters` alone inserts no line breaks at all
            // (per Foundation's own docs); both end-line options together
            // are what actually produce a real CRLF, RFC 2045's line ending.
            let base64 = attachment.data.base64EncodedString(
                options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            parts += "--\(boundary)\r\n"
                + "Content-Type: \(attachment.mimeType); name=\"\(headerName(attachment.filename))\"\r\n"
                + "Content-Disposition: attachment; \(dispositionFilename(attachment.filename))\r\n"
                + "Content-Transfer-Encoding: base64\r\n\r\n"
                + base64 + "\r\n"
        }
        parts += "--\(boundary)--"
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + parts
        return base64URLEncode(Data(message.utf8))
    }

    /// To and Cc as headers: "Sara Wiltshire <sara@…>" as written; a name
    /// with a comma or other special character quoted, and one in any other
    /// script ("Zoë", "রিদিতা") RFC 2047-encoded, so it arrives as typed.
    static func addressList(_ field: String) -> String {
        let entries = PeopleIndex.entries(in: field).map { entry in
            guard let (name, email) = PeopleIndex.parse(entry) else { return entry }
            guard !name.isEmpty else { return email }
            if !name.allSatisfy(\.isASCII) { return "\(MailEncoding.encodedWords(name)) <\(email)>" }
            if name.rangeOfCharacter(from: CharacterSet(charactersIn: "()<>[]:;@\\,.\"")) != nil {
                let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\" <\(email)>"
            }
            return "\(name) <\(email)>"
        }
        // Folded between addresses once a line runs long (RFC 5322 2.2.3):
        // a reply to everyone on a long thread made one line past the
        // 998 characters mail servers accept.
        var result = ""
        var lineLength = 4 // "To: "
        for (index, entry) in entries.enumerated() {
            let lines = entry.components(separatedBy: "\r\n")
            if index > 0 {
                if lineLength + 2 + (lines.first?.count ?? 0) > 76 {
                    result += ",\r\n "
                    lineLength = 1
                } else {
                    result += ", "
                    lineLength += 2
                }
            }
            result += entry
            lineLength = lines.count > 1 ? (lines.last?.count ?? 0) : lineLength + entry.count
        }
        return result
    }

    /// A filename as a header value: plain when it's ASCII (quotes and
    /// backslashes escaped), RFC 2047 otherwise, so "Facture_été.pdf"
    /// arrives with its name, not garbled.
    private static func headerName(_ filename: String) -> String {
        guard filename.allSatisfy(\.isASCII) else { return "=?UTF-8?B?\(Data(filename.utf8).base64EncodedString())?=" }
        return filename.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// RFC 2231 `filename*` for non-ASCII names (what Mail and Gmail send),
    /// with the encoded-word form beside it for older readers.
    private static func dispositionFilename(_ filename: String) -> String {
        guard !filename.allSatisfy(\.isASCII) else { return "filename=\"\(headerName(filename))\"" }
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = filename.unicodeScalars.map { scalar -> String in
            scalar.isASCII && unreserved.contains(scalar) ? String(scalar)
                : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
        return "filename=\"\(headerName(filename))\"; filename*=UTF-8''\(encoded)"
    }

    /// RFC 2047 encoding for a non-ASCII subject, in words of at most 75
    /// characters on lines of their own; left untouched otherwise, since
    /// most real subjects are plain ASCII and don't need it.
    private static func encodedSubject(_ subject: String) -> String {
        MailEncoding.encodedWords(subject)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
