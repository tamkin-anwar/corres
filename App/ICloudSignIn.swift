import Foundation

/// What an iCloud sign-in accepts, kept apart from the view so it can be
/// tested.
enum ICloudSignIn {
    /// Apple's app-specific passwords: four groups of four lowercase
    /// letters, with or without the dashes.
    static func looksLikeAppPassword(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .wholeMatch(of: /[a-z]{4}-?[a-z]{4}-?[a-z]{4}-?[a-z]{4}/) != nil
    }

    /// The address to sign in with: trimmed and lowercased, with
    /// "@icloud.com" added to a bare name. Nil when it can't be an address.
    static func address(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("@") { return text + "@icloud.com" }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return nil }
        return text
    }

    /// Apple's own domains. Anything else is a custom domain on iCloud+.
    static func isAppleDomain(_ address: String) -> Bool {
        ["icloud.com", "me.com", "mac.com"].contains(address.split(separator: "@").last.map(String.init) ?? "")
    }
}
