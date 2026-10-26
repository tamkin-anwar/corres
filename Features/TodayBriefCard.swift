import SwiftUI

/// The Daily Brief: a short Today card at the top of Needs You (Settings →
/// Sorting → Daily Brief). Everything on it comes from Corres's own
/// reading of your mail (deadlines, events, deliveries, who's waiting for
/// your answer), so it works without Apple Intelligence and never says
/// anything the list below doesn't back up. No paragraph is written.
struct TodayBriefCard: View {
    let brief: TodayBrief
    let onOpen: (Correspondence) -> Void
    let onHandled: (Correspondence) -> Void
    @AppStorage(GoogleAuthService.givenNameKey) private var givenName = ""
    @AppStorage(CorresSettings.briefCollapsedKey) private var collapsed = false
    @AppStorage(CorresSettings.briefDoneDayKey) private var doneDay = ""
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                ForEach(Array(brief.top.enumerated()), id: \.element.id) { index, item in
                    Hairline(leading: index == 0 ? 0 : 52)
                    row(item)
                }
                Hairline()
                HStack {
                    Spacer(minLength: 0)
                    Button("Done for Today") { finishForToday() }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CorresPalette.accent)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .contentShape(Rectangle())
                        .accessibilityHint("Hides today's summary until tomorrow.")
                }
            }
        }
        .corresSurface()
        .contextMenu {
            Button { finishForToday() } label: { Label("Done for Today", systemImage: "checkmark") }
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { collapsed.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day()).eyebrow(CorresPalette.accent)
                    Text(greeting)
                        .font(CorresType.heading)
                        .foregroundStyle(CorresPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(countLine)
                        .font(.subheadline)
                        .foregroundStyle(CorresPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(CorresPalette.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(greeting) \(countLine)"))
        .accessibilityValue(collapsed ? Text("Collapsed") : Text("Expanded"))
        .accessibilityHint(collapsed ? Text("Shows today's items.") : Text("Hides today's items."))
        .accessibilityAddTraits([.isHeader, .isButton])
    }

    /// Whole sentences, so each language can say them its own way.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let name = givenName.trimmingCharacters(in: .whitespaces)
        switch hour {
        case 5..<12: return name.isEmpty ? String(localized: "Good morning.") : String(localized: "Good morning, \(name).")
        case 12..<17: return name.isEmpty ? String(localized: "Good afternoon.") : String(localized: "Good afternoon, \(name).")
        default: return name.isEmpty ? String(localized: "Good evening.") : String(localized: "Good evening, \(name).")
        }
    }

    /// "1 overdue, 2 due today, 1 event, 3 replies you owe", joined the
    /// way the language lists things.
    private var countLine: String {
        var parts: [String] = []
        let overdue = brief.overdue, dueToday = brief.due - brief.overdue
        if overdue > 0 { parts.append(overdue == 1 ? String(localized: "1 overdue") : String(localized: "\(overdue) overdue")) }
        if dueToday > 0 { parts.append(dueToday == 1 ? String(localized: "1 due today") : String(localized: "\(dueToday) due today")) }
        if brief.meetings > 0 {
            parts.append(brief.meetings == 1 ? String(localized: "1 event today") : String(localized: "\(brief.meetings) events today"))
        }
        if brief.deliveries > 0 {
            parts.append(brief.deliveries == 1 ? String(localized: "1 delivery") : String(localized: "\(brief.deliveries) deliveries"))
        }
        if brief.replies > 0 {
            parts.append(brief.replies == 1 ? String(localized: "1 reply you owe") : String(localized: "\(brief.replies) replies you owe"))
        }
        return parts.formatted(.list(type: .and, width: .narrow))
    }

    // MARK: - Rows

    private func row(_ item: TodayBrief.Item) -> some View {
        let thread = item.thread
        let who = item.kind == .delivery && !thread.organization.isEmpty ? thread.organization : thread.sender
        let detail = detail(for: item)
        return HStack(spacing: 10) {
            Button { onOpen(thread) } label: {
                HStack(spacing: 14) {
                    Image(systemName: icon(for: item.kind))
                        .font(.body)
                        .foregroundStyle(item.kind == .overdue ? CorresPalette.alert : CorresPalette.secondary)
                        .frame(width: typeSize.isAccessibilitySize ? nil : 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: who)
                            .font(.body.weight(.medium))
                            .foregroundStyle(CorresPalette.ink)
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        (Text(verbatim: detail).foregroundStyle(item.kind == .overdue ? CorresPalette.alert : CorresPalette.secondary)
                         + Text(verbatim: thread.subject.isEmpty ? "" : " · " + thread.subject).foregroundStyle(CorresPalette.tertiary))
                            .font(.subheadline)
                            .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { onHandled(thread) } label: {
                Image(systemName: "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(CorresPalette.swipeHandled)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        // One element for VoiceOver: what it is, who, when; opening it is
        // the default action and Handled is one of its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [kindName(item.kind), who, detail, thread.subject]
            .filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen(thread) }
        .accessibilityAction(named: Text("Mark Handled")) { onHandled(thread) }
    }

    private func icon(for kind: TodayBrief.Kind) -> String {
        switch kind {
        case .overdue: "exclamationmark.circle"
        case .dueToday: "clock"
        case .meeting: "calendar"
        case .delivery: "shippingbox"
        case .reply: "arrowshape.turn.up.left"
        }
    }

    private func kindName(_ kind: TodayBrief.Kind) -> String {
        switch kind {
        case .overdue: String(localized: "Overdue")
        case .dueToday: String(localized: "Due today")
        case .meeting: String(localized: "Event")
        case .delivery: String(localized: "Delivery")
        case .reply: String(localized: "Reply owed")
        }
    }

    /// Times and dates in your own locale and time zone.
    private func detail(for item: TodayBrief.Item) -> String {
        let time = item.date?.formatted(date: .omitted, time: .shortened) ?? ""
        switch item.kind {
        case .overdue:
            guard let date = item.date else { return String(localized: "Overdue") }
            let when = Calendar.current.isDateInToday(date) && item.hasTime
                ? time : date.formatted(.dateTime.month(.abbreviated).day())
            return String(localized: "Was due \(when)")
        case .dueToday:
            return item.hasTime ? String(localized: "Due \(time)") : String(localized: "Due today")
        case .meeting:
            return item.hasTime ? String(localized: "Today at \(time)") : String(localized: "Today")
        case .delivery:
            return String(localized: "Arriving today")
        case .reply:
            let days = item.date.flatMap {
                Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: $0),
                                                to: Calendar.current.startOfDay(for: .now)).day
            } ?? 0
            return days < 1 ? String(localized: "Wrote today")
                : days == 1 ? String(localized: "Wrote yesterday") : String(localized: "Wrote \(days) days ago")
        }
    }

    private func finishForToday() {
        withAnimation(.snappy(duration: 0.3)) { doneDay = CorresSettings.briefDay() }
        Assistive.announce(String(localized: "Today's summary hidden until tomorrow."))
    }
}
