import Foundation

/// Lists are built once per change to the mail, with every conversation in,
/// and the few waiting out Undo (or already removed) are taken out after:
/// a swipe or ⌘⌫ then filters the rows a list already has instead of
/// filtering and sorting the whole mailbox again.
public enum ListExclusion {
    /// `rows` less the conversations in `excluded` (`id` is nil for a
    /// heading). A heading left with nothing under it goes. With
    /// `pairedHeadings` (Needs You's "Due soon" and "When you can", shown
    /// only while both have mail), a heading left on its own goes too, so
    /// the list reads as it would built without them.
    public static func rows<Row>(_ rows: [Row], leaving excluded: Set<ThreadID>, id: (Row) -> ThreadID?,
                                 pairedHeadings: Bool = false) -> [Row] {
        guard !excluded.isEmpty else { return rows }
        var kept: [Row] = []
        kept.reserveCapacity(rows.count)
        var heading: Row?
        var headings = 0
        for row in rows {
            guard let rowID = id(row) else {
                // Kept only once a conversation under it is.
                heading = row
                continue
            }
            if excluded.contains(rowID) { continue }
            if let pending = heading {
                kept.append(pending)
                headings += 1
                heading = nil
            }
            kept.append(row)
        }
        if pairedHeadings, headings == 1 { kept.removeAll { id($0) == nil } }
        return kept
    }

    /// The same for a plain list of conversations.
    public static func threads(_ threads: [Correspondence], leaving excluded: Set<ThreadID>) -> [Correspondence] {
        excluded.isEmpty ? threads : threads.filter { !excluded.contains($0.id) }
    }
}
