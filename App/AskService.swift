import Foundation
import FoundationModels
import Observation

/// "Ask your mail": a question in plain language, answered from your own
/// email on this iPhone. The on-device model is given one tool, a search
/// over your mail (synced mail, plus Gmail's own search to reach older
/// messages), and answers only from what that search returns, citing the
/// emails it used. Without Apple Intelligence, Ask still works as a smart
/// search: the same ranked results, just without the written answer.
@MainActor @Observable
final class AskService {
    struct Source: Identifiable, Equatable {
        let thread: Correspondence
        var id: ThreadID { thread.id }
    }

    enum Phase: Equatable { case idle, searching, answering, done }

    private(set) var phase: Phase = .idle
    private(set) var answer: String?
    private(set) var sources: [Source] = []
    private(set) var question = ""

    private let store: MailStore
    private let sync: GmailSyncService
    private let auth: GoogleAuthService
    private var task: Task<Void, Never>?

    init(store: MailStore, sync: GmailSyncService, auth: GoogleAuthService) {
        self.store = store
        self.sync = sync
        self.auth = auth
    }

    var canAnswer: Bool {
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.availability == .available }
        return false
    }

    func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        question = trimmed
        answer = nil
        sources = []
        task = Task { await run(trimmed) }
    }

    func reset() {
        task?.cancel()
        phase = .idle
        answer = nil
        sources = []
        question = ""
    }

    private func run(_ text: String) async {
        phase = .searching
        guard canAnswer, #available(iOS 26.0, *) else {
            sources = await search(Self.keywords(in: text)).map(Source.init)
            phase = .done
            return
        }
        let recorder = SourceRecorder()
        let tool = SearchMailTool(recorder: recorder) { [weak self] query in
            await self?.search(query) ?? []
        }
        do {
            let session = LanguageModelSession(tools: [tool], instructions: Self.instructions)
            phase = .answering
            let response = try await session.respond(to: "Today is \(Date.now.formatted(date: .complete, time: .omitted)). \(text)")
            guard !Task.isCancelled else { return }
            answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let used = await recorder.threads
            sources = used.isEmpty ? await search(Self.keywords(in: text)).map(Source.init) : used.map(Source.init)
        } catch {
            guard !Task.isCancelled else { return }
            // The model declined or ran out of room: fall back to results.
            sources = await search(Self.keywords(in: text)).map(Source.init)
        }
        phase = .done
    }

    // MARK: - Search

    /// Ranks mail for `query`: every word must appear somewhere in the
    /// conversation, with sender and subject matches weighted above body
    /// matches, then newer first. Reaches Gmail's own search first when an
    /// account is connected, so older mail that never synced is found too.
    func search(_ query: String) async -> [Correspondence] {
        let words = Self.keywords(in: query).lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let accounts = auth.accounts.map(\.email)
        if !accounts.isEmpty, await sync.search(words.joined(separator: " "), accounts: accounts) {
            await store.refresh()
        }
        let scored: [(Correspondence, Int)] = store.threads.compactMap { thread in
            let head = (thread.sender + " " + (thread.senderEmail ?? "") + " " + thread.subject).lowercased()
            let body = (thread.excerpt + " " + thread.body).lowercased()
            var score = 0
            for word in words {
                if head.contains(word) { score += 3 } else if body.contains(word) { score += 1 } else { return nil }
            }
            return (thread, score)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.receivedAt > $1.0.receivedAt }
            .prefix(6).map(\.0)
    }

    /// Drops question words and filler so "when does my Denver flight
    /// leave" searches for "denver flight".
    static func keywords(in text: String) -> String {
        let stop: Set<String> = ["a", "an", "the", "my", "me", "i", "is", "are", "was", "were", "do", "does", "did",
                                 "what", "whats", "when", "where", "who", "whom", "which", "how", "why", "can", "could",
                                 "to", "of", "for", "in", "on", "at", "from", "with", "about", "any", "there", "it",
                                 "and", "or", "be", "been", "has", "have", "had", "will", "would", "should", "you",
                                 "your", "tell", "show", "find", "email", "emails", "mail", "message", "messages",
                                 "latest", "last", "recent", "send", "sent", "leave", "get", "got", "that", "this"]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stop.contains($0) }
        return words.prefix(5).joined(separator: " ")
    }

    @available(iOS 26.0, *)
    private static let instructions = """
    You answer questions about the user's own email. Always call searchMail \
    first, with a few short keywords (names, places, companies, topics; not \
    whole sentences). You may search again with different keywords if the \
    first search finds nothing relevant. Answer only from the emails the \
    search returns: quote dates, times, amounts and names exactly as written. \
    If the emails don't contain the answer, say you couldn't find it. Answer \
    in one to three short sentences, plain text, no lists, and don't mention \
    the search tool.
    """
}

/// Collects which conversations the model actually looked at, in order,
/// so the answer can show them as sources.
actor SourceRecorder {
    private(set) var threads: [Correspondence] = []

    func record(_ found: [Correspondence]) {
        for thread in found where !threads.contains(where: { $0.id == thread.id }) {
            threads.append(thread)
        }
    }
}

@available(iOS 26.0, *)
struct SearchMailTool: Tool {
    let name = "searchMail"
    let description = "Searches the user's email by keywords and returns the best matching messages with sender, date, subject and text."

    @Generable
    struct Arguments {
        @Guide(description: "Two to five keywords: names, places, companies or topics. Not a full sentence.")
        let keywords: String
    }

    let recorder: SourceRecorder
    let search: @Sendable (String) async -> [Correspondence]

    func call(arguments: Arguments) async throws -> String {
        let found = Array(await search(arguments.keywords).prefix(5))
        await recorder.record(found)
        guard !found.isEmpty else { return "No emails matched \"\(arguments.keywords)\"." }
        return found.enumerated().map { index, thread in
            let text = MailIntelligence.prepared(thread.body.isEmpty ? thread.excerpt : thread.body).text
            return """
            [\(index + 1)] From: \(thread.sender)
            Date: \(thread.receivedAt.formatted(date: .abbreviated, time: .shortened))
            Subject: \(thread.subject)
            \(text.prefix(550))
            """
        }.joined(separator: "\n\n")
    }
}
