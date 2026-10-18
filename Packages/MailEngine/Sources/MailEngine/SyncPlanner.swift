import Foundation

/// What Corres remembers about a folder between syncs. The IMAP equivalent
/// of Gmail's history id.
public struct FolderSyncState: Sendable, Equatable, Codable {
    /// Changes when the server renumbers the folder; every stored UID for it
    /// is then meaningless.
    public var uidValidity: UInt32
    /// The UID the next new message will get, as of the last sync.
    public var uidNext: UInt32
    /// The folder's change counter (CONDSTORE servers only).
    public var highestModSeq: UInt64?
    /// The oldest UID Corres has fetched, for "load older".
    public var oldestFetchedUID: UInt32?

    public init(uidValidity: UInt32, uidNext: UInt32, highestModSeq: UInt64? = nil, oldestFetchedUID: UInt32? = nil) {
        self.uidValidity = uidValidity; self.uidNext = uidNext
        self.highestModSeq = highestModSeq; self.oldestFetchedUID = oldestFetchedUID
    }
}

/// What a SELECT reported.
public struct SelectedFolder: Sendable, Equatable {
    public let uidValidity: UInt32
    public let uidNext: UInt32
    public let exists: Int
    public let highestModSeq: UInt64?
    public init(uidValidity: UInt32, uidNext: UInt32, exists: Int, highestModSeq: UInt64?) {
        self.uidValidity = uidValidity; self.uidNext = uidNext; self.exists = exists; self.highestModSeq = highestModSeq
    }
}

/// Decides, from what's stored and what the server just said, the cheapest
/// way to bring a folder up to date.
public enum SyncPlanner {
    public enum Plan: Sendable, Equatable {
        /// First sync, or the server renumbered the folder: fetch the newest
        /// `limit` headers and start over. Anything stored for this folder is
        /// dropped by the caller.
        case full(newest: Int)
        /// Fetch headers of new UIDs (`from` through the end), and flag
        /// changes since `changedSince` (CONDSTORE) or for every known UID
        /// (otherwise, in batches).
        case incremental(newFrom: UInt32?, changedSince: UInt64?, checkFlagsOfKnown: Bool)
        /// Nothing new and nothing changed.
        case upToDate
    }

    public static let firstSyncLimit = 200

    public static func plan(stored: FolderSyncState?, selected: SelectedFolder, capabilities: Capabilities) -> Plan {
        guard let stored, stored.uidValidity == selected.uidValidity else {
            return .full(newest: firstSyncLimit)
        }
        let hasNew = selected.uidNext > stored.uidNext
        if capabilities.condstore, let modSeq = stored.highestModSeq, let current = selected.highestModSeq {
            if !hasNew && current == modSeq { return .upToDate }
            return .incremental(newFrom: hasNew ? stored.uidNext : nil,
                                changedSince: current != modSeq ? modSeq : nil,
                                checkFlagsOfKnown: false)
        }
        // No change counter (iCloud reportedly, some others): new mail by
        // UID, and read/flag changes by comparing flags of what's stored.
        return .incremental(newFrom: hasNew ? stored.uidNext : nil, changedSince: nil, checkFlagsOfKnown: true)
    }
}
