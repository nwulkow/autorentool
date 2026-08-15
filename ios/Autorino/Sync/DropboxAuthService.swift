import Foundation
import AuthenticationServices
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Dropbox OAuth 2.0 with PKCE — no client secret, safe to embed in a
/// public mobile client. Uses `ASWebAuthenticationSession` for the
/// browser hop and stores tokens in the Keychain via `KeychainService`.
@MainActor
final class DropboxAuthService: NSObject, ObservableObject {
    @Published private(set) var isConnected: Bool = false
    @Published var lastError: String?

    private var pendingCodeVerifier: String?
    private var webAuthSession: ASWebAuthenticationSession?
    private var presentationAnchor: ASPresentationAnchor?

    override init() {
        super.init()
        isConnected = KeychainService.get(.dropboxRefreshToken) != nil
    }

    var accessToken: String? { KeychainService.get(.dropboxAccessToken) }

    // MARK: - Sign in

    func startAuth() {
        guard let appKey = DropboxConfig.appKey else {
            lastError = "Add your Dropbox App Key in Settings before connecting — see README-iOS.md."
            return
        }
        let verifier = Self.randomURLSafeString(length: 64)
        pendingCodeVerifier = verifier
        let challenge = Self.codeChallenge(for: verifier)

        var components = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "redirect_uri", value: DropboxConfig.redirectURI),
        ]
        guard let authURL = components.url else { return }

        // Callback scheme is everything before "://" in the redirect URI, e.g. "db-abc123".
        let scheme = DropboxConfig.redirectURI.components(separatedBy: "://").first

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { [weak self] callbackURL, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    if (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        self.lastError = error.localizedDescription
                    }
                    return
                }
                guard let callbackURL else { return }
                await self.finishAuth(callbackURL: callbackURL)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        webAuthSession = session
        session.start()
    }

    /// Fallback path: if the OS hands the redirect to the app via
    /// `onOpenURL` instead of the session's own completion handler (can
    /// happen if the app was backgrounded mid-flow), finish auth from here.
    func handleRedirect(url: URL) {
        guard pendingCodeVerifier != nil, url.absoluteString.hasPrefix(DropboxConfig.redirectURI) else { return }
        Task { await finishAuth(callbackURL: url) }
    }

    private func finishAuth(callbackURL: URL) async {
        defer { pendingCodeVerifier = nil }
        guard let verifier = pendingCodeVerifier,
              let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
            lastError = "Dropbox sign-in did not return an authorization code."
            return
        }
        do {
            try await exchangeCodeForToken(code: code, verifier: verifier)
            isConnected = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func exchangeCodeForToken(code: String, verifier: String) async throws {
        guard let appKey = DropboxConfig.appKey else { throw DropboxAuthError.notConnected }
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = [
            "code": code,
            "grant_type": "authorization_code",
            "client_id": appKey,
            "code_verifier": verifier,
            "redirect_uri": DropboxConfig.redirectURI,
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        let token = try JSONDecoder().decode(DropboxTokenResponse.self, from: data)
        KeychainService.set(token.accessToken, for: .dropboxAccessToken)
        if let refresh = token.refreshToken {
            KeychainService.set(refresh, for: .dropboxRefreshToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 14400))
        KeychainService.set(ISO8601DateFormatter().string(from: expiry), for: .dropboxTokenExpiry)
    }

    /// Called by `DropboxClient` before each request; refreshes the access
    /// token if it's expired or about to expire.
    func validAccessToken() async throws -> String {
        if let expiryString = KeychainService.get(.dropboxTokenExpiry),
           let expiry = ISO8601DateFormatter().date(from: expiryString),
           expiry > Date().addingTimeInterval(60),
           let token = KeychainService.get(.dropboxAccessToken) {
            return token
        }
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = KeychainService.get(.dropboxRefreshToken) else {
            throw DropboxAuthError.notConnected
        }
        guard let appKey = DropboxConfig.appKey else { throw DropboxAuthError.notConnected }
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": appKey,
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        let token = try JSONDecoder().decode(DropboxTokenResponse.self, from: data)
        KeychainService.set(token.accessToken, for: .dropboxAccessToken)
        let expiry = Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 14400))
        KeychainService.set(ISO8601DateFormatter().string(from: expiry), for: .dropboxTokenExpiry)
        return token.accessToken
    }

    func disconnect() {
        KeychainService.delete(.dropboxAccessToken)
        KeychainService.delete(.dropboxRefreshToken)
        KeychainService.delete(.dropboxTokenExpiry)
        isConnected = false
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DropboxAuthError.requestFailed(body)
        }
    }

    // MARK: - PKCE helpers

    private static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension DropboxAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let activeWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return activeWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

private struct DropboxTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

enum DropboxAuthError: LocalizedError {
    case notConnected
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Dropbox."
        case .requestFailed(let body): return "Dropbox request failed: \(body)"
        }
    }
}
