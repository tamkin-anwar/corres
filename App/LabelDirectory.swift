import Foundation
import Observation

/// The mapping from Gmail's raw label ids (all `Correspondence.labelIds`
/// ever carries) to their human names, fetched once per connected account
/// from that account's own labels catalog rather than per-message:
/// `GmailAPIClient.fetchUserLabels` is the only place that actually
/// distinguishes a real, user-created label from one of Gmail's own system
/// ones (INBOX/UNREAD/SENT/CATEGORY_*, ...), since a per-message `labelIds`
/// list carries no type info of its own. Scoped per account (Batch 29):
/// two different Gmail accounts have entirely different custom labels, and
/// a label id from one account means nothing in another.
@MainActor @Observable
final class LabelDirectory {
    private(set) var labelsByAccount: [String: [GmailUserLabel]] = [:]
    private(set) var isLoading = false
    private let client = GmailAPIClient()

    /// Best-effort, deliberately silent on failure: a label chip or the
    /// "Labels" toggle menu just shows nothing new if this fails, not a
    /// scary error banner over what is, from the person's point of view, an
    /// ordinary background refresh they never asked for directly.
    func refreshIfConnected(accounts: [String]) async {
        guard !accounts.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await withTaskGroup(of: (String, [GmailUserLabel]?).self) { group in
            for account in accounts {
                group.addTask { (account, try? await self.client.fetchUserLabels(account: account)) }
            }
            for await (account, fetched) in group {
                if let fetched { labelsByAccount[account] = fetched }
            }
        }
    }

    func labels(for account: String) -> [GmailUserLabel] { labelsByAccount[account] ?? [] }

    func name(for labelId: String, account: String) -> String? {
        labels(for: account).first { $0.id == labelId }?.name
    }
}
