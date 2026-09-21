import SwiftUI

struct CorresShell: View {
    @Bindable var store: MailStore
    var auth: GoogleAuthService
    @State private var selection = Destination.brief
    @State private var showingSettings = false
    @State private var showingWelcome = false
    @State private var composeDraft: Draft?
    @AppStorage("corres.hasExplored") private var hasExplored = false

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Destination.allCases) { destination in
                NavigationStack {
                    destinationContent(for: destination)
                        .background(CorresPalette.canvas)
                        .navigationTitle(destination.rawValue)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { toolbarContent }
                        .navigationDestination(for: ThreadID.self) { id in
                            ConversationView(store: store, id: id)
                        }
                }
                .tabItem { Label { Text(destination.rawValue) } icon: { Image(uiImage: CorresIcon.tabImage(destination.glyph)) } }
                .tag(destination)
            }
        }
        .foregroundStyle(CorresPalette.ink)
        .task {
            if !hasExplored { showingWelcome = true }
            if store.state == .idle { await store.load() }
        }
        .sheet(isPresented: $showingSettings) { PreferencesView(store: store, auth: auth) }
        .sheet(item: $composeDraft) { draft in ComposeView(store: store, draft: draft) }
        .fullScreenCover(isPresented: $showingWelcome) {
            WelcomeView {
                hasExplored = true
                showingWelcome = false
            }
        }
        .alert("Could not save", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Please try again.") }
    }

    @ViewBuilder
    private func destinationContent(for destination: Destination) -> some View {
        switch store.state {
        case .idle, .loading:
            ProgressView("Preparing your space")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("A moment, please", systemImage: "arrow.clockwise")
            } description: {
                Text("Your sample conversations could not be opened.")
            } actions: {
                Button("Try again") { Task { await store.load() } }
            }
        case .loaded:
            if destination == .brief {
                BriefView(store: store, selection: $selection)
            } else {
                CorrespondenceList(store: store, destination: destination)
            }
        }
    }

    private var brandLabel: some View {
        HStack(spacing: 8) {
            CorrespondenceMark().frame(width: 30, height: 30)
            Text("corres")
                .font(.system(.title2, design: .serif).weight(.medium))
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Corres. Email, considered.")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The system wraps custom toolbar content in an automatic glass
        // capsule on iOS 26+, which breaks the icon+wordmark brand lockup
        // apart into separate pills. Opt out where that API exists; on
        // iOS 17-25 there is no such glass treatment to begin with.
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { brandLabel }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { brandLabel }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { composeDraft = Draft(kind: .new, to: "", subject: "") } label: {
                Image(systemName: "square.and.pencil")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("New message")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Preferences and privacy")
        }
    }
}
