import SwiftUI

@main
struct CorresApp: App {
    @State private var store = MailStore(repository: SampleMailRepository())
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            CorresShell(store: store)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .tint(CorresPalette.accent)
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}
