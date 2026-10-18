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
}
