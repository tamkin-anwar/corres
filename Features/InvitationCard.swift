import SwiftUI

/// An invitation's Yes / Maybe / No, answered from the email: the answer
/// goes to the organizer as a calendar reply (their calendar shows it), and
/// Corres remembers it, so the card says what you said and lets you change
/// your mind.
struct InvitationCard: View {
    let invitation: Invitation
    let event: EventSuggestion?
    let respond: (Invitation.Response) -> Void
    @State private var answered: Invitation.Response?

    private static func key(_ invitation: Invitation) -> String { "corres.rsvp.\(invitation.uid)" }

    static func remember(_ response: Invitation.Response, for invitation: Invitation) {
        UserDefaults.standard.set(response.rawValue, forKey: key(invitation))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Invitation", systemImage: "calendar.badge.clock").labelStyle(TightLabelStyle()).eyebrow(CorresPalette.accent)
            Text(invitation.summary).font(.headline)
            if let event {
                Text(event.start.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()))
                    .font(.subheadline).foregroundStyle(CorresPalette.secondary)
            }
            if let answered {
                HStack {
                    Label("You \(answered == .accepted ? "accepted" : answered == .tentative ? "said maybe" : "declined")",
                          systemImage: answered == .declined ? "xmark.circle" : "checkmark.circle")
                        .labelStyle(TightLabelStyle()).font(.subheadline.weight(.semibold))
                    Spacer()
                    Menu("Change") {
                        ForEach([Invitation.Response.accepted, .tentative, .declined].filter { $0 != answered }, id: \.self) { response in
                            Button(title(response)) { choose(response) }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } else {
                HStack(spacing: 8) {
                    ForEach([Invitation.Response.accepted, .tentative, .declined], id: \.self) { response in
                        Button(title(response)) { choose(response) }
                            .buttonStyle(CorresPillStyle())
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .corresSurface()
        .onAppear {
            answered = UserDefaults.standard.string(forKey: Self.key(invitation)).flatMap(Invitation.Response.init(rawValue:))
        }
        .sensoryFeedback(.success, trigger: answered)
    }

    private func title(_ response: Invitation.Response) -> String {
        switch response {
        case .accepted: "Accept"
        case .tentative: "Maybe"
        case .declined: "Decline"
        }
    }

    private func choose(_ response: Invitation.Response) {
        withAnimation(.snappy(duration: 0.25)) { answered = response }
        respond(response)
    }
}
