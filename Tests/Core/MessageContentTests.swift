import Foundation
import Testing
@testable import CorresCore

/// Everything an email carries reaching the reader: its pictures, every
/// text part, in the charset it was written in.
struct MessageContentTests {
    // MARK: Pictures sent with the email (cid:)

    /// Outlook's form, as an Amazon email had it: the logo showed as an
    /// empty box.
    @Test func outlookPicturesAreFoundByContentID() {
        let html = #"<td><img width="200" src="cid:image001.png@01DD5FDE.D10AB060" alt="Logo"></td>"#
        let image = InlineImages.Image(contentID: "<image001.png@01DD5FDE.D10AB060>", filename: "image001.png",
                                       dataURI: "data:image/png;base64,AAAA")
        #expect(InlineImages.references(in: html) == ["image001.png@01dd5fde.d10ab060"])
        #expect(InlineImages.resolving(html, with: [image]) == #"<td><img width="200" src="data:image/png;base64,AAAA" alt="Logo"></td>"#)
    }

    @Test func referencesAreMatchedLoosely() {
        let html = """
        <img src="CID:Logo%40Example.com">
        <table background="cid:bg@x"><tr><td style="background-image:url(cid:tile@x)">
        <div style="background:url('cid:corner@x')"></div><div style="background:url(&quot;cid:quoted@x&quot;)"></div>
        <img src=" cid:spaced@x ">
        """
        #expect(InlineImages.references(in: html) == ["logo@example.com", "bg@x", "tile@x", "corner@x", "quoted@x", "spaced@x"])
        let images = ["logo@example.com", "bg@x", "tile@x", "corner@x", "quoted@x", "spaced@x"].map {
            InlineImages.Image(contentID: " <\($0.uppercased())> ", filename: nil, dataURI: "data:image/gif;base64,R0")
        }
        let resolved = InlineImages.resolving(html, with: images)
        #expect(!resolved.lowercased().contains("cid:"))
        #expect(resolved.contains(#"url('data:image/gif;base64,R0')"#))
        #expect(resolved.contains("url(&quot;data:image/gif;base64,R0&quot;)"))
    }

    /// Not downloaded (offline), or not in the email at all: left as
    /// "cid:" for the reading view to treat as a missing picture.
    @Test func aPictureNotHereKeepsItsReference() {
        let html = #"<img src="cid:one@x"><img src="cid:two@x">"#
        let resolved = InlineImages.resolving(html, with: [InlineImages.Image(contentID: "one@x", filename: nil, dataURI: "data:image/png;base64,A")])
        #expect(resolved == #"<img src="data:image/png;base64,A"><img src="cid:two@x">"#)
        #expect(InlineImages.references(in: resolved) == ["two@x"])
    }

    @Test func aPartWithoutContentIDIsFoundByItsFileName() {
        #expect(InlineImages.matches("image001.png@01dd5fde.d10ab060", contentID: nil, filename: "image001.png"))
        #expect(InlineImages.matches("image001.png", contentID: nil, filename: "Image001.PNG"))
        // With a Content-ID, only that counts.
        #expect(!InlineImages.matches("image001.png", contentID: "<other@x>", filename: "image001.png"))
    }

