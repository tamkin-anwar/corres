import SwiftUI

/// Send Later in the sidebar: what's waiting to go, and when, as Mail
/// shows it. Select one to read it; send it now, change its time, edit it,
/// move it to Drafts or delete it.
struct MacScheduledList: View {
    @Binding var selection: UUID?
    private var scheduled: ScheduledSends { .shared }

    var body: some View {
        if scheduled.items.isEmpty {
            ContentUnavailableView("Nothing scheduled", systemImage: "clock.arrow.circlepath",
                                   description: Text("Choose Send Later in a new message to send it at a time you pick."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(scheduled.items, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.recipients(item.draft)).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.sendAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(CorresPalette.secondary)
                    }
                    Text(item.draft.subject.isEmpty ? "No subject" : item.draft.subject).lineLimit(1)
                    Label(item.heldBecauseReplied ? "Held: they replied first" : "Sends \(ScheduledSends.describe(item.sendAt))",
                          systemImage: item.heldBecauseReplied ? "pause.circle" : "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(item.heldBecauseReplied ? CorresPalette.alert : CorresPalette.accent)
                }
                .padding(.vertical, 4)
                .tag(item.id)
            }
            .listStyle(.inset)
        }
    }

    static func recipients(_ draft: Draft) -> String {
        let people = PeopleIndex.entries(in: draft.to + "," + (draft.cc ?? "") + "," + (draft.bcc ?? ""))
            .compactMap { PeopleIndex.parse($0) }
            .map { $0.name.isEmpty ? $0.email : Person.readable($0.name) }
        if !people.isEmpty { return people.joined(separator: ", ") }
        // Names without addresses, as typed.
        let typed = [draft.to, draft.cc ?? "", draft.bcc ?? ""].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return typed.isEmpty ? String(localized: "No recipients") : typed.joined(separator: ", ")
    }
}

/// One scheduled email, read as it will go, with what can be done to it.
struct MacScheduledDetail: View {
    let item: ScheduledSends.Item
    let services: MacServices
    /// Opens it in Compose (taken off the schedule first).
    let edit: (Draft) -> Void
    @State private var changingTime = false
    @State private var newTime = Date.now
    @State private var confirmingDelete = false
    private var scheduled: ScheduledSends { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.draft.subject.isEmpty ? "No subject" : item.draft.subject)
                    .font(.system(size: 24, weight: .regular, design: .serif))
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 4) {
                    line("To", MacScheduledList.recipients(item.draft))
                    if let from = item.draft.fromAddress ?? item.draft.fromAccount, from != "sample" { line("From", from) }
                }
                HStack(spacing: 10) {
                    Label(item.heldBecauseReplied ? "Held because they replied first. Send it, change it, or delete it."
                                                  : "Sends \(ScheduledSends.describe(item.sendAt)), from this Mac.",
                          systemImage: item.heldBecauseReplied ? "pause.circle" : "clock.arrow.circlepath")
                        .foregroundStyle(item.heldBecauseReplied ? CorresPalette.alert : CorresPalette.accent)
                    Spacer()
                }
                .font(.callout)
                .padding(12)
                .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    Button("Send Now") {
                        Task { await scheduled.sendNow(item.id, store: services.store, outbox: services.outbox) }
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    Button("Change Time…") { newTime = item.sendAt; changingTime = true }
                        .popover(isPresented: $changingTime, arrowEdge: .bottom) { timePicker }
                    Button("Edit") { if let draft = scheduled.remove(item.id) { edit(draft) } }
                    Button("Move to Drafts") {
                        if let draft = scheduled.remove(item.id) {
                            services.outbox.shelve(draft, replyingTo: draft.threadID.flatMap { services.store.thread($0) })
                        }
                    }
                    Spacer()
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                }
                Divider()
                Text(item.draft.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !item.draft.attachments.isEmpty {
                    Label(item.draft.attachments.count == 1 ? "1 attachment" : "\(item.draft.attachments.count) attachments", systemImage: "paperclip")
                        .font(.callout).foregroundStyle(CorresPalette.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(CorresPalette.canvas)
        .confirmationDialog("Delete this scheduled email?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { _ = scheduled.remove(item.id) }
        } message: {
            Text("It won't be sent, and it isn't kept in Drafts.")
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(CorresPalette.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private var timePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change Time").font(.headline)
            DatePicker("Send at", selection: $newTime, in: Date.now.addingTimeInterval(60)...,
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { changingTime = false }
                Button("Done") {
                    scheduled.reschedule(item.id, to: newTime)
                    scheduled.keepTime(store: services.store, outbox: services.outbox)
                    changingTime = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// A whole draft handed to a new Compose window (a scheduled email being
/// edited keeps its Cc, attachments and formatting).
@MainActor
enum MacComposeHandoff {
    static var drafts: [UUID: Draft] = [:]
}
