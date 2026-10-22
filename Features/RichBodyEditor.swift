import SwiftUI
import UIKit

/// What the Aa strip (and the text menu's own Bold, Italic, Underline)
/// act on: the message editor's selection, or what's typed next.
@MainActor @Observable
final class RichEditorController {
    weak var textView: UITextView?
    private(set) var isBold = false
    private(set) var isItalic = false
    private(set) var isUnderline = false
    private(set) var isStrikethrough = false
    private(set) var isBulleted = false
    private(set) var isNumbered = false
    /// Called after a change the editor didn't type itself.
    var onChange: (() -> Void)?

    static var bodyFont: UIFont { .preferredFont(forTextStyle: .body) }

    enum Style { case bold, italic, underline, strikethrough }

    func toggle(_ style: Style) {
        guard let textView else { return }
        let range = textView.selectedRange
        let turnOn = !isOn(style)
        if range.length == 0 {
            var typing = textView.typingAttributes
            apply(style, on: turnOn, to: &typing)
            textView.typingAttributes = typing
        } else {
            let storage = textView.textStorage
            storage.beginEditing()
            storage.enumerateAttributes(in: range) { attributes, subrange, _ in
                var changed = attributes
                apply(style, on: turnOn, to: &changed)
                storage.setAttributes(changed, range: subrange)
            }
            storage.endEditing()
            textView.selectedRange = range
            onChange?()
        }
        refresh()
    }

    /// Bullets or numbers on the lines the cursor or selection touches;
    /// again to take them off.
    func toggleList(numbered: Bool) {
        guard let textView else { return }
        let text = textView.text as NSString
        let lines = text.lineRange(for: textView.selectedRange)
        let current = text.substring(with: lines)
        // An empty line (or the end of the text): start the list here.
        if current.trimmingCharacters(in: .newlines).isEmpty {
            let prefix = numbered ? "1. " : "• "
            let at = NSRange(location: lines.location, length: 0)
            textView.textStorage.replaceCharacters(in: at, with: NSAttributedString(string: prefix, attributes: textView.typingAttributes))
            textView.selectedRange = NSRange(location: lines.location + (prefix as NSString).length, length: 0)
            onChange?()
            refresh()
            return
        }
        let rows = current.components(separatedBy: "\n")
        let removing = rows.filter { !$0.isEmpty }.allSatisfy { Self.listPrefix(of: $0, numbered: numbered) != nil }
        var number = 0
        let rebuilt = rows.enumerated().map { index, row -> String in
            if row.isEmpty && index == rows.count - 1 { return row }
            let bare = Self.stripListPrefix(row)
            if removing { return bare }
            number += 1
            return (numbered ? "\(number). " : "• ") + bare
        }.joined(separator: "\n")
        replace(lines, with: rebuilt, in: textView)
        refresh()
    }

