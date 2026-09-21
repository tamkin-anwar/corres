import SwiftUI

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("Make yourself comfortable") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Section("Your privacy, clearly") {
                    Label("No account connected", systemImage: "person.crop.circle.badge.checkmark")
                    Label("No advertising or analytics SDKs", systemImage: "hand.raised")
                    Label("No AI processing in this build", systemImage: "lock.shield")
                    Text("Sample conversations live in memory and reset when the app restarts. Only appearance and introduction preferences are saved on this device.")
                        .font(.footnote).foregroundStyle(CorresPalette.secondary)
                }
                Section("The next chapter") {
                    Text("Gmail will be the first connected account. Connection, reliable sync, offline storage, and sending are planned after this foundation is verified.")
                    Text("Future cloud intelligence will require a clear processing choice. Corres will never silently forward your correspondence to an AI service.")
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("corres").font(CorresType.heading)
                        Text("Email, considered.")
                        Text("A flagship by Anwar Creative Studio, alongside Artha.")
                            .font(.footnote).foregroundStyle(CorresPalette.secondary)
                        Text("Foundation preview · 0.1.0").font(.caption)
                    }.padding(.vertical, 8)
                }
            }
            .navigationTitle("Preferences")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        // .preferredColorScheme() set on a distant ancestor (here, the app's
        // WindowGroup root) does not reliably re-trait a .sheet() that is
        // already presented when the underlying value changes mid-presentation
        // — a separate SwiftUI quirk from the adaptive-color fix in Tokens.swift.
        // Applying it directly on this sheet's own content, driven by the same
        // @AppStorage value it already reads, makes it self-sufficient.
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
    }
}
