import Foundation

/// Thread-safe, in-memory holder for the current server URL and tokens.
///
/// This is the single source of truth for credentials at runtime. It replaces
/// storing the auth token in plaintext `UserDefaults`. Values are seeded from the
/// Keychain at launch (see `AuthViewModel.checkExistingSession`) and updated on
/// login / token refresh. Reads are synchronous so views (cover URLs) and the
/// `AVPlayer` setup can access the current access token without `await`.
final class AuthStore: @unchecked Sendable {
    static let shared = AuthStore()

    private let lock = NSLock()
    private var _serverURL: String = ""
    private var _accessToken: String = ""
    private var _refreshToken: String?

    private init() {}

    var serverURL: String { lock.withLock { _serverURL } }
    var accessToken: String { lock.withLock { _accessToken } }
    var refreshToken: String? { lock.withLock { _refreshToken } }

    var isConfigured: Bool {
        lock.withLock { !_serverURL.isEmpty && !_accessToken.isEmpty }
    }

    func set(serverURL: String, accessToken: String, refreshToken: String?) {
        lock.withLock {
            _serverURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            _accessToken = accessToken
            _refreshToken = refreshToken
        }
    }

    func updateTokens(accessToken: String, refreshToken: String?) {
        lock.withLock {
            _accessToken = accessToken
            if let refreshToken { _refreshToken = refreshToken }
        }
    }

    func clear() {
        lock.withLock {
            _serverURL = ""
            _accessToken = ""
            _refreshToken = nil
        }
    }
}
