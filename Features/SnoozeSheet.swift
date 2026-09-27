import SwiftUI

/// Snooze by typing ("in 3 days at 9am", "friday", "tonight") or with one
/// of four presets. The parsed time is shown back as a real date before
/// anything happens, so there's never a guess about when mail returns.
struct SnoozeSheet: View {
    let onSnooze: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var pickingDate = false
    @State private var pickedDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @FocusState private var fieldFocused: Bool
    @Environment(\.displayScale) private var displayScale

    private var parsed: Date? { TimePhrase.parse(phrase) }
    private var target: Date? { pickingDate ? pickedDate : parsed }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    typedField
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(SnoozeOption.allCases, id: \.self) { option in
                            Button {
                                finish(option.date())
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.title).font(.body.weight(.semibold)).foregroundStyle(CorresPalette.ink)
                                    Text(Self.describe(option.date())).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(CorresPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(CorresPalette.line, lineWidth: 1 / displayScale))
                            }
                            .buttonStyle(CorresRowButtonStyle())
                        }
                    }
                    Toggle("Pick a date and time", isOn: $pickingDate.animation(.easeOut(duration: 0.2)))
                        .tint(CorresPalette.accent)
                    if pickingDate {
                        DatePicker("Return on", selection: $pickedDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                            .tint(CorresPalette.accent)
                    }
                    Button(target.map { "Snooze until \(Self.describe($0))" } ?? "Snooze") {
                        if let target { finish(target) }
                    }
                    .buttonStyle(CorresButtonStyle())
                    .disabled(target == nil)
                    .opacity(target == nil ? 0.45 : 1)
                    Text("It leaves Needs You and Waiting until then, and stays in Mail and search the whole time.")
                        .font(.footnote).foregroundStyle(CorresPalette.tertiary)
                }
                .padding(.horizontal, CorresSpace.page).padding(.vertical, 8)
            }
            .background(CorresPalette.canvas)
            .navigationTitle("Snooze")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var typedField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type a time").eyebrow()
            TextField("in 3 days at 9am", text: $phrase)
                .font(.title3)
                .focused($fieldFocused)
                .submitLabel(.done)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { if let parsed { finish(parsed) } }
                .onChange(of: phrase) { if !phrase.isEmpty { pickingDate = false } }
            Text(parsed.map(Self.describe) ?? (phrase.isEmpty ? "Try \u{201C}tomorrow evening\u{201D} or \u{201C}next friday\u{201D}" : "Not sure when that is"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(parsed == nil ? CorresPalette.tertiary : CorresPalette.accent)
                .contentTransition(.opacity)
        }
        .padding(14)
        .background(CorresPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(fieldFocused ? CorresPalette.accent : CorresPalette.line, lineWidth: fieldFocused ? 1 : 1 / displayScale))
    }

    private func finish(_ date: Date) {
        onSnooze(date)
        dismiss()
    }

    static func describe(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow, \(time)" }
        if let days = calendar.dateComponents([.day], from: .now, to: date).day, days < 6 {
            return "\(date.formatted(.dateTime.weekday(.wide))), \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())), \(time)"
    }
}
