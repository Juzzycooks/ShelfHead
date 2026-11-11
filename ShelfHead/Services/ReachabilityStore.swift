import Foundation

/// Distinguishes "you're offline" from "your server is down" (F10). `NetworkMonitor`
/// only tells you about the device's own connectivity — it can't tell you that the
/// device is online but the user's self-hosted server happens to be unreachable
/// (down, DNS hiccup, VPN not connected, etc). That distinction matters a lot for a
/// self-hosted audience, and was previously a common source of "the app is just
/// broken" confusion with nothing in the UI to explain it.
// CRIT-3 step 2 (REVIEW_2026-08-12.md): de-facto main-actor state. `nonisolated` on
// `shared`/`init()` mirrors `ThemeStore`/`FavoritesStore` — see `ThemeStore.swift` for
// the full rationale.
@MainActor
@Observable
final class ReachabilityStore {
    nonisolated static let shared = ReachabilityStore()

    enum Status: Equatable {
        case ok
        /// The device itself has no network connectivity.
        case offline
        /// The device is online, but the configured server didn't respond.
        case serverUnreachable
    }

    private(set) var status: Status = .ok
    /// Review 7 Low (stale reachability): when `checkNow` last finished; nil if it never ran
    /// (monitoring starts from `MainTabView`, so a CarPlay-only/background launch has no probe).
    private(set) var lastCheckedAt: Date?
    private var pollTask: Task<Void, Never>?

    private nonisolated init() {
        // Check immediately whenever connectivity comes back, rather than waiting for
        // the next poll tick, so the banner clears promptly.
        NetworkMonitor.shared.addConnectivityRestoredObserver { [weak self] in
            Task { @MainActor [weak self] in await self?.checkNow() }
        }
    }

    /// Starts a periodic check. Safe to call repeatedly (e.g. once per login session,
    /// from `MainTabView`'s `.task`) — cancels any previous poll first.
    ///
    /// 60s rather than the original 30s — this only drives a passive foreground
    /// connectivity banner (already stopped entirely in the background, see
    /// `ShelfHeadApp`'s `scenePhase` handling), so halving its cadence is a real
    /// network-radio-wake reduction for something that isn't time-critical: a stale
    /// banner for up to a minute costs nothing but a delayed UI update, whereas each
    /// tick wakes the radio for an HTTP round-trip regardless of whether anything
    /// changed.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Design review (14 Aug 2026), item 1: an ad hoc `/ping` check against a
    /// CANDIDATE server address — unlike `checkNow()` above, this never touches
    /// `status` or reads `AuthStore.shared.serverURL`, since it runs before the user
    /// has signed in to anything. Used by the split login flow's "Test Connection"
    /// step so a failure can name one specific cause (URL typo, server down, wrong
    /// port, TLS problem, a reverse proxy blocking the ping) instead of the single
    /// generic error a failed login used to give, which could mean any of five things.
    struct ConnectionTestResult: Equatable {
        enum Outcome: Equatable {
            /// Responded, over https (or a local/private http host — see
            /// `AuthViewModel.isLocalOrPrivateHost`), and looks like Audiobookshelf.
            case reachable
            /// Responded and looks like Audiobookshelf, but over http to a
            /// non-local/private host — the caller should confirm before proceeding.
            case reachableInsecure
            /// Responded with a success-ish status, but the body doesn't look like
            /// Audiobookshelf's own `/ping` response — a reverse proxy's block page, a
            /// different app's default page, or a login page for something else
            /// entirely can all still return 200.
            case notAudiobookshelf
            /// No response, a timeout, or a non-2xx/3xx status. Which of those it was is
            /// on `ConnectionTestResult.failure` (Critique 2026-10-06) — kept as one case so
            /// every existing `switch` over `Outcome` stays exhaustive.
            case unreachable
            /// `AuthViewModel.normalizedServerURL` couldn't make sense of the input at
            /// all — not even a network attempt was made.
            case invalidURL
        }
        let outcome: Outcome
        /// The cleaned-up address actually tested, so the UI can show the user what it
        /// parsed their input as — nil only for `.invalidURL`, where there's nothing
        /// valid to show.
        let resolvedURL: String?
        /// Audiobookshelf's advertised sign-in methods (e.g. `["local", "openid"]`), read
        /// from the follow-up `GET /status` call `fetchServerStatus` makes below — only
        /// attempted for `.reachable`/`.reachableInsecure`. `nil` for every other outcome
        /// (no second call is made), for a server too old to report the field, or for any
        /// failure along the way (timeout, non-2xx, malformed JSON) — `/ping`'s outcome
        /// stays authoritative regardless. Feeds
        /// `ServerConnectionRules.advertisesSingleSignOn`/`otherSignInOptionsTitle`/
        /// `otherSignInOptionsStartExpanded`, which `AddServerView`'s "Other sign-in
        /// options" disclosure was already written against — this is what stops it being
        /// dormant. Defaulted to `nil` in the initializer below so every existing call
        /// site and test that only names `outcome:`/`resolvedURL:` keeps compiling.
        let authMethods: [String]?
        /// Critique 2026-10-06 (harden): WHY an `.unreachable` failed, so the form can say
        /// something more useful than one catch-all sentence (TLS vs timeout vs DNS vs
        /// refused vs offline vs an HTTP error status). `nil` for every other outcome.
        /// Additive and defaulted, so existing callers and tests keep compiling.
        let failure: ServerConnectionFailure?
        /// True when no scheme was typed, https failed at the transport level, and plain
        /// http to the same local/private host answered instead
        /// (`ServerURLRules.connectionCandidates`). `resolvedURL` is then the http address.
        let usedPlainHTTPFallback: Bool
        /// True whenever the http fallback was attempted, whether it worked or not — so a
        /// failure the user sees after it doesn't offer a "Use http://" that was already tried.
        let triedPlainHTTP: Bool
        /// Batch 490 (REVIEW 2026-11-11 F8): everything else `GET /status` said (version,
        /// set-up state, the admin's login message and SSO button text). `nil` exactly
        /// when `authMethods` would be: no `/status` call, or it failed. Defaulted, so
        /// existing call sites and tests keep compiling.
        let serverStatus: ServerStatusInfo?

