import Foundation
import Observation

/// Saved bits of text you write again and again: an intro, an address, a
/// polite no. Kept on this iPhone only. `{first name}` in a snippet is
/// filled with the recipient's first name when it's inserted.
@MainActor @Observable
final class SnippetStore {
    struct Snippet: Codable, Identifiable, Hashable {
        var id = UUID()
        var title: String
        var body: String
    }

    static let firstNameToken = "{first name}"
    private static let key = "corres.snippets"
    private(set) var snippets: [Snippet] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = stored
        } else {
            snippets = [
                Snippet(title: "Thanks, will follow up", body: "Thanks, {first name}. I'll get back to you by end of day."),
                Snippet(title: "Let's find a time", body: "Happy to talk, {first name}. What times work for you this week?"),
            ]
        }
    }

    func save(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[index] = snippet } else { snippets.append(snippet) }
        persist()
    }

    func delete(at offsets: IndexSet) {
        snippets.remove(atOffsets: offsets)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        snippets.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// The snippet's text with `{first name}` filled in, or removed cleanly
    /// ("Thanks, {first name}." becomes "Thanks.") when no name is known.
    static func expand(_ body: String, recipientName: String?) -> String {
        let first = recipientName?.split(separator: " ").first.map(String.init)
        if let first, !first.isEmpty, !first.contains("@") {
            return body.replacingOccurrences(of: firstNameToken, with: first)
        }
        return body.replacingOccurrences(of: ", " + firstNameToken, with: "")
            .replacingOccurrences(of: " " + firstNameToken, with: "")
            .replacingOccurrences(of: firstNameToken, with: "")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snippets) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
