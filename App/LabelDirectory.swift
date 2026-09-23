import Foundation
import Observation

/// The mapping from Gmail's raw label ids (all `Correspondence.labelIds`
/// ever carries) to their human names, fetched once from Gmail's labels
/// catalog rather than per-message: `GmailAPIClient.fetchUserLabels` is the
/// only place that actually distinguishes a real, user-created label from
/// one of Gmail's own system ones (INBOX, UNREAD, SENT, CATEGORY_*, ...),
/// since a per-message `labelIds` list carries no type info of its own.
@MainActor @Observable
final class LabelDirectory {
    private(set) var labels: [GmailUserLabel] = []
    private(set) var isLoading = false
    private let client = GmailAPIClient()

    /// Best-effort, deliberately silent on failure: a label chip or the
    /// "Labels" toggle menu just shows nothing new if this fails, not a
    /// scary error banner over what is, from the person's point of view, an
    /// ordinary background refresh they never asked for directly.
    func refreshIfConnected(account: String?) async {
        guard account != nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        labels = (try? await client.fetchUserLabels()) ?? labels
    }

    func name(for labelId: String) -> String? {
        labels.first { $0.id == labelId }?.name
    }
}
