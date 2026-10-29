import Foundation
import Testing
@testable import Postwright

struct MIMETests {
    func parse(_ text: String) -> ParsedMessage { MIMEParser.parse(Data(text.utf8)) }

    @Test func plainMessage() {
        let m = parse("From: a@b.c\r\nSubject: Hi\r\n\r\nHello there.\r\n")
        #expect(m.plainText == "Hello there.\r\n")
        #expect(m.html == nil)
        #expect(m.header("subject") == "Hi")
    }

    @Test func alternativeKeepsBothBodies() {
        let m = parse("""
        Content-Type: multipart/alternative; boundary="b1"\r
        \r
        --b1\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain\r
        --b1\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Rich</p>\r
        --b1--\r

        """)
        #expect(m.plainText == "Plain")
        #expect(m.html == "<p>Rich</p>")
    }

    @Test func quotedPrintableInLatin1() {
        let m = parse("Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nGr=FC=DFe aus K=F6ln, and a soft=\r\n break.\r\n")
        #expect(m.plainText == "Grüße aus Köln, and a soft break.\r\n")
    }

    @Test func softBreakWithSpacesAfterIt() {
        let m = parse("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nOne long=  \r\n line, a=\t\nnd more.\r\n")
        #expect(m.plainText == "One long line, and more.\r\n")
    }

    @Test func mixedWithAPDFAndAnInlineImage() {
        let pdf = Data("%PDF-1.4 fake".utf8).base64EncodedString()
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let m = parse("""
        Content-Type: multipart/mixed; boundary=outer\r
        \r
        --outer\r
        Content-Type: multipart/related; boundary=inner\r
        \r
        --inner\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <img src="cid:logo@x">\r
        --inner\r
        Content-Type: image/png\r
        Content-Transfer-Encoding: base64\r
        Content-ID: <logo@x>\r
        \r
        \(png)\r
        --inner--\r
        --outer\r
        Content-Type: application/pdf; name="Invoice 42.pdf"\r
        Content-Disposition: attachment; filename="Invoice 42.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(pdf)\r
        --outer--\r

        """)
        #expect(m.html == #"<img src="cid:logo@x">"#)
        #expect(m.attachments.count == 2)
        let image = m.attachments.first { $0.mimeType == "image/png" }
        #expect(image?.contentID == "logo@x")
        #expect(image?.isInline == true)
        #expect(image?.data == Data([0x89, 0x50, 0x4E, 0x47]))
        let invoice = m.attachments.first { $0.mimeType == "application/pdf" }
        #expect(invoice?.filename == "Invoice 42.pdf")
        #expect(invoice?.isInline == false)
        #expect(invoice?.data == Data("%PDF-1.4 fake".utf8))
    }

    @Test func internationalFilenames() {
        let m = parse("""
        Content-Type: multipart/mixed; boundary=z\r
        \r
        --z\r
        Content-Type: text/plain\r
        \r
        See attached.\r
        --z\r
        Content-Type: application/pdf\r
        Content-Disposition: attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf\r
        \r
        x\r
        --z\r
        Content-Type: application/pdf; name="=?UTF-8?B?4Kas4Ka/4Kay?=.pdf"\r
        \r
        y\r
        --z--\r

        """)
        #expect(m.plainText == "See attached.")
        #expect(m.attachments.map(\.filename) == ["résumé.pdf", "বিল.pdf"])
    }

    @Test func lfOnlyLineEndingsStillParse() {
        let m = parse("Content-Type: multipart/alternative; boundary=q\n\n--q\nContent-Type: text/plain\n\nHi\n--q--\n")
        #expect(m.plainText == "Hi")
    }

    /// A part inside whose boundary starts with its parent's: the inner
    /// delimiters aren't the outer's (RFC 2046 5.1.1).
    @Test func innerBoundaryStartingWithTheOuterOne() {
        let m = parse("""
        Content-Type: multipart/mixed; boundary="b"\r
        \r
        --b \r
        Content-Type: multipart/alternative; boundary="b1"\r
        \r
        --b1\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain\r
        --b1\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Rich</p>\r
        --b1--\r
        --b\r
        Content-Type: application/pdf; name="a.pdf"\r
        \r
        PDF\r
        --b--\r

        """)
        #expect(m.plainText == "Plain")
        #expect(m.html == "<p>Rich</p>")
        #expect(m.attachments.map(\.filename) == ["a.pdf"])
    }
}

/// Charset labels read as the larger encoding senders actually write.
struct CharsetTests {
    func parse(_ text: String, body: Data) -> ParsedMessage {
        var raw = Data(text.utf8)
        raw.append(body)
        return MIMEParser.parse(raw)
    }

    @Test func chineseLabelledGB2312ReadsGB18030Characters() {
        // "镕" is in GBK/GB18030 but not GB2312.
        let text = "朱镕基你好"
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let body = text.data(using: gb18030)!
        let m = parse("Content-Type: text/plain; charset=gb2312\r\n\r\n", body: body)
        #expect(m.plainText == text)
    }

    @Test func koreanLabelledEUCKRReadsCP949() {
        // "똠" is in code page 949 but not in EUC-KR's KS X 1001 set.
        let text = "똠방각하 안녕하세요"
        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        let body = text.data(using: cp949)!
        for label in ["euc-kr", "ks_c_5601-1987"] {
            #expect(parse("Content-Type: text/plain; charset=\(label)\r\n\r\n", body: body).plainText == text)
        }
    }

    @Test func japaneseLabelledShiftJISReadsCP932() {
        // "①" and "髙" are Windows additions to Shift_JIS.
        let text = "①髙橋様"
        let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        let body = text.data(using: cp932)!
        #expect(parse("Content-Type: text/plain; charset=shift_jis\r\n\r\n", body: body).plainText == text)
    }

