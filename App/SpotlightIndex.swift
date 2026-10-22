import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import os

/// Corres in Spotlight: your conversations turn up in Search on the Home
/// Screen (and in Spotlight on the Mac), and open straight to the
/// conversation, as Mail's do. The index is the system's own, kept on this
/// device; Settings can turn it off, which empties it.
@MainActor
final class SpotlightIndex {
    static let shared = SpotlightIndex()

    static let enabledKey = "corres.spotlight"
    static var isEnabled: Bool {
        #if DEBUG
        // Screenshots run on sample mail beside a real Corres: hands off its index.
        if ProcessInfo.processInfo.arguments.contains("-SampleMailOnly") { return false }
        #endif
        return UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The newest conversations, enough for years of most people's mail.
    static let limit = 5_000

    nonisolated private static let indexName = "corres.mail"
    private var index: CSSearchableIndex { CSSearchableIndex(name: Self.indexName) }
    private var pending: Task<Void, Never>?
    private var working = false
    private static let log = Logger(subsystem: "studio.anwarcreative.corres", category: "spotlight")

    /// What's in the index, and as of when, so each pass only sends what
    /// changed: a new reply moves a conversation's date, a loaded body
    /// adds its full text.
    private var indexed: [String: Int] = [:]
    private var loadedIndexed = false
    private var stateURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("spotlight-index.json")
    }

    /// After the mail changes; a burst of changes makes one pass.
    func scheduleUpdate(_ threads: @escaping @MainActor () -> [Correspondence]) {
        guard Self.isEnabled else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await update(threads())
        }
    }

    func update(_ threads: [Correspondence]) async {
        guard Self.isEnabled, !working else { return }
        working = true
        defer { working = false }
        loadState()
        let current = Array(threads.lazy.filter { thread in
            thread.id.account != "sample" && !thread.labelIds.contains("TRASH") && !thread.labelIds.contains("SPAM")
        }.sorted { $0.receivedAt > $1.receivedAt }.prefix(Self.limit))
        var wanted: [String: Int] = [:]
        var changed: [Correspondence] = []
        for thread in current {
            let key = Self.key(thread.id)
            let stamp = Self.stamp(thread)
            wanted[key] = stamp
            if indexed[key] != stamp { changed.append(thread) }
        }
        let gone = indexed.keys.filter { wanted[$0] == nil }
        guard !changed.isEmpty || !gone.isEmpty else { return }
        let removed = Array(gone)
        do {
            try await Task.detached(priority: .utility) { try await Self.send(changed, removing: removed) }.value
            indexed = wanted
            saveState()
            Self.log.info("Spotlight: \(changed.count) indexed, \(removed.count) removed, \(wanted.count) in all")
        } catch {
            Self.log.error("Spotlight indexing failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Off the main thread: building thousands of items is real work.
    nonisolated private static func send(_ threads: [Correspondence], removing gone: [String]) async throws {
        let index = CSSearchableIndex(name: indexName)
        if !gone.isEmpty { try await index.deleteSearchableItems(withIdentifiers: gone) }
        for start in stride(from: 0, to: threads.count, by: 500) {
            try await index.indexSearchableItems(threads[start..<min(start + 500, threads.count)].map(item))
        }
    }

    /// Settings turned it off, or an account was removed.
    func removeAll() async {
        pending?.cancel()
        try? await index.deleteAllSearchableItems()
        indexed = [:]
        loadedIndexed = true
        saveState()
    }

    func forget(account: String) async {
        try? await index.deleteSearchableItems(withDomainIdentifiers: [account.lowercased()])
        loadState()
        indexed = indexed.filter { !$0.key.lowercased().hasPrefix(account.lowercased() + "|") }
        saveState()
    }

    /// The conversation a Spotlight result opens.
    static func threadID(from activity: NSUserActivity) -> ThreadID? {
        guard let key = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let bar = key.firstIndex(of: "|") else { return nil }
        return ThreadID(account: String(key[..<bar]), providerID: String(key[key.index(after: bar)...]))
    }

    // MARK: Items

    nonisolated private static func key(_ id: ThreadID) -> String { id.account + "|" + id.providerID }

    nonisolated private static func stamp(_ thread: Correspondence) -> Int {
        Int(thread.receivedAt.timeIntervalSince1970) * 2 + (thread.isBodyLoaded ? 1 : 0)
    }

    nonisolated private static func item(_ thread: Correspondence) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .emailMessage)
        let subject = thread.subject.isEmpty ? String(localized: "No subject") : thread.subject
        attributes.title = subject
        attributes.displayName = subject
        attributes.subject = subject
        attributes.contentDescription = thread.sender + " · " + thread.excerpt.previewText
        attributes.authorNames = [thread.sender]
        if let email = thread.senderEmail { attributes.authorEmailAddresses = [email] }
        attributes.recipientNames = thread.toRecipients + thread.ccRecipients
        attributes.contentCreationDate = thread.receivedAt
        attributes.contentModificationDate = thread.receivedAt
        if !thread.organization.isEmpty { attributes.keywords = [thread.organization] }
        // The words of the email, once it's been read here, so Spotlight
        // finds it by what it says, not only by its subject.
        if thread.isBodyLoaded { attributes.textContent = String(thread.body.prefix(4_000)) }
        let item = CSSearchableItem(uniqueIdentifier: key(thread.id), domainIdentifier: thread.id.account.lowercased(),
                                    attributeSet: attributes)
        item.expirationDate = .distantFuture
        // The same email as Siri knows it, so a question about your mail
        // can find it by meaning and act on it.
        if #available(iOS 18.0, macOS 15.0, *) { attributes.associateAppEntity(CorresMailMessage(thread)) }
        return item
    }

    // MARK: State

    private func loadState() {
        guard !loadedIndexed else { return }
        loadedIndexed = true
        if let url = stateURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) {
            indexed = saved
        }
    }

    private func saveState() {
        guard let url = stateURL, let data = try? JSONEncoder().encode(indexed) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
