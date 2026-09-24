import SwiftUI

struct WelcomeView: View {
    var scrolls = true
    let onExplore: () -> Void
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue

    var body: some View {
        Group {
            if scrolls { ScrollView { content } } else { content }
        }
        .foregroundStyle(CorresPalette.ink).background(CorresPalette.canvas)
        // Self-contained, like PreferencesView and ComposeView: a distant
        // .preferredColorScheme does not reliably re-trait an already-
        // presented fullScreenCover if Appearance changes while it's open.
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
    }

    var content: some View {
            VStack(spacing: 30) {
                Text("ANWAR CREATIVE STUDIO")
                    .font(CorresType.label).tracking(3).foregroundStyle(CorresPalette.secondary)
                    .padding(.top, 28)
                ZStack {
                    InkMaterial(radius: 56)
                        .shadow(color: CorresPalette.midnight.opacity(0.25), radius: 28, y: 20)
                    CorrespondenceMark(sculpted: true).padding(34)
                }
                .frame(width: 214, height: 214).padding(.vertical, 20)
                VStack(spacing: 12) {
                    Text("corres")
                        .font(.system(.largeTitle, design: .serif))
                        // A hero wordmark still deserves to grow with Dynamic
                        // Type, but capped short of the accessibility sizes
                        // where 500pt-tall text would break this fixed layout.
                        .dynamicTypeSize(...(.xxxLarge))
                    Text("Email, considered.").font(CorresType.heading)
                    Text("A quieter place for the decisions,\nrelationships, and promises in your inbox.")
                        .font(.body).foregroundStyle(CorresPalette.secondary).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 22) {
                    welcomeRow(.brief, title: "Perspective, before the inbox", detail: "Brief brings the important conversations together.")
                    welcomeRow(.needsYou, title: "Know what needs you", detail: "A clear place for decisions and replies.")
                    welcomeRow(.waiting, title: "Give the rest some space", detail: "Keep track of what is moving with others.")
                }
                .padding(24).corresSurface()
                Button("Explore Corres", action: onExplore).buttonStyle(CorresButtonStyle())
                Text("Explore with fictional mail first, or connect your real Gmail account anytime from Preferences.")
                    .font(.footnote).foregroundStyle(CorresPalette.secondary).multilineTextAlignment(.center)
            }
            .padding(28).frame(maxWidth: 520).frame(maxWidth: .infinity)
    }

    private func welcomeRow(_ glyph: CorresGlyph, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            SculptedBadge(glyph: glyph)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.footnote).foregroundStyle(CorresPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
