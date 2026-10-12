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
    static func compose(from: String, to: String, cc: String? = nil, bcc: String? = nil, subject: String, body: String, inReplyTo: String?,
                        messageID: String, attachments: [PendingAttachment] = []) -> String {
        var headers = [
            "From: \(from)",
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
        PeopleIndex.entries(in: field).map { entry in
            guard let (name, email) = PeopleIndex.parse(entry) else { return entry }
            guard !name.isEmpty else { return email }
            if !name.allSatisfy(\.isASCII) { return "=?UTF-8?B?\(Data(name.utf8).base64EncodedString())?= <\(email)>" }
            if name.rangeOfCharacter(from: CharacterSet(charactersIn: "()<>[]:;@\\,.\"")) != nil {
                let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\" <\(email)>"
            }
            return "\(name) <\(email)>"
        }.joined(separator: ", ")
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
