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
    var focusOnAppear = false
    /// Lets Compose put text in where the cursor is (a template).
    var inserter: MacTextInserter?

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
        let font = NSFont.systemFont(ofSize: 14)
        text.font = font
        text.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        text.string = initialText
        text.textStorage?.addAttributes([.font: font, .foregroundColor: NSColor.labelColor],
                                        range: NSRange(location: 0, length: (initialText as NSString).length))
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
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacRichEditor
        weak var textView: NSTextView?

        init(_ parent: MacRichEditor) { self.parent = parent }

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
