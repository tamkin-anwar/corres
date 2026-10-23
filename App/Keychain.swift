import Foundation
import Security

/// Minimal Keychain wrapper for exactly one job: storing a per-account OAuth
/// refresh token string. GoogleSignIn's own Keychain-backed session store
/// (see GmailAccount's doc comment, ADR 005) only ever remembers one signed-in
/// user at a time; true simultaneous multi-account requires Corres to hold
/// its own refresh token per connected account, which is what this and
/// GoogleTokenProvider exist for. No dependency beyond the Security
/// framework: a token this small and single-purpose doesn't need a
/// third-party wrapper.
///
/// Kept in the App Group's keychain group, so the Share extension can send
/// as the same accounts (an App Group is also a keychain access group on
/// iOS; no other app can read it). Tokens saved before sharing existed sit
/// in the app's own group and are moved over by `share(key:)`.
enum Keychain {
    static let sharedGroup = "group.studio.anwarcreative.corres"
    /// Where the iCloud Keychain copy lives: the app's own identifier,
    /// which the iPhone, iPad and Mac apps share (one App ID).
    static let syncGroup = "7GGTC43CG8.studio.anwarcreative.corres"

    /// The Mac's modern keychain, the same kind iOS has, so nothing ever
    /// asks for the login keychain's password. Ignored on iOS.
    private static var modern: [String: Any] { [kSecUseDataProtectionKeychain as String: true] }

    static func set(_ value: String, key: String) {
        let data = Data(value.utf8)
        setSynced(data, key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ].merging(modern) { $1 }
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // Available as soon as the device is unlocked once after boot, and
        // stays available in the background: needed for background push /
        // BGAppRefreshTask token refreshes, which can run before the person
        // has unlocked the device this session.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var shared = attributes
        shared[kSecAttrAccessGroup as String] = sharedGroup
        // Never lose a sign-in: if the shared group is refused, keep it
        // where it always was (sharing just waits).
        if SecItemAdd(shared as CFDictionary, nil) != errSecSuccess {
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    /// Moves a token saved before sharing existed into the shared group:
    /// the shared copy is added first, and the old one removed only once
    /// that worked, so a sign-in is never lost on the way.
    static func share(key: String) {
        let inShared: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: sharedGroup,
        ]
        guard SecItemCopyMatching(inShared as CFDictionary, nil) == errSecItemNotFound,
              let value = get(key: key) else { return }
        var added = inShared
        added[kSecValueData as String] = Data(value.utf8)
        added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { return }
        // Every other copy of it (the app's own group) goes.
        let all: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var found: AnyObject?
        guard SecItemCopyMatching(all as CFDictionary, &found) == errSecSuccess,
              let items = found as? [[String: Any]] else { return }
        for item in items {
            guard let group = item[kSecAttrAccessGroup as String] as? String, group != sharedGroup else { continue }
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecAttrAccessGroup as String: group,
            ] as CFDictionary)
        }
    }

    static func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ].merging(modern) { $1 }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            syncOnce(data, key: key)
            return String(data: data, encoding: .utf8)
        }
        // Signed in on another of your devices: its iCloud Keychain copy.
        return getSynced(key: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Removes the sign-in here, and with `everywhere` from your other
    /// devices too. Removed from this device only, the iCloud Keychain copy
    /// stays for the devices still using it.
    static func delete(key: String, everywhere: Bool = true) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ].merging(modern) { $1 }
        SecItemDelete(query as CFDictionary)
        if everywhere { SecItemDelete(syncedQuery(key: key) as CFDictionary) }
    }

    // MARK: iCloud Keychain

    nonisolated(unsafe) private static var checkedSync: Set<String> = []
    private static let checkLock = NSLock()

    /// Sign-ins saved before syncing existed get their iCloud copy the
    /// first time they're read, once per key per launch.
    private static func syncOnce(_ data: Data, key: String) {
        checkLock.lock()
        let first = checkedSync.insert(key).inserted
        checkLock.unlock()
        guard first, getSynced(key: key) == nil else { return }
        setSynced(data, key: key)
    }

    /// A copy in iCloud Keychain, end-to-end encrypted by Apple, so your
    /// accounts are signed in on your other devices too. Corres's servers
    /// never see it. With iCloud Keychain off, it simply stays here.
    static func setSynced(_ data: Data, key: String) {
        let query = syncedQuery(key: key)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func getSynced(key: String) -> Data? {
        var query = syncedQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func syncedQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "corres.synced",
            kSecAttrAccessGroup as String: syncGroup,
            kSecAttrSynchronizable as String: true,
        ].merging(modern) { $1 }
    }
}
