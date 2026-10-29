import AppKit
import SwiftUI

/// The compose body: a real Mac text view, with the Format menu's Bold,
/// Italic and Underline (⌘B, ⌘I, ⌘U), links, spelling and grammar,
/// dictation and Writing Tools, all as in Mail. What you write goes as
/// plain text, plus HTML when anything is formatted (`RichBody`), the same
/// as from the iPhone.
struct MacRichEditor: NSViewRepresentable {
    @Binding var plain: String
    @Binding var html: String?
    var initialText: String
    /// The formatting it had (an email opened again: Undo Send, Send
    /// Later, a draft), laid back onto `initialText`.
    var initialHTML: String?
    var focusOnAppear = false
    /// Lets Compose put text in where the cursor is (a template).
    var inserter: MacTextInserter?
    /// View › Bigger and Smaller. Only how it shows here: what's sent
    /// carries no size (`RichBody`).
    @AppStorage(CorresSettings.textScaleKey) private var textScale = 1.0
    private static let baseSize: CGFloat = 14

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.delegate = context.coordinator
        text.isRichText = true
        text.allowsUndo = true
        text.importsGraphics = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = true
        text.isAutomaticLinkDetectionEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = true
        text.usesFindBar = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 12, height: 12)
        let font = NSFont.systemFont(ofSize: (Self.baseSize * MacTextSize.clamped(textScale)).rounded())
        context.coordinator.size = font.pointSize
        text.font = font
        text.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        text.textStorage?.setAttributedString(Self.attributed(initialText, html: initialHTML, font: font))
        scroll.drawsBackground = false
        context.coordinator.textView = text
        inserter?.textView = text
        if focusOnAppear {
            DispatchQueue.main.async {
                text.window?.makeFirstResponder(text)
                text.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.resize(to: (Self.baseSize * MacTextSize.clamped(textScale)).rounded())
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// `text` at the body's size, with its bold, italic, underline and
    /// links from `html` (`RichBody.runs`): reopened, an email used to come
    /// back as plain text, and went out again without them.
    static func attributed(_ text: String, html: String?, font: NSFont) -> NSAttributedString {
        let plainAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        guard let html, !html.isEmpty else { return NSAttributedString(string: text, attributes: plainAttributes) }
        let result = NSMutableAttributedString()
        for run in RichBody.runs(plain: text, html: html) {
            var attributes = plainAttributes
            var styled = font
            if run.bold { styled = NSFontManager.shared.convert(styled, toHaveTrait: .boldFontMask) }
            if run.italic { styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask) }
            attributes[.font] = styled
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacRichEditor
        weak var textView: NSTextView?
        var size: CGFloat = 0

        init(_ parent: MacRichEditor) { self.parent = parent }

        /// Every run at the new size, keeping its bold and italic. Not an
        /// edit: it isn't undoable and the draft doesn't change.
        func resize(to newSize: CGFloat) {
            guard newSize != size, let text = textView, let storage = text.textStorage else { return }
            size = newSize
            func resized(_ font: NSFont?) -> NSFont {
                guard let font else { return .systemFont(ofSize: newSize) }
                return NSFont(descriptor: font.fontDescriptor, size: newSize) ?? .systemFont(ofSize: newSize)
            }
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                storage.addAttribute(.font, value: resized(value as? NSFont), range: range)
            }
            storage.endEditing()
            text.typingAttributes[.font] = resized(text.typingAttributes[.font] as? NSFont)
        }

        func textDidChange(_ notification: Notification) {
            guard let text = textView, let storage = text.textStorage else { return }
            parent.plain = text.string
            var runs: [RichRun] = []
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                runs.append(RichRun((storage.string as NSString).substring(with: range),
                                    bold: traits.contains(.bold), italic: traits.contains(.italic),
                                    underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                                    strikethrough: (attributes[.strikethroughStyle] as? Int ?? 0) != 0,
                                    link: attributes[.link] as? URL ?? (attributes[.link] as? String).flatMap(URL.init(string:))))
            }
            parent.html = RichBody.html(runs)
        }
    }
}

/// Puts text into the compose body where the cursor is, as typing would,
/// so it's undoable and the draft hears about it.
@MainActor
final class MacTextInserter {
    weak var textView: NSTextView?

    func insert(_ text: String) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let at = range.location == NSNotFound ? NSRange(location: (textView.string as NSString).length, length: 0) : range
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: at)
    }

    /// Swaps `old` for `new` where it is in the body (a signature), as one
    /// undoable change. False if `old` isn't there.
    @discardableResult
    func replace(_ old: String, with new: String) -> Bool {
        guard let textView, !old.isEmpty else { return false }
        let range = (textView.string as NSString).range(of: old)
        guard range.location != NSNotFound else { return false }
        var target = range
        // Taking a signature out takes the blank line above it too.
        if new.isEmpty, range.location >= 2,
           (textView.string as NSString).substring(with: NSRange(location: range.location - 2, length: 2)) == "\n\n" {
            target = NSRange(location: range.location - 2, length: range.length + 2)
        }
        guard textView.shouldChangeText(in: target, replacementString: new) else { return false }
        textView.textStorage?.replaceCharacters(in: target, with: NSAttributedString(string: new, attributes: textView.typingAttributes))
        textView.didChangeText()
        return true
    }

    /// Add Link (⌘K): the chosen words link to `url`, or with nothing
    /// chosen, the address goes in where the cursor is, linked. Undoable,
    /// and the draft's HTML hears about it.
    func link(_ url: URL) {
        guard let textView, let storage = textView.textStorage else { return }
        var range = textView.selectedRange()
        if range.location == NSNotFound { range = NSRange(location: storage.length, length: 0) }
        textView.window?.makeFirstResponder(textView)
        if range.length == 0 {
            let text = url.scheme == "mailto" ? String(url.absoluteString.dropFirst("mailto:".count)) : url.absoluteString
            guard textView.shouldChangeText(in: range, replacementString: text) else { return }
            var attributes = textView.typingAttributes
            attributes[.link] = url
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
            // What's typed next isn't part of the link.
            textView.typingAttributes[.link] = nil
        } else {
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.addAttribute(.link, value: url, range: range)
            textView.didChangeText()
        }
    }

    /// What's typed into Add Link, as a link: "corres.app" is a web
    /// address, "ana@example.com" an email one. Nil for nothing usable.
    static func linkURL(_ typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) { return url }
        if text.contains("@"), !text.contains("/") { return URL(string: "mailto:" + text) }
        guard text.contains(".") else { return nil }
        return URL(string: "https://" + text)
    }

    /// Adds `text` at `offset` characters from the start (a signature
    /// above the quoted email), undoably.
    func insert(_ text: String, at offset: Int) {
        guard let textView else { return }
        let location = min(max(0, offset), (textView.string as NSString).length)
        let target = NSRange(location: location, length: 0)
        guard textView.shouldChangeText(in: target, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: target, with: NSAttributedString(string: text, attributes: textView.typingAttributes))
        textView.didChangeText()
    }
}
