import SwiftUI

struct BriefView: View {
    var scrolls = true
    let store: MailStore
    /// Optional: nil only for the offline preview-render script, which never
    /// exercises the scrolls==true/refreshable path that uses these.
    var sync: GmailSyncService?
    var auth: GoogleAuthService?
    @Binding var selection: Destination
    @Environment(\.dynamicTypeSize) private var typeSize

    private var snapshot: BriefSnapshot { BriefSnapshot(threads: store.threads, now: .now) }
    private var priorities: [Correspondence] { MailQuery.filter(store.threads, attention: .needsYou) }

    var body: some View {
        if scrolls {
            ScrollView { content }.refreshable {
                _ = await sync?.syncIfConnected(account: auth?.account?.email)
                await store.load()
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    Spacer(minLength: 8)
                    Text("SAMPLE").tracking(1.5)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(CorresPalette.line, lineWidth: 0.75))
                }
                .font(CorresType.label).foregroundStyle(CorresPalette.secondary)
                Text("A little clarity.").font(CorresType.display)
                Text("Your day, thoughtfully considered.")
                    .foregroundStyle(CorresPalette.secondary)
            }
            briefCard
            attentionCards
            HStack(alignment: .firstTextBaseline) {
                Text("Worth your attention").font(CorresType.heading)
                Spacer(minLength: 8)
                Button { selection = .needsYou } label: {
                    Image(systemName: "arrow.up.right").font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("View all conversations that need you")
            }.padding(.bottom, -14)
            if priorities.isEmpty {
                Label("Nothing needs you right now.", systemImage: "checkmark.circle")
                    .padding(24).frame(maxWidth: .infinity, alignment: .leading).corresSurface()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(priorities.prefix(3).enumerated()), id: \.element.id) { index, thread in
                        NavigationLink(value: thread.id) { CorrespondenceRow(thread: thread) }
                            .buttonStyle(CorresRowButtonStyle())
                        if index < min(priorities.count, 3) - 1 { Divider().padding(.leading, 78).padding(.trailing, 20) }
                    }
                }.corresSurface()
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield").font(.title3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Private by intention.").font(.subheadline.weight(.medium))
                    Text("Fictional mail. No account connected.").font(.footnote)
                }
            }
            .foregroundStyle(CorresPalette.secondary).padding(.horizontal, 6)
            Text("ANWAR CREATIVE STUDIO")
                .font(CorresType.label).tracking(2.5).foregroundStyle(CorresPalette.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .padding(CorresSpace.page).frame(maxWidth: 680).frame(maxWidth: .infinity)
    }

    private var briefCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("CORRES BRIEF").font(CorresType.label).tracking(2.5)
                Spacer()
                Image(systemName: "sun.horizon").font(.body).accessibilityHidden(true)
            }.foregroundStyle(CorresPalette.champagne)
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Less noise.\nMore perspective.")
                        .font(.system(.title, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("A moment to see\nwhat matters.")
                        .font(.subheadline).foregroundStyle(Color(hex: 0xD3DFE4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize {
                    CorrespondenceSculpture().frame(width: 124, height: 155)
                        .padding(.trailing, -12)
                }
            }
            Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
            Text(snapshot.needsYou == 0
                 ? "Nothing needs your attention. Take the space."
                 : "\(snapshot.needsYou) conversations need your perspective.")
                .font(.subheadline).foregroundStyle(Color(hex: 0xE3EAED))
                .fixedSize(horizontal: false, vertical: true)
            if snapshot.upcoming > 0 {
                Label("\(snapshot.upcoming) due within the next 24 hours", systemImage: "clock")
                    .font(.caption).foregroundStyle(CorresPalette.champagne)
            }
            Button { selection = .needsYou } label: {
                HStack {
                    Text("Open your priorities")
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(hex: 0x183344))
                .padding(16).frame(minHeight: 52)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0xF6EBD5), Color(hex: 0xD9C6A5)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.6), lineWidth: 0.75))
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 4)
                }
            }.buttonStyle(CorresRowButtonStyle())
        }
        .padding(24)
        .foregroundStyle(Color(hex: 0xFAF7EF))
        .background(InkMaterial())
        .shadow(color: CorresPalette.midnight.opacity(0.16), radius: 18, x: 0, y: 12)
    }

    private var attentionCards: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            attentionCard(.needsYou, count: snapshot.needsYou, caption: "Your next move", glyph: .needsYou)
            attentionCard(.waiting, count: snapshot.waiting, caption: "In their hands", glyph: .waiting)
        }
    }

    private func attentionCard(_ destination: Destination, count: Int, caption: String, glyph: CorresGlyph) -> some View {
        Button { selection = destination } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SculptedBadge(glyph: glyph)
                    Spacer(minLength: 4)
                    Text(count, format: .number).font(.system(.largeTitle, design: .serif)).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(destination.rawValue).font(.subheadline.weight(.semibold))
                    Text(caption).font(.caption).foregroundStyle(CorresPalette.secondary)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).corresSurface()
        }
        .buttonStyle(CorresRowButtonStyle())
        .accessibilityLabel("\(destination.rawValue), \(count) conversations. \(caption)")
    }
}