        init(outcome: Outcome, resolvedURL: String?, authMethods: [String]? = nil,
             failure: ServerConnectionFailure? = nil, usedPlainHTTPFallback: Bool = false,
             triedPlainHTTP: Bool = false, serverStatus: ServerStatusInfo? = nil) {
            self.outcome = outcome
            self.resolvedURL = resolvedURL
            // Batch 490 (REVIEW 2026-11-11 F8): a caller that only passes `serverStatus`
            // still gets `authMethods` from it.
            self.authMethods = authMethods ?? serverStatus?.authMethods
            self.failure = failure
            self.usedPlainHTTPFallback = usedPlainHTTPFallback
            self.triedPlainHTTP = triedPlainHTTP || usedPlainHTTPFallback
            self.serverStatus = serverStatus
        }
    }

    /// Item 28: pure host-comparison half of the fix below — whether it's safe for
    /// `testConnection(rawURL:customHeaders:)` to fall back to the ACTIVE account's
    /// `AuthStore.shared.customHeaders` when the caller didn't supply headers of its own.
    /// Safe only when the host being tested is the same one that active account is
    /// actually signed into (case-insensitively — hostnames aren't case-sensitive); never
    /// when it's `nil` (nothing signed in yet, e.g. adding a brand-new server) or when it
    /// names a different host. Without this, `LoginView`'s "Add Server" screen sent
    /// whichever proxy-gate credentials (Cloudflare Access, Authelia, nginx
    /// `auth_request`) happened to belong to the CURRENTLY signed-in account to any host
    /// the user typed into that screen — a credential leak to an arbitrary server.
    nonisolated static func shouldForwardActiveHeaders(testedHost: String?, activeHost: String?) -> Bool {
        guard let testedHost, !testedHost.isEmpty,
              let activeHost, !activeHost.isEmpty else { return false }
        return testedHost.caseInsensitiveCompare(activeHost) == .orderedSame
    }

