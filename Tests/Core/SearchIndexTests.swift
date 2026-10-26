import Foundation
import Testing
@testable import CorresCore

/// Search reads each conversation's text from `SearchIndex`, folded once,
/// instead of calling `localizedStandardContains` on every field. These
/// check it finds exactly what the old way found.
struct SearchIndexTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Search as it was: every field compared with `localizedStandardContains`.
    private func oldMatches(_ terms: MailQuery.SearchTerms, _ item: Correspondence, serverMatched: Bool = false) -> Bool {
        if terms.hasAttachment && item.attachments.isEmpty && !(serverMatched && !item.isBodyLoaded) { return false }
        if terms.unread && !item.isUnread { return false }
        if terms.flagged && !item.isFlagged { return false }
        if serverMatched { return true }
        for name in terms.from where ![item.sender, item.senderEmail ?? "", item.organization].contains(where: { $0.localizedStandardContains(name) }) {
            return false
        }
        for name in terms.to where !(item.toRecipients + item.ccRecipients).contains(where: { $0.localizedStandardContains(name) }) {
            return false
        }
        guard !terms.words.isEmpty else { return true }
        let fields = [item.sender, item.organization, item.subject, item.excerpt, item.senderEmail ?? "", item.body]
            + item.toRecipients + item.ccRecipients
        return MailQuery.SearchTerms.searchWords(terms.words).allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
    }

    private func oldRelevance(_ terms: MailQuery.SearchTerms, _ item: Correspondence) -> Double {
        var score = 0.0
        let sender = [item.sender, item.organization, item.senderEmail ?? ""].joined(separator: " ").lowercased()
        let subject = item.subject.lowercased()
        let preview = item.excerpt.lowercased()
        func startsWord(_ word: String, in text: String) -> Bool {
            text.hasPrefix(word) || text.contains(" " + word) || text.contains("@" + word) || text.contains("." + word)
        }
        for word in MailQuery.SearchTerms.searchWords(terms.words).map({ $0.lowercased() }) where !word.isEmpty {
            if sender.contains(word) { score += startsWord(word, in: sender) ? 6 : 4 }
            if subject.contains(word) { score += startsWord(word, in: subject) ? 4 : 3 }
            if preview.contains(word) { score += 1.5 } else if item.body.localizedStandardContains(word) { score += 1 }
        }
        if !terms.from.isEmpty { score += 3 }
        let days = max(0, now.timeIntervalSince(item.receivedAt) / 86_400)
        score += 4 * exp(-days / 30)
        if item.isFlagged || item.isPinned { score += 1.5 }
        if item.attention == .needsYou { score += 1 }
        if item.isUnread { score += 0.5 }
        if item.isArchivedCopy { score -= 0.5 }
        return score
    }

    private static let queries = [
        // Case and accents, both ways.
        "cafe", "CAFÉ", "Café", "resume", "RÉSUMÉ", "strasse", "STRASSE", "Straße", "munchen", "MÜNCHEN", "jose", "José",
        "zoe", "angstrom", "naive", "ecole",
        // Several words, anywhere; quoted phrases together.
        "invoice march", "march invoice", "invoice xyz", "\"thanks hello\"", "\"hello thanks\" receipt", "\"",
        // Who it's from and who it went to.
        "from:jose", "from:ACME", "from:müller", "to:lena", "to:example.org", "to:LENA invoice", "from:delta to:me@example.com",
        "souza", "example.de", "mahmud.hasan@example.org",
        // Bengali, partly typed.
        "কি", "বা", "শুভ কিছু",
        // Filters.
        "is:unread invoice", "is:flagged", "has:attachment",
        // Nothing, and part of a word.
        "xyz", "i", "inv", "e"
    ]

    @Test func findsWhatLocalizedStandardContainsFound() {
        let threads = SearchSpeedTests.mailbox(600, seed: 11)
        for query in Self.queries {
            let terms = MailQuery.SearchTerms(query)
            let expected = MailQuery.sortedNewestFirst(threads.filter { oldMatches(terms, $0) }).map(\.id)
            #expect(MailQuery.filter(threads, search: query, now: now).map(\.id) == expected, "\(query)")
            #expect(threads.allSatisfy { terms.matches($0) == oldMatches(terms, $0) }, "\(query)")
        }
    }

    @Test func topResultsRankAsBefore() {
        let threads = SearchSpeedTests.mailbox(600, seed: 12)
        for query in Self.queries {
            let terms = MailQuery.SearchTerms(query)
            let matches = MailQuery.filter(threads, search: query, now: now)
            for item in matches.prefix(50) {
                #expect(abs(terms.relevance(of: item, now: now) - oldRelevance(terms, item)) < 1e-9, "\(query)")
            }
            guard matches.count > 8, !terms.words.isEmpty || !terms.from.isEmpty else { continue }
            let expected = matches.map { (item: $0, score: oldRelevance(terms, $0)) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.receivedAt > $1.item.receivedAt }
                .prefix(5).map(\.item.id)
            #expect(MailQuery.topResults(matches, search: query, now: now).map(\.id) == Array(expected), "\(query)")
        }
    }

    @Test func eachFieldIsSearched() {
        let item = Correspondence(id: ThreadID(account: "me@example.com", providerID: "f"), sender: "Renée Dubois",
                                  senderEmail: "renee@atelier.fr", organization: "Atelier Ōno", subject: "Quarterly figures",
                                  excerpt: "Here are the numbers", body: "Le café est fermé le lundi. Ｆｕｌｌ width.",
                                  latestMessageID: "m1", receivedAt: now, dueAt: nil, reason: "", attention: .quiet,
                                  toRecipients: ["bjørn@example.no"], ccRecipients: ["Ünal@example.tr"])
        for query in ["renee", "RENÉE", "atelier.fr", "ono", "quarterly", "numbers", "CAFE FERME", "\"le cafe\"",
                      "bjørn", "unal", "to:ünal", "from:dubois", "from:ono", "Ｆｕｌｌ", "fermé lundi",
                      "bjorn", "cafe\u{301}", "\"cafe est\"", "\"fermé.\"", "quarterly lundi renee unal"] {
            let terms = MailQuery.SearchTerms(query)
            #expect(terms.matches(item) == oldMatches(terms, item), "\(query)")
        }
        // Width folds now, as it does in Mail: "full" finds "Ｆｕｌｌ".
        #expect(MailQuery.SearchTerms("full").matches(item))
    }

    @Test func aChangedMessageIsReadAgain() {
        let id = ThreadID(account: "me@example.com", providerID: "changing")
        func version(_ message: String?, body: String, loaded: Bool = true) -> Correspondence {
            Correspondence(id: id, sender: "Sam", organization: "", subject: "Plans", excerpt: "See below", body: body,
                           latestMessageID: message, receivedAt: now, dueAt: nil, reason: "", attention: .quiet,
                           isBodyLoaded: loaded)
        }
        #expect(MailQuery.filter([version("m1", body: "lunch on friday", loaded: false)], search: "dinner").isEmpty)
        #expect(MailQuery.filter([version("m1", body: "dinner on friday")], search: "dinner").count == 1)
        #expect(MailQuery.filter([version("m2", body: "breakfast")], search: "dinner").isEmpty)
        #expect(MailQuery.filter([version(nil, body: "tea")], search: "tea").count == 1)
        #expect(MailQuery.filter([version(nil, body: "coffee")], search: "coffee").count == 1)
    }

    @Test func typingFurtherNarrows() {
        func narrows(_ new: String, _ old: String) -> Bool { MailQuery.SearchTerms(new).narrows(MailQuery.SearchTerms(old)) }
        #expect(narrows("invoice", "invo"))
        #expect(narrows("invoice march", "invoice"))
        #expect(narrows("Invoice", "invo"))
        #expect(narrows("café", "CAFE"))
        #expect(narrows("from:samuel", "from:sam"))
        #expect(narrows("\"for march\"", "\"for"))
        #expect(narrows("is:unread invoice", "invoice"))
        #expect(!narrows("invoice", "invoice march"))
        #expect(!narrows("invoice", "is:unread invoice"))
        #expect(!narrows("invoice", ""))
        #expect(!narrows("inv", "invoice"))
        #expect(!narrows("from:sam", "to:sam"))
    }

    @MainActor @Test func largeMailboxesAreSearchedAway() async {
        let threads = SearchSpeedTests.mailbox(MailSearch.inlineLimit + 500, seed: 13)
        let search = MailSearch()
        let request = MailSearch.Request(search: "invoice march", source: 1)
        var shown = 0
        #expect(search.matches(for: request, in: { threads }, now: now, onFound: { shown += 1 }) == nil)
        while shown == 0 { await Task.yield() }
        let expected = MailQuery.filter(threads, search: "invoice march", now: now)
        #expect(search.matches(for: request, in: { threads }, now: now, onFound: {}) == expected)
        #expect(shown == 1)
        // Top Results ranked with them, also once some are hidden.
        #expect(search.topResults(expected) == MailQuery.topResults(expected, search: "invoice march", now: now))
        let fewer = expected.enumerated().filter { $0.offset % 3 != 0 }.map(\.element)
        #expect(search.topResults(fewer) == MailQuery.topResults(fewer, search: "invoice march", now: now))

        // Typing more looks through what was found, not the whole mailbox.
        var read = false
        let further = MailSearch.Request(search: "invoice march quarterly", source: 1)
        let narrowed = search.matches(for: further, in: { read = true; return threads }, now: now, onFound: {})
        #expect(!read || expected.count > MailSearch.inlineLimit)
        if let narrowed {
            #expect(narrowed == MailQuery.filter(threads, search: "invoice march quarterly", now: now))
        }

        // Other mail, or a different search: the whole mailbox again.
        #expect(!MailSearch.Request(search: "invoice march quarterly", source: 2).narrows(request))
        #expect(!MailSearch.Request(search: "invoice", source: 1).narrows(request))
        #expect(!MailSearch.Request(search: "invoice march x", serverMatches: [threads[0].id], source: 1).narrows(request))
    }

    @MainActor @Test func smallMailboxesAreSearchedRightAway() {
        let threads = SearchSpeedTests.mailbox(50, seed: 14)
        let search = MailSearch()
        let found = search.matches(for: MailSearch.Request(search: "cafe", source: 0), in: { threads }, now: now, onFound: {})
        #expect(found == MailQuery.filter(threads, search: "cafe", now: now))
    }
}
