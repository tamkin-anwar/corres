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
    /// How many messages the folder held, as of the last sync. Nil in
    /// state saved before it was kept.
    public var exists: Int?

    public init(uidValidity: UInt32, uidNext: UInt32, highestModSeq: UInt64? = nil, oldestFetchedUID: UInt32? = nil,
                exists: Int? = nil) {
        self.uidValidity = uidValidity; self.uidNext = uidNext
        self.highestModSeq = highestModSeq; self.oldestFetchedUID = oldestFetchedUID
        self.exists = exists
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
        /// (otherwise, in batches). Without QRESYNC nothing reports a
        /// removal, so a caller that wants those compares the known UIDs
        /// either way.
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
            // Without QRESYNC a server needn't move the counter when a
            // message is expunged, so a different count (or none stored)
            // means look again, even with the counter where it was.
            let sameCount = stored.exists == selected.exists
            if !hasNew && current == modSeq && sameCount { return .upToDate }
            return .incremental(newFrom: hasNew ? stored.uidNext : nil,
                                changedSince: current != modSeq ? modSeq : nil,
                                checkFlagsOfKnown: !sameCount && current == modSeq)
        }
        // No change counter (iCloud reportedly, some others): new mail by
        // UID, and read/flag changes by comparing flags of what's stored.
        return .incremental(newFrom: hasNew ? stored.uidNext : nil, changedSince: nil, checkFlagsOfKnown: true)
    }
}

/// Which known messages changed since the last check, from one FETCH FLAGS
/// over them: how a sync notices mail read, flagged or removed elsewhere
/// without QRESYNC (which iCloud's handling of can't be relied on). Only
/// read and flagged are compared; no other flag changes what Corres shows.
public enum FlagChanges {
    /// Read (1) and flagged (2), as kept between syncs.
    public static let flagBits: UInt8 = 0b11

    public static func code(_ flags: Set<String>) -> UInt8 {
        var code: UInt8 = 0
        for flag in flags {
            switch flag.lowercased() {
            case "\\seen": code |= 1
            case "\\flagged": code |= 2
            default: break
            }
        }
        return code
    }

    public struct Result: Sendable, Equatable {
        /// Still in the folder, and read or flagged differs from what was
        /// kept (or nothing was kept for it).
        public var changed: [UInt32]
        /// Known, but no longer in the folder.
        public var vanished: [UInt32]
        /// What to keep for next time, for every known UID still there.
        public var codes: [UInt32: UInt8]
    }

    /// `previous` nil means nothing was kept (an older cursor, or a check
    /// that reports everything on purpose): every message still there
    /// counts as changed. Bits above `flagBits` are the caller's own; they
    /// aren't compared and are carried over as they were.
    public static func compare(known: [UInt32], previous: [UInt32: UInt8]?, current: [UInt32: Set<String>]) -> Result {
        var result = Result(changed: [], vanished: [], codes: [:])
        for uid in known.sorted() {
            guard let flags = current[uid] else {
                result.vanished.append(uid)
                continue
            }
            let old = previous?[uid]
            let code = self.code(flags) | ((old ?? 0) & ~flagBits)
            result.codes[uid] = code
            if old.map({ $0 & flagBits }) != code & flagBits { result.changed.append(uid) }
        }
        return result
    }
}
