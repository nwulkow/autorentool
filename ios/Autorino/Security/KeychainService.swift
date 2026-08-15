import Foundation
import Security

/// Minimal generic-password Keychain wrapper. Replaces `.env`/
/// `GEMINI_API_KEY` parsing and gives Dropbox tokens a safer home than
/// UserDefaults/plain files.
enum KeychainService {
    private static let service = "com.autorino.app"

    enum Key: String {
        case geminiAPIKey = "gemini_api_key"
        case dropboxAccessToken = "dropbox_access_token"
        case dropboxRefreshToken = "dropbox_refresh_token"
        case dropboxTokenExpiry = "dropbox_token_expiry"
        case dropboxAccountId = "dropbox_account_id"
        case dropboxAppKey = "dropbox_app_key"
    }

    static func set(_ value: String, for key: Key) {
        let data = Data(value.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