    /// Critique 2026-10-06 (harden): the address(es) to try now come from
    /// `ServerURLRules.connectionCandidates` (https, then http for a scheme-less
    /// local/private host), and a failure carries a `ServerConnectionFailure`.
    ///
    /// Deliberately NOT `nonisolated` — `AuthViewModel.normalizedServerURL` (formerly
    /// called here) is itself main-actor-isolated (it doesn't need to be `nonisolated` the
    /// way `isLocalOrPrivateHost` does, since nothing calls it from a non-actor
    /// context), so this stays on the main actor too rather than needing a hop. Every
    /// realistic caller (the split login flow) is itself SwiftUI/main-actor code
    /// anyway.
    ///
    /// Item 28: `customHeaders` lets a caller pass the headers that actually belong to
    /// the URL being tested (e.g. the ones just typed into a per-account custom-headers
    /// field, before that account is ever saved). The existing call site
    /// (`LoginView.testConnection()`) doesn't pass any yet — see this fix's report for
    /// the one-line change it would need to start doing so — so it now relies on
    /// `shouldForwardActiveHeaders` below instead of unconditionally picking up whichever
    /// account happens to be active, which is exactly the leak this fixes.
    static func testConnection(rawURL: String, customHeaders: [String: String] = [:]) async -> ConnectionTestResult {
        // Critique 2026-10-06 (harden): a scheme-less LAN address (`192.168.1.50:13378`)
        // used to be tested over https only, and Audiobookshelf on a home network is
        // usually plain http — so a perfectly good server failed with a generic error.
        // `connectionCandidates` returns `[https, http]` for exactly that case (no scheme
        // typed, local/private host) and a single address otherwise.
        let candidates = ServerURLRules.connectionCandidates(for: rawURL)
        guard let primaryURL = candidates.first else {
            return ConnectionTestResult(outcome: .invalidURL, resolvedURL: nil)
        }
        let primary = await probe(cleanURL: primaryURL, customHeaders: customHeaders)
        guard candidates.count > 1,
              primary.outcome == .unreachable,
              let primaryFailure = primary.failure,
              primaryFailure.warrantsPlainHTTPRetry else {
            return primary
        }
        let fallbackURL = candidates[1]
        let fallback = await probe(cleanURL: fallbackURL, customHeaders: customHeaders)
        switch fallback.outcome {
        case .reachable, .reachableInsecure:
            // `reachableInsecure` can't really happen here (the fallback is only offered
            // for local/private hosts, which the insecure rule exempts), but pass it
            // through unchanged rather than assume.
            return ConnectionTestResult(outcome: fallback.outcome, resolvedURL: fallbackURL,
                                        authMethods: fallback.authMethods,
                                        usedPlainHTTPFallback: true,
                                        serverStatus: fallback.serverStatus)
        case .notAudiobookshelf, .unreachable, .invalidURL:
            // Something other than Audiobookshelf on the http side is no better an answer
            // than the https failure, so only a real pass adopts the fallback. Otherwise
            // report whichever failure says more (`preferredFailure`), against the
            // address that produced it.
            let fallbackFailure = fallback.failure ?? .other
            let chosen = ServerConnectionFailure.preferredFailure(https: primaryFailure, http: fallbackFailure)
            let usesHTTPSide = (chosen == fallbackFailure && chosen != primaryFailure)
            return ConnectionTestResult(outcome: .unreachable,
                                        resolvedURL: usesHTTPSide ? fallbackURL : primaryURL,
                                        failure: chosen,
                                        triedPlainHTTP: true)
        }
    }

