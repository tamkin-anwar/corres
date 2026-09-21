import SwiftUI

struct ConversationView: View {
    let store: MailStore
    let id: ThreadID
    @State private var composeDraft: Draft?

    var body: some View {
        Group {
            if let thread = store.threads.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text(thread.subject).font(CorresType.display)
                        HStack(spacing: 14) {
                            CorrespondentAvatar(initials: thread.initials)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(thread.sender).font(.headline)
                                Text(thread.organization).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                            }
                        }
                        Text(thread.receivedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(CorresPalette.secondary)
                        VStack(alignment: .leading, spacing: 12) {
                            Label(thread.attention.title, systemImage: "text.bubble")
                                .font(.subheadline.weight(.semibold))
                            Text(thread.reason).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                            Text("Context supplied with this fictional conversation. No AI processing.")
                                .font(.caption).foregroundStyle(CorresPalette.secondary)
                        }
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading).corresSurface()
                        Text(thread.body).font(.body).lineSpacing(8).textSelection(.enabled)
                            .padding(24).frame(maxWidth: .infinity, alignment: .leading).corresSurface()
                        Divider()
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Keep it in the right place").font(CorresType.heading)
                            Text("Changes apply to this sample session only.")
                                .font(.footnote).foregroundStyle(CorresPalette.secondary)
                            ForEach(Attention.allCases, id: \.self) { attention in
                                Button {
                                    Task { await store.update(id, to: attention) }
                                } label: {
                                    HStack {
                                        Text(attention.title)
                                        Spacer()
                                        if thread.attention == attention { Image(systemName: "checkmark") }
                                    }
                                    .padding(.horizontal, 18).frame(minHeight: 48)
                                    .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(thread.attention == attention ? CorresPalette.accent : CorresPalette.line, lineWidth: thread.attention == attention ? 1.5 : 0.5))
                                }
                                .disabled(store.pending.contains(id))
                                .accessibilityValue(thread.attention == attention ? "Selected" : "")
                            }
                        }
                        Text("Replying, forwarding, and sending stay on this device until Gmail is connected.")
                            .font(.footnote).foregroundStyle(CorresPalette.secondary)
                    }
                    .padding(CorresSpace.page).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom) { replyBar(for: thread) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { composeDraft = thread.draft(kind: .forward) } label: {
                                Label("Forward", systemImage: "arrowshape.turn.up.right")
                            }
                            Button {
                                Task { await store.setPinned(!thread.isPinned, for: id) }
                            } label: {
                                Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin")
                            }
                            Menu {
                                ForEach(SnoozeOption.allCases, id: \.self) { option in
                                    Button(option.title) { Task { await store.snooze(id, until: option.date()) } }
                                }
                            } label: {
                                Label("Snooze", systemImage: "moon")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("More actions")
                        .disabled(store.pending.contains(id))
                    }
                }
            } else {
                ContentUnavailableView("Conversation unavailable", systemImage: "text.bubble")
            }
        }
        .background(CorresPalette.canvas)
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $composeDraft) { draft in
            ComposeView(store: store, draft: draft)
        }
    }

    private func replyBar(for thread: Correspondence) -> some View {
        HStack(spacing: 12) {
            Button { composeDraft = thread.draft(kind: .reply) } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            Button { composeDraft = thread.draft(kind: .replyAll) } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, CorresSpace.page).padding(.vertical, 10)
        .background(.bar)
    }
}

enum SnoozeOption: CaseIterable {
    case laterToday, tomorrow, nextWeek

    var title: String {
        switch self {
        case .laterToday: "Later today"
        case .tomorrow: "Tomorrow morning"
        case .nextWeek: "Next week"
        }
    }

    func date(from now: Date = .now) -> Date {
        let calendar = Calendar.current
        switch self {
        case .laterToday:
            return calendar.date(byAdding: .hour, value: 3, to: now) ?? now
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .nextWeek:
            return calendar.date(byAdding: .day, value: 7, to: now) ?? now
        }
    }
}
