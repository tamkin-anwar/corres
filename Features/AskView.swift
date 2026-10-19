import SwiftUI

/// Ask your mail, inside Search: a question typed in the search field
/// is answered here, above the results, from your own email, with the
/// conversations it came from, tappable.
struct AskAnswerCard: View {
    @Bindable var ask: AskService
    @Environment(\.conversationSelection) private var splitSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch ask.phase {
            case .idle: EmptyView()
            case .searching, .answering: progress
            case .done: result
            }
        }
        .animation(.easeOut(duration: 0.2), value: ask.phase)
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

}
