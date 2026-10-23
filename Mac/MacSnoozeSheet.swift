import SwiftUI

/// Snooze until a time you type ("tuesday 9am", "in 3 days") or pick,
/// with the four usual times one click away.
struct MacSnoozeSheet: View {
    let onSnooze: (Date) -> Void
    @State private var phrase = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var parsed: Date? { TimePhrase.parse(phrase) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Snooze until…").macFont(size: 18, weight: .regular, design: .serif)
            TextField("Tomorrow 8am, next friday, in 3 days", text: $phrase)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let parsed { finish(parsed) } }
            if let parsed {
                Text(parsed.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
                    .macFont(.callout).foregroundStyle(CorresPalette.accent)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    option(.laterToday); option(.tomorrow)
                }
                GridRow {
                    option(.thisWeekend); option(.nextWeek)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Snooze") { if let parsed { finish(parsed) } }
                    .keyboardShortcut(.defaultAction).disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func option(_ option: SnoozeOption) -> some View {
        Button { finish(option.date()) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title).macFont(.callout, weight: .semibold)
                Text(option.date().formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .macFont(.caption).foregroundStyle(CorresPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CorresPalette.line))
        }
        .buttonStyle(.plain)
    }

    private func finish(_ date: Date) {
        onSnooze(date)
        dismiss()
    }
}
