import SwiftUI

struct MailListView: View {
    let store: WatchMailStore

    var body: some View {
        List {
            if !store.hasHeardFromPhone {
                Text("Open Corres on your iPhone to see your mail here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if store.needsYou.isEmpty && store.waiting.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "checkmark.circle").font(.title3).foregroundStyle(WatchPalette.accent)
                    Text("Nothing needs you").font(.headline)
                    Text("You're all caught up.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !store.needsYou.isEmpty {
                Section("Needs You") {
                    ForEach(store.needsYou) { mail in
                        NavigationLink(value: mail) { MailRow(mail: mail, showsReason: true) }
                    }
                }
            }
            if !store.waiting.isEmpty {
                Section("Waiting") {
                    ForEach(store.waiting) { mail in
                        NavigationLink(value: mail) { MailRow(mail: mail, showsReason: false) }
                    }
                }
            }
        }
        .navigationTitle("Corres")
        .navigationDestination(for: WatchLink.Mail.self) { mail in
            MailDetailView(store: store, mail: mail)
        }
    }
}

private struct MailRow: View {
    let mail: WatchLink.Mail
    let showsReason: Bool
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if mail.isUnread {
                    Circle().fill(WatchPalette.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Text(mail.sender).font(.headline).lineLimit(1)
            }
            Text(mail.subject).font(.footnote).lineLimit(2)
            if showsReason, !mail.reason.isEmpty {
                Text(mail.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        // Who wrote and what about stay hidden with your wrist down.
        .privacySensitive()
        .redacted(reason: isLuminanceReduced ? .privacy : [])
        .accessibilityElement(children: .combine)
        .accessibilityValue(mail.isUnread ? Text("Unread") : Text(""))
    }
}

struct MailDetailView: View {
    let store: WatchMailStore
    let mail: WatchLink.Mail
    @State private var replying = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    Text(mail.sender).font(.headline)
                    Text(mail.subject).font(.subheadline.weight(.semibold))
                    if !mail.reason.isEmpty {
                        Text(mail.reason).font(.footnote).foregroundStyle(WatchPalette.accent)
                    }
                }
                .privacySensitive()
                Text(mail.receivedAt, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                Text(mail.preview).font(.body)
                    .privacySensitive()
                VStack(spacing: 6) {
                    Button { replying = true } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    Button {
                        store.send(.handled(key: mail.key))
                        dismiss()
                    } label: { Label("Handled", systemImage: "checkmark.circle") }
                    Button {
                        store.send(.archive(key: mail.key))
                        dismiss()
                    } label: { Label("Archive", systemImage: "archivebox") }
                }
                .padding(.top, 6)
            }
        }
        .redacted(reason: isLuminanceReduced ? .privacy : [])
        .navigationTitle(isLuminanceReduced ? "" : mail.sender)
        .onAppear { if mail.isUnread { store.send(.markRead(key: mail.key)) } }
        .sheet(isPresented: $replying) {
            ReplyView(store: store, mail: mail)
        }
    }
}

/// A reply by voice, Scribble or a ready answer, sent from your iPhone.
struct ReplyView: View {
    let store: WatchMailStore
    let mail: WatchLink.Mail
    @State private var text = ""
    @State private var sent = false
    /// The iPhone was out of reach: the reply waits on the Watch until it's back.
    @State private var queued = false
    @Environment(\.dismiss) private var dismiss

    private var suggestions: [String] {
        [String(localized: "Thanks, got it."), String(localized: "Sounds good."),
         String(localized: "I'll get back to you soon."), String(localized: "Yes, that works.")]
    }

    var body: some View {
        if sent {
            VStack(spacing: 8) {
                Image(systemName: queued ? "clock" : "paperplane.fill").font(.title2).foregroundStyle(WatchPalette.accent)
                (queued ? Text("Will send from your iPhone") : Text("Sent from your iPhone"))
                    .font(.footnote).multilineTextAlignment(.center)
            }
            .task {
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            }
        } else {
            List {
                TextField("Say or write a reply", text: $text)
                    .onSubmit { send(text) }
                Section {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { send(suggestion) }
                    }
                }
            }
            .navigationTitle("Reply")
        }
    }

    private func send(_ words: String) {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queued = !store.send(.reply(key: mail.key, text: trimmed))
        sent = true
    }
}
