import Foundation
import Testing
@testable import CorresCore

struct WritingStyleTests {
    private func sample(_ text: String, to name: String = "Maya Chen", daysAgo: Double = 1) -> WritingStyle.Sample {
        WritingStyle.Sample(text: text, recipientName: name, date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400))
    }

    @Test func takesOffTheQuotedEmailAndSignature() {
        let text = """
        Sounds good, see you then.

        Thanks,
        Tamkin
        Sent from my iPhone

        On Tue, Oct 20, 2026 at 3:14 PM Maya Chen <maya@example.com> wrote:
        > Can we meet Thursday?
        """
        #expect(WritingStyle.ownWords(in: text) == "Sounds good, see you then.\n\nThanks,\nTamkin")
        let signed = "Done, it's attached.\n\n--\nTamkin Anwar\nAnwar Creative Studio"
        #expect(WritingStyle.ownWords(in: signed, signature: "--\nTamkin Anwar\nAnwar Creative Studio") == "Done, it's attached.")
        #expect(WritingStyle.ownWords(in: "Oui, merci.\n\nLe mar. 20 oct. 2026, Maya a écrit :\n> Bonjour") == "Oui, merci.")
    }

    @Test func learnsTheGreetingSignOffAndLength() {
        let samples = [
            sample("Hi Maya,\n\nThat works for me. I'll bring the slides.\n\nThanks,\nTamkin"),
            sample("Hi Jordan,\n\nYes, Thursday at 2 is fine. Send the room when you have it.\n\nThanks,\nTamkin", to: "Jordan Lee"),
            sample("Hi Sam,\n\nGot it, I'll take a look tonight and get back to you.\n\nThanks,\nTamkin", to: "Sam Ortiz"),
            sample("Hi Maya,\n\nPerfect. Let's keep it to thirty minutes.\n\nBest,\nTamkin"),
            sample("Hi Priya,\n\nThanks for sending this over. I'll review it by Friday.\n\nThanks,\nTamkin", to: "Priya Rao"),
        ]
        let style = WritingStyle.learn(from: samples, ownNames: ["Tamkin Anwar"])
        #expect(style?.greeting == "Hi {name},")
        #expect(style?.greeting(for: "Alex Kim") == "Hi Alex,")
        #expect(style?.signOff == "Thanks,")
        #expect(style?.usesExclamations == false)
        #expect(style?.language == "en")
        #expect((5...15).contains(style?.typicalWords ?? 0))
        #expect(style?.examples.count == 3)
        #expect(style?.examples.first?.hasPrefix("Hi Maya,") == true)
    }

    @Test func noteThatYouStartStraightIn() {
        let samples = (0..<6).map { n in sample("sure, works for me \(n). see you there\n\nTamkin", daysAgo: Double(n)) }
        let style = WritingStyle.learn(from: samples, ownNames: ["Tamkin Anwar"])
        #expect(style?.greeting == "")
        #expect(style?.writesLowercase == true)
        #expect(style?.instructions(recipientName: "Maya", replyLanguage: "en").contains("Start straight in") == true)
    }

    @Test func needsEnoughMailToCallItAHabit() {
        let samples = (0..<4).map { _ in sample("Hi Maya,\n\nOK.\n\nThanks,\nTamkin") }
        #expect(WritingStyle.learn(from: samples, ownNames: ["Tamkin"]) == nil)
    }

    @Test func greetingAndSignOffOnlyInTheirOwnLanguage() {
        let samples = (0..<5).map { n in sample("Hi Maya,\n\nThat works, thank you for organizing it \(n).\n\nThanks,\nTamkin") }
        let style = WritingStyle.learn(from: samples, ownNames: ["Tamkin"])
        let german = style?.instructions(recipientName: "Jonas", replyLanguage: "de") ?? ""
        #expect(!german.contains("Hi Jonas"))
        #expect(!german.contains("Thanks,"))
        #expect(!german.contains("Replies I wrote"))
        #expect(german.contains("about"))
        #expect(style?.instructions(recipientName: "Jonas", replyLanguage: "en").contains("Open with: Hi Jonas,") == true)
    }

    @Test func aGreetingIsShortAndLooksLikeOne() {
        #expect(WritingStyle.greeting(in: "Hey Sam!", recipient: "Sam Ortiz") == "Hey {name}!")
        #expect(WritingStyle.greeting(in: "Maya,", recipient: "Maya Chen") == "{name},")
        #expect(WritingStyle.greeting(in: "Hi all,", recipient: "Maya Chen") == "Hi all,")
        #expect(WritingStyle.greeting(in: "Thanks for the update on the launch plan", recipient: "Maya Chen") == nil)
        #expect(WritingStyle.greeting(in: "Sure,", recipient: "Maya Chen") == nil)
    }

    @Test func readsTheShapesRealMailComesIn() {
        // A signature under the sign-off: phone, address, email.
        let signed = WritingStyle.parse("Hi Sam,\nThe deck is attached.\nBest,\nTamkin\n(555) 010-2000\nLos Angeles, CA\ntamkin@example.com",
                                        recipient: "Sam Ortiz", ownNames: ["Tamkin Anwar"])
        #expect(signed.greeting == "Hi {name},")
        #expect(signed.signOff == "Best,")
        #expect(signed.body == "The deck is attached.")
        // The lines were lost: everything on one.
        let flat = WritingStyle.parse("Hi Maya, that works for me and I'll bring the slides. Thanks, Tamkin",
                                      recipient: "Maya Chen", ownNames: ["Tamkin Anwar"])
        #expect(flat.greeting == "Hi {name},")
        #expect(flat.signOff == "Thanks,")
        #expect(flat.body == "that works for me and I'll bring the slides.")
        // "On … wrote:" wrapped onto two lines, with nothing after it.
        let wrapped = "Sounds good.\n\nOn Tue, Oct 20, 2026 at 3:14 PM Maya Chen <\nmaya@example.com> wrote:"
        #expect(WritingStyle.ownWords(in: wrapped) == "Sounds good.")
    }

    @Test func leavesOutWhatAppsSendFromYourAddress() {
        #expect(!WritingStyle.isPersonal("---------- Forwarded message ---------\nFrom: Store"))
        #expect(!WritingStyle.isPersonal("DO_NOT_DELETE-b7ohm3zblwgzmv2tlzshwhabsv4ao49qlx2lo67612k5g394vgx1qssqcq81tlo-DO_NOT_DELETE"))
        #expect(!WritingStyle.isPersonal("ok"))
        #expect(WritingStyle.isPersonal("Sure, Thursday works for me."))
    }
}