    func addLink(_ url: URL, title: String?) {
        guard let textView else { return }
        let range = textView.selectedRange
        var attributes = textView.typingAttributes
        attributes[.link] = url
        let shown = range.length > 0 ? (textView.text as NSString).substring(with: range) : (title?.isEmpty == false ? title! : url.absoluteString)
        textView.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: shown, attributes: attributes))
        textView.selectedRange = NSRange(location: range.location + (shown as NSString).length, length: 0)
        onChange?()
        refresh()
    }

    /// The body as styled runs, for its HTML.
    func runs() -> [RichRun] {
        guard let storage = textView?.textStorage else { return [] }
        var result: [RichRun] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let font = attributes[.font] as? UIFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            result.append(RichRun((storage.string as NSString).substring(with: range),
                                  bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic),
                                  underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                                  strikethrough: (attributes[.strikethroughStyle] as? Int ?? 0) != 0,
                                  link: attributes[.link] as? URL ?? (attributes[.link] as? String).flatMap(URL.init(string:))))
        }
        return result
    }

    func refresh() {
        guard let textView else { return }
        let attributes: [NSAttributedString.Key: Any]
        if textView.selectedRange.length > 0, textView.selectedRange.location < textView.textStorage.length {
            attributes = textView.textStorage.attributes(at: textView.selectedRange.location, effectiveRange: nil)
        } else {
            attributes = textView.typingAttributes
        }
        let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
        isBold = traits.contains(.traitBold)
        isItalic = traits.contains(.traitItalic)
        isUnderline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        isStrikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        let line = (textView.text as NSString).substring(with: (textView.text as NSString).lineRange(for: NSRange(location: textView.selectedRange.location, length: 0)))
        isBulleted = line.hasPrefix("• ")
        isNumbered = Self.listPrefix(of: line, numbered: true) != nil
    }

    private func isOn(_ style: Style) -> Bool {
        switch style {
        case .bold: isBold
        case .italic: isItalic
        case .underline: isUnderline
        case .strikethrough: isStrikethrough
        }
    }

    private func apply(_ style: Style, on: Bool, to attributes: inout [NSAttributedString.Key: Any]) {
        switch style {
        case .bold, .italic:
            let font = attributes[.font] as? UIFont ?? Self.bodyFont
            var traits = font.fontDescriptor.symbolicTraits
            let trait: UIFontDescriptor.SymbolicTraits = style == .bold ? .traitBold : .traitItalic
            if on { traits.insert(trait) } else { traits.remove(trait) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                attributes[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            }
        case .underline:
            attributes[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil
        case .strikethrough:
            attributes[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : nil
        }
    }

    private func replace(_ range: NSRange, with text: String, in textView: UITextView) {
        let attributes = textView.typingAttributes
        textView.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        textView.selectedRange = NSRange(location: range.location + (text as NSString).length - (text.hasSuffix("\n") ? 1 : 0), length: 0)
        onChange?()
    }

    static func listPrefix(of line: String, numbered: Bool) -> String? {
        if numbered {
            return line.patternRange(#"^\d{1,3}\. "#).map { String(line[$0]) }
        }
        return line.hasPrefix("• ") ? "• " : nil
    }

    static func stripListPrefix(_ line: String) -> String {
        if line.hasPrefix("• ") { return String(line.dropFirst(2)) }
        if let match = line.patternRange(#"^\d{1,3}\. "#) { return String(line[match.upperBound...]) }
        return line
    }
}

/// The message itself: a UIKit text view, so it can carry bold, italic,
/// lists and links (SwiftUI's TextEditor holds plain text only). `text`
/// stays the plain words, which everything else uses (signature, quoting,
/// rewrites, snippets); `html` is set only when something is formatted.
struct RichBodyEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var html: String?
    let controller: RichEditorController
    /// Changes only when Compose sets the words itself; the editor takes
    /// `text` from outside then, and never otherwise, so a binding value a
    /// keystroke behind can't be written back over what's being typed.
    var revision: Int
    var isFocused: Bool
    var onFocus: (Bool) -> Void

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichBodyEditor
        /// What the editor last handed out: an update carrying anything
        /// else came from outside. Comparing with the view's own text
        /// instead treated a value a keystroke behind as new, and wrote it
        /// back over what was just typed.
        var lastText: String
        var revision: Int
        init(_ parent: RichBodyEditor) { self.parent = parent; self.lastText = parent.text; self.revision = parent.revision }

        func textViewDidChange(_ textView: UITextView) { publish(textView) }

        func publish(_ textView: UITextView) {
            lastText = textView.text
            if parent.text != textView.text { parent.text = textView.text }
            let html = RichBody.html(parent.controller.runs())
            if parent.html != html { parent.html = html }
            parent.controller.refresh()
        }

        func textViewDidChangeSelection(_ textView: UITextView) { parent.controller.refresh() }
        func textViewDidBeginEditing(_ textView: UITextView) { if !parent.isFocused { parent.onFocus(true) } }
        func textViewDidEndEditing(_ textView: UITextView) { if parent.isFocused { parent.onFocus(false) } }

        /// Return in a list starts the next item; on an empty item, ends
        /// the list, as in Notes and Mail.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText: String) -> Bool {
            guard replacementText == "\n" else { return true }
            let text = textView.text as NSString
            let line = text.substring(with: text.lineRange(for: NSRange(location: range.location, length: 0)))
                .trimmingCharacters(in: .newlines)
            let numbered = RichEditorController.listPrefix(of: line, numbered: true)
            let bullet = RichEditorController.listPrefix(of: line, numbered: false)
            guard let prefix = numbered ?? bullet else { return true }
            let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
            if line == prefix {
                // An empty item: out of the list.
                textView.textStorage.replaceCharacters(in: NSRange(location: lineStart, length: (prefix as NSString).length), with: "")
                textView.selectedRange = NSRange(location: lineStart, length: 0)
            } else {
                let next = numbered.flatMap { Int($0.dropLast(2)) }.map { "\($0 + 1). " } ?? "• "
                let insert = NSAttributedString(string: "\n" + next, attributes: textView.typingAttributes)
                textView.textStorage.replaceCharacters(in: range, with: insert)
                textView.selectedRange = NSRange(location: range.location + insert.length, length: 0)
            }
            publish(textView)
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = PasteTidyTextView()
        view.delegate = context.coordinator
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.font = RichEditorController.bodyFont
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.typingAttributes = [.font: RichEditorController.bodyFont, .foregroundColor: UIColor.label]
        // The text menu's own Bold, Italic and Underline work too.
        view.allowsEditingTextAttributes = true
        view.dataDetectorTypes = []
        // What VoiceOver and Voice Control call it ("Tap Message").
        view.accessibilityLabel = String(localized: "Message")
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.text = text
        controller.textView = view
        controller.onChange = { [weak view, coordinator = context.coordinator] in
            if let view { coordinator.publish(view) }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = view
        // Changed from outside (a rewrite, a snippet, dictation, a new
        // signature): the new words, in the body style.
        if revision != context.coordinator.revision {
            context.coordinator.revision = revision
            let selection = view.selectedRange
            view.attributedText = NSAttributedString(string: text, attributes: [.font: RichEditorController.bodyFont,
                                                                                .foregroundColor: UIColor.label])
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
            context.coordinator.publish(view)
        }
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(260, fitted.height))
    }
}

/// Pasted from a web page or Notes: the words keep their bold, italic,
/// underline, strikethrough and links, in the message's own font and
/// color, never the page's (black text that vanishes in Dark Mode, a
/// 30-point heading in the middle of a sentence).
final class PasteTidyTextView: UITextView {
    override func paste(_ sender: Any?) {
        guard let pasted = Self.pasteboardAttributedString() else {
            super.paste(sender)
            return
        }
        let body = RichEditorController.bodyFont
        let tidy = NSMutableAttributedString(string: pasted.string)
        pasted.enumerateAttributes(in: NSRange(location: 0, length: pasted.length)) { attributes, range, _ in
            let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic]) ?? []
            var kept: [NSAttributedString.Key: Any] = [
                .font: body.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: body.pointSize) } ?? body,
                .foregroundColor: UIColor.label,
            ]
            if let underline = attributes[.underlineStyle] { kept[.underlineStyle] = underline }
            if let strike = attributes[.strikethroughStyle] { kept[.strikethroughStyle] = strike }
            if let link = attributes[.link] { kept[.link] = link }
            tidy.setAttributes(kept, range: range)
        }
        let range = selectedRange
        textStorage.replaceCharacters(in: range, with: tidy)
        selectedRange = NSRange(location: range.location + tidy.length, length: 0)
        delegate?.textViewDidChange?(self)
    }

    private static func pasteboardAttributedString() -> NSAttributedString? {
        let board = UIPasteboard.general
        for (type, documentType) in [("public.rtf", NSAttributedString.DocumentType.rtf), ("public.html", .html)] {
            if let data = board.data(forPasteboardType: type),
               let string = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil) {
                return string
            }
        }
        return nil
    }
}