    /// One `/ping` (plus the optional `/status` follow-up) against one already-normalised
    /// address. The body of what `testConnection` used to be, split out so the http
    /// fallback above can run it twice.
    private static func probe(cleanURL: String, customHeaders: [String: String]) async -> ConnectionTestResult {
        guard let url = URL(string: "\(cleanURL)/ping") else {
            return ConnectionTestResult(outcome: .invalidURL, resolvedURL: nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Same reasoning as `checkNow()`: a reverse proxy in front of the server would
        // otherwise 401 this unauthenticated ping and be misread as "unreachable" — but
        // only forward the ACTIVE account's headers when the host being tested is that
        // same account's own host. A caller testing a different host must bring its own
        // headers (`customHeaders`) or get none at all — never the wrong account's.
        var headersToApply = customHeaders
        if headersToApply.isEmpty {
            let testedHost = URLComponents(string: cleanURL)?.host
            let activeHost = URL(string: AuthStore.shared.serverURL)?.host
            if Self.shouldForwardActiveHeaders(testedHost: testedHost, activeHost: activeHost) {
                headersToApply = AuthStore.shared.customHeaders
            }
        }
        request.applyCustomHeaders(headersToApply)
        // Mirrors `AuthViewModel.requiresInsecureConnectionConfirmation(for:)` exactly
        // — plain http to a LAN/Tailscale/private address is the normal, expected way
        // to reach a self-hosted server without TLS and shouldn't trigger the "Continue
        // Anyway" warning; only non-local http (credentials genuinely travelling over
        // the open internet in the clear) should. Using a different rule here than
        // `login()` itself uses would mean this screen's warning and the login gate it
        // exists to move earlier could disagree with each other.
        var isInsecureRisk = false
        if let comps = URLComponents(string: cleanURL), comps.scheme?.lowercased() == "http",
           let host = comps.host {
            isInsecureRisk = !AuthViewModel.isLocalOrPrivateHost(host)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode
                return ConnectionTestResult(outcome: .unreachable, resolvedURL: cleanURL,
                                            failure: status.map { .httpStatus($0) } ?? .other)
            }
            // Audiobookshelf's real `/ping` responds with a JSON object containing a
            // `success` key. Anything else reachable at this address that still
            // returned a 2xx/3xx — a reverse-proxy block/login page, a static site, a
            // completely different app's default page — won't have that shape.
            let looksLikeAudiobookshelf = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["success"] != nil
            guard looksLikeAudiobookshelf else {
                return ConnectionTestResult(outcome: .notAudiobookshelf, resolvedURL: cleanURL)
            }
            let outcome: ConnectionTestResult.Outcome = isInsecureRisk ? .reachableInsecure : .reachable
            // Only bother once `/ping` has already confirmed this looks like a real
            // Audiobookshelf server — see `fetchServerStatus` for why this is a follow-up
            // call rather than folded into `/ping` itself.
            // Batch 490 (REVIEW 2026-11-11 F8): the same one `/status` call, now read for
            // more than `authMethods`.
            let status = await fetchServerStatus(cleanURL: cleanURL, headers: headersToApply)
            return ConnectionTestResult(outcome: outcome, resolvedURL: cleanURL,
                                        authMethods: status?.authMethods, serverStatus: status)
        } catch {
            // Critique 2026-10-06 (harden): was a bare `.unreachable` for every error,
            // which is why the form could only ever say "Can't reach this server".
            let failure = ServerConnectionFailure.classify(error,
                                                           deviceIsOnline: NetworkMonitor.shared.isConnected)
            return ConnectionTestResult(outcome: .unreachable, resolvedURL: cleanURL, failure: failure)
        }
    }

    /// Second, optional request to Audiobookshelf's unauthenticated `GET /status` —
    /// reuses the same headers/timeout/cache policy as `/ping` above, and the same
    /// pre-auth `URLSession.shared` exception (CLAUDE.md > Architecture): no token exists
    /// yet at this point in the connection-test flow, so there's nothing to route through
    /// `AudiobookshelfAPI.send`.
    ///
    /// Deliberately a second call rather than replacing `/ping`: `/ping`'s `success` key
    /// is what tells a real Audiobookshelf server apart from a reverse proxy's own 200
    /// block page (see the `looksLikeAudiobookshelf` check above) — `/status` has no
    /// equivalent marker of its own, so it stays the richer, strictly optional follow-up
    /// made only once that distinction is already settled, and its failure can never flip
    /// an outcome the `/ping` check already decided.
    ///
    /// Any failure — timeout, non-2xx, malformed JSON, an older server without the field
    /// — yields `nil`, never an error surfaced anywhere; the caller's outcome is already
    /// final by the time this runs.
    ///
    /// Batch 490 (REVIEW 2026-11-11 F8): renamed from `fetchAuthMethods` and widened to
    /// the whole `ServerStatusInfo` (`parseServerStatus`). Same request, same call site,
    /// no new `URLSession` use.
    private static func fetchServerStatus(cleanURL: String, headers: [String: String]) async -> ServerStatusInfo? {
        guard let statusURL = URL(string: "\(cleanURL)/status") else { return nil }
        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.applyCustomHeaders(headers)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return parseServerStatus(from: data)
    }

    /// Batch 490 (REVIEW 2026-11-11 F8): pure parse of the whole `GET /status` body.
    /// Audiobookshelf's `Server.js` answers `{ app, serverVersion, isInit, language,
    /// authMethods, authFormData }`, where `authFormData` carries
    /// `authLoginCustomMessage` (HTML-sanitised, may be null) and, only when OpenID is
    /// active, `authOpenIDButtonText`. Every field is optional and type-checked on its
    /// own, so one odd value never loses the rest. `nil` only when the body isn't a JSON
    /// object at all.
    nonisolated static func parseServerStatus(from data: Data) -> ServerStatusInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let form = object["authFormData"] as? [String: Any]
        return ServerStatusInfo(
            authMethods: parseAuthMethods(from: data),
            serverVersion: ServerStatusInfo.cleanedLine(object["serverVersion"] as? String, maxLength: 40),
            isInitialized: object["isInit"] as? Bool,
            loginMessage: ServerStatusInfo.plainLoginMessage(form?["authLoginCustomMessage"] as? String),
            openIDButtonText: ServerStatusInfo.cleanedLine(form?["authOpenIDButtonText"] as? String, maxLength: 40))
    }

