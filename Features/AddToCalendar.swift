import EventKit
import EventKitUI
import SwiftUI

/// Mail's calendar suggestion: the event an email is about, one tap from
/// your calendar. Opens Apple's own New Event sheet, filled in, for you to
/// check and add; since iOS 17 that needs no calendar permission, because
/// the sheet runs outside Corres and Corres never reads your calendar.
struct CalendarSuggestionCard: View {
    let event: EventSuggestion
    @State private var adding = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar")
                .font(.title3)
                .foregroundStyle(CorresPalette.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(CorresPalette.ink)
                Label(event.start.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()),
                      systemImage: "clock")
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
            Button("Add") { adding = true }
                .buttonStyle(CorresPillStyle(minHeight: 32))
                .accessibilityLabel("Add \(event.title) to Calendar")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .corresSurface()
        .sheet(isPresented: $adding) {
            NewEventSheet(event: event).ignoresSafeArea()
        }
    }
}

private struct NewEventSheet: UIViewControllerRepresentable {
    let event: EventSuggestion
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let draft = EKEvent(eventStore: store)
        draft.title = event.title
        draft.startDate = event.start
        draft.endDate = event.start.addingTimeInterval(3_600)
        draft.location = event.location
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = draft
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            dismiss()
        }
    }
}