    /// Mail on an iPhone gives an attached PDF a Content-ID; the HTML never
    /// refers to it, so it's a file to list, not a picture to hide.
    @Test func onlyPicturesTheHTMLShowsAreHiddenFromAttachments() {
        let references = InlineImages.references(in: #"<p>Hi</p><img src="cid:photo@x">"#)
        #expect(InlineImages.isReferenced(contentID: "<photo@x>", filename: "IMG_1.jpg", in: references))
        #expect(!InlineImages.isReferenced(contentID: "<5B1E2C@apple.com>", filename: "Plan.pdf", in: references))
    }

    @Test func aPictureLabelledAsBytesIsNamedByItsExtension() {
        #expect(InlineImages.dataURI(base64: "A", mimeType: "application/octet-stream", filename: "logo.PNG") == "data:image/png;base64,A")
        #expect(InlineImages.dataURI(base64: "A", mimeType: "image/jpeg; name=x.jpg", filename: nil) == "data:image/jpeg;base64,A")
    }

    // MARK: Which parts are the text

    /// The Amazon email's shape: mixed > related > (alternative[plain,
    /// html], seven named inline pictures) + a PDF.
    @Test func outlookEmailWithPicturesAndAPDF() {
        let pictures = (1...7).map { MIMEOutline(mimeType: "image/png", disposition: "inline; filename=\"image00\($0).png\"", filename: "image00\($0).png") }
        let root = MIMEOutline(mimeType: "multipart/mixed", children: [
            MIMEOutline(mimeType: "multipart/related", children: [
                MIMEOutline(mimeType: "multipart/alternative", children: [
                    MIMEOutline(mimeType: "text/plain"), MIMEOutline(mimeType: "text/html"),
                ]),
            ] + pictures),
            MIMEOutline(mimeType: "application/pdf", disposition: "attachment", filename: "Fact Sheet.pdf"),
        ])
        #expect(MessageLayout.pieces(of: root) == [MessageLayout.Piece(path: [0, 0, 1], kind: .html)])
    }

    @Test func textAroundAFileIsAllShown() {
        let root = MIMEOutline(mimeType: "multipart/alternative", children: [
            MIMEOutline(mimeType: "text/plain"),
            MIMEOutline(mimeType: "multipart/mixed", children: [
                MIMEOutline(mimeType: "text/html"),
                MIMEOutline(mimeType: "application/pdf", disposition: "inline", filename: "Plan.pdf"),
                MIMEOutline(mimeType: "text/html"),
            ]),
        ])
        #expect(MessageLayout.pieces(of: root).map(\.path) == [[1, 0], [1, 2]])
        let html = MessageLayout.html(joining: [(.html, "<html><body><p>Before</p></body></html>"), (.html, "<p>After</p>")])
        #expect(html == "<html><body><p>Before</p><p>After</p></body></html>")
    }

    @Test func aPlainFooterAfterHTMLIsKeptAsText() {
        let root = MIMEOutline(mimeType: "multipart/mixed", children: [
            MIMEOutline(mimeType: "multipart/alternative", children: [MIMEOutline(mimeType: "text/plain"), MIMEOutline(mimeType: "text/html")]),
            MIMEOutline(mimeType: "text/plain", disposition: "inline"),
        ])
        #expect(MessageLayout.pieces(of: root) == [MessageLayout.Piece(path: [0, 1], kind: .html), MessageLayout.Piece(path: [1], kind: .plain)])
        let html = MessageLayout.html(joining: [(.html, "<p>News</p>"), (.plain, "Leave: <list@x.org>")]) ?? ""
        #expect(html.hasPrefix("<p>News</p>"))
        #expect(html.contains("Leave: &lt;list@x.org&gt;"))
    }

    @Test func plainTextMailStaysPlain() {
        let root = MIMEOutline(mimeType: "multipart/mixed", children: [
            MIMEOutline(mimeType: "text/plain"),
            MIMEOutline(mimeType: "image/jpeg", disposition: "inline", filename: "IMG_1.jpg"),
            MIMEOutline(mimeType: "text/plain"),
        ])
        let pieces = MessageLayout.pieces(of: root)
        #expect(pieces.map(\.kind) == [.plain, .plain])
        #expect(MessageLayout.html(joining: [(.plain, "Here it is:"), (.plain, "Sent from my iPhone")]) == nil)
        #expect(MessageLayout.plain(joining: [(.plain, "Here it is:"), (.plain, "Sent from my iPhone")]) == "Here it is:\n\nSent from my iPhone")
    }

    @Test func anInvitationsCalendarPartIsNotTheText() {
        let root = MIMEOutline(mimeType: "multipart/alternative", children: [
            MIMEOutline(mimeType: "text/plain"), MIMEOutline(mimeType: "text/html"), MIMEOutline(mimeType: "text/calendar"),
        ])
        #expect(MessageLayout.pieces(of: root) == [MessageLayout.Piece(path: [1], kind: .html)])
    }

    /// A forwarded email attached is a file, as Gmail shows it: the note
    /// written around it is the text, not the forwarded email's.
    @Test func aForwardedEmailIsNotTakenForTheText() {
        let root = MIMEOutline(mimeType: "multipart/mixed", children: [
            MIMEOutline(mimeType: "text/plain"),
            MIMEOutline(mimeType: "message/rfc822", filename: "Original.eml", children: [
                MIMEOutline(mimeType: "multipart/alternative", children: [MIMEOutline(mimeType: "text/plain"), MIMEOutline(mimeType: "text/html")]),
            ]),
        ])
        #expect(MessageLayout.pieces(of: root) == [MessageLayout.Piece(path: [0], kind: .plain)])
        // With nothing else, its text is still shown rather than nothing.
        let alone = MIMEOutline(mimeType: "multipart/mixed", children: [
            MIMEOutline(mimeType: "message/rfc822", children: [MIMEOutline(mimeType: "text/html")]),
        ])
        #expect(MessageLayout.pieces(of: alone) == [MessageLayout.Piece(path: [0, 0], kind: .html)])
    }

    @Test func aSinglePartEmailIsItsOwnText() {
        #expect(MessageLayout.pieces(of: MIMEOutline(mimeType: "text/html")) == [MessageLayout.Piece(path: [], kind: .html)])
        // A body that also carries a name is still shown when it's all there is.
        #expect(MessageLayout.pieces(of: MIMEOutline(mimeType: "text/html", filename: "message.html")).count == 1)
    }

    // MARK: Charsets

    @Test func htmlNamesItsCharsetInItsOwnMetaTag() {
        let old = Data(#"<html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252"></head>"#.utf8)
        #expect(MessageLayout.metaCharset(in: old) == "windows-1252")
        #expect(MessageLayout.metaCharset(in: Data(#"<meta charset='Shift_JIS'>"#.utf8)) == "Shift_JIS")
        #expect(MessageLayout.metaCharset(in: Data("<p>No charset here</p>".utf8)) == nil)
    }
}