    /// Pure parse of Audiobookshelf's `GET /status` body down to just `authMethods`,
    /// split out so it can be unit-tested with fixtures rather than a live network call
    /// (CLAUDE.md > Testing: pin the pure decision function, not the I/O around it). `nil`
    /// whenever the shape isn't what's expected — the key is absent (older server), the
    /// body isn't a JSON object, or the value isn't an array at all — and non-string
    /// elements inside an otherwise-array value are silently dropped rather than nil-ing
    /// the whole result, so a server that sent one malformed entry doesn't lose every
    /// legitimate one alongside it. An empty array is a valid parse (a server with no
    /// auth methods reported, as opposed to no field at all) and comes back as `[]`, not
    /// `nil`.
    nonisolated static func parseAuthMethods(from data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMethods = object["authMethods"] as? [Any] else {
            return nil
        }
        return rawMethods.compactMap { $0 as? String }
    }

    /// Review 7 Low (stale reachability): a non-.ok status older than `maxAge` (or never probed)
    /// is treated as unknown (.ok) so callers don't trust an old verdict.
    nonisolated static func trustedStatus(_ status: Status, lastCheckedAt: Date?, now: Date = Date(), maxAge: TimeInterval = 120) -> Status {
        guard let last = lastCheckedAt, now.timeIntervalSince(last) <= maxAge else { return .ok }
        return status
    }

    /// `status`, or .ok when it is stale. Use for decisions made outside the foreground UI.
    var trustedStatus: Status { Self.trustedStatus(status, lastCheckedAt: lastCheckedAt) }

    func checkNow() async {
        defer { lastCheckedAt = Date() }
        guard NetworkMonitor.shared.isConnected else {
            status = .offline
            return
        }
        let server = AuthStore.shared.serverURL
        guard !server.isEmpty, let url = URL(string: "\(server)/ping") else {
            // Not signed in yet, or no server configured — nothing meaningful to check.
            status = .ok
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // A reverse proxy in front of the server (Cloudflare Access, Authelia, etc.)
        // would otherwise 401 this unauthenticated ping and be misread as "unreachable".
        request.applyCustomHeaders()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                status = .ok
            } else {
                status = .serverUnreachable
            }
        } catch {
            status = .serverUnreachable
        }
    }
}

/// Batch 490 (REVIEW 2026-11-11 F8): what Audiobookshelf's unauthenticated `GET /status`
/// says about itself, beyond `authMethods`. Every field is optional: an older server, or
/// one that sent an unexpected type, just leaves that field `nil`. Pinned by
/// `QuickWinsSignInTests`.
nonisolated struct ServerStatusInfo: Equatable, Sendable {
    /// `authMethods`, e.g. `["local", "openid"]` (`ReachabilityStore.parseAuthMethods`).
    let authMethods: [String]?
    /// `serverVersion`, e.g. "2.17.2".
    let serverVersion: String?
    /// `isInit`: `false` means no root user exists yet, so nobody can sign in until setup
    /// is finished in a browser. `nil` when the server didn't say.
    let isInitialized: Bool?
    /// `authFormData.authLoginCustomMessage`, reduced to plain text and capped
    /// (`plainLoginMessage`). `nil` when unset or empty.
    let loginMessage: String?
    /// `authFormData.authOpenIDButtonText`, only when the admin changed it from
    /// Audiobookshelf's default (`serverDefaultOpenIDButtonText`).
    let openIDButtonText: String?

    init(authMethods: [String]? = nil, serverVersion: String? = nil, isInitialized: Bool? = nil,
         loginMessage: String? = nil, openIDButtonText: String? = nil) {
        self.authMethods = authMethods
        self.serverVersion = serverVersion
        self.isInitialized = isInitialized
        self.loginMessage = loginMessage
        // The server default is generic English and the app's own label says the same
        // thing in the user's language, so only a customised label is kept.
        if let openIDButtonText,
           openIDButtonText.caseInsensitiveCompare(Self.serverDefaultOpenIDButtonText) != .orderedSame {
            self.openIDButtonText = openIDButtonText
        } else {
            self.openIDButtonText = nil
        }
    }

    /// `ServerSettings.js`'s default for `authOpenIDButtonText`.
    static let serverDefaultOpenIDButtonText = "Login with OpenId"

    /// Longest login message shown, in characters, before it is cut with an ellipsis.
    static let loginMessageMaxLength = 280

    /// The server stores the login message as sanitised HTML (the web client renders it
    /// with `v-html`). The app shows it as one quiet line of plain text: tags removed
    /// (line-breaking ones become spaces), the common entities decoded, whitespace
    /// collapsed, and capped at `loginMessageMaxLength`. `nil` when nothing is left.
    static func plainLoginMessage(_ raw: String?) -> String? {
        guard var text = raw else { return nil }
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "\u{2019}"), ("&#x27;", "\u{2019}"), ("&apos;", "\u{2019}"), ("&amp;", "&")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return cleanedLine(text, maxLength: loginMessageMaxLength)
    }

    /// Whitespace and control characters collapsed to single spaces, trimmed, and capped
    /// at `maxLength` characters (with an ellipsis). `nil` for `nil` or nothing left.
    static func cleanedLine(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        let pieces = raw.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            .filter { !$0.isEmpty }
        let joined = pieces.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        guard joined.count > maxLength, maxLength > 1 else { return joined }
        let cut = joined.prefix(maxLength - 1).trimmingCharacters(in: .whitespaces)
        return cut + "\u{2026}"
    }
}

