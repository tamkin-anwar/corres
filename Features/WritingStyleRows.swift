import SwiftUI

/// Settings › Composing: "Write Replies Like Me", and what Corres has
/// learned from your sent mail, in plain words, so what it does with your
/// writing is never a mystery.
struct WritingStyleRows: View {
    @AppStorage(WritingStyleBook.enabledKey) private var enabled = true
    @State private var style: WritingStyle?

    var body: some View {
        Group { rows }
            // Read when shown, from the mail already on this device.
            .task(id: enabled) { style = WritingStyleBook.shared.summary() }
    }

    @ViewBuilder private var rows: some View {
        Toggle("Write Replies Like Me", isOn: $enabled)
        if enabled {
            if let style {
                if let greeting = style.greeting {
                    LabeledContent("Greeting", value: greeting.isEmpty ? String(localized: "None, straight in") : greeting.replacingOccurrences(of: "{name}", with: String(localized: "Name")))
                }
                if let signOff = style.signOff { LabeledContent("Sign-Off", value: signOff) }
                LabeledContent("Usual Length") { Text("About \(style.typicalWords) words") }
            } else {
                Text("Corres learns your greeting, sign-off and length once you've sent a few more emails.")
                    .font(.footnote).foregroundStyle(CorresPalette.secondary)
            }
        }
    }
}
