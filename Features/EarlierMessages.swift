import SwiftUI

/// The rest of the conversation, above its latest message: each earlier
/// message as a compact row (who, when, first line) that opens in place to
/// its full text. Long conversations fold their middle behind one "N more"
/// row, the way Gmail and Apple Mail do, so the latest message stays close.
struct EarlierMessages: View {
    let messages: [Correspondence]
    let account: String
    @State private var expanded: Set<String> = []
    @State private var showsAll = false
    @Environment(\.displayScale) private var displayScale

    private var visible: [Correspondence] {
        guard !showsAll, messages.count > 4 else { return messages }
        return [messages[0]] + messages.suffix(2)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { index, message in
                if index == 1, !showsAll, messages.count > 4 {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { showsAll = true }
                    } label: {
                        HStack {
                            Text("\(messages.count - 3) more messages")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(CorresPalette.accent)
                            Spacer()
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                                .foregroundStyle(CorresPalette.tertiary)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CorresRowButtonStyle())
                    Hairline(leading: 14)
                }
                row(message)
                if index < visible.count - 1 { Hairline(leading: 14) }
            }
        }
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(CorresPalette.line, lineWidth: 1 / displayScale))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func key(_ message: Correspondence) -> String { message.latestMessageID ?? message.id.providerID }

    private func row(_ message: Correspondence) -> some View {
        let isOpen = expanded.contains(key(message))
        let isMine = message.senderEmail?.lowercased() == account.lowercased()
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                if isOpen { expanded.remove(key(message)) } else { expanded.insert(key(message)) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    CorrespondentAvatar(initials: isMine ? "Y" : message.initials,
                                        size: CGSize(width: 30, height: 30))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(isMine ? "You" : message.sender).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(CorrespondenceRow.timestamp(message.receivedAt))
                                .font(.caption).monospacedDigit().foregroundStyle(CorresPalette.tertiary)
                        }
                        if !isOpen {
                            Text(message.excerpt).font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                        }
                    }
                }
                if isOpen {
                    Text(Self.readableText(message.body))
                        .font(.body).lineSpacing(4)
                        .foregroundStyle(CorresPalette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isOpen ? "Collapses this message" : "Shows the full message")
    }

    /// The message itself, without the quoted history every reply repeats.
    static func readableText(_ body: String) -> String {
        var kept: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(">") { continue }
            if line.range(of: #"^On .+ wrote:\s*$"#, options: .regularExpression) != nil { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
