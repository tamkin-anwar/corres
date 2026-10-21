import SwiftUI

/// Saves the search being typed, named after its words.
struct SaveSearchButton: View {
    let query: String
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let saved = Organizer.shared.isSaved(query: trimmed)
            Button {
                name = trimmed
                naming = true
            } label: {
                Label(saved ? "Saved" : "Save Search", systemImage: saved ? "bookmark.fill" : "bookmark")
            }
            .disabled(saved)
            .alert("Save Search", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Organizer.shared.save(SavedSearch(name: finalName.isEmpty ? trimmed : finalName, query: trimmed))
                }
            } message: {
                Text("It shows in Mailboxes, run again each time you open it.")
            }
        }
    }
}
