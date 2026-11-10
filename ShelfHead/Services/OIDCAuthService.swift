import AuthenticationServices
import CryptoKit
import UIKit

/// Handles the "Sign in with SSO" flow against an Audiobookshelf server's OpenID
/// Connect (OIDC) support.
///
/// Corrected implementation: Audiobookshelf's `/auth/openid` endpoint is a standard
/// OAuth2 authorization request — it does NOT hand tokens back directly on a redirect
/// to the client's callback scheme. The documented contract requires PKCE (S256) and
/// four parameters (`code_challenge`, `redirect_uri`, `client_id`, `state`); the server
/// redirects to the identity provider, the identity provider eventually redirects back
/// to this app's callback scheme carrying `code` and `state` (not a token), and a
/// second request — `GET /auth/openid/callback?state=&code=&code_verifier=` — performs
/// the actual token exchange and returns the user object (with `user.token`).
///
/// The tricky part: `/auth/openid/callback` is stateful — Audiobookshelf sets a cookie
/// during the initial `/auth/openid` request that must be sent back on the callback
/// request. `ASWebAuthenticationSession` owns its own browser cookie jar that this
/// app's `URLSession` can't read, so the ABS-facing leg of this flow (the initiation
/// request and the token exchange) is done with a dedicated `URLSession`/cookie jar
/// of this app's own, and `ASWebAuthenticationSession` is used only for the identity
/// provider leg — the part that actually needs an interactive browser and that this
/// app has no business seeing credentials for.
///
/// Flow:
/// 1. Generate a PKCE verifier/challenge and a random `state`.
/// 2. `GET {server}/auth/openid?...` on our own `URLSession` (own cookie jar, redirects
///    followed manually) — same-host redirects (e.g. a reverse proxy upgrading http to
///    https) are replayed on this same session so the cookie lands in our jar; the
///    first redirect that leaves the server's host is treated as the identity
///    provider's URL.
/// 3. Present that identity-provider URL in `ASWebAuthenticationSession`, catching the
///    final redirect back to our own `shelfhead-oidc://oauth` callback scheme.
/// 4. Verify `state` matches, extract `code`.
/// 5. `GET {server}/auth/openid/callback?state=&code=&code_verifier=` on the *same*
///    `URLSession`/cookie jar as step 2, so the session cookie set there is replayed.
/// 6. Decode the returned user object for `token`/`refreshToken`.
///
/// Because steps 2 and 5 are plain `URLRequest`s (not owned by `ASWebAuthenticationSession`),
/// `applyCustomHeaders()` works on both — a server behind a reverse-proxy header gate
/// can use SSO *and* that header together, as long as the identity-provider's own login
/// page (step 3, the only part still running in the system browser) doesn't itself sit
/// behind the same proxy.
enum OIDCAuthService {
    /// ShelfHead's own callback scheme, distinct from the official app's `audiobookshelf://`
    /// so both can be registered as separate "Allowed Mobile Redirect URIs" on the same
    /// server without colliding.
    static let callbackScheme = "shelfhead-oidc"
    /// The host component of the callback URL (`shelfhead-oidc://oauth` — "oauth" is
    /// the host here, not a path segment, since a custom-scheme URL with no further
    /// slashes parses that way). Broken out as its own constant so
    /// `extractAuthorizationCode` can validate the callback's shape independently of
    /// `callbackURLString`, which is only used to build the `redirect_uri` sent to the
    /// server and to word the `.noCodeInCallback` error message.
    private static let callbackHost = "oauth"
    private static let callbackURLString = "\(callbackScheme)://\(callbackHost)"
    /// Sent as `client_id`. Audiobookshelf's docs note this parameter is currently
    /// unused server-side but may become mandatory — sending a stable, recognizable
    /// value now costs nothing and avoids a future breakage.
    private static let clientId = "ShelfHead-iOS"

