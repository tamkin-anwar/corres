import SwiftUI

/// Mailboxes → Send Later: what's waiting to go, and when. Tap one to send
/// it now, change its time, edit it, or take it off the schedule.
struct ScheduledView: View {
    let store: MailStore
    let outbox: OutboxService
    let auth: GoogleAuthService
    private var scheduled: ScheduledSends { ScheduledSends.shared }
    @State private var chosen: ScheduledSends.Item?
    @State private var changingTime: ScheduledSends.Item?
    @State private var newTime = Date.now
    @State private var editing: Draft?

    var body: some View {
        List {
            if scheduled.items.isEmpty {
                Text("Nothing scheduled. Press and hold Send to send an email later.")
                    .foregroundStyle(CorresPalette.secondary)
            }
            ForEach(scheduled.items) { item in
                Button { chosen = item } label: { row(item) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Send Now") { Task { await scheduled.sendNow(item.id, store: store, outbox: outbox) } }
                            .tint(CorresPalette.accent)
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Send Later")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(chosen?.draft.subject.isEmpty == false ? chosen!.draft.subject : "Scheduled email",
                            isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                            titleVisibility: .visible, presenting: chosen) { item in
            Button("Send Now") { Task { await scheduled.sendNow(item.id, store: store, outbox: outbox) } }
            Button("Change Time") { newTime = item.sendAt; changingTime = item }
            Button("Edit") { editing = scheduled.remove(item.id) }
            Button("Move to Drafts") {
                if let draft = scheduled.remove(item.id) {
                    outbox.shelve(draft, replyingTo: draft.threadID.flatMap { store.thread($0) })
                }
            }
            Button("Delete", role: .destructive) { scheduled.remove(item.id) }
        }
        .sheet(item: $changingTime) { item in
            NavigationStack {
                DatePicker("Send at", selection: $newTime, in: Date.now.addingTimeInterval(60)..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical).tint(CorresPalette.accent)
                    .padding(.horizontal, CorresSpace.page)
                Spacer()
                    .navigationTitle("Change Time")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { changingTime = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                scheduled.reschedule(item.id, to: newTime)
                                scheduled.keepTime(store: store, outbox: outbox)
                                changingTime = nil
                            }
                            .fontWeight(.semibold)
                        }
                    }
            }
        }
        .sheet(item: $editing) { draft in
            ComposeView(store: store, outbox: outbox, auth: auth, draft: draft,
                        sourceThread: draft.threadID.flatMap { store.thread($0) })
        }
    }

    private func row(_ item: ScheduledSends.Item) -> some View {
        let to = PeopleIndex.entries(in: item.draft.to + "," + (item.draft.cc ?? "") + "," + (item.draft.bcc ?? ""))
            .compactMap { PeopleIndex.parse($0) }
            .map { $0.name.isEmpty ? $0.email : Person.readable($0.name) }
        return VStack(alignment: .leading, spacing: 3) {
            Text(to.isEmpty ? String(localized: "No recipients") : to.joined(separator: ", ")).font(.body.weight(.semibold)).lineLimit(1)
            Text(item.draft.subject.isEmpty ? String(localized: "No subject") : item.draft.subject).font(.subheadline).lineLimit(1)
            Label(item.heldBecauseReplied ? "Held: they replied first. Tap to send or change it."
                                          : "Sends \(ScheduledSends.describe(item.sendAt))",
                  systemImage: item.heldBecauseReplied ? "pause.circle" : "clock.arrow.circlepath")
                .labelStyle(TightLabelStyle())
                .font(.footnote)
                .foregroundStyle(item.heldBecauseReplied ? CorresPalette.alert : CorresPalette.accent)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
