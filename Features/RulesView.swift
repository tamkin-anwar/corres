import SwiftUI

/// Settings → Sorting → Rules: what happens to certain mail as it arrives,
/// on every account. One condition, and what to do: as plain as Mail's
/// rules, without the scripting.
struct RulesView: View {
    @State private var editing: MailRule?
    private var organizer: Organizer { .shared }
    private var server: ServerRules { .shared }

    var body: some View {
        List {
            accountsNotice
            if organizer.rules.isEmpty {
                Section {
                    Text("Nothing here yet. A rule acts on mail as it arrives, on every account: into Promotions, out of Needs You, marked read, archived.")
                        .foregroundStyle(CorresPalette.secondary)
                }
            } else {
                Section {
                    ForEach(organizer.rules) { rule in
                        Button { editing = rule } label: { RuleRow(rule: rule) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { organizer.delete(rule: rule.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                            .contextMenu {
                                Button(role: .destructive) { organizer.delete(rule: rule.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                    .onMove { organizer.moveRules(from: $0, to: $1) }
                } footer: {
                    Text("Rules act on mail that arrives after you make them. They run in order, and on this device and your others through iCloud.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // New rules also run in Gmail and Outlook when there's one to run in.
                Button { editing = MailRule(inAccounts: server.hasCapableAccount ? true : nil) } label: {
                    Label("New Rule", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule, isNew: !organizer.rules.contains { $0.id == rule.id })
        }
    }
}

extension RulesView {
    /// Gmail still needs to allow filters, or an account couldn't be
    /// reached: said once, above the rules, with the fix.
    @ViewBuilder
    private var accountsNotice: some View {
        let usesAccounts = organizer.rules.contains { $0.inAccounts == true }
        if usesAccounts, !server.needsPermission.isEmpty {
            Section {
                Button {
                    Task { await server.allowGmail() }
                } label: {
                    Label("Allow Corres to Add Gmail Filters", systemImage: "checkmark.shield")
                }
            } footer: {
                Text("Your rules run in Corres now. Allow this and Gmail runs them too, even with Corres closed: \(server.needsPermission.sorted().joined(separator: ", ")).")
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if usesAccounts, !server.failedAccounts.isEmpty {
            Section {
                Button {
                    Task { await server.update() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
            } footer: {
                Text("Couldn't update the rules in \(server.failedAccounts.sorted().joined(separator: ", ")). They still run in Corres.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RuleRow: View {
    let rule: MailRule

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(rule.summaryCondition)
                .font(.body)
                .foregroundStyle(rule.isEnabled ? CorresPalette.ink : CorresPalette.tertiary)
            Text(rule.summaryActions)
                .font(.subheadline)
                .foregroundStyle(CorresPalette.secondary)
            if rule.inAccounts == true, rule.isEnabled, rule.runsInService {
                Label(String(localized: "Also in \(ServerRules.serviceNames)"), systemImage: "cloud")
                    .font(.caption)
                    .foregroundStyle(CorresPalette.tertiary)
            }
            if !rule.isEnabled { Text("Off").font(.caption).foregroundStyle(CorresPalette.tertiary) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One rule, written as a sentence: when an email is from…, do this.
struct RuleEditor: View {
    @State var rule: MailRule
    let isNew: Bool
    @State private var appliedCount: Int?
    @State private var isApplying = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("When", selection: $rule.field) {
                        Text("From").tag(MailRule.Field.from)
                        Text("To").tag(MailRule.Field.to)
                        Text("Subject").tag(MailRule.Field.subject)
                        Text("Anywhere").tag(MailRule.Field.anywhere)
                    }
                    TextField(rule.field.placeholder, text: $rule.text)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("When an email")
                } footer: {
                    Text("contains these words, ignoring case. Several words must all appear.")
                }
                Section("Do This") {
                    Picker("Needs You", selection: $rule.attention) {
                        Text("Corres decides").tag(Attention?.none)
                        Text("Always Needs You").tag(Attention?.some(.needsYou))
                        Text("Never Needs You").tag(Attention?.some(.quiet))
                    }
                    Picker("Category", selection: $rule.category) {
                        Text("Corres decides").tag(InboxCategory?.none)
                        ForEach(InboxCategory.allCases, id: \.self) { category in
                            Text(category.title).tag(InboxCategory?.some(category))
                        }
                    }
                    Toggle("Mark as Read", isOn: $rule.markRead)
                    Toggle("Flag", isOn: $rule.flag)
                    Toggle("Archive", isOn: $rule.archive)
                }
                if ServerRules.shared.hasCapableAccount {
                    Section {
                        Toggle(String(localized: "Also in \(ServerRules.serviceNames)"), isOn: Binding(
                            get: { rule.inAccounts == true && rule.runsInService },
                            set: { rule.inAccounts = $0 }))
                            .disabled(!rule.runsInService)
                    } footer: {
                        Text(serviceFooter).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if rule.archive && rule.attention == .needsYou {
                    Section {
                        Label("Archived mail leaves Needs You, so it won't be seen there.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(CorresPalette.secondary)
                    }
                }
                Section {
                    Toggle("On", isOn: $rule.isEnabled)
                    if rule.isUsable {
                        Button {
                            Task {
                                isApplying = true
                                Organizer.shared.save(rule)
                                appliedCount = await Organizer.shared.applyToExisting(rule)
                                isApplying = false
                            }
                        } label: {
                            HStack {
                                Text("Apply to Mail Already Here")
                                Spacer()
                                if isApplying { ProgressView() }
                            }
                        }
                        .disabled(isApplying)
                    }
                } footer: {
                    if let appliedCount {
                        Text(appliedCount == 1 ? "Applied to 1 conversation." : "Applied to \(appliedCount) conversations.")
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete Rule", role: .destructive) {
                            Organizer.shared.delete(rule: rule.id)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Rule" : "Edit Rule")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Organizer.shared.save(rule)
                        dismiss()
                    }
                    .disabled(!rule.isUsable)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}

extension RuleEditor {
    /// What the service does with this rule, and what stays in Corres.
    private var serviceFooter: String {
        let names = ServerRules.serviceNames
        guard rule.runsInService else {
            return String(localized: "Nothing in this rule can run in \(names): Needs You is Corres's own.")
        }
        var parts = [String(localized: "This runs in \(names) too, even with Corres closed and on the web. Deleting the rule here removes it there.")]
        if rule.attention != nil { parts.append(String(localized: "Needs You stays in Corres.")) }
        if ServerRules.hasOutlook, rule.flag || rule.category != nil {
            parts.append(String(localized: "Outlook can mark as read and archive, not flag or choose a tab."))
        }
        return parts.joined(separator: " ")
    }
}

extension MailRule {
    /// Whether any part of the rule is something Gmail or Outlook can do.
    var runsInService: Bool {
        var probe = self
        probe.isEnabled = true
        return ServerRuleSpec.gmail(for: probe) != nil || ServerRuleSpec.outlook(for: probe) != nil
    }
}

extension MailRule.Field {
    var placeholder: String {
        switch self {
        case .from: String(localized: "A name, address or company, like amazon.com")
        case .to: String(localized: "An address you receive at")
        case .subject: String(localized: "Words in the subject")
        case .anywhere: String(localized: "Words anywhere in the email")
        }
    }
}

extension MailRule {
    /// "From amazon.com", as a list shows it.
    var summaryCondition: String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return switch field {
        case .from: String(localized: "From \u{201C}\(words)\u{201D}")
        case .to: String(localized: "To \u{201C}\(words)\u{201D}")
        case .subject: String(localized: "Subject has \u{201C}\(words)\u{201D}")
        case .anywhere: String(localized: "Mentions \u{201C}\(words)\u{201D}")
        }
    }

    /// "Updates · Mark as Read · Archive".
    var summaryActions: String {
        var parts: [String] = []
        if attention == .needsYou { parts.append(String(localized: "Always Needs You")) }
        if attention == .quiet { parts.append(String(localized: "Never Needs You")) }
        if let category { parts.append(category.title) }
        if markRead { parts.append(String(localized: "Mark as Read")) }
        if flag { parts.append(String(localized: "Flag")) }
        if archive { parts.append(String(localized: "Archive")) }
        return parts.joined(separator: " · ")
    }
}
