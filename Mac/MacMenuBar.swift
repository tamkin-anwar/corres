import SwiftUI

/// Needs You in the menu bar: how many emails ask something of you, and
/// the first few, one click from opening, without bringing Corres forward
/// first. Settings › General can hide it.
struct MacMenuBarContent: View {
    let services: MacServices
    @Environment(\.openWindow) private var openWindow

    private var needsYou: [Correspondence] {
        MailQuery.prioritized(services.store.threads, attention: .needsYou)
    }

    var body: some View {
        let items = needsYou
        if items.isEmpty {
            Text("Nothing needs you")
        } else {
            Text(items.count == 1 ? "1 email needs you" : "\(items.count) emails need you")
            Divider()
            ForEach(items.prefix(8)) { thread in
                Button {
                    services.router.pending = .thread(thread.id)
                    openWindow(id: "main")
                    NSApp.activate()
                } label: {
                    Text("\(thread.sender): \(thread.subject.isEmpty ? String(localized: "No subject") : thread.subject)")
                }
            }
        }
        Divider()
        Button("New Message") {
            openWindow(value: ComposeRequest(kind: .new))
            NSApp.activate()
        }
        .keyboardShortcut("n")
        Button("Open Corres") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Get New Mail") { Task { await services.checkForMail() } }
    }
}

/// The menu bar icon: the mark, with the count beside it when something
/// needs you.
struct MacMenuBarLabel: View {
    let services: MacServices

    var body: some View {
        let count = MailQuery.prioritized(services.store.threads, attention: .needsYou).count
        if count > 0 {
            Label("\(count)", systemImage: "tray.full")
                .accessibilityLabel(count == 1 ? "Corres: 1 email needs you" : "Corres: \(count) emails need you")
        } else {
            Image(systemName: "tray")
                .accessibilityLabel("Corres: nothing needs you")
        }
    }
}

enum MacMenuBarSetting {
    static let key = "corres.mac.menuBar"
}
