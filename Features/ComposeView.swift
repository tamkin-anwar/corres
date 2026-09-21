import SwiftUI

struct ComposeView: View {
    let store: MailStore
    @State var draft: Draft
    @Environment(\.dismiss) private var dismiss
    @State private var showingDiscardConfirmation = false
    @FocusState private var focusedField: Field?

    private enum Field { case to, subject, body }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    field(title: "To", text: $draft.to, isEditable: draft.kind == .new || draft.kind == .forward)
                        .focused($focusedField, equals: .to)
                    Divider().padding(.leading, CorresSpace.page)
                    field(title: "Subject", text: $draft.subject, isEditable: true)
                        .focused($focusedField, equals: .subject)
                    Divider().padding(.leading, CorresSpace.page)
                    TextEditor(text: $draft.body)
                        .focused($focusedField, equals: .body)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 260)
                        .padding(.horizontal, CorresSpace.page - 5)
                        .padding(.vertical, 12)
                }
                .padding(.vertical, 12)
            }
            .background(CorresPalette.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { attemptDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await sendAndDismiss() } }
                            .disabled(!draft.isSendable)
                            .fontWeight(.semibold)
                    }
                }
            }
            .confirmationDialog("Delete this draft?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
                Button("Delete Draft", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .interactiveDismissDisabled(hasContent)
            .onAppear { focusedField = draft.to.isEmpty ? .to : .body }
        }
    }

    private var title: String {
        switch draft.kind {
        case .new: "New Message"
        case .reply: "Reply"
        case .replyAll: "Reply All"
        case .forward: "Forward"
        }
    }

    private var isSending: Bool { store.sending.contains(draft.id) }
    private var hasContent: Bool {
        !draft.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func attemptDismiss() {
        if hasContent && draft.kind != .forward { showingDiscardConfirmation = true } else { dismiss() }
    }

    private func sendAndDismiss() async {
        if await store.send(draft) { dismiss() }
    }

    private func field(title: String, text: Binding<String>, isEditable: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline).foregroundStyle(CorresPalette.secondary).frame(width: 64, alignment: .leading)
            if isEditable {
                TextField(title == "To" ? "Recipient" : "Subject", text: text)
                    .textInputAutocapitalization(title == "To" ? .never : .sentences)
                    .keyboardType(title == "To" ? .emailAddress : .default)
                    .autocorrectionDisabled(title == "To")
            } else {
                Text(text.wrappedValue).foregroundStyle(CorresPalette.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, CorresSpace.page).frame(minHeight: 44)
    }
}

extension Correspondence {
    func draft(kind: Draft.Kind) -> Draft {
        let quoted = "\n\n—\n\(sender) wrote:\n\(body.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n"))"
        switch kind {
        case .new:
            return Draft(kind: .new, to: "", subject: "")
        case .reply, .replyAll:
            return Draft(kind: kind, threadID: id, to: sender,
                         subject: subject.hasPrefix("Re: ") ? subject : "Re: \(subject)",
                         body: quoted)
        case .forward:
            return Draft(kind: .forward, threadID: id, to: "",
                         subject: subject.hasPrefix("Fwd: ") ? subject : "Fwd: \(subject)",
                         body: quoted)
        }
    }
}
