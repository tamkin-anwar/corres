import SwiftUI

struct WelcomeView: View {
    var scrolls = true
    let onExplore: () -> Void
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize
    /// At the accessibility sizes the note under the button scrolls with
    /// the rest, so the part that stays put is only the button.
    private var noteScrolls: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        Group {
            if scrolls {
                // Explore Corres stays on screen at every size, from iPhone
                // SE to the largest text; what's above it scrolls. When it
                // all fits, it sits in the middle of the space, as before.
                GeometryReader { proxy in
                    ScrollView {
                        introduction(withNote: noteScrolls)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // What scrolls under it fades out rather than stopping
                    // at a hard edge.
                    actions(withNote: !noteScrolls)
                        .background {
                            LinearGradient(stops: [.init(color: CorresPalette.canvas.opacity(0), location: 0),
                                                   .init(color: CorresPalette.canvas, location: 0.25)],
                                           startPoint: .top, endPoint: .bottom)
                                .ignoresSafeArea()
                        }
                }
            } else {
                content
            }
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

    /// All of it in one column, for the design render.
    var content: some View {
        VStack(spacing: 0) {
            introduction(withNote: false)
            actions(withNote: true)
        }
        .frame(maxWidth: .infinity, minHeight: 700)
    }

    private func introduction(withNote: Bool) -> some View {
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
                      "Every account in one inbox, newest first. First emails from new senders are marked New.")
                point("lock", "Private by design",
                      "Sorting, summaries and drafts run on this \(Device.name). Your mail never goes to our servers or to an AI company.")
            }
            .padding(.top, 44)
            if withNote { note.padding(.top, 32) }
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 480)
    }

    private func actions(withNote: Bool) -> some View {
        VStack(spacing: 14) {
            Button("Explore Corres", action: onExplore).buttonStyle(CorresButtonStyle())
            if withNote { note }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 480)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }

    private var note: some View {
        Text("Start with sample mail. Connect Gmail, Outlook, iCloud or another email account anytime from Settings.")
            .font(.footnote).foregroundStyle(CorresPalette.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func point(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
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
