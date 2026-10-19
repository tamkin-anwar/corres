import GoogleSignIn
import SwiftUI

/// Corres for Mac: a native Mac app on the same engine, sync, sorting and
/// iCloud state as the iPhone app. Its own windows, sidebar, toolbar,
/// menus and keyboard, built for the Mac rather than carried over from
/// iPhone.
@main
struct CorresMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var services = MacServices()
    @State private var model = MacMailboxModel()
    @AppStorage("corres.appearance") private var appearance = "system"

    var body: some Scene {
        Window("Corres", id: "main") {
            MacMainView(services: services, model: model)
                .environment(services.intelligence)
                .environment(services.router)
                .environment(services.ask)
                .environment(services.entitlements)
                .environment(services.people)
                .tint(CorresPalette.accent)
                .preferredColorScheme(colorScheme)
                .frame(minWidth: 900, minHeight: 560)
                .task { await services.launch() }
                .onOpenURL { url in
                    if !services.router.open(url) { GIDSignIn.sharedInstance.handle(url) }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { MacCommands() }

        // A conversation in a window of its own.
        WindowGroup("Conversation", for: ThreadID.self) { $id in
            if let id, let thread = services.store.thread(id) {
                ReadingPane(thread: thread, services: services) { _ in }
                    .environment(services.intelligence)
                    .environment(services.people)
                    .tint(CorresPalette.accent)
                    .preferredColorScheme(colorScheme)
                    .frame(minWidth: 560, minHeight: 480)
            }
        }
        .defaultSize(width: 760, height: 820)

        WindowGroup("New Message", for: ComposeRequest.self) { $request in
            if let request {
                MacComposeView(request: request, services: services)
                    .tint(CorresPalette.accent)
                    .preferredColorScheme(colorScheme)
            }
        }
        .defaultSize(width: 680, height: 560)

        Settings {
            MacSettingsView(services: services)
                .tint(CorresPalette.accent)
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance { case "light": .light; case "dark": .dark; default: nil }
    }
}
