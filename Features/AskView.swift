import SwiftUI

/// Ask your mail: type a question, get an answer from your own email with
/// the conversations it came from, tappable.
struct AskView: View {
    @Bindable var ask: AskService
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.conversationSelection) private var splitSelection

    private let suggestions = [
        "When is my next flight?", "What did Maya ask me?", "Receipts this month", "Attachments from Oliver",
    ]

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
            Text("Try").eyebrow()
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    text = suggestion
                    submit(suggestion)
                } label: {
                    Text(suggestion)
                }
                .buttonStyle(CorresPillStyle())
            }
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
                Text("Nothing in your mail matched \u{201C}\(ask.question)\u{201D}.")
                    .font(.subheadline).foregroundStyle(CorresPalette.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(ask.answer != nil && ask.answerFound ? "Sources" : "Closest matches").eyebrow().padding(.horizontal, 4)
                VStack(spacing: 0) {
                    let ids = ask.sources.map(\.id)
                    ForEach(Array(ask.sources.enumerated()), id: \.element.id) { index, source in
                        let route = ConversationRoute(id: source.id, orderedIDs: ids)
                        Group {
                            if let splitSelection {
                                Button { splitSelection.wrappedValue = route } label: { CorrespondenceRow(thread: source.thread) }
                            } else {
                                NavigationLink(value: route) { CorrespondenceRow(thread: source.thread) }
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

    private func submit(_ question: String) {
        focused = false
        ask.ask(question)
    }
}
