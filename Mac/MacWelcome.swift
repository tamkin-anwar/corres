import SwiftUI

/// The first time Corres opens on a Mac with no accounts: what it is, and
/// a choice between adding an account and looking around with sample
/// mail. Accounts already added on an iPhone or iPad arrive on their own
/// (iCloud Keychain), so this only shows when there are none.
struct MacWelcome: View {
    let onExplore: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            CorrespondenceMark(glow: true)
                .frame(width: 110, height: 110)
                .padding(.top, 36)
            Text("corres")
                .macFont(size: 42, weight: .regular, design: .serif)
                .padding(.top, 14)
            Text("Email, considered.")
                .macFont(.title3, design: .serif).italic()
                .foregroundStyle(CorresPalette.secondary)
            VStack(alignment: .leading, spacing: 16) {
                point("exclamationmark.circle", "What needs you, first",
                      "The few conversations that ask something of you, with the reason for each.")
                point("tray.2", "Every account, one inbox",
                      "Gmail, Outlook, iCloud and more. Accounts you added on your iPhone or iPad appear here on their own.")
                point("keyboard", "Made for the Mac",
                      "Mail's shortcuts, ⌘K to go anywhere, and drag to file. Press ? any time to see every key.")
                point("lock", "Private by design",
                      "Sorting, summaries and drafts run on this Mac. Your mail never goes to our servers or to an AI company.")
            }
            .padding(.top, 30)
            .padding(.horizontal, 44)
            HStack(spacing: 12) {
                Button("Explore Sample Mail", action: onExplore)
                    .controlSize(.large)
                Button("Add Account") {
                    onExplore()
                    openSettings()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 30)
            .padding(.bottom, 32)
        }
        .frame(width: 560)
        .background(CorresPalette.canvas)
    }

    private func point(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .macFont(.body, weight: .medium)
                .foregroundStyle(CorresPalette.accent)
                .frame(width: 24, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).macFont(.body, weight: .semibold)
                Text(detail).macFont(.callout).foregroundStyle(CorresPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
