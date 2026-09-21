import GoogleSignIn
import SwiftData
import SwiftUI

@main
struct CorresApp: App {
    @State private var store: MailStore
    @State private var sync: GmailSyncService
    @State private var auth = GoogleAuthService()
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue

    init() {
        let container = Self.makeModelContainer()
        let repository = SwiftDataMailRepository(modelContainer: container)
        _store = State(initialValue: MailStore(repository: repository))
        _sync = State(initialValue: GmailSyncService(repository: repository))
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema(CorresSchemaV1.models)
        do {
            return try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                      configurations: [ModelConfiguration(schema: schema)])
        } catch {
            // A corrupt/incompatible on-disk store should not brick the app on
            // launch; fall back to a fresh in-memory container so it still
            // opens, at the cost of that device's local history this session.
            let fallbackConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            guard let fallback = try? ModelContainer(for: schema, configurations: [fallbackConfiguration]) else {
                fatalError("Could not create any Corres local store, including an in-memory fallback: \(error)")
            }
            return fallback
        }
    }

    var body: some Scene {
        WindowGroup {
            CorresShell(store: store, auth: auth, sync: sync)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .tint(CorresPalette.accent)
                .task {
                    await auth.restorePreviousSignIn()
                    if await sync.syncIfConnected(account: auth.account?.email) {
                        await store.load()
                    }
                }
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
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
