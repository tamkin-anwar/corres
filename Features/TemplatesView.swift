import SwiftUI

/// Settings → Composing → Templates: text you send often, a tap away while
/// writing. `{first name}` becomes the recipient's as it goes in.
struct TemplatesView: View {
    @State private var editing: MailTemplate?
    private var organizer: Organizer { .shared }

    var body: some View {
        List {
            if organizer.templates.isEmpty {
                Section {
                    Text("Nothing here yet. Save replies you write often, like directions, a thank-you or a meeting link, and add one from Templates while you write.")
                        .foregroundStyle(CorresPalette.secondary)
                }
            } else {
                Section {
                    ForEach(organizer.templates) { template in
                        Button { editing = template } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(template.displayName).foregroundStyle(CorresPalette.ink)
                                Text(template.body.replacingOccurrences(of: "\n", with: " "))
                                    .font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(2)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { organizer.delete(template: template.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button(role: .destructive) { organizer.delete(template: template.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    .onMove { organizer.moveTemplates(from: $0, to: $1) }
                } footer: {
                    Text("On this device and your others through iCloud.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Templates")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = MailTemplate() } label: { Label("New Template", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { template in
            TemplateEditor(template: template, isNew: !organizer.templates.contains { $0.id == template.id })
        }
    }
}

struct TemplateEditor: View {
    @State var template: MailTemplate
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, like Directions or Thanks", text: $template.name)
                } footer: {
                    Text("Only you see the name, when choosing a template.")
                }
                Section {
                    TextField("Subject (optional)", text: $template.subject)
                } footer: {
                    Text("Used only when the email has no subject yet.")
                }
                Section {
                    TextEditor(text: $template.body)
                        .frame(minHeight: 160)
                    Button {
                        template.body += (template.body.isEmpty || template.body.hasSuffix(" ") || template.body.hasSuffix("\n") ? "" : " ")
                            + MailTemplate.firstNameToken
                    } label: {
                        Label("Insert First Name", systemImage: "person.text.rectangle")
                    }
                } header: {
                    Text("Text")
                } footer: {
                    Text("\(MailTemplate.firstNameToken) becomes the recipient's first name as the template goes in, or is left out if there's no name to use.")
                }
                if !isNew {
                    Section {
                        Button("Delete Template", role: .destructive) {
                            Organizer.shared.delete(template: template.id)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Template" : "Edit Template")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Organizer.shared.save(template)
                        dismiss()
                    }
                    .disabled(template.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }
}

/// Templates while writing: pick one, or save what you've written as one.
struct TemplateMenuItems: View {
    /// The recipient's name, for {first name}.
    let recipientName: String?
    let currentSubject: String
    let currentBody: String
    let insert: (_ subject: String?, _ body: String) -> Void

    var body: some View {
        let organizer = Organizer.shared
        ForEach(organizer.templates) { template in
            Button(template.displayName) {
                let filled = template.filled(recipientName: recipientName)
                insert(filled.subject.isEmpty ? nil : filled.subject, filled.body)
            }
        }
        if !organizer.templates.isEmpty { Divider() }
        Button {
            let trimmed = currentBody.trimmingCharacters(in: .whitespacesAndNewlines)
            Organizer.shared.save(MailTemplate(name: currentSubject.isEmpty ? String(trimmed.prefix(30)) : currentSubject,
                                               subject: currentSubject, body: trimmed))
        } label: {
            Label("Save as Template", systemImage: "square.and.arrow.down")
        }
        .disabled(currentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

extension MailTemplate {
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(body.prefix(30)) : trimmed
    }
}
