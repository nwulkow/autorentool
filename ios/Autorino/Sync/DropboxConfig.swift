import Foundation

/// Dropbox App Key is entered once at runtime (Settings → Dropbox Sync)
/// and kept in the Keychain — not hardcoded here, so the repo stays
/// generic and the key can be rotated without a rebuild.
///
/// The URL scheme, by contrast, *must* be baked into `Info.plist` at build
/// time (`ios/project.yml`'s `CFBundleURLTypes`), because iOS registers
/// `CFBundleURLSchemes` from the bundle at install time, before any
/// runtime code runs. It does not need to be derived from the app key —
/// any reserved, unique scheme works — so `project.yml` uses a fixed
/// `db-autorino` scheme that never needs to change. Register the matching
/// `db-autorino://oauth2redirect` as a Redirect URI in the Dropbox App
/// Console once, and it stays valid even if you rotate the key later. Full
/// walkthrough in README-iOS.md.
enum DropboxConfig {
    static var appKey: String? {
        let value = KeychainService.get(.dropboxAppKey)
        return (value?.isEmpty ?? true) ? nil : value
    }
    static let redirectURI = "db-autorino://oauth2redirect"
    static var isConfigured: Bool { appKey != nil }
}
