import SwiftUI
import UIKit

// Shared by Compose and the Share sheet.

/// Lays chips out in lines, wrapping like text; the last view (the text
/// field) takes what's left of its line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                let size = item.size
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                           proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let isLast = index == subviews.indices.last
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let used = rows[rows.count - 1].width + (rows[rows.count - 1].items.isEmpty ? 0 : spacing)
            if isLast {
                // The field fills the rest of the line, or a line of its own.
                let rest = width - used
                if rest < size.width, !rows[rows.count - 1].items.isEmpty { rows.append(Row()) }
                let start = rows[rows.count - 1].width + (rows[rows.count - 1].items.isEmpty ? 0 : spacing)
                size.width = max(size.width, width - start)
            } else if used + size.width > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// An address field that hears Backspace even when it's empty (UIKit's
/// `deleteBackward`), which SwiftUI's TextField doesn't pass on. Focus is
/// kept in step with Compose's own `addressFocus`.
struct AddressTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isFocused: Bool
    var onFocus: (Bool) -> Void
    var onEmptyBackspace: () -> Void
    var onSubmit: () -> Void

    final class Field: UITextField {
        var onEmptyBackspace: (() -> Void)?
        override func deleteBackward() {
            if (text ?? "").isEmpty { onEmptyBackspace?() }
            super.deleteBackward()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressTextField
        init(_ parent: AddressTextField) { self.parent = parent }

        /// What the field last handed out (see RichBodyEditor's).
        var lastText = ""

        @objc func changed(_ field: UITextField) {
            let value = field.text ?? ""
            if value != parent.text { parent.text = value }
            // The binding may have turned it into a chip; show what's left.
            if field.text != parent.text { field.text = parent.text }
            lastText = field.text ?? ""
        }
        func textFieldDidBeginEditing(_ textField: UITextField) { if !parent.isFocused { parent.onFocus(true) } }
        func textFieldDidEndEditing(_ textField: UITextField) { if parent.isFocused { parent.onFocus(false) } }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.keyboardType = .emailAddress
        field.textContentType = .emailAddress
        field.returnKeyType = .next
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.onEmptyBackspace = onEmptyBackspace
        // Only what changed from outside (a chip made, a suggestion picked),
        // never a value a keystroke behind what's typed.
        if text != context.coordinator.lastText, field.text != text {
            field.text = text
            context.coordinator.lastText = text
        }
        if field.placeholder != placeholder {
            field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor.tertiaryLabel])
        }
        // A beat later: becoming first responder while SwiftUI is still
        // laying out is ignored.
        if isFocused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Field, context: Context) -> CGSize? {
        let fitted = uiView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 32))
        return CGSize(width: max(90, fitted.width + 8), height: max(32, fitted.height))
    }
}