    enum OIDCError: Error, LocalizedError {
        case invalidServerURL
        case cancelled
        case sessionFailed(String)
        case noAuthorizationRedirect
        case stateMismatch
        case noCodeInCallback
        case tokenExchangeFailed(String)
        case unexpectedCallbackURL
        case randomGenerationFailed
        case insecureRedirect
        /// Polish pass (J1-5): the server itself couldn't be reached (TLS, timeout, DNS,
        /// refused) on the initiation or token-exchange leg. Carries the `URLError` so
        /// `AuthViewModel.signInErrorMessage` can say which, instead of the raw
        /// `localizedDescription` `sessionFailed`/`tokenExchangeFailed` used to show.
        case connectionFailed(URLError)

        var errorDescription: String? {
            switch self {
            case .insecureRedirect:
                return String(localized: "The server redirected to an unencrypted (http://) address mid sign-in. Sign-in was stopped to avoid sending your session over an unencrypted connection.")
            case .invalidServerURL:
                return String(localized: "Enter a valid server address first.")
            case .cancelled:
                return nil // User-initiated cancel — don't show an error toast for this.
            case .sessionFailed(let message):
                return String(localized: "SSO sign-in failed: \(message)", comment: "%@ is the failure reason")
            case .noAuthorizationRedirect:
                return String(localized: "The server didn't start the sign-in flow as expected. Confirm OIDC/SSO is enabled under Audiobookshelf's Authentication settings.")
            case .stateMismatch:
                return String(localized: "SSO sign-in failed a security check (state mismatch). Please try again.")
            case .noCodeInCallback:
                return String(localized: "The server didn't return an authorisation code after sign-in. Make sure this app's redirect URI (\(callbackURLString)) is added to Audiobookshelf's Allowed Mobile Redirect URIs.", comment: "%@ is the redirect URI")
            case .tokenExchangeFailed(let message):
                return String(localized: "SSO sign-in failed while completing sign-in: \(message)", comment: "%@ is the failure reason")
            case .unexpectedCallbackURL:
                return String(localized: "SSO sign-in failed a security check (unexpected callback address). Please try again.")
            case .randomGenerationFailed:
                return String(localized: "SSO sign-in failed to generate a secure random value. Please try again.")
            case .connectionFailed:
                return String(localized: "Can\u{2019}t reach your server. Check your connection and try again.")
            }
        }
    }

    /// The tokens Audiobookshelf's OIDC callback exchange handed back. Mirrors the
    /// two-token (access + refresh) shape the native `/login` endpoint also returns —
    /// see `LoginResponse` — so the result can be fed into the same `AuthStore`/Keychain
    /// plumbing as a password login.
    struct Result {
        let accessToken: String
        let refreshToken: String?
    }

    /// Launches the system SSO sign-in sheet and resolves once the identity provider
    /// redirects back and the token exchange completes. Must be called from the main
    /// actor (presents UI).
    @MainActor
    static func signIn(serverURL: String, customHeaders: [String: String]) async throws -> Result {
        let trimmed = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: trimmed), baseURL.scheme != nil, baseURL.host != nil else {
            throw OIDCError.invalidServerURL
        }

        // Both throw if the system CSPRNG (`SecRandomCopyBytes`) reports failure — see
        // `randomBytes(count:)` below for why this must fail closed instead of silently
        // proceeding with a predictable, zero-filled verifier/state.
        let verifier = try makeCodeVerifier()
        let challenge = codeChallenge(for: verifier)
        let state = try makeState()

        // A dedicated, ephemeral `URLSession` for this sign-in attempt only — `.ephemeral`
        // already provisions its own private, in-memory cookie jar (assigning a bare
        // `HTTPCookieStorage()` on top is both redundant and not a documented way to get
        // a working independent store, so this relies on `.ephemeral`'s own jar instead).
        // The ABS session cookie set on the initiation request needs to be replayed on
        // the token-exchange request later — using the same session instance for both is
        // what makes that happen — and none of it should leak into the app's other
        // networking. Explicitly invalidated once this function returns, since a strong
        // delegate reference would otherwise leak the session per sign-in attempt.
        let redirectBlocker = NoRedirectSessionDelegate()
        let urlSession = URLSession(configuration: .ephemeral, delegate: redirectBlocker, delegateQueue: nil)
        defer { urlSession.finishTasksAndInvalidate() }

