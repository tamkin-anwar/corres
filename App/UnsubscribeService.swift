import Foundation
import Observation
import UIKit

/// Performs the actual unsubscribe once a message offers one, via
/// `Correspondence.listUnsubscribeMailto`/`listUnsubscribeURL`/
/// `listUnsubscribeOneClick` (parsed from the real `List-Unsubscribe`/
/// `List-Unsubscribe-Post` headers by `GmailAPIClient.map`; RFC 2369/8058).
///
/// Researched against what real mail clients actually do before building
/// this (see Docs/Architecture.md): Apple Mail only ever acts on the
/// `mailto:` form; Gmail supports both `mailto:` and a plain `https:` link.
/// Neither implements RFC 8058's one-click POST client-side as far as could
/// be found. Corres does, and prefers it whenever a message offers it: a
/// real HTTP POST the sender has explicitly vouched is safe to call
/// automatically, no email sent and no webpage visited, strictly faster and
/// more certain than either fallback. Order of preference, each one only
/// attempted if the one before it isn't offered or actually fails:
/// 1. RFC 8058 one-click POST (`listUnsubscribeOneClick` + `listUnsubscribeURL`).
/// 2. A `mailto:` opt-out message, sent for real through the connected
///    account (RFC 2369's older, still very common form).
/// 3. Opening a plain `https:`/`http:` link with no one-click header in
///    Safari: with no signal the endpoint is safe to call unattended, the
///    honest, safe choice is to hand it to the person to finish themselves,
///    not guess at submitting a form on an arbitrary third-party page.
@MainActor @Observable
final class UnsubscribeService {
    enum Outcome: Equatable { case done, opened, failed }

    var errorMessage: String?
    private let client = GmailAPIClient()

    func canUnsubscribe(_ thread: Correspondence) -> Bool {
        thread.listUnsubscribeMailto != nil || thread.listUnsubscribeURL != nil
    }

    @discardableResult
    func unsubscribe(from thread: Correspondence, store: MailStore) async -> Outcome {
        if thread.listUnsubscribeOneClick, let urlString = thread.listUnsubscribeURL, let url = URL(string: urlString) {
            if await postOneClick(url) {
                await markDone(thread, store: store)
                return .done
            }
            // A one-click POST that actually failed (dead endpoint, no
            // network) still has a real mailto/link fallback worth trying,
            // not an immediate dead end.
        }
        if let mailtoRaw = thread.listUnsubscribeMailto {
            if await sendMailtoUnsubscribe(mailtoRaw, account: thread.id.account) {
                await markDone(thread, store: store)
                return .done
            }
        }
        if let urlString = thread.listUnsubscribeURL, let url = URL(string: urlString) {
            _ = await UIApplication.shared.open(url)
            // Not marked done here: the person still has to complete
            // whatever that page asks for, and Corres has no way to confirm
            // they actually finished (unlike the two paths above, where a
            // 2xx response or a real accepted Gmail send is itself the
            // confirmation).
            return .opened
        }
        errorMessage = "Could not unsubscribe. Please try again."
        return .failed
    }

    private func markDone(_ thread: Correspondence, store: MailStore) async {
        guard let senderEmail = thread.senderEmail else { return }
        await store.markSenderUnsubscribed(senderEmail, account: thread.id.account)
    }

    /// RFC 8058's exact required shape: POST the literal body
    /// `List-Unsubscribe=One-Click`, form-encoded, to the URL the sender
    /// already vouched for. A 2xx response is the sender's own
    /// acknowledgment that the request was received and will be honored;
    /// nothing more to confirm on Corres's side.
    private func postOneClick(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "List-Unsubscribe=One-Click".data(using: .utf8)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return false }
        return true
    }

    /// Sends a real message through the connected account to whatever
    /// address (and, when the sender pre-filled one, subject/body) the
    /// `mailto:` URI specifies, exactly as RFC 2369 expects: the mere act
    /// of that message arriving is what the sender's own list software
    /// treats as the opt-out request.
    private func sendMailtoUnsubscribe(_ mailtoRaw: String, account: String) async -> Bool {
        guard let parsed = Self.parseMailto(mailtoRaw) else { return false }
        let raw = GmailMessageComposer.compose(from: account, to: parsed.address,
                                                subject: parsed.subject.isEmpty ? "unsubscribe" : parsed.subject,
                                                body: parsed.body, inReplyTo: nil)
        return (try? await client.send(raw: raw, threadId: nil, account: account)) != nil
    }

    private static func parseMailto(_ raw: String) -> (address: String, subject: String, body: String)? {
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "mailto" else { return nil }
        // A mailto: URI has no host of its own; URLComponents parses the
        // address portion into `path`, not `host`.
        let address = components.path
        guard !address.isEmpty else { return nil }
        var subject = ""
        var body = ""
        for item in components.queryItems ?? [] {
            switch item.name.lowercased() {
            case "subject": subject = item.value ?? ""
            case "body": body = item.value ?? ""
            default: break
            }
        }
        return (address, subject, body)
    }
}
