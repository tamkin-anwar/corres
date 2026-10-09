import SwiftUI

/// Ask your mail: type a question, get an answer from your own email with
/// the conversations it came from, tappable.
struct AskView: View {
    @Bindable var ask: AskService
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.conversationSelection) private var splitSelection

    /// Built from this person's own mail each time Ask opens (see
    /// `AskService.suggestions`), so every one finds something.
    @State private var suggestions: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                field
                switch ask.phase {
                case .idle: suggestionList
                case .searching, .answering: progress
                case .done: result
                }
            }
            .padding(.horizontal, CorresSpace.page).padding(.top, 4).padding(.bottom, 32)
            .readableWidth()
            .frame(maxWidth: .infinity)
        }
        // The keyboard covers the tab bar, so every way out of it matters:
        // scrolling, tapping anywhere outside the field, Cancel, or Search.
        .scrollDismissesKeyboard(.immediately)
        .background(CorresPalette.canvas.onTapGesture { focused = false })
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button { focused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                    .accessibilityLabel("Hide keyboard")
            }
        }
        .animation(.easeOut(duration: 0.2), value: ask.phase)
        .onAppear { suggestions = ask.suggestions() }
    }

    private var field: some View {
        HStack(spacing: 12) {
            fieldCapsule
            if focused {
                Button("Cancel") { focused = false }
                    .font(.body)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: focused)
    }

    private var fieldCapsule: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(CorresPalette.accent)
            TextField("Ask about your mail", text: $text)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { submit(text) }
            if !text.isEmpty {
                Button {
                    text = ""
                    ask.reset()
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(CorresPalette.tertiary)
                }
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 50)
        .corresSurface(radius: 25)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !ask.recent.isEmpty {
                HStack {
                    Text("Recent").eyebrow()
                    Spacer()
                    Button("Clear") { ask.clearRecent() }.font(.footnote)
                }
                ForEach(ask.recent, id: \.self) { question in
                    Button {
                        text = question
                        submit(question)
                    } label: {
                        Label(question, systemImage: "clock.arrow.circlepath")
                            .labelStyle(TightLabelStyle())
                            .font(.subheadline).foregroundStyle(CorresPalette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 2)
            }
            Text("Try").eyebrow()
            ForEach(suggestions.filter { !ask.recent.contains($0) }, id: \.self) { suggestion in
                Button {
                    text = suggestion
                    submit(suggestion)
                } label: {
                    Text(suggestion)
                }
                .buttonStyle(CorresPillStyle())
            }
            Text("Ask about a person (“from Sam”), files (“attachments”), receipts or packages, and a time (“this month”, “last week”).")
                .font(.footnote).foregroundStyle(CorresPalette.secondary)
                .padding(.top, 4)
            Label(ask.canAnswer ? "Answered on this iPhone from your own mail. Nothing is sent to a server."
                                : "Turn on Apple Intelligence for written answers. Until then, Ask finds the right emails.",
                  systemImage: "lock")
                .labelStyle(TightLabelStyle())
                .font(.footnote).foregroundStyle(CorresPalette.tertiary)
                .padding(.top, 8)
        }
    }

    private var progress: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(ask.phase == .searching ? "Searching your mail…" : "Reading what it found…")
                .font(.subheadline).foregroundStyle(CorresPalette.secondary)
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var result: some View {
        if let listTitle = ask.listTitle {
            Label(listTitle, systemImage: ask.query?.wantsAttachments == true ? "paperclip" : "line.3.horizontal.decrease")
                .labelStyle(TightLabelStyle()).eyebrow(CorresPalette.accent)
                .padding(.horizontal, 4)
        }
        if let answer = ask.answer {
            VStack(alignment: .leading, spacing: 10) {
                Label(ask.answerFound ? "Answer · from \(ask.sources.count) \(ask.sources.count == 1 ? "email" : "emails")" : "Not found",
                      systemImage: ask.answerFound ? "sparkle" : "magnifyingglass")
                    .labelStyle(TightLabelStyle()).eyebrow(CorresPalette.accent)
                Text(answer)
                    .font(CorresType.brief).lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .corresSurface()
        }
        if ask.sources.isEmpty {
            if ask.answer == nil {
                Text("Nothing in your mail matched \u{201C}\(ask.question)\u{201D}. Try a name, a company, or fewer words.")
                    .font(.subheadline).foregroundStyle(CorresPalette.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if ask.listTitle == nil {
                    Text(ask.answer != nil && ask.answerFound ? "Sources" : "Closest matches").eyebrow().padding(.horizontal, 4)
                }
                VStack(spacing: 0) {
                    let ids = ask.sources.map(\.id)
                    ForEach(Array(ask.sources.enumerated()), id: \.element.id) { index, source in
                        let route = ConversationRoute(id: source.id, orderedIDs: ids)
                        Group {
                            if let splitSelection {
                                Button { splitSelection.wrappedValue = route } label: { sourceRow(source.thread) }
                            } else {
                                NavigationLink(value: route) { sourceRow(source.thread) }
                            }
                        }
                        .buttonStyle(CorresRowButtonStyle())
                        if index < ask.sources.count - 1 { Hairline(leading: 77) }
                    }
                }
                .padding(.vertical, 4)
                .corresSurface()
            }
        }
    }

    /// A source, with its files named when the question was about files.
    private func sourceRow(_ thread: Correspondence) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CorrespondenceRow(thread: thread)
            if ask.query?.wantsAttachments == true, !thread.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(thread.attachments) { file in
                        Label(file.filename, systemImage: "doc")
                            .labelStyle(TightLabelStyle())
                            .font(.footnote).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                    }
                }
                .padding(.leading, 77).padding(.trailing, 18).padding(.bottom, 12).padding(.top, -4)
            }
        }
    }

    private func submit(_ question: String) {
        focused = false
        ask.ask(question)
    }
}