        var initiationComponents = URLComponents(
            url: baseURL.appendingPathComponent("auth/openid"), resolvingAgainstBaseURL: false
        )
        initiationComponents?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: callbackURLString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let initiationURL = initiationComponents?.url else {
            throw OIDCError.invalidServerURL
        }

        // Follows redirects ourselves, on our own cookie-carrying session, for as long as
        // they stay on the server's own host — a reverse proxy upgrading a plain-http
        // entry to https (or ABS's own internal redirects) is common and must still flow
        // through this session so the ABS session cookie lands in our jar, not the
        // browser's. Only once a redirect actually leaves the server's host is it treated
        // as the identity provider and handed to `ASWebAuthenticationSession`. Capped to
        // guard against a pathological redirect loop.
        var initiationRequest = URLRequest(url: initiationURL)
        initiationRequest.applyCustomHeaders(customHeaders)
        // Polish pass (J1-4): 20 s, not URLSession's 60 s default (`AudiobookshelfAPI.signInTimeout`).
        initiationRequest.timeoutInterval = AudiobookshelfAPI.signInTimeout
        let identityProviderURL: URL
        do {
            var currentRequest = initiationRequest
            var resolved: URL?
            for _ in 0..<5 {
                let (_, response) = try await urlSession.data(for: currentRequest)
                guard let http = response as? HTTPURLResponse,
                      (300..<400).contains(http.statusCode),
                      let location = http.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: currentRequest.url)?.absoluteURL else {
                    throw OIDCError.noAuthorizationRedirect
                }
                // SEC-2: a server reached over HTTPS that redirects to a *plain HTTP*
                // address — same host or not — must be treated as a hard failure, not
                // followed. Without this, `isExternalRedirect`'s host-only comparison
                // judges `http://books.example.com` "same host, not external" when
                // reached via `https://books.example.com`, and the loop below replays
                // the request (with `applyCustomHeaders(customHeaders)` attached — a
                // reverse-proxy service secret such as a Cloudflare Access/Authelia
                // token) on that unencrypted connection. `NSAllowsArbitraryLoads = true`
                // means ATS won't stop it either. An HTTP→HTTPS *upgrade* (the
                // documented reverse-proxy case above) stays allowed — only the
                // downgrade is rejected.
                guard !isSchemeDowngrade(from: currentRequest.url?.scheme, to: next.scheme) else {
                    throw OIDCError.insecureRedirect
                }
                if isExternalRedirect(next, relativeToServerHost: baseURL.host) {
                    resolved = next
                    break
                }
                var nextRequest = URLRequest(url: next)
                nextRequest.applyCustomHeaders(customHeaders)
                nextRequest.timeoutInterval = AudiobookshelfAPI.signInTimeout   // Polish pass (J1-4)
                currentRequest = nextRequest
            }
            guard let resolved else { throw OIDCError.noAuthorizationRedirect }
            identityProviderURL = resolved
        } catch let error as OIDCError {
            throw error
        } catch let error as URLError {
            throw OIDCError.connectionFailed(error)   // Polish pass (J1-5)
        } catch {
            throw OIDCError.sessionFailed(error.localizedDescription)
        }

        let presentationProvider = PresentationContextProvider()
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: identityProviderURL, callbackURLScheme: callbackScheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                    return
                }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: OIDCError.cancelled)
                } else {
                    continuation.resume(throwing: OIDCError.sessionFailed(error?.localizedDescription ?? String(localized: "Unknown error")))
                }
            }
            session.presentationContextProvider = presentationProvider
            // SEC-5: `false` shares the SSO cookie with Safari's persistent jar, so
            // after `logout()` tapping "Sign in with SSO" again silently
            // re-authenticates as the same user with no prompt — on a shared or
            // handed-over device, "Sign Out" doesn't actually let anyone else sign in
            // as themselves, and the departing user's IdP session can be resumed by
            // anyone with the phone unlocked. `true` costs a re-login each time, which
            // is an acceptable tradeoff for an app whose own sessions are long-lived.
            session.prefersEphemeralWebBrowserSession = true
            if !session.start() {
                continuation.resume(throwing: OIDCError.sessionFailed(String(localized: "Couldn't start the sign-in sheet.")))
            }
        }

        let code = try extractAuthorizationCode(from: callbackURL, expectedState: state)

        var exchangeComponents = URLComponents(
            url: baseURL.appendingPathComponent("auth/openid/callback"), resolvingAgainstBaseURL: false
        )
        exchangeComponents?.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        guard let exchangeURL = exchangeComponents?.url else {
            throw OIDCError.tokenExchangeFailed(String(localized: "Couldn't build the token exchange request."))
        }
        var exchangeRequest = URLRequest(url: exchangeURL)
        exchangeRequest.applyCustomHeaders(customHeaders)
        exchangeRequest.timeoutInterval = AudiobookshelfAPI.signInTimeout   // Polish pass (J1-4)

        let data: Data
        do {
            let (responseData, response) = try await urlSession.data(for: exchangeRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw OIDCError.tokenExchangeFailed(String(localized: "The server rejected the token exchange."))
            }
            data = responseData
        } catch let error as OIDCError {
            throw error
        } catch let error as URLError {
            throw OIDCError.connectionFailed(error)   // Polish pass (J1-5)
        } catch {
            throw OIDCError.tokenExchangeFailed(error.localizedDescription)
        }

        // Same response shape as the native `/login` endpoint — `{ "user": { "token"/
        // "accessToken"/"refreshToken": ... } }` — so `LoginResponse` decodes it as-is.
        guard let decoded = try? JSONDecoder().decode(LoginResponse.self, from: data),
              let accessToken = decoded.user.effectiveAccessToken, !accessToken.isEmpty else {
            throw OIDCError.tokenExchangeFailed(String(localized: "The server didn't return a session token."))
        }
        return Result(accessToken: accessToken, refreshToken: decoded.user.refreshToken)
    }

    // MARK: - Redirect / callback validation (pure, unit-tested)

    /// Whether `redirectURL` has left the server's own host — the signal used to decide
    /// a redirect from `/auth/openid` is the identity provider (hand off to the system
    /// browser) rather than a same-host hop (e.g. a reverse proxy's http→https upgrade,
    /// which must be followed on this app's own cookie-carrying session instead). A
    /// `nil` `serverHost` (shouldn't happen — `signIn` already validates the server URL
    /// has a host before this is ever called) is treated as "always external," since
    /// there's nothing to compare against.
    static func isExternalRedirect(_ redirectURL: URL, relativeToServerHost serverHost: String?) -> Bool {
        guard let serverHost else { return true }
        return redirectURL.host != serverHost
    }

    /// Whether following a redirect from `currentScheme` to `nextScheme` would
    /// downgrade the connection from HTTPS to plain HTTP (SEC-2). Compared
    /// case-insensitively. An HTTP→HTTPS upgrade, or staying on HTTP throughout (a
    /// legitimately plain-HTTP self-hosted server, already gated elsewhere by
    /// `AuthViewModel.requiresInsecureConnectionConfirmation`), is not a downgrade.
    static func isSchemeDowngrade(from currentScheme: String?, to nextScheme: String?) -> Bool {
        currentScheme?.lowercased() == "https" && nextScheme?.lowercased() != "https"
    }

    /// Validates the final redirect back to this app's callback scheme: the callback
    /// URL's own scheme and host must match `shelfhead-oidc://oauth` exactly, the
    /// `state` query parameter must match what was sent on the initiation request
    /// (CSRF/session-fixation protection), and a non-empty `code` must be present.
    /// Returns the authorization code on success.
    ///
    /// The scheme/host check is defense-in-depth, not the primary guard:
    /// `ASWebAuthenticationSession` is constructed with `callbackURLScheme:
    /// callbackScheme`, so the OS itself already filters out any redirect that isn't on
    /// our scheme before this function ever sees it. But relying solely on that means
    /// this function's own contract is unstated and effectively untestable against a
    /// malformed/wrong-shaped URL — checking it explicitly here makes the validation
    /// this function performs self-contained, and guards against any future caller that
    /// might feed it a URL from somewhere other than `ASWebAuthenticationSession`.
    static func extractAuthorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard callbackURL.scheme?.lowercased() == callbackScheme.lowercased(),
              callbackURL.host == callbackHost else {
            throw OIDCError.unexpectedCallbackURL
        }
        guard let callbackItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
            throw OIDCError.noCodeInCallback
        }
        guard let returnedState = callbackItems.first(where: { $0.name == "state" })?.value,
              returnedState == expectedState else {
            throw OIDCError.stateMismatch
        }
        guard let code = callbackItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OIDCError.noCodeInCallback
        }
        return code
    }

    // MARK: - PKCE (pure, unit-tested)

    /// A cryptographically random verifier, per RFC 7636 §4.1: 43–128 characters from
    /// the unreserved URL-safe alphabet. 32 random bytes, base64url-encoded, yields 43.
    /// Throws `.randomGenerationFailed` if the system CSPRNG reports failure — see
    /// `randomBytes(count:)`.
    static func makeCodeVerifier() throws -> String {
        base64URLEncode(try randomBytes(count: 32))
    }

    /// `challenge = BASE64URL(SHA256(verifier))`, per RFC 7636 §4.2 (S256 method).
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    /// A random `state` value for CSRF/session-fixation protection, and the mechanism
    /// `/auth/openid/mobile-redirect` uses server-side to resolve which client redirect
    /// URI to send the user back to. Throws `.randomGenerationFailed` if the system
    /// CSPRNG reports failure — see `randomBytes(count:)`.
    static func makeState() throws -> String {
        base64URLEncode(try randomBytes(count: 16))
    }

    /// `SecRandomCopyBytes` almost always succeeds on iOS, but "almost always" isn't
    /// good enough here: on failure it leaves the output buffer as whatever it was
    /// initialized to (all zeros, from the `[UInt8](repeating: 0, ...)` above) rather
    /// than filling in anything random. A caller that ignored the return status — as
    /// this function previously did — would silently hand back a fixed, predictable
    /// verifier/state instead of a random one, which guts the CSRF protection `state`
    /// exists for and the PKCE protection the code verifier exists for, without ever
    /// surfacing an error. Throwing instead means a CSPRNG failure surfaces as a failed
    /// sign-in attempt (extremely unlikely, but a hard failure is unambiguously the
    /// correct behavior) rather than a silently-weakened one.
    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw OIDCError.randomGenerationFailed
        }
        return Data(bytes)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Hands `ASWebAuthenticationSession` the app's key window to present from. If no
    /// foreground-active scene exists (e.g. triggered from a background context, which
    /// shouldn't normally happen for an interactive sign-in), fails loudly rather than
    /// silently presenting into an empty, unattached window.
    private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            let scene = UIApplication.shared.connectedScenes
                .first { $0.activationState == .foregroundActive } as? UIWindowScene
            if let window = scene?.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
            // No real window to present into. `ASWebAuthenticationSession` requires a
            // synchronous, non-optional return here, so there's no clean way to fail
            // from this exact call — but the sign-in attempt will fail to actually show
            // anything, which surfaces as a session error the caller already handles,
            // rather than the "silent-looking empty window" this used to be.
            assertionFailure("OIDCAuthService: no foreground window available to present SSO sign-in from.")
            return ASPresentationAnchor()
        }
    }

    /// Prevents `URLSession` from automatically following the redirect Audiobookshelf's
    /// `/auth/openid` returns — that redirect needs to be handed to
    /// `ASWebAuthenticationSession` for interactive display, not silently fetched.
    private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