    @Test func latin1ReadsWindows1252Quotes() {
        // 0x93/0x94 are curly quotes and 0x80 the euro sign in Windows-1252.
        let body = Data([0x93, 0x48, 0x69, 0x94, 0x20, 0x80, 0x35])
        #expect(parse("Content-Type: text/plain; charset=iso-8859-1\r\n\r\n", body: body).plainText == "\u{201C}Hi\u{201D} €5")
    }

    @Test func encodedWordsUseTheSameMapping() {
        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        let word = "똠방".data(using: cp949)!.base64EncodedString()
        #expect(MIMEWords.decode("=?ks_c_5601-1987?B?\(word)?=") == "똠방")
        #expect(Charset.encoding(named: "\"GB2312\"") != nil)
        #expect(Charset.encoding(named: "us-ascii") == .utf8)
    }
}

/// Which parts are the email, read as Mail and Thunderbird read them.
struct BodyLayoutTests {
    func parse(_ text: String) -> ParsedMessage { MIMEParser.parse(Data(text.utf8)) }

    func parse(_ text: String, body: Data) -> ParsedMessage {
        var raw = Data(text.utf8)
        raw.append(body)
        return MIMEParser.parse(raw)
    }

    /// Mail on a Mac or iPhone, a file put in the middle of the text: the
    /// text after it is a second HTML part, and the file is marked inline.
    @Test func textOnBothSidesOfAFileIsAllShown() {
        let pdf = Data("%PDF-1.4 fake".utf8).base64EncodedString()
        let m = parse("""
        Content-Type: multipart/alternative; boundary=alt\r
        \r
        --alt\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Before. After.\r
        --alt\r
        Content-Type: multipart/mixed; boundary=mix\r
        \r
        --mix\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><div>Before the file.</div></body></html>\r
        --mix\r
        Content-Type: application/pdf; name="Plan.pdf"\r
        Content-Disposition: inline; filename="Plan.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(pdf)\r
        --mix\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><div>After the file. Thanks, Sam</div></body></html>\r
        --mix--\r
        --alt--\r

        """)
        #expect(m.html?.contains("Before the file.") == true)
        #expect(m.html?.contains("After the file. Thanks, Sam") == true)
        // The second part inside the first one's body.
        #expect(m.html?.hasSuffix("</body></html>") == true)
        #expect(m.plainText == "Before. After.")
        #expect(m.attachments.map(\.filename) == ["Plan.pdf"])
    }

    @Test func aMailingListFooterIsShown() {
        let m = parse("""
        Content-Type: multipart/mixed; boundary=mix\r
        \r
        --mix\r
        Content-Type: multipart/alternative; boundary=alt\r
        \r
        --alt\r
        Content-Type: text/plain\r
        \r
        Meeting moved to 3pm.\r
        --alt\r
        Content-Type: text/html\r
        \r
        <p>Meeting moved to 3pm.</p>\r
        --alt--\r
        --mix\r
        Content-Type: text/plain; charset=us-ascii\r
        Content-Disposition: inline\r
        \r
        To unsubscribe, write to list-leave@example.org\r
        --mix--\r

        """)
        #expect(m.html?.contains("<p>Meeting moved to 3pm.</p>") == true)
        #expect(m.html?.contains("list-leave@example.org") == true)
        #expect(m.attachments.isEmpty)
    }

    @Test func alternativesPreferTheLastThatCanBeShown() {
        let m = parse("""
        Content-Type: multipart/alternative; boundary=alt\r
        \r
        --alt\r
        Content-Type: text/plain\r
        \r
        Plain\r
        --alt\r
        Content-Type: multipart/related; boundary=rel\r
        \r
        --rel\r
        Content-Type: text/html\r
        \r
        <p>Rich <img src="cid:a@b"></p>\r
        --rel\r
        Content-Type: image/gif\r
        Content-ID: <a@b>\r
        Content-Transfer-Encoding: base64\r
        \r
        R0lGODlhAQABAAAAACw=\r
        --rel--\r
        --alt\r
        Content-Type: text/calendar; method=REQUEST\r
        \r
        BEGIN:VCALENDAR\r
        END:VCALENDAR\r
        --alt--\r

        """)
        #expect(m.html == #"<p>Rich <img src="cid:a@b"></p>"#)
        #expect(m.plainText == "Plain")
        // The invitation's calendar part, unnamed, is still there to answer.
        #expect(m.attachments.contains { $0.mimeType == "text/calendar" && $0.filename == "invite.ics" })
    }

    @Test func plainTextOnlyAroundAPhoto() {
        let m = parse("""
        Content-Type: multipart/mixed; boundary=mix\r
        \r
        --mix\r
        Content-Type: text/plain\r
        \r
        Here's the photo:\r
        --mix\r
        Content-Type: image/jpeg; name="IMG_1.jpg"\r
        Content-Disposition: inline; filename="IMG_1.jpg"\r
        Content-ID: <photo1>\r
        Content-Transfer-Encoding: base64\r
        \r
        /9j/4AAQ\r
        --mix\r
        Content-Type: text/plain\r
        \r
        Sent from my iPhone\r
        --mix--\r

        """)
        #expect(m.html == nil)
        #expect(m.plainText == "Here's the photo:\n\nSent from my iPhone")
        #expect(m.attachments.map(\.filename) == ["IMG_1.jpg"])
    }

    @Test func htmlNamesItsCharsetInAMetaTag() {
        let text = "日本語のメール"
        let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        var body = Data(#"<html><head><meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS"></head><body>"#.utf8)
        body += text.data(using: cp932)!
        body += Data("</body></html>".utf8)
        #expect(parse("Content-Type: text/html\r\n\r\n", body: body).html?.contains(text) == true)
    }
}
