import Foundation
import os
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

    typealias Entry = ServerRulePlan.Entry

    private static let ledgerKey = "corres.serverRules"
    private static let log = Logger(subsystem: "studio.anwarcreative.corres", category: "rules")
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
        // Filters made before this list existed count as Corres's own.
        let kept = ledger.values.flatMap { $0.values.map(\.id) }
        if !Set(kept).isSubset(of: Self.madeIDs) { Self.noteMade(kept) }
    }

    /// Every Gmail filter Corres made, on any of your devices (it follows
    /// you through iCloud). Only one of these is ever adopted, so a filter
    /// you made yourself, however alike, is never taken over or deleted.
    static let madeKey = "corres.serverRuleIDs"
    static var madeIDs: Set<String> { Set(UserDefaults.standard.stringArray(forKey: madeKey) ?? []) }
    static func noteMade(_ ids: [String]) {
        UserDefaults.standard.set(madeIDs.union(ids).sorted(), forKey: madeKey)
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
            // Apart from `pending`, so a later edit cancels only the wait,
            // never an update halfway through its calls.
            Task { await self.update() }
        }
    }

    /// When Corres comes back: tries again for accounts whose last update
    /// failed (offline, or the service was busy).
    func retryIfFailed() {
        if !failedAccounts.isEmpty { schedule() }
    }

    /// How many filters or inbox rules this device made or found in the
    /// account.
    func keptCount(for account: String) -> Int {
        ledger.values.filter { $0[account] != nil }.count
    }

    /// Removed from all your devices: Corres's filters or rules in it are
    /// taken out, while it can still be reached.
    func removeAll(for account: String) async {
        // Every one Corres made there, from any of your devices: this
        // device's record, and what's in the account that carries Corres's
        // mark (its Gmail filters by id, its Outlook rules by name).
        var ids = Set(ledger.values.compactMap { $0[account]?.id })
        let isOutlook = MailAccounts.provider(for: account) == .microsoft
        if isOutlook {
            if let there = try? await outlook.messageRules(account: account) {
                ids.formUnion(there.filter { ($0.displayName ?? "").hasPrefix("Corres · ") }.map(\.id))
            }
        } else if MailAccounts.provider(for: account) == .google {
            if let there = try? await gmail.filters(account: account) {
                let made = Self.madeIDs
                ids.formUnion(there.compactMap(\.id).filter { made.contains($0) })
            }
        } else {
            return
        }
        var failed = Set<String>()
        for id in ids {
            do {
                if isOutlook { try await outlook.deleteMessageRule(id: id, account: account) }
                else { try await gmail.deleteFilter(id: id, account: account) }
            } catch {
                failed.insert(id)
                Self.log.error("Couldn't remove a rule from a removed account: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            }
        }
        // Ones that couldn't be removed stay recorded, so they aren't lost.
        for ruleID in ledger.keys {
            if let entry = ledger[ruleID]?[account], !failed.contains(entry.id) { ledger[ruleID]?[account] = nil }
        }
        save()
    }

    /// Removed from this device: what it kept for the account is forgotten
    /// here; your other devices look after the filters themselves.
    func forget(account: String) {
        var changed = false
        for ruleID in ledger.keys where ledger[ruleID]?[account] != nil {
            ledger[ruleID]?[account] = nil
            changed = true
        }
        if changed { save() }
        needsPermission.remove(account)
        failedAccounts.remove(account)
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

    static var hasGmail: Bool {
        capableAccounts(shared.auth?.accounts.map(\.email) ?? []).contains { MailAccounts.provider(for: $0) == .google }
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
        // Entries for accounts not connected right now are kept: at launch
        // the accounts may not be back yet, and forgetting would leave
        // filters behind that nothing could remove later.
        save()
        needsPermission = lacking
        failedAccounts = failed
    }

    // MARK: Gmail

    private func updateGmail(_ account: String, rules: [MailRule]) async throws {
        var specs: [String: ServerRuleSpec.Gmail] = [:]
        for rule in rules { if let spec = ServerRuleSpec.gmail(for: rule) { specs[rule.id.uuidString] = spec } }
        let wanted = specs.sorted { $0.key < $1.key }.map { ruleID, spec in
            ServerRulePlan.Wanted(ruleID: ruleID, signature: ServerRuleSpec.signature(spec),
                                  keys: [Self.key(spec), Self.key(spec.withoutCategory)])
        }
        for step in ServerRulePlan.removals(wanted: wanted, kept: kept(account)) {
            switch step {
            case .remove(let ruleID, let id):
                // Only Corres's own: a filter of yours that a rule leaned on
                // is let go, never deleted.
                if Self.madeIDs.contains(id) { try await gmail.deleteFilter(id: id, account: account) }
                ledger[ruleID]?[account] = nil
            case .forget(let ruleID):
                ledger[ruleID]?[account] = nil
            case .adopt, .create:
                break
            }
        }
        guard !ServerRulePlan.additions(wanted: wanted, kept: kept(account), existing: []).isEmpty else { return }
        let made = Self.madeIDs
        let all = try await gmail.filters(account: account).compactMap { filter -> ServerRulePlan.Existing? in
            guard let id = filter.id else { return nil }
            return ServerRulePlan.Existing(id: id, key: ServerRulePlan.gmailKey(
                query: filter.criteria.query ?? "", add: filter.action.addLabelIds ?? [], remove: filter.action.removeLabelIds ?? []))
        }
        let existing = all.filter { made.contains($0.id) }
        // Yours, exactly alike: Gmail refuses to make a second, and yours
        // already does the job, so the rule rests on it without owning it.
        let yours = all.filter { !made.contains($0.id) }
        for step in ServerRulePlan.additions(wanted: wanted, kept: kept(account), existing: existing) {
            switch step {
            case .adopt(let ruleID, let id, let signature):
                ledger[ruleID, default: [:]][account] = Entry(id: id, signature: signature)
            case .create(let ruleID, let signature):
                guard let spec = specs[ruleID] else { continue }
                let id: String
                do {
                    id = try await create(spec, account)
                } catch GmailAPIClient.ClientError.badResponse(statusCode: 400)
                            where yours.contains(where: { $0.key == Self.key(spec) }) {
                    let own = yours.first { $0.key == Self.key(spec) }!
                    ledger[ruleID, default: [:]][account] = Entry(id: own.id, signature: signature)
                    continue
                } catch GmailAPIClient.ClientError.badResponse(statusCode: 400) {
                    // Gmail may not let a filter choose a tab; the rest still goes.
                    // Only on that refusal: offline or busy, it's tried again later.
                    let fallback = spec.withoutCategory
                    guard fallback != spec, fallback.hasAction else { throw GmailAPIClient.ClientError.badResponse(statusCode: 400) }
                    id = try await create(fallback, account)
                }
                Self.noteMade([id])
                ledger[ruleID, default: [:]][account] = Entry(id: id, signature: signature)
            case .remove, .forget:
                break
            }
        }
    }

    private func create(_ spec: ServerRuleSpec.Gmail, _ account: String) async throws -> String {
        try await gmail.createFilter(query: spec.query, addLabelIds: spec.addLabelIds, removeLabelIds: spec.removeLabelIds, account: account)
    }

    private static func key(_ spec: ServerRuleSpec.Gmail) -> String {
        ServerRulePlan.gmailKey(query: spec.query, add: spec.addLabelIds, remove: spec.removeLabelIds)
    }

    // MARK: Outlook

    private func updateOutlook(_ account: String, rules: [MailRule]) async throws {
        var specs: [String: ServerRuleSpec.Outlook] = [:]
        for rule in rules { if let spec = ServerRuleSpec.outlook(for: rule) { specs[rule.id.uuidString] = spec } }
        let wanted = specs.sorted { $0.key < $1.key }.map { ruleID, spec in
            ServerRulePlan.Wanted(ruleID: ruleID, signature: ServerRuleSpec.signature(spec), keys: [spec.key])
        }
        for step in ServerRulePlan.removals(wanted: wanted, kept: kept(account)) {
            switch step {
            case .remove(let ruleID, let id):
                try await outlook.deleteMessageRule(id: id, account: account)
                ledger[ruleID]?[account] = nil
            case .forget(let ruleID):
                ledger[ruleID]?[account] = nil
            case .adopt, .create:
                break
            }
        }
        guard !ServerRulePlan.additions(wanted: wanted, kept: kept(account), existing: []).isEmpty else { return }
        let rulesThere = try await outlook.messageRules(account: account)
        let existing = rulesThere.map { rule in
            ServerRulePlan.Existing(id: rule.id, key: ServerRuleSpec.Outlook.key(displayName: rule.displayName ?? "",
                                                                                markAsRead: rule.actions?.markAsRead == true,
                                                                                archive: rule.actions?.moveToFolder != nil))
        }
        var count = rulesThere.count
        for step in ServerRulePlan.additions(wanted: wanted, kept: kept(account), existing: existing) {
            switch step {
            case .adopt(let ruleID, let id, let signature):
                ledger[ruleID, default: [:]][account] = Entry(id: id, signature: signature)
            case .create(let ruleID, let signature):
                guard let spec = specs[ruleID] else { continue }
                count += 1
                let id = try await outlook.createMessageRule(displayName: spec.displayName, condition: spec.condition, phrase: spec.phrase,
                                                             markAsRead: spec.markAsRead, archive: spec.archive,
                                                             sequence: count, account: account)
                ledger[ruleID, default: [:]][account] = Entry(id: id, signature: signature)
            case .remove, .forget:
                break
            }
        }
    }

    /// What this device keeps for one account, by rule.
    private func kept(_ account: String) -> [String: Entry] {
        ledger.compactMapValues { $0[account] }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(ledger), forKey: Self.ledgerKey)
    }
}
