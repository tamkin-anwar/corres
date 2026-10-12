import Foundation
import Testing
@testable import CorresCore

struct PeopleIndexTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    /// Niloy's case: typing "sara" or "sara.wiltshire" offers the Sara he
    /// writes to.
    @Test func someoneYouWriteToIsOffered() {
        var index = PeopleIndex()
        for day in [1.0, 8, 20] { index.recordSent(to: "Sara Wiltshire <Sara.Wiltshire@portsmouth.ac.uk>", at: daysAgo(day)) }
        index.recordReceived(from: "Sara Wiltshire", email: "sara.wiltshire@portsmouth.ac.uk", at: daysAgo(2), isAutomated: false)
        for query in ["sara", "Sar", "wilt", "sara wil", "sara.wiltshire", "SARA.W", "portsmouth"] {
            #expect(index.suggestions(for: query, now: now).first?.email == "sara.wiltshire@portsmouth.ac.uk", "\(query)")
        }
        #expect(index.suggestions(for: "sara", now: now).first?.address == "Sara Wiltshire <sara.wiltshire@portsmouth.ac.uk>")
    }

    /// The Sara you write to every week before one who wrote once.
    @Test func closerPeopleComeFirst() {
        var index = PeopleIndex()
        index.recordReceived(from: "Sarah Lee", email: "sarah@shop.example", at: daysAgo(200), isAutomated: false)
        for day in [3.0, 10, 17, 24] { index.recordSent(to: "Sara Khan <sara.khan@example.com>", at: daysAgo(day)) }
        #expect(index.suggestions(for: "sar", now: now).map(\.email) == ["sara.khan@example.com", "sarah@shop.example"])
    }

    @Test func automatedSendersAreNotPeople() {
        var index = PeopleIndex()
        index.recordReceived(from: "Uber Receipts", email: "noreply@uber.com", at: now, isAutomated: true)
        index.recordReceived(from: "Morning Brew", email: "crew@morningbrew.com", at: now, isAutomated: true)
        index.recordReceived(from: "DoorDash", email: "no-reply@doordash.com", at: now, isAutomated: false)
        #expect(index.people.isEmpty)
        // …unless you write to them yourself.
        index.recordSent(to: "support@uber.com", at: now)
        #expect(index.suggestions(for: "uber", now: now).map(\.email) == ["support@uber.com"])
    }

    @Test func accentsAndCaseDontMatter() {
        var index = PeopleIndex()
        index.recordSent(to: "Zoë Müller <zoe.muller@example.de>", at: now)
        index.recordSent(to: "রিদিতা রহমান <ridita.r@gmail.com>", at: now)
        #expect(index.suggestions(for: "zoe mul", now: now).first?.name == "Zoë Müller")
        #expect(index.suggestions(for: "রিদিতা", now: now).first?.email == "ridita.r@gmail.com")
        #expect(index.suggestions(for: "ridi", now: now).first?.email == "ridita.r@gmail.com")
    }

    @Test func addressFieldsSplitWhereTheyShould() {
        #expect(PeopleIndex.entries(in: #""Doe, Jane" <jane@x.com>, b@y.com; Sam <sam@z.io>"#)
                == [#""Doe, Jane" <jane@x.com>"#, "b@y.com", "Sam <sam@z.io>"])
        #expect(PeopleIndex.parse(#""Doe, Jane" <Jane@X.com>"#)! == ("Doe, Jane", "jane@x.com"))
        #expect(PeopleIndex.parse("not an address") == nil)
        #expect(PeopleIndex.parse("sara.wiltshire") == nil)
    }

    @Test func noMatchMeansNothing() {
        var index = PeopleIndex()
        index.recordSent(to: "Sara <sara@x.com>", at: now)
        #expect(index.suggestions(for: "bob", now: now).isEmpty)
        #expect(index.suggestions(for: "sara", excluding: ["sara@x.com"], now: now).isEmpty)
    }

    @Test func fieldSplitsIntoChipsAndTyping() {
        #expect(PeopleIndex.split("") == ([], ""))
        #expect(PeopleIndex.split("sar") == ([], "sar"))
        #expect(PeopleIndex.split("Sara <s@x.com>, ") == (["Sara <s@x.com>"], ""))
        #expect(PeopleIndex.split(#""Doe, Jane" <j@x.com>, b@y.com, mi"#) == ([#""Doe, Jane" <j@x.com>"#, "b@y.com"], "mi"))
        #expect(PeopleIndex.split("a@x.com, sara ") == (["a@x.com"], "sara "))
    }

    /// Before typing: who you're in touch with now, each once.
    @Test func topPeopleBeforeTyping() {
        var index = PeopleIndex()
        for day in [1.0, 3, 6] { index.recordSent(to: "Hoare, Olivia <olivia.hoare@work.co.uk>", at: daysAgo(day)) }
        index.recordSent(to: "Olivia Hoare <olivia@gmail.com>", at: daysAgo(40))
        index.recordSent(to: "Ridu <ridita.r@gmail.com>", at: daysAgo(2))
        index.recordSent(to: "Old Colleague <old@x.com>", at: daysAgo(400))
        // Writes to you a lot, never heard back: still a person in touch.
        for day in [1.0, 2, 4] { index.recordReceived(from: "Ash", email: "ash@x.com", at: daysAgo(day), isAutomated: false) }
        // Wrote once: not yet.
        index.recordReceived(from: "Stranger", email: "s@x.com", at: daysAgo(1), isAutomated: false)
        let top = index.top(now: now)
        #expect(top.first?.displayName == "Olivia Hoare")
        // Two addresses, maybe two people: both offered, never merged.
        #expect(top.filter { $0.displayName == "Olivia Hoare" }.count == 2)
        #expect(top.map(\.email).contains("ridita.r@gmail.com"))
        #expect(top.map(\.email).contains("ash@x.com"))
        #expect(!top.map(\.email).contains("s@x.com"))
        #expect(top.last?.email == "old@x.com")
        #expect(!index.top(excluding: ["ridita.r@gmail.com"], now: now).map(\.email).contains("ridita.r@gmail.com"))
    }
}
