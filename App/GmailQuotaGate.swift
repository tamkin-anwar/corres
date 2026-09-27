import Foundation

/// Gmail allows each user 250 quota units per second, and a message fetch
/// costs 5. Sync, body backfill, older-mail paging, and search each paced
/// themselves independently, so together they could spend the whole
/// allowance, and a change the person made (mark read, archive, flag)
/// arriving in that second was refused with a 403 "user rate limit
/// exceeded", found live as "Could not mark this conversation as read".
///
/// One token bucket per account, shared by every background fetch, keeps
/// that traffic at 200 units per second so the remaining 50 are always
/// free for what the person just did. Changes don't wait on it.
actor GmailQuotaGate {
    static let shared = GmailQuotaGate()

    static let unitsPerMessageFetch = 5
    private static let capacity = 250.0
    private static let refillPerSecond = 200.0

    private var buckets: [String: (units: Double, updated: ContinuousClock.Instant)] = [:]
    private let clock = ContinuousClock()

    /// Waits until `units` can be spent for `account` in the background budget.
    func reserve(_ units: Int, for account: String) async {
        let cost = min(Double(units), Self.capacity)
        while true {
            let now = clock.now
            var bucket = buckets[account] ?? (Self.capacity, now)
            let elapsed = bucket.updated.duration(to: now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            bucket.units = min(Self.capacity, bucket.units + seconds * Self.refillPerSecond)
            bucket.updated = now
            if bucket.units >= cost {
                bucket.units -= cost
                buckets[account] = bucket
                return
            }
            buckets[account] = bucket
            let wait = (cost - bucket.units) / Self.refillPerSecond
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 10))
        }
    }
}
