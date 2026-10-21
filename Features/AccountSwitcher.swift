import SwiftUI

/// Gmail's account switcher, from your photo: All Inboxes, then each
/// account with its colour and unread count, then Settings. A sheet, not a
/// menu, so each account shows who it is at a glance, as Gmail and Spark
/// show them.
struct AccountSwitcher: View {
    let store: MailStore
    var auth: GoogleAuthService
    @Binding var selection: String?
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AccountPreferences.revisionKey) private var accountsRevision = 0

    private var emails: [String] { auth.accounts.map(\.email) }

    /// Unread in Primary, as Gmail's switcher counts and the inbox's own
    /// "· 9 unread" reads: not every newsletter ever left unread.
    private func unread(_ account: String?) -> Int {
        store.overview(account: account, all: emails).primaryUnread
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CorresSpace.medium) {
                    VStack(spacing: 0) {
                        row(account: nil)
                        ForEach(auth.accounts) { account in
                            Divider().padding(.leading, 68)
                            row(account: account.email)
                        }
                    }
                    .corresCardFill(in: RoundedRectangle(cornerRadius: CorresSpace.radius, style: .continuous))

                    Button {
                        openSettings()
                        dismiss()
                    } label: {
                        Label("Manage Accounts and Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CorresButtonStyle())
                }
                .padding(.horizontal, CorresSpace.page)
                .padding(.top, 4)
            }
            .background(CorresPalette.canvas)
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(account: String?) -> some View {
        let isSelected = selection == account
        let count = unread(account)
        return Button {
            selection = account
            dismiss()
        } label: {
            HStack(spacing: 12) {
                icon(for: account)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.map(AccountPreferences.nickname(for:)) ?? "All Inboxes")
                        .font(.body.weight(.medium)).foregroundStyle(CorresPalette.ink).lineLimit(1)
                    Text(subtitle(for: account))
                        .font(.footnote).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if count > 0 {
                    Text("\(count)").font(.subheadline).monospacedDigit().foregroundStyle(CorresPalette.secondary)
                }
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CorresPalette.accent)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 18)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(count > 0 ? "\(count) unread" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func icon(for account: String?) -> some View {
        if let account {
            let profile = auth.profile(for: account)
            AccountAvatar(email: account, name: profile?.name, photoURL: profile?.photoURL, size: 38)
                .padding(2)
                .overlay {
                    if let color = AccountPreferences.color(for: account, among: emails) {
                        Circle().strokeBorder(color, lineWidth: 2)
                    }
                }
        } else {
            Image(systemName: "tray.2")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(CorresPalette.accent)
                .frame(width: 42, height: 42)
                .background(CorresPalette.accent.opacity(0.14), in: Circle())
        }
    }

    private func subtitle(for account: String?) -> String {
        guard let account else {
            let shown = AccountPreferences.allInboxesAccounts(emails).count
            return shown == emails.count ? String(localized: "Every account, newest first") : String(localized: "\(shown) of \(emails.count) accounts")
        }
        return AccountPreferences.showsInAllInboxes(account) ? account : String(localized: "\(account) · not in All Inboxes")
    }
}
