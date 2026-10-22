import Foundation
import NaturalLanguage

/// Your writing style (see `WritingStyle`), learned from the email you've
/// sent from each account, and for the people you write to most, how you
/// write to them. Worked out again only when there's new sent mail to
/// learn from. Settings › Composing shows what it learned and can turn it
/// off; nothing is kept anywhere but in memory on this device.
@MainActor
final class WritingStyleBook {
    static let shared = WritingStyleBook()

    static let enabledKey = "corres.writeInMyStyle"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private struct Learned {
        let sentCount: Int
        let overall: WritingStyle?
        /// Your samples, by recipient address, for those you've written to often.
        let byRecipient: [String: [WritingStyle.Sample]]
        let ownNames: [String]
    }
    private var learned: [String: Learned] = [:]

    /// How you write from this account, and to this person when there's
    /// enough mail to them to say.
    func style(for account: String, recipient: String? = nil) -> WritingStyle? {
        guard Self.isEnabled, let learned = learn(account) else { return nil }
        if let recipient, let theirs = learned.byRecipient[recipient.lowercased()],
           let personal = WritingStyle.learn(from: theirs, ownNames: learned.ownNames, signature: signature(account)) {
            // Your length and tone overall; your greeting and examples for them.
            var style = learned.overall ?? personal
            style.greeting = personal.greeting ?? style.greeting
            style.signOff = personal.signOff ?? style.signOff
            style.examples = personal.examples
            return style
        }
        return learned.overall
    }

    /// For Settings: what was learned, from the account with the most sent mail.
    func summary() -> WritingStyle? {
        let accounts = Set(sentThreads().map(\.id.account))
        return accounts.compactMap { learn($0)?.overall }.max { $0.sampleCount < $1.sampleCount }
    }

    private func sentThreads() -> [Correspondence] {
        (Organizer.shared.store?.threads ?? []).filter {
            $0.isFromAccountOwner && $0.isBodyLoaded && $0.id.account != "sample" && !$0.labelIds.contains("DRAFT")
        }
    }

    private func learn(_ account: String) -> Learned? {
        let sent = sentThreads().filter { $0.id.account == account }
        if let cached = learned[account], cached.sentCount == sent.count { return cached }
        let samples = sent.sorted { $0.receivedAt > $1.receivedAt }.prefix(300).map { thread in
            (address: Self.recipientAddress(thread),
             sample: WritingStyle.Sample(text: thread.body, recipientName: thread.counterpartName(), date: thread.receivedAt))
        }
        let byRecipient = Dictionary(grouping: samples.filter { !$0.address.isEmpty }, by: \.address)
            .filter { $0.value.count >= WritingStyle.minimumSamples }
            .mapValues { $0.map(\.sample) }
        let names = ownNames(account, sent: sent)
        let result = Learned(sentCount: sent.count,
                             overall: WritingStyle.learn(from: samples.map(\.sample), ownNames: names, signature: signature(account)),
                             byRecipient: byRecipient, ownNames: names)
        learned[account] = result
        return result
    }

    private static func recipientAddress(_ thread: Correspondence) -> String {
        let first = (thread.toRecipients + thread.ccRecipients).first { !$0.lowercased().contains(thread.id.account.lowercased()) }
        return first.flatMap(PeopleIndex.parse)?.email.lowercased() ?? ""
    }

    /// The names you sign with: the one set for the account, your first
    /// name, and the name your sent mail goes out under.
    private func ownNames(_ account: String, sent: [Correspondence]) -> [String] {
        let given = UserDefaults.standard.string(forKey: GoogleAuthService.givenNameKey)
        return ([AccountPreferences.senderName(for: account), given] + sent.prefix(1).map(\.sender))
            .compactMap { $0 }.filter { !$0.isEmpty && !$0.contains("@") }
    }

    private func signature(_ account: String) -> String? {
        let text = CorresSettings.signature(for: account, reply: true)
        return text.isEmpty ? nil : text
    }

    /// The language a reply to this email is written in.
    nonisolated static func language(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(1_000)))?.rawValue
    }
}
