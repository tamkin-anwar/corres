import SwiftUI

/// ⌘K: go anywhere or do anything by typing a few letters of it. Mailboxes
/// and labels, and what can be done to the selected conversations, in one
/// list that narrows as you type; Return runs the first.
struct MacCommandPalette: View {
    struct Command: Identifiable {
        let id = UUID()
        let title: String
        let detail: String?
        let systemImage: String
        let run: () -> Void
    }

    let commands: [Command]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var matches: [Command] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return commands }
        return commands
            .filter { command in
                let text = (command.title + " " + (command.detail ?? "")).lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            // Titles that start with what's typed first.
            .sorted { a, b in
                let first = String(words[0])
                return a.title.lowercased().hasPrefix(first) && !b.title.lowercased().hasPrefix(first)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(CorresPalette.secondary)
                TextField("Go to a mailbox or do something…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    // The system's typing suggestions covered the list.
                    .autocorrectionDisabled()
                    .textContentType(.none)
                    .onSubmit(runHighlighted)
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(matches.prefix(40).enumerated()), id: \.element.id) { index, command in
                        HStack(spacing: 10) {
                            Image(systemName: command.systemImage)
                                .frame(width: 20)
                                .foregroundStyle(index == highlighted ? CorresPalette.accent : CorresPalette.secondary)
                            Text(command.title).foregroundStyle(CorresPalette.ink)
                            Spacer()
                            if let detail = command.detail {
                                Text(detail).font(.caption).foregroundStyle(CorresPalette.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .listRowBackground(index == highlighted ? CorresPalette.accent.opacity(0.18) : Color.clear)
                        .onTapGesture { run(command) }
                        .id(index)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
            }
            .frame(height: 320)
            if matches.isEmpty {
                Text("Nothing matches \u{201C}\(query)\u{201D}.")
                    .font(.callout).foregroundStyle(CorresPalette.secondary)
                    .padding(.bottom, 14)
            }
        }
        .frame(width: 520)
        .background(CorresPalette.surface)
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(matches.prefix(40).count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func runHighlighted() {
        let list = Array(matches.prefix(40))
        guard list.indices.contains(highlighted) else { return }
        run(list[highlighted])
    }

    private func run(_ command: Command) {
        dismiss()
        // After the sheet is gone, so what it opens isn't behind it.
        DispatchQueue.main.async { command.run() }
    }
}
