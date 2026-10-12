import Foundation

/// Everyone who has emailed you, one row each, for Settings → Senders:
/// where an allow, a block or a subscription can be changed later. HEY's
/// Screener History lists only who you screened out; Gmail's blocked list
/// is web-only; iOS keeps blocked contacts under Privacy & Security.
public struct SenderSummary: Identifiable, Hashable, Sendable {
    public let email: String
    public let account: String
    public var name: String
    public var count: Int
    public var unread: Int
    public var lastReceived: Date
    public var decision: SenderDecision
    /// Sends with an unsubscribe link: a newsletter, a store, a service.
    public var isList: Bool
    public var isUnsubscribed: Bool
    public var id: String { account + "|" + email }
}

public enum SenderDirectory {
    public enum Filter: String, CaseIterable, Sendable {
        case all, allowed, blocked, new, subscriptions
    }

    public enum Order: String, CaseIterable, Sendable { case recent, most, name }

    /// One summary per sender and account, from mail on this iPhone; your
    /// own messages aren't a sender.
    public static func summaries(_ threads: [Correspondence]) -> [SenderSummary] {
        var byKey: [String: SenderSummary] = [:]
        for thread in threads where !thread.isFromAccountOwner && thread.id.account != "sample" {
            guard let raw = thread.senderEmail, !raw.isEmpty else { continue }
            let email = raw.lowercased()
            let key = thread.id.account + "|" + email
            let isList = thread.listUnsubscribeMailto != nil || thread.listUnsubscribeURL != nil
            if var existing = byKey[key] {
                existing.count += 1
                existing.unread += thread.isUnread ? 1 : 0
                existing.isList = existing.isList || isList
                existing.isUnsubscribed = existing.isUnsubscribed || thread.senderUnsubscribed
                if thread.receivedAt > existing.lastReceived {
                    existing.lastReceived = thread.receivedAt
                    existing.name = thread.sender
                    // The newest decision is the current one.
                    existing.decision = thread.senderDecision
                }
                byKey[key] = existing
            } else {
                byKey[key] = SenderSummary(email: email, account: thread.id.account, name: thread.sender, count: 1,
                                           unread: thread.isUnread ? 1 : 0, lastReceived: thread.receivedAt,
                                           decision: thread.senderDecision, isList: isList,
                                           isUnsubscribed: thread.senderUnsubscribed)
            }
        }
        return Array(byKey.values)
    }

    public static func filtered(_ senders: [SenderSummary], _ filter: Filter, search: String = "",
                                order: Order = .recent) -> [SenderSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let kept = senders.filter { sender in
            let fits: Bool = switch filter {
            case .all: true
            case .allowed: sender.decision == .approved
            case .blocked: sender.decision == .blocked
            case .new: sender.decision == .pending
            case .subscriptions: sender.isList && sender.decision != .blocked
            }
            return fits && (query.isEmpty || sender.name.localizedStandardContains(query) || sender.email.localizedStandardContains(query))
        }
        return kept.sorted { a, b in
            switch order {
            case .recent: return a.lastReceived != b.lastReceived ? a.lastReceived > b.lastReceived : a.email < b.email
            case .most: return a.count != b.count ? a.count > b.count : a.lastReceived > b.lastReceived
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}
