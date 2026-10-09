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
    /// Whether the answer actually came from the emails shown. False when
    /// the model couldn't find it: the list is then "closest matches",
    /// not sources.
    private(set) var answerFound = false
    private(set) var sources: [Source] = []
    private(set) var question = ""
    /// The question as read for people, attachments, kinds and dates.
    private(set) var query: AskQuery?
    /// A list answer ("3 receipts"), shown without the model: filtering
    /// gives the exact set, where a written answer could only paraphrase.
    private(set) var listTitle: String?

    /// Questions asked before, newest first.
    private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: AskService.recentKey) ?? []
    private static let recentKey = "corres.ask.recent"

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
        answerFound = false
        sources = []
        listTitle = nil
        query = AskQuery(trimmed)
        recent = Array(([trimmed] + recent.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }).prefix(5))
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
        task = Task { await run(trimmed) }
    }

    func reset() {
        task?.cancel()
        phase = .idle
        answer = nil
        sources = []
        question = ""
        query = nil
        listTitle = nil
    }

    func clearRecent() {
        recent = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    private func run(_ text: String) async {
        phase = .searching
        let query = AskQuery(text)
        if query.isList {
            let found = await search(query, limit: 30)
            guard !Task.isCancelled else { return }
            sources = found.map(Source.init)
            listTitle = found.isEmpty ? nil : query.title(count: found.count)
            phase = .done
            return
        }
        guard canAnswer, #available(iOS 26.0, *) else {
            sources = await search(query, limit: 6).map(Source.init)
            phase = .done
            return
        }
        let recorder = SourceRecorder()
        // The model's own keywords, still held to the person and dates the
        // question named ("what did Maya ask" only reads Maya's mail).
        let tool = SearchMailTool(recorder: recorder) { [weak self] keywords in
            var narrowed = AskQuery(keywords)
            narrowed.person = query.person ?? narrowed.person
            narrowed.range = query.range ?? narrowed.range
            narrowed.wantsAttachments = query.wantsAttachments || narrowed.wantsAttachments
            if narrowed.person != nil, narrowed.keywords.count > 1 { narrowed.keywords = [] }
            return await self?.search(narrowed, limit: 6) ?? []
        }
        do {
            // Find first, then answer once. Left to search on its own, the
            // model kept searching after it had the email (nine searches
            // for "What did Maya ask me?" and no answer after a minute).
            // It searches itself only when Corres finds nothing, at most
            // three times.
            let found = await search(query, limit: 5)
            guard !Task.isCancelled else { return }
            let today = "Today is \(Date.now.formatted(date: .complete, time: .omitted))."
            let session: LanguageModelSession
            let prompt: String
            if found.isEmpty {
                session = LanguageModelSession(tools: [tool], instructions: Self.instructions)
                prompt = "\(today) \(text)"
            } else {
                let numbers = await recorder.record(found)
                session = LanguageModelSession(instructions: Self.answerInstructions)
                prompt = "\(today)\n\nQuestion: \(text)\n\nEmails:\n\n" + SearchMailTool.describe(Array(zip(numbers, found)))
            }
            phase = .answering
            let response = try await session.respond(to: prompt, generating: AskAnswer.self)
            guard !Task.isCancelled else { return }
            let result = response.content
            answer = result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            answerFound = result.found
            let seen = await recorder.threads
            // Only the emails the answer actually used count as sources.
            let cited = result.sourceNumbers.compactMap { number in
                (1...seen.count).contains(number) ? seen[number - 1] : nil
            }
            if result.found, !cited.isEmpty {
                sources = cited.map(Source.init)
            } else {
                answerFound = result.found && !seen.isEmpty
                sources = Array(seen.prefix(4)).map(Source.init)
            }
        } catch {
            guard !Task.isCancelled else { return }
            // The model declined or ran out of room: fall back to results.
            sources = await search(query, limit: 6).map(Source.init)
        }
        phase = .done
    }

    // MARK: - Search

    /// Mail that fits the question: its person, attachments, kind and
    /// dates as filters, then its words ranked (sender and subject above
    /// the body), newest first. Asks Gmail too, in its own search
    /// operators, so older mail that never synced is found.
    func search(_ query: AskQuery, limit: Int) async -> [Correspondence] {
        let hasStructure = query.person != nil || query.wantsAttachments || query.topic != nil || query.range != nil
        guard hasStructure || !query.keywords.isEmpty else { return [] }
        let accounts = auth.accounts.map(\.email)
        if !accounts.isEmpty, await sync.search(query.gmailQuery, accounts: accounts) {
            await store.refresh()
        }
        let words = query.keywords
        let scored: [(Correspondence, Int)] = store.threads.compactMap { thread in
            guard !thread.isScreenedOut, query.matches(thread) else { return nil }
            let head = (thread.sender + " " + (thread.senderEmail ?? "") + " " + thread.subject).lowercased()
            let body = (thread.excerpt + " " + thread.body).lowercased()
            var score = 0
            for word in words {
                if head.contains(word) { score += 3 } else if body.contains(word) { score += 1 }
                else if query.topic != .travel { return nil }
            }
            if query.topic == .travel, score == 0,
               (head + " " + body).range(of: #"\b(flight|itinerary|boarding|reservation|confirmation|check-?in|departs?)\b"#,
                                          options: .regularExpression) == nil { return nil }
            // Promotions rarely answer a question ("next flight" should find
            // the booking, not the airline's sale), so they rank last.
            if InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) == .promotions {
                score -= 100
            }
            return (thread, score)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.receivedAt > $1.0.receivedAt }
            .prefix(limit).map(\.0)
    }

    // MARK: - Suggestions

    /// Questions that work on this person's own mail, built from it rather
    /// than fixed examples: the people who wrote to them, who sent files,
    /// and whether receipts, packages or trips are actually in there.
    func suggestions(now: Date = .now) -> [String] {
        let threads = store.threads.filter { !$0.isScreenedOut }
        func isPerson(_ thread: Correspondence) -> Bool {
            !thread.isFromAccountOwner
                && InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) == nil
        }
        func firstName(_ thread: Correspondence) -> String? {
            guard let first = thread.sender.split(separator: " ").first.map(String.init),
                  first.count >= 2, first.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }) else { return nil }
            return first
        }
        var result: [String] = []
        let recentPeople = threads.filter { isPerson($0) && now.timeIntervalSince($0.receivedAt) < 14 * 86_400 }
            .sorted { ($0.attention == .needsYou ? 1 : 0, $0.receivedAt) > ($1.attention == .needsYou ? 1 : 0, $1.receivedAt) }
        if let name = recentPeople.lazy.compactMap(firstName).first { result.append("What did \(name) ask me?") }
        let senders = threads.filter { !$0.attachments.isEmpty && isPerson($0) && now.timeIntervalSince($0.receivedAt) < 60 * 86_400 }
            .sorted { $0.receivedAt > $1.receivedAt }
        if let name = senders.lazy.compactMap(firstName).first(where: { !result.joined().contains($0) }) ?? senders.lazy.compactMap(firstName).first {
            result.append("Attachments from \(name)")
        }
        for (question, wanted) in [("Receipts this month", AskQuery.Topic.receipts), ("Where are my packages?", .packages)] {
            let probe = AskQuery(question, now: now)
            let window = wanted == .packages ? DateInterval(start: now.addingTimeInterval(-14 * 86_400), end: now) : probe.range
            if threads.contains(where: { thread in
                guard window.map({ $0.contains(thread.receivedAt) }) ?? true else { return false }
                return probe.matches(thread)
            }) { result.append(question) }
        }
        let travel = threads.contains { thread in
            now.timeIntervalSince(thread.receivedAt) < 120 * 86_400
                && (thread.subject + " " + thread.excerpt).range(of: #"(?i)\b(flight|itinerary|boarding pass|e-?ticket)\b"#,
                                                                options: .regularExpression) != nil
        }
        if travel { result.insert("When is my next flight?", at: 0) }
        // Only offered when it would find something.
        if result.count < 3 {
            for fallback in ["Attachments this week", "Attachments this month"] {
                let probe = AskQuery(fallback, now: now)
                if threads.contains(where: probe.matches) {
                    result.append(fallback)
                    break
                }
            }
        }
        return Array(result.prefix(5))
    }

    @available(iOS 26.0, *)
    private static let answerInstructions = """
    You answer a question about the user's own email, using only the \
    numbered emails given. Quote dates, times, amounts and names exactly as \
    written. Answer in one to three short plain sentences addressed to the \
    user ("Maya asked you to approve…", "Your flight to Denver leaves \
    Thursday at 6:40 AM"), not a copied line. For "next" or "upcoming" \
    things, use only dates after today. Marketing and promotional emails \
    never count as an answer. List the numbers of the emails your answer \
    came from. If they don't contain the answer, set found to false and say \
    briefly what you couldn't find.
    """

    @available(iOS 26.0, *)
    private static let instructions = """
    You answer questions about the user's own email. Always call searchMail \
    first, with a few short keywords (names, places, companies, topics; not \
    whole sentences). If the results don't answer the question, search again \
    with different words: for travel try "itinerary", "confirmation", \
    "boarding pass", "reservation" or an airline or hotel name; for purchases \
    try "receipt", "order" or "invoice". Marketing and promotional emails \
    (sales, offers, "last chance") never count as an answer. For questions \
    about "next" or "upcoming" things, use only dates after today. Answer \
    only from the emails the search returns, quoting dates, times, amounts \
    and names exactly as written, in one to three short plain sentences \
    that answer the question directly, addressed to the user ("Maya asked \
    you to approve…", "Your flight to Denver leaves Thursday at 6:40 AM"), \
    not a copied line from the email, and without mentioning the search tool. List the numbers of the emails your \
    answer came from. If they don't contain the answer, set found to false \
    and say briefly what you couldn't find.
    """
}

