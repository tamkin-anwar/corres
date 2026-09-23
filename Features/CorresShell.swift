import SwiftUI

struct CorresShell: View {
    @Bindable var store: MailStore
    var auth: GoogleAuthService
    var sync: GmailSyncService
    @Bindable var outbox: OutboxService
    @Bindable var threadActions: ThreadActionService
    @State private var selection = Destination.brief
    @State private var showingSettings = false
    @State private var showingScreener = false
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
                        .navigationDestination(for: ConversationRoute.self) { route in
                            ConversationView(store: store, outbox: outbox, threadActions: threadActions, route: route)
                        }
                }
                .tabItem { Label { Text(destination.rawValue) } icon: { Image(uiImage: CorresIcon.tabImage(destination.glyph)) } }
                .tag(destination)
            }
        }
        .foregroundStyle(CorresPalette.ink)
        .overlay(alignment: .bottom) { outboxBanner }
        .animation(.easeOut(duration: 0.22), value: outbox.pending?.id)
        .animation(.easeOut(duration: 0.22), value: outbox.failed?.id)
        .task {
            if !hasExplored { showingWelcome = true }
            if store.state == .idle { await store.load() }
        }
        .sheet(isPresented: $showingSettings) { PreferencesView(store: store, auth: auth, sync: sync) }
        .sheet(isPresented: $showingScreener) { ScreenerView(store: store) }
        .sheet(item: $composeDraft) { draft in ComposeView(store: store, outbox: outbox, draft: draft, sourceThread: nil) }
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
        .alert("Could not complete this action", isPresented: Binding(
            get: { threadActions.errorMessage != nil },
            set: { if !$0 { threadActions.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { threadActions.errorMessage = nil }
        } message: { Text(threadActions.errorMessage ?? "Please try again.") }
    }

    @ViewBuilder
    private var outboxBanner: some View {
        if let pending = outbox.pending {
            HStack(spacing: 12) {
                Text("Sending \u{201C}\(pending.subjectPreview)\u{201D} in \(pending.secondsRemaining)\u{2026}")
                    .font(.subheadline).lineLimit(1)
                Spacer(minLength: 8)
                Button("Undo") { outbox.undo() }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, CorresSpace.page).padding(.bottom, 90)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let failed = outbox.failed {
            HStack(spacing: 12) {
                Text("Couldn't send \u{201C}\(failed.draft.subject)\u{201D}").font(.subheadline).lineLimit(1)
                Spacer(minLength: 8)
                Button("Discard") { outbox.discardFailed() }.font(.subheadline)
                Button("Retry") { outbox.retryFailed() }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, CorresSpace.page).padding(.bottom, 90)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
                BriefView(store: store, sync: sync, auth: auth, selection: $selection, showingScreener: $showingScreener)
            } else {
                CorrespondenceList(store: store, sync: sync, auth: auth, threadActions: threadActions, destination: destination)
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
