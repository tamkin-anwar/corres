import EventKit
import SwiftUI

/// An invitation, the way a good calendar shows one: what, when (in your
/// time zone), where, the call to join, whether you're free then, and
/// Accept / Maybe / Decline, answered from the email. The answer goes to
/// the organizer as a calendar reply (their calendar shows it), and Corres
/// remembers it, so the card says what you said and lets you change your
/// mind. An updated invitation asks again; a canceled one says so, and
/// takes the event off your calendar if you like.
struct InvitationCard: View {
    let invitation: Invitation
    /// Who sent the email, so the organizer is only named when it's
    /// someone else (an assistant sending for their manager, say).
    let senderEmail: String?
    var senderName: String = ""
    let respond: (Invitation.Response) -> Void

    @State private var answered: Invitation.Response?
    /// Answered an earlier version, before the organizer changed it.
    @State private var earlierAnswer: Invitation.Response?
    @State private var overlaps: [String] = []
    @State private var onCalendar: EKEvent?
    @State private var addingEvent = false
    @State private var confirmingRemove = false
    @State private var calendarError: String?
    @AppStorage("corres.calendarAdded") private var addedRaw = ""
    @Environment(\.openURL) private var openURL
    private var calendar: CalendarAccess { .shared }

    private static func key(_ invitation: Invitation) -> String { "corres.rsvp.\(invitation.uid)" }

    static func remember(_ response: Invitation.Response, for invitation: Invitation) {
        UserDefaults.standard.set(response.rawValue, forKey: key(invitation))
        UserDefaults.standard.set(invitation.sequence, forKey: key(invitation) + ".seq")
    }

    /// The invitation an email carries (its .ics), to answer.
    nonisolated static func find(in thread: Correspondence) async -> Invitation? {
        if thread.id.account == "sample" { return SampleCorrespondence.invitation(for: thread) }
        guard let invite = thread.attachments.first(where: {
                  $0.mimeType.lowercased().hasPrefix("text/calendar") || $0.filename.lowercased().hasSuffix(".ics") }),
              let messageID = thread.latestMessageID, thread.id.account != "sample",
              let data = try? await MailClient().fetchAttachmentData(messageId: messageID, attachmentId: invite.id,
                                                                          account: thread.id.account),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return Invitation.parse(text)
    }

    /// The answer, to the organizer, from the address the invitation was
    /// sent to; remembered so the card shows it.
    static func reply(_ response: Invitation.Response, to invitation: Invitation, in thread: Correspondence) -> Draft {
        let account = thread.id.account
        let address = SendAsDirectory.shared.address(for: account, answering: thread)
        let me = invitation.invitedAddress(among: [account] + SendAsDirectory.shared.addresses(for: account).map(\.email),
                                           fallback: address?.email ?? account)
        let name = address?.name.isEmpty == false ? address?.name : nil
        let verb = response == .tentative ? "Tentatively accepted" : response.verb
        var draft = Draft(kind: .reply, threadID: thread.id, fromAccount: account, to: invitation.organizerEmail,
                          subject: "\(verb): \(invitation.summary)",
                          body: "\(name ?? me) \(response == .accepted ? "accepted" : response == .tentative ? "might attend" : "declined") \u{201C}\(invitation.summary)\u{201D}.")
        draft.fromAddress = address?.isPrimary == false ? address?.email : nil
        draft.fromName = name
        draft.calendarReply = invitation.reply(response, attendee: me, name: name)
        remember(response, for: invitation)
        return draft
    }

