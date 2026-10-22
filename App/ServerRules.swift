import Foundation
import Observation

/// Keeps a Gmail filter and an Outlook inbox rule for each Corres rule set
/// to run in your accounts (`MailRule.inAccounts`), so it works with
/// Corres closed and on Gmail's and Outlook's own websites. See
/// `ServerRuleSpec` for what goes over.
///
/// Each device remembers which filters it made or found for which rule.
/// Before making one it looks for an identical filter, so two devices
/// never make the same one twice; a rule changed or deleted on any device
/// has its copies replaced or removed by the next device to look.
@MainActor @Observable
final class ServerRules {
    static let shared = ServerRules()

    /// Gmail accounts that haven't allowed Corres to manage filters yet.
    private(set) var needsPermission: Set<String> = []
    /// Accounts whose last attempt failed (offline, or the service said no).
    private(set) var failedAccounts: Set<String> = []
    private(set) var isUpdating = false

    struct Entry: Codable, Equatable {
        var id: String
        var signature: String
    }

    private static let ledgerKey = "corres.serverRules"
    /// Rule id → account → the filter or rule kept for it.
    @ObservationIgnored private var ledger: [String: [String: Entry]]
    @ObservationIgnored private weak var auth: GoogleAuthService?
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// A change made while an update was running: one more pass after.
    @ObservationIgnored private var updateAgain = false
    @ObservationIgnored private let gmail = GmailAPIClient()
    @ObservationIgnored private let outlook = OutlookClient()

    private init() {
        ledger = UserDefaults.standard.data(forKey: Self.ledgerKey)
            .flatMap { try? JSONDecoder().decode([String: [String: Entry]].self, from: $0) } ?? [:]
    }

    /// Called once at launch.
    func attach(auth: GoogleAuthService) {
        self.auth = auth
        schedule()
    }