/// Critique 2026-10-06 (harden): why a connection test couldn't reach the server, split
/// out of the single `.unreachable` it used to collapse into. Top-level and `nonisolated`
/// (rather than nested in the `@MainActor` store) so the classification and the copy
/// built on it are plain pure functions, pinned by `ServerConnectionFailureTests`.
nonisolated enum ServerConnectionFailure: Equatable, Sendable {
    /// TLS couldn't be set up: the server may not speak https at all (an http-only
    /// Audiobookshelf answering a TLS handshake with plain bytes), or its certificate
    /// isn't trusted (self-signed, expired, wrong name).
    case secureConnection
    /// Nothing answered within the test's timeout.
    case timedOut
    /// The name didn't resolve (DNS).
    case hostNotFound
    /// Resolved, but the connection was refused or dropped.
    case cannotConnect
    /// The device itself has no network.
    case offline
    /// A response came back, but with this non-2xx/3xx HTTP status.
    case httpStatus(Int)
    /// Anything else.
    case other

    /// Maps a `URLError` code. `deviceIsOnline` is `NetworkMonitor`'s view: a
    /// "not connected to the internet" error while the device's own path is satisfied
    /// isn't really "offline" — on a private host it's what a blocked local-network
    /// connection can look like — so it's reported as `.cannotConnect`, whose copy
    /// mentions the Local Network permission for private hosts.
    nonisolated static func classify(_ code: URLError.Code, deviceIsOnline: Bool) -> ServerConnectionFailure {
        switch code {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return .secureConnection
        case .timedOut:
            return .timedOut
        case .cannotFindHost, .dnsLookupFailed:
            return .hostNotFound
        case .cannotConnectToHost, .networkConnectionLost:
            return .cannotConnect
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return deviceIsOnline ? .cannotConnect : .offline
        default:
            return .other
        }
    }

    nonisolated static func classify(_ error: Error, deviceIsOnline: Bool) -> ServerConnectionFailure {
        if let urlError = error as? URLError {
            return classify(urlError.code, deviceIsOnline: deviceIsOnline)
        }
        return .other
    }

    /// Whether a failed https attempt is worth retrying over plain http to the same host.
    /// Yes for anything at the transport/TLS level; no when the name doesn't resolve or
    /// the device is offline (http can't fix either), or when an HTTP status came back
    /// (the https side was answered — a different scheme won't change the server's mind).
    nonisolated var warrantsPlainHTTPRetry: Bool {
        switch self {
        case .secureConnection, .timedOut, .cannotConnect, .other: return true
        case .hostNotFound, .offline, .httpStatus: return false
        }
    }

    /// When both the https attempt and the http fallback fail, which one to report.
    /// A TLS failure on https means *something* answered on that port, which is the more
    /// specific clue (an untrusted certificate, most often), so it wins. Otherwise the
    /// http side's failure is reported, since http is what a scheme-less LAN address most
    /// likely meant.
    nonisolated static func preferredFailure(https: ServerConnectionFailure,
                                             http: ServerConnectionFailure) -> ServerConnectionFailure {
        https == .secureConnection ? https : http
    }
}
