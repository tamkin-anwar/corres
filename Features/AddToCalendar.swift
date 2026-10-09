import EventKit
import EventKitUI
import SwiftUI

/// Mail's calendar suggestion: the event an email is about, one tap from
/// your calendar. Opens Apple's own New Event sheet, filled in, for you to
/// check and add; since iOS 17 that needs no calendar permission, because
/// the sheet runs outside Corres and Corres never reads your calendar.
struct CalendarSuggestionCard: View {
    let event: EventSuggestion
    let sender: String
    /// Remembers, on this iPhone, that this email's event was added.
    let threadKey: String
    @State private var adding = false
    @AppStorage("corres.calendarAdded") private var addedRaw = ""

    private var addedKey: String { "\(threadKey)@\(Int(event.start.timeIntervalSince1970))" }
    private var isAdded: Bool { addedRaw.split(separator: "|").contains { $0 == addedKey } }

    /// "Monday, September 28 at 2:45 – 3:30 PM", or just the start.
    private var when: String {
        let start = event.start.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())
        guard let end = event.end, end > event.start else { return start }
        let sameDay = Calendar.current.isDate(end, inSameDayAs: event.start)
        return start + " – " + (sameDay ? end.formatted(date: .omitted, time: .shortened)
                                        : end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar")
                .font(.title3)
                .foregroundStyle(CorresPalette.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(CorresPalette.ink)
                Label(when, systemImage: "clock")
                    .labelStyle(TightLabelStyle())
                    .font(.footnote).foregroundStyle(CorresPalette.secondary)
                if let location = event.location {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .labelStyle(TightLabelStyle())
                        .font(.footnote).foregroundStyle(CorresPalette.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if isAdded {
                Label("Added", systemImage: "checkmark")
                    .labelStyle(TightLabelStyle())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CorresPalette.secondary)
                    .frame(minHeight: 32)
            } else {
                Button("Add") { adding = true }
                    .buttonStyle(CorresPillStyle(minHeight: 32))
                    .accessibilityLabel("Add \(event.title) to Calendar")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .corresSurface()
        .sheet(isPresented: $adding) {
            NewEventSheet(event: event, sender: sender) { saved in
                if saved { addedRaw = (addedRaw.split(separator: "|").map(String.init) + [addedKey]).suffix(200).joined(separator: "|") }
            }
            .ignoresSafeArea()
        }
    }
}

struct NewEventSheet: UIViewControllerRepresentable {
    let event: EventSuggestion
    let sender: String
    let onFinish: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let draft = EKEvent(eventStore: store)
        draft.title = event.title
        draft.startDate = event.start
        draft.endDate = event.end.flatMap { $0 > event.start ? $0 : nil } ?? event.start.addingTimeInterval(3_600)
        draft.location = event.location
        // The confirmation number is what you need at the desk.
        draft.notes = [event.confirmation.map { "Confirmation: \($0)" }, "From \(sender), via Corres"]
            .compactMap { $0 }.joined(separator: "\n")
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = draft
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator { saved in
            onFinish(saved)
            dismiss()
        }
    }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let finish: (Bool) -> Void
        init(finish: @escaping (Bool) -> Void) { self.finish = finish }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            finish(action == .saved)
        }
    }
}