    /// After a moment, so a burst of edits makes one round of changes.
    func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await update()
        }
    }

    /// Whether any connected account can run rules itself.
    var hasCapableAccount: Bool { !Self.capableAccounts(auth?.accounts.map(\.email) ?? []).isEmpty }

    /// "Gmail", "Outlook" or "Gmail and Outlook": the services you have.
    static var serviceNames: String {
        let accounts = capableAccounts(shared.auth?.accounts.map(\.email) ?? [])
        let gmail = accounts.contains { MailAccounts.provider(for: $0) == .google }
        let outlook = accounts.contains { MailAccounts.provider(for: $0) == .microsoft }
        switch (gmail, outlook) {
        case (true, true): return String(localized: "Gmail and Outlook")
        case (false, true): return String(localized: "Outlook")
        default: return String(localized: "Gmail")
        }
    }

    static var hasOutlook: Bool {
        capableAccounts(shared.auth?.accounts.map(\.email) ?? []).contains { MailAccounts.provider(for: $0) == .microsoft }
    }

    static func capableAccounts(_ accounts: [String]) -> [String] {
        accounts.filter { [.google, .microsoft].contains(MailAccounts.provider(for: $0)) }
    }

    /// Asks Google for filter permission on each Gmail account still
    /// without it, then brings the filters up to date.
    func allowGmail() async {
        guard let auth else { return }
        for account in needsPermission.sorted() {
            _ = await auth.grantSettings(for: account)
        }
        await update()
    }

    func update() async {
        guard let auth else { return }
        guard !isUpdating else { updateAgain = true; return }
        isUpdating = true
        defer {
            isUpdating = false
            if updateAgain { updateAgain = false; schedule() }
        }
        let rules = Organizer.shared.rules
        var lacking = Set<String>()
        var failed = Set<String>()
        for account in Self.capableAccounts(auth.accounts.map(\.email)) {
            let wanted = rules.filter { $0.inAccounts == true }
            let hasWork = !wanted.isEmpty || ledger.values.contains { $0[account] != nil }
            guard hasWork else { continue }
            if MailAccounts.provider(for: account) == .google, !(await auth.canManageSettings(account)) {
                if !wanted.isEmpty { lacking.insert(account) }
                continue
            }
            do {
                if MailAccounts.provider(for: account) == .google {
                    try await updateGmail(account, rules: wanted)
                } else {
                    try await updateOutlook(account, rules: wanted)
                }
            } catch {
                failed.insert(account)
            }
        }
        // Forget accounts that were removed.
        let connected = Set(auth.accounts.map(\.email))
        for (rule, accounts) in ledger {
            ledger[rule] = accounts.filter { connected.contains($0.key) }
            if ledger[rule]?.isEmpty == true { ledger[rule] = nil }
        }
        save()
        needsPermission = lacking
        failedAccounts = failed
    }

    // MARK: Gmail

    private func updateGmail(_ account: String, rules: [MailRule]) async throws {
        var desired: [String: ServerRuleSpec.Gmail] = [:]
        for rule in rules { if let spec = ServerRuleSpec.gmail(for: rule) { desired[rule.id.uuidString] = spec } }
        // Out of date or no longer wanted: removed.
        for (ruleID, accounts) in ledger {
            guard let entry = accounts[account] else { continue }
            if let spec = desired[ruleID], ServerRuleSpec.signature(spec) == entry.signature { continue }
            try await gmail.deleteFilter(id: entry.id, account: account)
            ledger[ruleID]?[account] = nil
        }
        let missing = desired.filter { ledger[$0.key]?[account] == nil }
        guard !missing.isEmpty else { return }
        // Made already, by another device: kept, not made twice.
        var existing = try await gmail.filters(account: account)
        for (ruleID, spec) in missing {
            let signature = ServerRuleSpec.signature(spec)
            if let match = existing.first(where: { Self.matches($0, spec) || Self.matches($0, spec.withoutCategory) }), let id = match.id {
                ledger[ruleID, default: [:]][account] = Entry(id: id, signature: signature)
                existing.removeAll { $0.id == id }
                continue
            }
            let id: String
            do {
                id = try await create(spec, account)
            } catch {
                // Gmail may not let a filter choose a tab; the rest still goes.
                let fallback = spec.withoutCategory
                guard fallback != spec, fallback.hasAction else { throw error }
                id = try await create(fallback, account)
            }
            ledger[ruleID, default: [:]][account] = Entry(id: id, signature: signature)
        }
    }

    private func create(_ spec: ServerRuleSpec.Gmail, _ account: String) async throws -> String {
        try await gmail.createFilter(query: spec.query, addLabelIds: spec.addLabelIds, removeLabelIds: spec.removeLabelIds, account: account)
    }

    private static func matches(_ filter: GmailAPIClient.Filter, _ spec: ServerRuleSpec.Gmail) -> Bool {
        filter.criteria.query == spec.query
            && Set(filter.action.addLabelIds ?? []) == Set(spec.addLabelIds)
            && Set(filter.action.removeLabelIds ?? []) == Set(spec.removeLabelIds)
    }

    // MARK: Outlook

    private func updateOutlook(_ account: String, rules: [MailRule]) async throws {
        var desired: [String: ServerRuleSpec.Outlook] = [:]
        for rule in rules { if let spec = ServerRuleSpec.outlook(for: rule) { desired[rule.id.uuidString] = spec } }
        for (ruleID, accounts) in ledger {
            guard let entry = accounts[account] else { continue }
            if let spec = desired[ruleID], ServerRuleSpec.signature(spec) == entry.signature { continue }
            try await outlook.deleteMessageRule(id: entry.id, account: account)
            ledger[ruleID]?[account] = nil
        }
        let missing = desired.filter { ledger[$0.key]?[account] == nil }
        guard !missing.isEmpty else { return }
        var existing = try await outlook.messageRules(account: account)
        for (ruleID, spec) in missing {
            let signature = ServerRuleSpec.signature(spec)
            if let match = existing.first(where: { $0.displayName == spec.displayName }) {
                ledger[ruleID, default: [:]][account] = Entry(id: match.id, signature: signature)
                existing.removeAll { $0.id == match.id }
                continue
            }
            let id = try await outlook.createMessageRule(displayName: spec.displayName, condition: spec.condition, phrase: spec.phrase,
                                                         markAsRead: spec.markAsRead, archive: spec.archive,
                                                         sequence: existing.count + 1, account: account)
            existing.append(OutlookClient.MessageRule(id: id, displayName: spec.displayName))
            ledger[ruleID, default: [:]][account] = Entry(id: id, signature: signature)
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(ledger), forKey: Self.ledgerKey)
    }
}
