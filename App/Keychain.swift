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
enum Keychain {
    static func set(_ value: String, key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // Available as soon as the device is unlocked once after boot, and
        // stays available in the background: needed for background push /
        // BGAppRefreshTask token refreshes, which can run before the person
        // has unlocked the device this session.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
