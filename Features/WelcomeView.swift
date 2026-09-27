import SwiftUI

struct WelcomeView: View {
    var scrolls = true
    let onExplore: () -> Void
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue

    var body: some View {
        Group {
            if scrolls { ScrollView { content }.scrollBounceBehavior(.basedOnSize) } else { content }
        }
        .foregroundStyle(CorresPalette.ink)
        .background {
            ZStack {
                CorresPalette.canvas
                RadialGradient(colors: [CorresPalette.accent.opacity(0.10), .clear],
                               center: UnitPoint(x: 0.5, y: 0.18), startRadius: 0, endRadius: 420)
            }
            .ignoresSafeArea()
        }
        // Self-contained, like PreferencesView and ComposeView: a distant
        // .preferredColorScheme does not reliably re-trait an already-
        // presented fullScreenCover if Appearance changes while it's open.
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
    }

    var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 72)
            CorrespondenceMark(glow: true)
                .frame(width: 150, height: 150)
            VStack(spacing: 10) {
                Text("corres")
                    .font(.system(size: 50, weight: .regular, design: .serif))
                    .dynamicTypeSize(...(.xxxLarge))
                Text("Email, considered.")
                    .font(.system(.title3, design: .serif).italic())
                    .foregroundStyle(CorresPalette.secondary)
            }
            .padding(.top, 20)
            VStack(alignment: .leading, spacing: 18) {
                point("exclamationmark.circle", "What needs you, first",
                      "The few conversations that ask something of you, with the reason for each.")
                point("tray", "Everything else, in one place",
                      "Every account in one inbox, newest first. Nothing hidden, ever.")
                point("lock", "Private by design",
                      "Sorting, summaries and drafts run on this iPhone. Your mail is never read on a server.")
            }
            .padding(.top, 44)
            Spacer(minLength: 40)
            VStack(spacing: 14) {
                Button("Explore Corres", action: onExplore).buttonStyle(CorresButtonStyle())
                Text("Start with sample mail. Connect Gmail anytime from Settings.")
                    .font(.footnote).foregroundStyle(CorresPalette.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, minHeight: 700)
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(CorresPalette.accent)
                .frame(width: 26, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