    private var isCanceled: Bool { invitation.method == .cancel }
    private var isPast: Bool { (invitation.end ?? invitation.start ?? .distantFuture) < .now }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(eyebrow, systemImage: isCanceled ? "calendar.badge.minus" : "calendar.badge.clock")
                .labelStyle(TightLabelStyle())
                .eyebrow(isCanceled ? CorresPalette.alert : CorresPalette.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(invitation.summary)
                    .font(.headline)
                    .foregroundStyle(CorresPalette.ink)
                    .strikethrough(isCanceled, color: CorresPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let when { detail(when, "clock") }
                if let repeats = invitation.repeats { detail(repeats, "repeat") }
                if let location = invitation.location { detail(location, "mappin.and.ellipse") }
                if let organizer { detail(organizer, "person") }
            }
            if !isCanceled, !isPast, let join = invitation.joinURL {
                Button { openURL(join) } label: {
                    Label("Join \(invitation.joinService ?? "Call")", systemImage: "video.fill")
                        .labelStyle(TightLabelStyle())
                }
                .buttonStyle(CorresPillStyle(minHeight: 32))
            }
            if !isCanceled, !isPast { availability }
            Hairline()
            if isCanceled { canceledActions } else { answerActions }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .corresSurface()
        .onAppear(perform: loadAnswer)
        .task(id: calendar.revision) { lookAtCalendar() }
        .sensoryFeedback(.success, trigger: answered)
        #if os(iOS)
        .sheet(isPresented: $addingEvent) {
            NewEventSheet(event: suggestion, sender: invitation.organizerName ?? invitation.organizerEmail) { saved in
                if saved { markAdded() }
            }
            .ignoresSafeArea()
        }
        #endif
        .confirmationDialog("Remove \u{201C}\(invitation.summary)\u{201D} from your calendar?",
                            isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove from Calendar", role: .destructive) { removeFromCalendar() }
        }
        .alert("Couldn't Change Your Calendar", isPresented: Binding(get: { calendarError != nil }, set: { if !$0 { calendarError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(calendarError ?? "") }
    }

    // MARK: What it says

    private var eyebrow: String {
        if isCanceled { return "Canceled" }
        return earlierAnswer != nil ? "Updated Invitation" : "Invitation"
    }

    /// "Tuesday, October 20, 9:00 – 9:45 AM", in your own time zone.
    private var when: String? {
        guard let start = invitation.start else { return nil }
        if invitation.isAllDay {
            let day = start.formatted(.dateTime.weekday(.wide).month(.wide).day())
            guard let end = invitation.end, end.timeIntervalSince(start) > 86_400 else { return day + ", all day" }
            return day + " – " + end.addingTimeInterval(-1).formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        let first = start.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())
        guard let end = invitation.end, end > start else { return first }
        return first + " – " + (Calendar.current.isDate(end, inSameDayAs: start)
            ? end.formatted(date: .omitted, time: .shortened)
            : end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
    }

    private var organizer: String? {
        guard invitation.organizerEmail != senderEmail?.lowercased(),
              invitation.organizerName?.caseInsensitiveCompare(senderName) != .orderedSame else { return nil }
        return "Organized by \(invitation.organizerName ?? invitation.organizerEmail)"
    }

    private func detail(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(TightLabelStyle())
            .font(.subheadline)
            .foregroundStyle(CorresPalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Your calendar

    @ViewBuilder
    private var availability: some View {
        if calendar.canRead, invitation.start != nil, !invitation.isAllDay {
            if let first = overlaps.first {
                let more = overlaps.count > 1 ? " and \(overlaps.count - 1) more" : ""
                Label("Overlaps \(first)\(more)", systemImage: "exclamationmark.circle")
                    .labelStyle(TightLabelStyle())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CorresPalette.flag)
            } else {
                Label("You're free then", systemImage: "checkmark.circle")
                    .labelStyle(TightLabelStyle())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CorresPalette.swipeHandled)
            }
        } else if calendar.canAsk, invitation.start != nil, !invitation.isAllDay {
            Button { Task { await calendar.requestRead() } } label: {
                Label("Check Your Calendar", systemImage: "calendar")
                    .labelStyle(TightLabelStyle())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CorresPalette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows whether you're free then. Your calendar stays on this device.")
        }
    }

    private func lookAtCalendar() {
        guard let start = invitation.start else { return }
        let end = invitation.end ?? start.addingTimeInterval(3_600)
        onCalendar = calendar.event(title: invitation.summary, start: start)
        overlaps = invitation.isAllDay ? [] : calendar.overlaps(start: start, end: end, excluding: invitation.summary)
            .map { $0.title?.isEmpty == false ? $0.title! : "another event" }
    }

    private var addedKey: String { "\(invitation.uid)@\(Int(invitation.start?.timeIntervalSince1970 ?? 0))" }
    private var isAdded: Bool { onCalendar != nil || addedRaw.split(separator: "|").contains { $0 == addedKey } }

    private func markAdded() {
        addedRaw = (addedRaw.split(separator: "|").map(String.init) + [addedKey]).suffix(200).joined(separator: "|")
    }

    private var suggestion: EventSuggestion {
        let start = invitation.start ?? .now
        return EventSuggestion(title: invitation.summary, start: start, end: invitation.end,
                               location: invitation.location ?? invitation.joinURL?.absoluteString)
    }

    private func addToCalendar() {
        #if os(iOS)
        addingEvent = true
        #else
        Task {
            guard let start = invitation.start else { return }
            guard await calendar.requestWrite() else {
                calendarError = "Corres can add events once it's allowed to in System Settings → Privacy & Security → Calendars."
                return
            }
            do {
                try calendar.add(title: invitation.summary, start: start,
                                 end: invitation.end ?? start.addingTimeInterval(invitation.isAllDay ? 86_400 : 3_600),
                                 allDay: invitation.isAllDay, location: invitation.location, url: invitation.joinURL,
                                 notes: "From \(invitation.organizerName ?? invitation.organizerEmail), via Corres")
                markAdded()
            } catch {
                calendarError = error.localizedDescription
            }
        }
        #endif
    }

    private func removeFromCalendar() {
        guard let onCalendar else { return }
        do {
            try calendar.remove(onCalendar)
            self.onCalendar = nil
        } catch {
            calendarError = error.localizedDescription
        }
    }

    // MARK: Answering

    @ViewBuilder
    private var answerActions: some View {
        if let answered {
            HStack(spacing: 12) {
                Label(youSaid(answered), systemImage: answered == .declined ? "xmark.circle" : "checkmark.circle")
                    .labelStyle(TightLabelStyle()).font(.subheadline.weight(.semibold))
                    .foregroundStyle(CorresPalette.ink)
                Spacer(minLength: 8)
                if answered != .declined, !isPast { calendarButton }
                Menu {
                    ForEach([Invitation.Response.accepted, .tentative, .declined].filter { $0 != answered }, id: \.self) { response in
                        Button(title(response)) { choose(response) }
                    }
                } label: {
                    Text("Change").font(.subheadline.weight(.semibold)).foregroundStyle(CorresPalette.accent)
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let earlierAnswer {
                    Text("The organizer changed this event. You'd \(earlierAnswer == .accepted ? "accepted" : earlierAnswer == .tentative ? "said maybe to" : "declined") the earlier version.")
                        .font(.footnote).foregroundStyle(CorresPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    ForEach([Invitation.Response.accepted, .tentative, .declined], id: \.self) { response in
                        Button { choose(response) } label: {
                            Text(title(response)).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CorresPillStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var calendarButton: some View {
        if isAdded {
            Label("On Calendar", systemImage: "checkmark")
                .labelStyle(TightLabelStyle())
                .font(.subheadline.weight(.medium))
                .foregroundStyle(CorresPalette.secondary)
        } else if invitation.start != nil {
            Button("Add to Calendar") { addToCalendar() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(CorresPalette.accent)
        }
    }

    @ViewBuilder
    private var canceledActions: some View {
        HStack(spacing: 12) {
            Text("The organizer canceled this event.")
                .font(.subheadline).foregroundStyle(CorresPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if onCalendar != nil {
                Button("Remove from Calendar", role: .destructive) { confirmingRemove = true }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(CorresPalette.alert)
            }
        }
        if onCalendar == nil, calendar.canAsk {
            Button { Task { await calendar.requestRead() } } label: {
                Label("Check Your Calendar", systemImage: "calendar")
                    .labelStyle(TightLabelStyle())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CorresPalette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Finds this event on your calendar so you can remove it. Your calendar stays on this device.")
        }
    }

    private func youSaid(_ response: Invitation.Response) -> String {
        switch response {
        case .accepted: "You accepted"
        case .tentative: "You said maybe"
        case .declined: "You declined"
        }
    }

    private func title(_ response: Invitation.Response) -> String {
        switch response {
        case .accepted: "Accept"
        case .tentative: "Maybe"
        case .declined: "Decline"
        }
    }

    private func loadAnswer() {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: Self.key(invitation)).flatMap(Invitation.Response.init(rawValue:))
        // Answers from before Corres kept the version count are taken as current.
        let storedSequence = defaults.object(forKey: Self.key(invitation) + ".seq") as? Int ?? invitation.sequence
        if let stored, invitation.sequence > storedSequence, invitation.method == .request {
            earlierAnswer = stored
            answered = nil
        } else {
            answered = stored
        }
    }

    private func choose(_ response: Invitation.Response) {
        withAnimation(.snappy(duration: 0.25)) {
            answered = response
            earlierAnswer = nil
        }
        respond(response)
    }
}
