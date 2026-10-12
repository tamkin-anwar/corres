import Foundation

/// Keeps the Share extension ready to write as you: your accounts, their
/// send-as addresses and signatures, and who you write to, refreshed as
/// Corres opens and as it goes to the background. Also lets the extension
/// use each account's sign-in (moved into the shared Keychain group).
@MainActor
enum ShareBridge {
    static func update(auth: GoogleAuthService, people: PeopleDirectory?, threads: [Correspondence]) async {
        let emails = auth.accounts.map(\.email)
        for email in emails { await GoogleTokenProvider.shared.share(email) }
        guard !emails.isEmpty else {
            // Still being restored at launch: keep what the extension has.
            guard !GoogleAuthService.hasSavedAccounts else { return }
            ShareSnapshot(accounts: [], defaultAccount: nil, people: PeopleIndex(), favored: [], ownNames: [], updatedAt: .now).save()
            return
        }
        people?.update(from: threads, accounts: emails)
        let shared = people?.forSharing() ?? (index: PeopleIndex(), favored: [])
        let directory = SendAsDirectory.shared
        let accounts = emails.map { email in
            ShareSnapshot.Account(
                email: email, name: auth.profile(for: email)?.name,
                addresses: directory.addresses(for: email).map {
                    ShareSnapshot.Address(email: $0.email, name: $0.name, isDefault: $0.isDefault, isPrimary: $0.isPrimary)
                },
                signature: CorresSettings.signature(for: email))
        }
        let defaultAccount = CorresSettings.defaultFromAccount.flatMap { emails.contains($0) ? $0 : nil } ?? emails.first
        ShareSnapshot(accounts: accounts, defaultAccount: defaultAccount, people: shared.index, favored: shared.favored,
                      ownNames: Set(emails.compactMap { auth.profile(for: $0)?.name }), updatedAt: .now).save()
    }
}
