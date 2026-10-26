import Foundation
import Testing
@testable import CorresCore

/// Lists are built with every conversation in and the hidden ones taken out
/// after: what's left must read exactly as a list built without them.
struct ListExclusionTests {
    private enum Row: Equatable {
        case heading(String)
        case thread(ThreadID)
        var id: ThreadID? { if case .thread(let id) = self { id } else { nil } }
    }

    private func id(_ n: Int) -> ThreadID { ThreadID(account: "me@example.com", providerID: "t\(n)") }

    /// Needs You's two headings, shown only while both have mail, built
    /// from scratch the way the Mac list builds them.
    private func needsYou(soon: [Int], rest: [Int]) -> [Row] {
        guard !soon.isEmpty, !rest.isEmpty else { return (soon + rest).map { .thread(id($0)) } }
        return [.heading("Due soon")] + soon.map { .thread(id($0)) } + [.heading("When you can")] + rest.map { .thread(id($0)) }
    }

    @Test func nothingHiddenIsTheSameList() {
        let rows = needsYou(soon: [1, 2], rest: [3])
        #expect(ListExclusion.rows(rows, leaving: [], id: \.id, pairedHeadings: true) == rows)
    }

    @Test func hidingMatchesBuildingWithout() {
        let soon = [1, 2, 3], rest = [4, 5, 6, 7]
        let all = needsYou(soon: soon, rest: rest)
        // Every way of hiding one or two conversations, including emptying
        // either group, which takes both headings away.
        let ids = soon + rest
        var cases: [Set<Int>] = ids.map { [$0] }
        for a in ids { for b in ids where b > a { cases.append([a, b]) } }
        cases += [Set(soon), Set(rest), Set(ids)]
        for hidden in cases {
            let expected = needsYou(soon: soon.filter { !hidden.contains($0) }, rest: rest.filter { !hidden.contains($0) })
            let left = ListExclusion.rows(all, leaving: Set(hidden.map(id)), id: \.id, pairedHeadings: true)
            #expect(left == expected, "hiding \(hidden.sorted())")
        }
    }

    @Test func aHeadingWithNothingUnderItGoes() {
        let rows: [Row] = [.heading("Top Results"), .thread(id(1)), .heading("Everything Else"), .thread(id(2)), .thread(id(3))]
        #expect(ListExclusion.rows(rows, leaving: [id(1)], id: \.id)
                == [.heading("Everything Else"), .thread(id(2)), .thread(id(3))])
        // Unpaired headings stay while their own group has mail.
        #expect(ListExclusion.rows(rows, leaving: [id(2)], id: \.id)
                == [.heading("Top Results"), .thread(id(1)), .heading("Everything Else"), .thread(id(3))])
    }

    @Test func plainListsKeepTheirOrder() {
        let threads = (0..<6).map { n in
            Correspondence(id: id(n), sender: "Ana", organization: "", subject: "Plans \(n)", excerpt: "", body: "",
                           receivedAt: Date(timeIntervalSince1970: Double(1_800_000_000 - n * 60)), dueAt: nil,
                           reason: "", attention: .quiet)
        }
        let left = ListExclusion.threads(threads, leaving: [id(1), id(4), id(99)])
        #expect(left.map(\.id) == [0, 2, 3, 5].map(id))
        #expect(ListExclusion.threads(threads, leaving: []).map(\.id) == threads.map(\.id))
    }
}
