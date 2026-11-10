import Foundation

/// Thread-safe, in-memory holder for the current server URL and tokens.
///
/// This is the single source of truth for credentials at runtime. It replaces
/// storing the auth token in plaintext `UserDefaults`. Values are seeded from the
/// Keychain at launch (see `AuthViewModel.checkExistingSession`) and updated on
/// login / token refresh. Reads are synchronous so views (cover URLs) and the
/// `AVPlayer` setup can access the current access token without `await`.
///
/// **Explicitly `nonisolated` (build fix, 28 August 2026).** This file compiles into
/// two targets with different `SWIFT_DEFAULT_ACTOR_ISOLATION` settings: the main app
/// (`ShelfHead`) is `nonisolated`, the Watch app (`ShelfHead Watch`, added in Stage 1)
/// is `MainActor`. Without an explicit annotation, this class — and the
/// `applyCustomHeaders` extension below — would silently pick up whichever default
/// the *compiling* target happens to have, which is exactly what broke
/// `WatchAudiobookshelfAPI.swift`'s build: every `AuthStore.shared.___` access from
/// its plain (non-Main) actor was treated as an implicit cross-actor hop needing
/// `await`, because the Watch target's ambient `MainActor` default silently applied
/// to this file the moment it started compiling there too. Marking the type
/// `nonisolated` here pins its real isolation (none — it's `@unchecked Sendable` over
/// an `NSLock`, by design meant to be callable synchronously from anywhere) so it
/// behaves identically in both targets regardless of either one's default, rather
/// than depending on the two happening to agree.
nonisolated final class AuthStore: @unchecked Sendable {
    static let shared = AuthStore()

    private let lock = NSLock()
    private var _serverURL: String = ""
    private var _accessToken: String = ""
    private var _refreshToken: String?
    /// Extra headers to send with every request to this server — e.g. a reverse-proxy
    /// auth header (Cloudflare Access `Cf-Access-Client-Secret`, Authelia, a Bearer
    /// token for an nginx `auth_request` gate) sitting in front of a self-hosted
    /// Audiobookshelf instance. Set from the active `ServerAccount.customHeaders` on
    /// login/session-restore/account-switch — see `AuthViewModel`.
    private var _customHeaders: [String: String] = [:]

    /// Internal, not private: `OtherServersStore` creates a second, non-shared instance
    /// per secondary server so its session never touches `AuthStore.shared`.
    init() {}

    var serverURL: String { lock.withLock { _serverURL } }
    var accessToken: String { lock.withLock { _accessToken } }
    var refreshToken: String? { lock.withLock { _refreshToken } }
    var customHeaders: [String: String] { lock.withLock { _customHeaders } }

    var isConfigured: Bool {
        lock.withLock { !_serverURL.isEmpty && !_accessToken.isEmpty }
    }

    // MARK: - Custom header sanitization (security-review finding #3)
    //
    // Custom headers exist so a user can satisfy a reverse-proxy gate (Cloudflare
    // Access, Authelia, an nginx `auth_request` check) sitting in front of their
    // self-hosted Audiobookshelf instance. They are user-supplied free text, stored in
    // the Keychain/`ServerAccount` and replayed onto every outgoing request. Nothing
    // previously stopped a header name from colliding with one this app (or Foundation's
    // URL loading system, or AVPlayer) depends on for correctness — most importantly
    // `Authorization` itself: a custom header literally named `Authorization` would
    // silently replace the real bearer token on every request, since
    // `setValue(_:forHTTPHeaderField:)` is last-write-wins. Depending on apply order that
    // either breaks auth outright or, worse, quietly sends the *wrong* token to the
    // wrong place. Other names carry their own hazards: `Cookie`/`Proxy-Authorization`
    // could exfiltrate or corrupt session state, `Host` can break TLS SNI/virtual-host
    // routing, `Content-Length`/`Transfer-Encoding`/`Connection` are hop-by-hop framing
    // headers `URLSession` manages itself, `Range`/`If-Range` can interfere with
    // AVPlayer's own byte-range streaming requests, and `x-refresh-token`/
    // `x-return-tokens` are this app's own token-refresh signaling headers (see
    // `AudiobookshelfAPI`) that a custom header could spoof or clobber.
    //
    // `reservedHeaderNames` and `sanitizedCustomHeaders(_:)` below are the single
    // enforcement point: every header name is compared case-insensitively (HTTP header
    // names are case-insensitive per RFC 7230 §3.2), and every remaining name/value pair
    // is validated against the actual HTTP grammar rather than merely denylisted, so
    // header-name characters that could confuse a proxy or inject a second header
    // (spaces, colons, control characters) are rejected even if they don't happen to
    // match a reserved name, and CRLF (or other control characters) in a value — the
    // classic HTTP response/request-splitting injection vector — are rejected too.
    static let reservedHeaderNames: Set<String> = [
        "authorization", "host", "cookie", "content-length", "transfer-encoding",
        "connection", "range", "if-range", "proxy-authorization",
        "x-refresh-token", "x-return-tokens",
    ]

    /// RFC 7230 §3.2.6 `tchar` set: the only characters legal in an HTTP header field
    /// *name*. Anything else (spaces, colons, control characters, non-ASCII) is either
    /// meaningless as a header name or a sign of malformed/malicious input (e.g. trying
    /// to smuggle a second header via an embedded colon or CRLF).
    private static let headerNameAllowedCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        set.formUnion(.init(charactersIn: "0123456789"))
        set.formUnion(.init(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        set.formUnion(.init(charactersIn: "abcdefghijklmnopqrstuvwxyz"))
        return set
    }()

    /// True if `name` is safe to use as a custom HTTP header field name: non-empty, not
    /// one of `reservedHeaderNames` (case-insensitively), and composed entirely of
    /// RFC 7230 `tchar`s. Exposed (not just used internally by `sanitizedCustomHeaders`)
    /// so the header-editing UI (`AddServerView`, `SettingsView`) can show an inline
    /// "this header name can't be used" hint as the user types, without duplicating the
    /// reserved-name/grammar rules in two places. The UI check is advisory only — it
    /// doesn't block typing or saving — because the actual enforcement is this file's
    /// `sanitizedCustomHeaders`, called unconditionally wherever headers are stored or
    /// applied, so a header rejected here is guaranteed to never reach the network
    /// regardless of what the UI does.
    static func isValidCustomHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty, !reservedHeaderNames.contains(name.lowercased()) else { return false }
        return name.unicodeScalars.allSatisfy { headerNameAllowedCharacters.contains($0) }
    }

    /// True if `value` is safe to use as a custom HTTP header field value: no control
    /// characters (CR, LF, or any other C0/DEL byte — the CRLF-injection /
    /// header-smuggling risk). Exposed for the same UI-hint reason as
    /// `isValidCustomHeaderName` above.
    static func isValidCustomHeaderValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Filters a raw, user-supplied custom-header dictionary down to the subset that is
    /// safe to place on an outgoing request — see `isValidCustomHeaderName` and
    /// `isValidCustomHeaderValue` for exactly what's rejected and why.
    ///
    /// Called at every point a custom-header dictionary enters storage or memory
    /// (`set(serverURL:...)`, `setCustomHeaders(_:)`) so bad headers are stripped once,
    /// up front, rather than re-validated on every single network request. Additionally,
    /// `applyCustomHeaders` in `Extensions.swift` calls this again immediately before
    /// writing headers onto a `URLRequest` — that redundancy is intentional defense in
    /// depth: it means a bad header can never physically land on a request no matter how
    /// it got into memory (a future call site that forgets to sanitize on the way in,
    /// a direct Keychain read that bypasses `AuthStore`, etc.).
    static func sanitizedCustomHeaders(_ headers: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (name, value) in headers {
            guard isValidCustomHeaderName(name), isValidCustomHeaderValue(value) else { continue }
            sanitized[name] = value
        }
        return sanitized
    }

    func set(serverURL: String, accessToken: String, refreshToken: String?, customHeaders: [String: String] = [:]) {
        lock.withLock {
            _serverURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            _accessToken = accessToken
            _refreshToken = refreshToken
            _customHeaders = Self.sanitizedCustomHeaders(customHeaders)
        }
    }

    func setCustomHeaders(_ headers: [String: String]) {
        lock.withLock { _customHeaders = Self.sanitizedCustomHeaders(headers) }
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
            _customHeaders = [:]
        }
    }

    /// Builds a `URLRequest` with the current `Authorization` bearer token and custom
    /// headers already applied — the single place every authenticated request to the
    /// server should be constructed from, rather than each call site manually setting
    /// `Authorization` and remembering to also call `applyCustomHeaders()`.
    ///
    /// This exists because that exact pattern — a cross-cutting concern (a header) that
    /// needs to land on every outgoing request — has produced the same class of bug
    /// three separate times as new call sites were added over time (Wi-Fi-only missed a
    /// session config, custom headers missed the Watch cover fetch, the Now Playing
    /// artwork fetch missed `applyCustomHeaders()` entirely). Each was only found by
    /// reading the code, not by the compiler — a plain `URLRequest(url:)` constructor
    /// compiles whether or not the headers were remembered. Routing every authenticated
    /// request through this factory instead doesn't make the bug merely less likely; it
    /// makes the missing-header version of it not exist as a distinct code path to
    /// forget in the first place.
    ///
    /// Ordering matters here and is deliberate: custom headers are applied *first*,
    /// then `Authorization` is set *last*. `setValue(_:forHTTPHeaderField:)` is
    /// last-write-wins, so whichever header is set second overwrites the first if the
    /// names collide. `sanitizedCustomHeaders` should already have stripped anything
    /// named `Authorization` before it ever reached `_customHeaders` — but this ordering
    /// is the defense-in-depth backstop for that filtering: even if a reserved name
    /// somehow slipped through (a bug in the filter, a future call site that bypasses
    /// `set`/`setCustomHeaders`, etc.), the real bearer token set afterward always wins,
    /// so a hostile or accidental custom header can never actually override the app's
    /// own auth header on the wire.
    func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.applyCustomHeaders(customHeaders)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

