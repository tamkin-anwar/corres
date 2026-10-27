import Foundation
import Testing
@testable import CorresCore

/// What goes into a raw email: any length, any script, through any server.
struct MailEncodingTests {
    /// Decodes quoted-printable the way a mail app does.
    func decodeQP(_ text: String) -> String {
        var bytes: [UInt8] = []
        let lines = text.components(separatedBy: "\r\n")
        for (index, line) in lines.enumerated() {
            var chars = Array(line.utf8)
            var soft = false
            if chars.last == UInt8(ascii: "=") { chars.removeLast(); soft = true }
            var i = 0
            while i < chars.count {
                if chars[i] == UInt8(ascii: "="), i + 2 < chars.count {
                    let hex = String(decoding: chars[(i + 1)...(i + 2)], as: UTF8.self)
                    bytes.append(UInt8(hex, radix: 16)!)
                    i += 3
                } else {
                    bytes.append(chars[i])
                    i += 1
                }
            }
            if !soft, index < lines.count - 1 { bytes += Array("\n".utf8) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func decodeWords(_ header: String) -> String {
        let words = header.components(separatedBy: "\r\n ")
        var bytes: [UInt8] = []
        for word in words {
            #expect(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="))
            let base64 = word.dropFirst(10).dropLast(2)
            let data = Data(base64Encoded: String(base64))
            #expect(data != nil)
            // Each word is whole UTF-8 on its own, never half a letter.
            #expect(String(data: data ?? Data(), encoding: .utf8) != nil)
            bytes += data ?? Data()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func longParagraphsAreWrapped() {
        let bengali = String(repeating: "আমি তোমাকে ভালোবাসি। ", count: 120)
        let english = String(repeating: "A long paragraph with no line breaks at all. ", count: 60)
        let body = english + "\n\n" + bengali + "\nLast line ends with a space "
        let encoded = MailEncoding.quotedPrintable(body)
        for line in encoded.components(separatedBy: "\r\n") {
            #expect(line.utf8.count <= 76)
            #expect(line.allSatisfy { $0.isASCII })
        }
        #expect(decodeQP(encoded) == body)
    }

    @Test func equalsSignsAndTabsSurvive() {
        let body = "a=b\tc\nx = 1 \t"
        #expect(decodeQP(MailEncoding.quotedPrintable(body)) == body)
        #expect(MailEncoding.quotedPrintable("1+1=2").contains("=3D"))
    }

    @Test func plainSubjectsStayAsTheyAre() {
        #expect(MailEncoding.encodedWords("Lunch on Friday?") == "Lunch on Friday?")
    }

    @Test func longSubjectsInAnyScriptAreSplitIntoShortWords() {
        let subjects = [
            "আগামী সপ্তাহের মিটিং এবং প্রকল্পের অগ্রগতি নিয়ে আলোচনা করার জন্য সময়সূচি",
            "Café meeting re: the naïve résumé, and a few more words to make it long enough to fold",
            "👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦 family plans 🎉🎉🎉 for the weekend trip",
        ]
        for subject in subjects {
            let encoded = MailEncoding.encodedWords(subject)
            for word in encoded.components(separatedBy: "\r\n ") {
                #expect(word.count <= 75)
            }
            #expect(decodeWords(encoded) == subject)
        }
        #expect(MailEncoding.encodedWords(subjects[0]).contains("\r\n "))
    }

    /// Drafts saved before the reply headers and signature flag existed
    /// still open.
    @Test func olderDraftsDecode() throws {
        let draft = Draft(kind: .reply, threadID: ThreadID(account: "me@x.test", providerID: "t"), to: "a@x.test", subject: "Re: Hi")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as! [String: Any]
        json["inReplyTo"] = nil
        json["rootReference"] = nil
        json["signatureAdded"] = nil
        let decoded = try JSONDecoder().decode(Draft.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.inReplyTo == nil && decoded.signatureAdded == nil)
        var withHeaders = draft
        withHeaders.inReplyTo = "abc@mail.example"
        let again = try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(withHeaders))
        #expect(again.inReplyTo == "abc@mail.example")
    }

    /// The Date header reads the same whatever language or calendar the
    /// device is set to, with the sender's own offset.
    @Test func dateHeaderIsRFC5322() {
        let date = Date(timeIntervalSince1970: 1_793_065_739) // 2026-10-27 01:48:59 UTC
        #expect(MailEncoding.dateHeader(date, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "Mon, 26 Oct 2026 18:48:59 -0700")
        #expect(MailEncoding.dateHeader(date, timeZone: TimeZone(identifier: "Asia/Dhaka")!) == "Tue, 27 Oct 2026 07:48:59 +0600")
        #expect(MailEncoding.dateHeader(date, timeZone: TimeZone(identifier: "UTC")!) == "Tue, 27 Oct 2026 01:48:59 +0000")
    }
}
