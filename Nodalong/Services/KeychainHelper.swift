import Foundation
import Security

/// Minimal Keychain wrapper for storing small strings (OAuth tokens) — no new
/// dependency, just the `Security` framework. Used by `SpotifyMusicService` for
/// access/refresh token storage (deliberately Keychain-only, not Firestore —
/// see the Spotify integration plan's decisions log).
///
/// Device-scoped by design: a reinstall or new device requires re-linking.
enum KeychainHelper {
    /// Writes `value` under `account` (upserts — deletes any existing item
    /// first so this is safe to call repeatedly, e.g. on token refresh).
    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Reads the string stored under `account`, or `nil` if absent.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes whatever is stored under `account`, if anything.
    static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static let service = "com.bigdeccyh.nodalong.keychain"
}