// MARK: - Custom HTTP headers (reverse-proxy auth)

// Watch standalone Stage 1 (28 August 2026): moved here from Extensions.swift, which
// imports UIKit and pulls in this app's wider dependency graph (scaledFont, Haptics,
// etc.) — none of which this one small extension actually needs. Its only real
// dependency is `AuthStore.sanitizedCustomHeaders` right above, so it travels with
// AuthStore.swift now that this file is shared into the Watch target (see
// WATCH_STANDALONE_PROPOSAL_2026-08-28-ADDENDUM.md §1 for why AuthStore.swift, unlike
// AudiobookshelfAPI.swift, was judged clean enough to share as-is). Purely a file-
// organization change for the iOS app — Swift extensions are visible module-wide
// regardless of which file they're defined in, so nothing about the app's own behavior
// changes; this is just moving the method next to the one thing it actually depends on.
extension URLRequest {
    /// Applies the server connection's custom HTTP headers (e.g. Cloudflare Access,
    /// Authelia forward-auth, an nginx `auth_request` gate — anything sitting in front
    /// of a self-hosted Audiobookshelf instance) on top of whatever's already been set.
    ///
    /// Called *directly* only at request sites built before/outside
    /// `AuthStore.authorizedRequest(url:)` exists to do it for them:
    /// `AudiobookshelfAPI.login`/`performTokenRefreshOrReauth` (there's no token yet to
    /// authorize with), `OIDCAuthService`'s sign-in exchange, `ReachabilityStore`'s ping,
    /// and `WatchAudiobookshelfAPI`'s equivalents. Everything else — downloads
    /// (`DownloadManager`), cover fetches (`Extensions.swift`'s `authorizedCoverRequest`),
    /// and ordinary authenticated API calls — gets custom headers for free by going
    /// through `authorizedRequest(url:)` instead, which calls this method itself (see
    /// that function's own doc comment above for the exact bug class routing everything
    /// through one factory avoids). Corrected 28 August 2026 — this previously listed
    /// "downloads" and "cover fetches" as if they called this method directly; they
    /// don't, they reach it transitively via `authorizedRequest`. `AudioPlayerService.
    /// assetURL` merges the dictionary directly into its `AVURLAssetHTTPHeaderFieldsKey`
    /// options instead, since AVPlayer doesn't build a `URLRequest` at all.
    ///
    /// Runs `AuthStore.sanitizedCustomHeaders` again here, even though `AuthStore.set`
    /// and `setCustomHeaders` already sanitize on the way in — this is the last line of
    /// defense before headers actually land on the wire. `AuthStore.shared.customHeaders`
    /// should always already be sanitized, but call sites that build their own
    /// dictionary and pass it explicitly (rather than relying on the default parameter)
    /// bypass that storage-time filtering, so re-sanitizing here means a reserved or
    /// malformed header name/value (e.g. one that would overwrite `Authorization`, or
    /// smuggle a second header via an embedded CRLF) can never reach a `URLRequest`
    /// regardless of which code path constructed the dictionary.
    // `nonisolated` for the same reason as `AuthStore` itself, immediately above this
    // extension — this method lives in a file shared into a target with a different
    // `SWIFT_DEFAULT_ACTOR_ISOLATION` default (see that comment). Marking `AuthStore`
    // nonisolated doesn't cover this: it's an extension on `URLRequest`, a separate
    // type, so it needs its own explicit annotation to avoid the same implicit-MainActor
    // trap in the Watch target.
    nonisolated mutating func applyCustomHeaders(_ headers: [String: String] = AuthStore.shared.customHeaders) {
        for (key, value) in AuthStore.sanitizedCustomHeaders(headers) {
            setValue(value, forHTTPHeaderField: key)
        }
    }
}