/// Collects which conversations the model actually looked at, in order,
/// so the answer can show them as sources.
actor SourceRecorder {
    private(set) var threads: [Correspondence] = []

    /// Records results and returns each one's stable number, so emails
    /// keep the same [n] across repeated searches in one answer.
    private var searches = 0

    /// Counts a search and returns how many there have been.
    func countSearch() -> Int {
        searches += 1
        return searches
    }

    func record(_ found: [Correspondence]) -> [Int] {
        found.map { thread in
            if let index = threads.firstIndex(where: { $0.id == thread.id }) { return index + 1 }
            threads.append(thread)
            return threads.count
        }
    }
}

@available(iOS 26.0, *)
@Generable
struct AskAnswer {
    @Guide(description: "True only if the emails actually contain the answer.")
    let found: Bool
    @Guide(description: "The answer in one to three short plain sentences, or a brief note of what couldn't be found.")
    let answer: String
    @Guide(description: "The [n] numbers of the emails the answer came from. Empty if not found.")
    let sourceNumbers: [Int]
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
        guard await recorder.countSearch() <= 3 else {
            return "No more searches. Answer now from the emails above, or set found to false."
        }
        let found = Array(await search(arguments.keywords).prefix(5))
        let numbers = await recorder.record(found)
        guard !found.isEmpty else { return "No emails matched \"\(arguments.keywords)\". Try different keywords." }
        return Self.describe(Array(zip(numbers, found)))
    }

    /// Numbered emails as the model reads them.
    static func describe(_ emails: [(Int, Correspondence)]) -> String {
        emails.map { number, thread in
            let text = MailIntelligence.prepared(thread.body.isEmpty ? thread.excerpt : thread.body).text
            return """
            [\(number)] From: \(thread.sender)
            Date: \(thread.receivedAt.formatted(date: .abbreviated, time: .shortened))
            Subject: \(thread.subject)
            \(text.prefix(550))
            """
        }.joined(separator: "\n\n")
    }
}
