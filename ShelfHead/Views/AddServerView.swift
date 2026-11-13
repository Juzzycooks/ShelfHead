import SwiftUI
// Critique 2026-10-06 (harden): `UIApplication.openSettingsURLString`, for the Local
// Network "Open Settings" recovery — SwiftUI has no equivalent (same reason
// `DownloadsView` imports it).
import UIKit

/// A single custom-header row being edited in the form. Kept as a plain struct with
/// its own identity (rather than a `[String: String]` bound directly) so a row with a
/// blank/duplicate key doesn't collapse into another one while the user is still typing.
///
/// Declared here rather than alongside the form itself because
/// `AccountSecuritySettingsView`'s own header editor reuses it and names this file.
struct EditableHeaderPair: Identifiable, Equatable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

/// Critique 2026-10-06 (harden): a custom header's value is usually a proxy secret (a
/// Cloudflare Access client secret, an Authelia token), so it's entered like a password:
/// hidden by default, with a show/hide toggle to check what was pasted. Shared by Add
/// Server's editor and Account & Security's. `onSubmit` runs on Return.
///
/// Note iOS clears a secure field's existing text when typing resumes in it after it lost
/// focus; Show switches to a plain field for editing an existing value in place.
struct HeaderValueField: View {
    @Binding var value: String
    var onSubmit: () -> Void
    @State private var isRevealed = false

    // Explicit, so it doesn't depend on a memberwise init next to a private `@State`.
    init(value: Binding<String>, onSubmit: @escaping () -> Void = {}) {
        _value = value
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if isRevealed {
                    TextField("Value", text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("Value", text: $value)
                }
            }
            .accessibilityLabel("Header value")
            .onSubmit(onSubmit)
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(Color.shelfMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isRevealed ? Text("Hide header value") : Text("Show header value"))
        }
    }
}


/// Which of the two entry points is presenting `ServerConnectionView`.
///
/// SB-1 (REVIEW_2026-09-14_DESIGN.md): `LoginView` (first run) and `AddServerView`
/// (Settings > Account & Security) were two separate screens with two different sets of
/// capabilities. Only the second one had OIDC/SSO and the custom-header editor — both of
/// which sit behind `authViewModel.isAuthenticated`, so a brand-new user whose server is
/// SSO-only, or gated by Cloudflare Access / Authelia / an nginx `auth_request`, had no
/// way to sign in at all. They're now one view; this is the only thing that differs
/// between the two presentations.
enum ServerConnectionPurpose: Equatable {
    /// First run — `LoginView`, shown by `ContentView` when nobody is signed in. There's
    /// nothing behind this screen, so no Cancel and no dismissal: a successful sign-in
    /// flips `isAuthenticated` and `ContentView` swaps in `MainTabView`.
    case firstRun
    /// Settings > Account & Security > Add Server — `AddServerView`, presented as a
    /// sheet, so it keeps its Cancel/Connect toolbar and dismisses itself on success.
    case addAccount

    /// The app mark + tagline only belong on the first-run screen; the sheet already has
    /// a navigation title and a screen full of app behind it.
    var showsBranding: Bool { self == .firstRun }

    /// Whether a successful sign-in should dismiss this view.
    var dismissesOnSuccess: Bool { self == .addAccount }

    /// Whether `AuthViewModel.errorMessage` is rendered directly (in addition to this
    /// view's own `localError`).
    ///
    /// First run only, and deliberately: Sign Out (`AuthViewModel.signOut`, and Remove All Servers) sets `errorMessage`
    /// *after* `isAuthenticated = false` specifically so a Keychain that wouldn't release
    /// an item is reported on the screen the user lands on — with no sign-in attempt
    /// having been made here. The sheet has no such producer, and rendering a stale
    /// message there would surface an error from some other screen out of context (see
    /// the note on `AuthViewModel.updateCustomHeaders`).
    var rendersViewModelError: Bool { self == .firstRun }
}

/// Pure form decisions behind `ServerConnectionView`, lifted out of the view so they can
/// be pinned by `LoginAddServerMergeTests` — the project's standing preference for
/// testing decision functions rather than stateful UI (see `CLAUDE.md` > Testing).
enum ServerConnectionRules {
    /// UX-4 (docs/design-review.md, Batch 355): what the form does once a password sign-in
    /// attempt returns. Success is only ever `login()`'s own `true`; "no error, nothing
    /// pending" is no longer read as success, because other code can clear that shared
    /// state (it did: the account-switch alert in `AccountSecuritySettingsView`).
    enum SignInOutcome: Equatable {
        /// The Insecure Connection alert is up; keep the form and its connecting state.
        case awaitingInsecureConfirmation
        case succeeded
        /// Show this message on the form and stay put.
        case failed(String)
    }

    static var genericSignInFailure: String { String(localized: "Couldn't sign in. Check the server address and try again.") }

    static func signInOutcome(succeeded: Bool, pendingInsecureConnection: Bool,
                              errorMessage: String?) -> SignInOutcome {
        if pendingInsecureConnection { return .awaitingInsecureConfirmation }
        if succeeded { return .succeeded }
        if let errorMessage, !errorMessage.isEmpty { return .failed(errorMessage) }
        return .failed(genericSignInFailure)
    }


    /// Which of the two pages `ServerConnectionView` is showing.
    ///
    /// Device feedback (14 Sep 2026): "after pressing test connection and it succeeds it
    /// should only show the next login page, should not be a scroll down. should be a
    /// live sign in page." The two steps were one scrolling `Form` with the second half
    /// revealed underneath; they're now two pages of one view, one on screen at a time.
    enum Page: Hashable {
        /// Address, Test Connection, the diagnosis, "Where do I find this?", the
        /// collapsed Advanced header editor, and the "Sign in anyway" hatch.
        case server
        /// A compact summary of the server just verified, then the credentials, Remember
        /// password, the primary button, and the collapsed SSO disclosure.
        case signIn
    }

    /// The page actually rendered, as opposed to the one the view last asked for.
    ///
    /// The invariant this exists to make structural: you can never be stranded on
    /// `.signIn` with nothing to sign in with. `showsCredentials` can go false at any
    /// moment — editing the address clears the test result and the bypass — and deriving
    /// the rendered page through here means that single source of truth pulls the user
    /// back to `.server` rather than leaving a dead page on screen. `.server` is always
    /// honoured, so "Change server" works even while a passing result is still in hand.
    static func resolvedPage(requested: Page, showsCredentials: Bool) -> Page {
        showsCredentials ? requested : .server
    }

    /// How the server summary row at the top of the sign-in page should read — derived
    /// from the same three inputs as `showsCredentials`, so the row can never claim a
    /// verification the gate didn't actually grant.
    enum ServerSummaryStyle: Hashable {
        /// A clean `/ping` over https (or to a local/private host).
        case verified
        /// Reachable, but plain HTTP to a non-local host, and the user accepted that.
        case insecureAccepted
        /// Here via "Sign in anyway" — the test never passed, and the row must say so
        /// rather than showing a reassuring lock.
        case unverified
    }

    @MainActor
    static func serverSummaryStyle(for result: ReachabilityStore.ConnectionTestResult?,
                                   insecureAccepted: Bool) -> ServerSummaryStyle {
        switch result?.outcome {
        case .reachable:
            return .verified
        case .reachableInsecure:
            return insecureAccepted ? .insecureAccepted : .unverified
        case .notAudiobookshelf, .unreachable, .invalidURL, nil:
            return .unverified
        }
    }

    /// The host to show in that row. Prefers the address the test actually resolved
    /// (`normalizedServerURL`'s output) so the user sees what was really contacted, falls
    /// back to the resolved string whole if it has no parseable host, and finally to
    /// whatever they typed — the row must never be blank.
    static func serverSummaryHost(resolvedURL: String?, typedURL: String) -> String {
        if let resolvedURL, !resolvedURL.isEmpty {
            if let host = URLComponents(string: resolvedURL)?.host, !host.isEmpty {
                return host
            }
            return resolvedURL
        }
        return typedURL.trimmingCharacters(in: .whitespaces)
    }

    static func serverSummaryGlyph(for style: ServerSummaryStyle) -> String {
        switch style {
        case .verified: return "lock.fill"
        case .insecureAccepted: return "lock.open.fill"
        case .unverified: return "questionmark.circle.fill"
        }
    }

    static func serverSummaryCaption(for style: ServerSummaryStyle) -> String {
        switch style {
        case .verified: return String(localized: "Connection verified", comment: "Caption under the server host on the sign-in page")
        case .insecureAccepted: return String(localized: "Insecure connection accepted", comment: "Caption under the server host on the sign-in page")
        case .unverified: return String(localized: "Connection not verified", comment: "Caption under the server host on the sign-in page")
        }
    }

    /// One VoiceOver stop for the whole row (the "Change server" button stays a separate,
    /// separately actionable element next to it).
    static func serverSummaryAccessibilityLabel(host: String, style: ServerSummaryStyle) -> String {
        String(localized: "Server \(host), \(serverSummaryCaption(for: style).lowercased())", comment: "VoiceOver label for the server summary row; first %@ is the host, second is the connection status caption in lowercase")
    }

    /// Whether a header name the user is currently typing will actually make it onto a
    /// request. A blank name (a freshly-added, not-yet-filled-in row) isn't flagged —
    /// there's nothing wrong with it yet, it's just incomplete — but anything non-empty
    /// that `AuthStore.sanitizedCustomHeaders` would strip is, so the inline warning
    /// matches enforcement exactly.
    static func headerNameIsUsable(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return AuthStore.isValidCustomHeaderName(trimmed)
    }

    /// Whether a header value the user is currently typing will actually reach a request
    /// — mirrors `headerNameIsUsable`, but for the value side. Item 30
    /// (REVIEW-2026-09-09.md). Deliberately doesn't trim first the way the name check
    /// does: a leading/trailing space is a harmless, valid header-value byte, but a
    /// leading/trailing newline is exactly the case this exists to catch, and trimming it
    /// away before checking would hide the warning instead of surfacing it. An empty
    /// value is already valid per `isValidCustomHeaderValue`, so it needs no separate
    /// blank-row carve-out.
    static func headerValueIsUsable(_ value: String) -> Bool {
        AuthStore.isValidCustomHeaderValue(value)
    }

    /// Non-empty-key header rows, collapsed into a dictionary. A row with a blank name
    /// (e.g. one just added and not yet filled in) is silently dropped rather than sent
    /// as an empty header name. Later rows win on a duplicate name — the same thing a
    /// `[String: String]` would do, and the header editor is small enough that a
    /// duplicate is visible on screen.
    static func customHeaders(from pairs: [EditableHeaderPair]) -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs {
            let key = pair.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = pair.value
        }
        return result
    }

    /// Whether the username/password path can be attempted. The server URL isn't
    /// validated here — `AuthViewModel.normalizedServerURL` owns that, and it reports a
    /// specific message for a URL it can't parse, which is more useful than a disabled
    /// button with no explanation.
    static func canSubmitPassword(serverURL: String, username: String, password: String) -> Bool {
        // Polish pass (J1-6): newlines too — a pasted username can end in one.
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !AuthViewModel.normalizedUsername(username).isEmpty &&
        !password.isEmpty
    }

    /// SSO needs only the server address — Audiobookshelf itself runs the whole OIDC
    /// exchange with the identity provider, so there's no username or password to type.
    static func canStartSingleSignOn(serverURL: String) -> Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// True when what the user has typed so far names a plain, unencrypted HTTP
    /// connection — drives the advisory caption under the fields. Advisory only: the
    /// actual gate is `AuthViewModel.requiresInsecureConnectionConfirmation`, which also
    /// exempts local/private hosts, and which blocks the connection outright until it's
    /// acknowledged.
    static func isInsecureURLText(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
    }

    /// Whether the sign-in step (username, password, SSO) belongs on screen yet.
    ///
    /// Device feedback (14 Sep 2026): "hide the username/pwd, custom http headers and
    /// SSO until connection test passes". A pass is exactly the two success outcomes of
    /// `ReachabilityStore.testConnection` — `.reachable`, and `.reachableInsecure` once
    /// the user has explicitly accepted the plain-HTTP risk (either from the inline
    /// "Continue Anyway" or from the `AuthViewModel` alert). `.reachableInsecure` on its
    /// own deliberately does NOT reveal step 2: the acknowledgement is the same gate
    /// `AuthViewModel.requiresInsecureConnectionConfirmation` would raise a moment later
    /// anyway, so asking for it here means it's asked once, in context, instead of twice.
    ///
    /// Every failing outcome keeps step 2 hidden, `.notAudiobookshelf` included. That is
    /// the outcome a proxy gate (Cloudflare Access, Authelia, an nginx `auth_request`)
    /// produces, and it's precisely why SB-1 removed the old stepper's gate — the first
    /// escape hatch is that the custom header editor now lives in step 1 and is reachable
    /// WITHOUT a passing test; adding the gate's header there and testing again is what
    /// turns this into `.reachable`.
    ///
    /// `bypassed` is the second escape hatch, for the residual case the header editor
    /// can't reach: a gate that blocks or rewrites `/ping` no matter what headers are
    /// sent, so the test can never go green for a server that is in fact perfectly
    /// signable-into. It's set only by the explicit "Sign in anyway" button, which
    /// `offersTestBypass(for:)` shows on exactly the two outcomes where it's plausible —
    /// never before a test has run, so a fresh form is still just the address field.
    /// Deliberately NOT a substitute for the insecure-connection acknowledgement: a
    /// bypassed sign-in to a plain-HTTP non-local host still meets
    /// `AuthViewModel.requiresInsecureConnectionConfirmation` and its alert.
    ///
    /// `@MainActor` only because `ReachabilityStore.ConnectionTestResult` is nested in
    /// the `@MainActor` `ReachabilityStore` and so inherits its isolation — the logic
    /// itself is pure. Same reason `AccountRemovalTests` is a `@MainActor` test class.
    @MainActor
    static func showsCredentials(for result: ReachabilityStore.ConnectionTestResult?,
                                 insecureAccepted: Bool,
                                 bypassed: Bool = false) -> Bool {
        // A bypass only means anything once a test has actually failed — it's offered
        // nowhere else, and honouring a stray flag with no result would put step 2 back
        // on a fresh form, which is the clutter this whole change removes.
        if bypassed, offersTestBypass(for: result) { return true }
        switch result?.outcome {
        case .reachable:
            return true
        case .reachableInsecure:
            return insecureAccepted
        case .notAudiobookshelf, .unreachable, .invalidURL, nil:
            return false
        }
    }

    /// Whether to offer "Sign in anyway" under the diagnosis.
    ///
    /// The two outcomes where the address is plausibly fine and the *test* is what's
    /// wrong: `.notAudiobookshelf` (a gate's block page answered `/ping`) and
    /// `.unreachable` (a gate that 403s or drops an unauthenticated `/ping` outright).
    /// Not `.invalidURL` — nothing was even attempted there, and the address genuinely
    /// can't be parsed — and obviously not on the two success outcomes or before a test
    /// has run, where an "anyway" button would be noise on a screen that is working.
    @MainActor
    static func offersTestBypass(for result: ReachabilityStore.ConnectionTestResult?) -> Bool {
        switch result?.outcome {
        case .notAudiobookshelf, .unreachable:
            return true
        case .reachable, .reachableInsecure, .invalidURL, nil:
            return false
        }
    }

    /// Whether the "Advanced: custom HTTP headers" disclosure in step 1 should be open
    /// without the user having tapped it.
    ///
    /// Two cases, both of them "this user demonstrably needs it": headers already exist
    /// (a prefilled/edited connection — opening collapsed would hide data that is
    /// already in the form), or the test came back `.notAudiobookshelf`, which for a
    /// self-hosted audience most often means a proxy gate answered `/ping` with its own
    /// block page. Only ever used to expand — never to collapse a disclosure the user
    /// opened themselves.
    ///
    /// Critique 2026-10-06 (harden): also an HTTP 401/403, whose advice ("add its headers
    /// under Advanced below", `failureAdvice`) pointed at a disclosure that stayed shut.
    ///
    /// `@MainActor` for the same reason as `showsCredentials` above.
    @MainActor
    static func headersDisclosureStartsExpanded(result: ReachabilityStore.ConnectionTestResult?,
                                                hasHeaders: Bool) -> Bool {
        if hasHeaders { return true }
        switch result?.outcome {
        case .notAudiobookshelf:
            return true
        case .unreachable:
            if case .httpStatus(let code) = result?.failure { return code == 401 || code == 403 }
            return false
        case .reachable, .reachableInsecure, .invalidURL, nil:
            return false
        }
    }

    /// Critique 2026-10-06 (harden): whether Account & Security's header editor should
    /// write the Keychain. It used to on every keystroke; now only when the headers differ
    /// from the last save, or that save failed (so its "try again" works). Pure, pinned by
    /// `HeaderSecretsTests`.
    static func headerSaveIsNeeded(_ headers: [String: String], lastSaved: [String: String]?,
                                   lastSaveFailed: Bool) -> Bool {
        lastSaveFailed || headers != lastSaved
    }

    /// Critique 2026-10-06 (harden + clarify): the line at the top of the sign-in form when
    /// it was opened for a saved server with no stored password ("Stay signed in" is off by
    /// default). Says what's needed instead of silently filling in the address. Pure,
    /// pinned by `ServerSwitchOutcomeTests`.
    static func passwordNeededPrompt(username: String, host: String, switchesAccount: Bool) -> String {
        if switchesAccount {
            return String(localized: "No password is saved for \(username) on \(host). Enter it to switch to it.", comment: "Sign-in form prompt when switching to a saved server; first %@ is the username, second the server host")
        }
        return String(localized: "No password is saved for \(username) on \(host). Enter it to sign in.", comment: "Sign-in form prompt for a saved server with no stored password; first %@ is the username, second the server host")
    }

    /// Whether the server has told us it offers OpenID Connect.
    ///
    /// Audiobookshelf's `GET /status` returns an `authMethods` array (e.g.
    /// `["local", "openid"]`). The connection test follows a passing `/ping` with that
    /// `/status` call and carries the list on `ConnectionTestResult.authMethods` (and the
    /// rest of the answer on `serverStatus`), which is what
    /// `ServerConnectionView.advertisedAuthMethods` passes in here. `nil` means the server
    /// didn't say (no test yet, a failed test, or an older server).
    /// Batch 495 (REVIEW 2026-11-11 O3): the values are the server's own strings, `local`
    /// and `openid` (audiobookshelf `server/Server.js` `/status`, `ServerSettings.js`).
    static func advertisesSingleSignOn(authMethods: [String]?) -> Bool {
        contains(authMethods, "openid")
    }

    /// Whether the server accepts username and password (`local`).
    static func advertisesPasswordSignIn(authMethods: [String]?) -> Bool {
        contains(authMethods, "local")
    }

    private static func contains(_ authMethods: [String]?, _ method: String) -> Bool {
        guard let authMethods else { return false }
        return authMethods.contains { $0.caseInsensitiveCompare(method) == .orderedSame }
    }

    /// Batch 495 (REVIEW 2026-11-11 O3): what the sign-in page shows, from the server's
    /// advertised `authMethods`.
    enum SignInLayout: Equatable {
        /// Today's page: password fields and primary button, SSO tucked in a disclosure.
        /// Local-only, unknown or unrecognised methods, and no `authMethods` at all.
        case passwordWithSSODisclosure
        /// Password primary, SSO a full-width secondary button directly under it.
        case passwordAndSSO
        /// OpenID without `local`: no password fields, SSO is the one primary button.
        case singleSignOnOnly

        var showsPasswordFields: Bool { self != .singleSignOnOnly }
        /// The SSO control is a button on the page (not inside the disclosure).
        var showsSSOButtonInline: Bool { self != .passwordWithSSODisclosure }
    }

    static func signInLayout(authMethods: [String]?) -> SignInLayout {
        let sso = advertisesSingleSignOn(authMethods: authMethods)
        let password = advertisesPasswordSignIn(authMethods: authMethods)
        if sso && password { return .passwordAndSSO }
        if sso { return .singleSignOnOnly }
        return .passwordWithSSODisclosure
    }

    /// Whether the SSO button is on screen now: always in the two SSO layouts, and in
    /// today's layout only while its disclosure is open. Feeds `statusRowShowsSpinner`.
    static func ssoButtonVisible(layout: SignInLayout, disclosureExpanded: Bool) -> Bool {
        layout.showsSSOButtonInline || disclosureExpanded
    }

    /// Batch 490 (REVIEW 2026-11-11 O6): which sign-in is in flight, so only that control
    /// spins and the other is disabled.
    enum SignInMethod: Equatable {
        case password
        case singleSignOn
    }

    /// Batch 490 (REVIEW 2026-11-11 O6): whether the status row shows its own spinner and
    /// "Connecting…". Not when the control that started the attempt is already spinning:
    /// the Sign In button is always on the sign-in page, and the SSO button is while its
    /// disclosure is open. Pinned by `QuickWinsSignInTests`.
    static func statusRowShowsSpinner(connecting: SignInMethod?, page: Page, ssoOptionsExpanded: Bool) -> Bool {
        guard let connecting else { return false }
        guard page == .signIn else { return true }
        switch connecting {
        case .password: return false
        case .singleSignOn: return !ssoOptionsExpanded
        }
    }

    /// Batch 490 (REVIEW 2026-11-11 F8): the server summary row's version line, from
    /// `/status`'s `serverVersion`. `nil` when the server didn't say.
    static func serverVersionLine(_ version: String?) -> String? {
        guard let version, !version.isEmpty else { return nil }
        return String(localized: "Audiobookshelf \(version)", comment: "Sign-in page server summary: the server's Audiobookshelf version; %@ is the version number")
    }

    /// Batch 490 (REVIEW 2026-11-11 F8): `/status` said `isInit: false` (no root user yet).
    /// Only an explicit `false` counts; a server that didn't say is assumed set up.
    static func serverNeedsSetup(_ status: ServerStatusInfo?) -> Bool {
        status?.isInitialized == false
    }

    static var serverNeedsSetupMessage: String {
        String(localized: "This server hasn\u{2019}t been set up yet. Finish setup in a browser, then try again.", comment: "Sign-in page warning when the Audiobookshelf server has no root user yet")
    }

    /// Batch 490 (REVIEW 2026-11-11 F8): the SSO button's title. The admin's own OpenID
    /// button text when they set one (`ServerStatusInfo.openIDButtonText` already drops
    /// Audiobookshelf's untouched default), otherwise the app's own label.
    static func singleSignOnButtonTitle(serverText: String?) -> String {
        if let serverText, !serverText.isEmpty { return serverText }
        return String(localized: "Sign in with SSO")
    }

    /// Batch 490 (REVIEW 2026-11-11 O4): whether an error on the form is the
    /// redirect-URI one, which gets a Copy button for the address to allow.
    static func errorOffersRedirectURICopy(_ message: String?) -> Bool {
        message == OIDCAuthService.redirectURINotAllowedMessage
    }

    /// Which error string the form should show. This view's own `localError` (the result
    /// of an attempt made here) always wins; `AuthViewModel.errorMessage` is a fallback
    /// only on first run — see `ServerConnectionPurpose.rendersViewModelError`.
    static func displayedError(localError: String?, viewModelError: String?,
                              purpose: ServerConnectionPurpose) -> String? {
        if let localError { return localError }
        return purpose.rendersViewModelError ? viewModelError : nil
    }

    /// Critique 2026-10-06 (harden + clarify): what a failed connection test says, and
    /// which one-tap recoveries go with it. Replaces the single "Can't reach this server.
    /// Check the address…" sentence every transport error used to collapse into.
    struct FailureAdvice: Equatable {
        /// What failed, in one plain sentence.
        let message: String
        /// What to do about it.
        let nextStep: String
        /// Show "Use http://" — a TLS failure on an https address where http hasn't
        /// already been tried. Public hosts still meet the plain-HTTP acknowledgement.
        let offersPlainHTTP: Bool
        /// Show "Open Settings" for iOS's Local Network permission — private hosts only,
        /// on the failures a denied permission can produce.
        let offersLocalNetworkSettings: Bool
    }

    static var genericUnreachableMessage: String { String(localized: "Can\u{2019}t reach this server.") }
    static var localNetworkNextStep: String { String(localized: "ShelfHead needs Local Network access to reach servers on your Wi-Fi. Check it\u{2019}s turned on in Settings, and that this device is on the same network as the server.") }

    /// Pure: chosen only from the classified failure, the address that was tested, and
    /// whether http was already tried — so every branch is pinned by
    /// `ServerConnectionFailureTests` without a network.
    ///
    /// Local Network: per Apple's TN3179 (Understanding local network privacy), an
    /// outgoing TCP connection to a local network address, and resolving a `.local` name,
    /// both need the Local Network privilege, and there is no API that reports whether the
    /// app has it — so the copy says "check", never "you've denied". It's offered for
    /// private hosts on the failures a blocked connection can show up as (timeout, refused,
    /// a `.local` name that won't resolve), and never for public hosts, which it doesn't
    /// affect.
    static func failureAdvice(failure: ServerConnectionFailure?, resolvedURL: String?,
                              triedPlainHTTP: Bool) -> FailureAdvice {
        let comps = resolvedURL.flatMap { URLComponents(string: $0) }
        let host = comps?.host ?? ""
        let isHTTPS = comps?.scheme?.lowercased() == "https"
        let isPrivate = !host.isEmpty && ServerURLRules.isLocalOrPrivateHost(host)
        let isMDNSName = host.lowercased().hasSuffix(".local")

        switch failure {
        case .secureConnection where isHTTPS:
            if triedPlainHTTP {
                return FailureAdvice(
                    message: String(localized: "This server didn\u{2019}t complete a secure (https) connection, and plain http didn\u{2019}t answer either."),
                    nextStep: String(localized: "If it uses a self-signed certificate, iOS won\u{2019}t trust it. Check the port number, and that Audiobookshelf is running."),
                    offersPlainHTTP: false, offersLocalNetworkSettings: false)
            }
            return FailureAdvice(
                message: String(localized: "This server didn\u{2019}t complete a secure (https) connection."),
                nextStep: isPrivate
                    ? String(localized: "It may not use https, which is common on a home network. Try plain http instead.")
                    : String(localized: "It may not use https, or iOS doesn\u{2019}t trust its certificate. You can try plain http, but it isn\u{2019}t encrypted."),
                offersPlainHTTP: true, offersLocalNetworkSettings: false)

        case .timedOut:
            return FailureAdvice(
                message: String(localized: "The server didn\u{2019}t answer in time."),
                nextStep: isPrivate
                    ? localNetworkNextStep
                    : String(localized: "Check the server is running and the port is right. If you reach it over a VPN or Tailscale, make sure that\u{2019}s connected."),
                offersPlainHTTP: false, offersLocalNetworkSettings: isPrivate)

        case .hostNotFound:
            return FailureAdvice(
                message: String(localized: "No server was found with this name."),
                nextStep: isMDNSName
                    ? String(localized: "A name ending in .local only works on the same Wi-Fi as the server, and needs ShelfHead\u{2019}s Local Network access turned on in Settings.")
                    : String(localized: "Check the spelling. If you reach it over a VPN or Tailscale, make sure that\u{2019}s connected."),
                offersPlainHTTP: false, offersLocalNetworkSettings: isMDNSName)

        case .cannotConnect:
            return FailureAdvice(
                message: String(localized: "The server refused the connection."),
                nextStep: isPrivate
                    ? String(localized: "Check the port number (Audiobookshelf uses 13378 by default) and that the server is running. ShelfHead also needs Local Network access, in Settings.")
                    : String(localized: "Check the port number and that the server is running."),
                offersPlainHTTP: false, offersLocalNetworkSettings: isPrivate)

        case .offline:
            return FailureAdvice(
                message: String(localized: "This device isn\u{2019}t connected to a network."),
                nextStep: String(localized: "Connect to Wi-Fi or mobile data, then test again."),
                offersPlainHTTP: false, offersLocalNetworkSettings: false)

        case .httpStatus(let code) where code == 401 || code == 403:
            return FailureAdvice(
                message: String(localized: "The server turned the test away (HTTP \(code))."),
                nextStep: String(localized: "If it sits behind Cloudflare Access, Authelia, or a similar gate, add its headers under Advanced below and test again."),
                offersPlainHTTP: false, offersLocalNetworkSettings: false)

        case .httpStatus(let code) where code >= 500:
            return FailureAdvice(
                message: String(localized: "The server answered with an error (HTTP \(code))."),
                nextStep: String(localized: "If it sits behind a reverse proxy, check that Audiobookshelf itself is running."),
                offersPlainHTTP: false, offersLocalNetworkSettings: false)

        case .httpStatus(let code):
            return FailureAdvice(
                message: String(localized: "Something answered, but not the way Audiobookshelf does (HTTP \(code))."),
                nextStep: String(localized: "Check the address, including any path after the server name."),
                offersPlainHTTP: false, offersLocalNetworkSettings: false)

        case .secureConnection, .other, nil:
            return FailureAdvice(
                message: genericUnreachableMessage,
                nextStep: String(localized: "Check the address, that the server is running, and that this device can reach it."),
                offersPlainHTTP: false, offersLocalNetworkSettings: false)
        }
    }

    /// The address a "Use http://" tap rewrites the field to: the tested https address
    /// with its scheme swapped (`ServerURLRules.plainHTTPVariant`).
    static func plainHTTPRetryAddress(resolvedURL: String?) -> String? {
        resolvedURL.flatMap { ServerURLRules.plainHTTPVariant(of: $0) }
    }

    /// The address a sign-in uses. Critique 2026-10-06 (harden): the test may have
    /// resolved a scheme-less LAN address to http (`usedPlainHTTPFallback`), and
    /// `login()` re-normalising the TYPED text would put `https://` back in front of it
    /// and fail. So once a test has resolved an address, that's what's signed into —
    /// for every other result it's the same string `normalizedServerURL` would produce
    /// from the typed text anyway.
    static func signInAddress(typedURL: String, resolvedURL: String?) -> String {
        if let resolvedURL, !resolvedURL.isEmpty { return resolvedURL }
        return typedURL
    }

    /// Success line for a passing test — says so when the scheme-less address only
    /// answered over plain http, so the http shown underneath isn't a surprise.
    static func reachableMessage(usedPlainHTTPFallback: Bool) -> String {
        usedPlainHTTPFallback
            ? String(localized: "Reachable over plain http, and it looks like Audiobookshelf. That\u{2019}s normal on a home network.")
            : String(localized: "Reachable, and it looks like Audiobookshelf.")
    }

    /// Caption under the "Remember password on this device" toggle, chosen from its
    /// current value — mirrors the on/off explanation pattern already used for the
    /// insecure-connection acknowledgement above (`"You've chosen to continue anyway."`).
    /// Kept in sync in spirit with `AccountSecuritySettingsView`'s own footer for the same
    /// setting ("When off, no password is kept for automatic re-login — for this server or
    /// any other saved server."); phrased for the moment of signing in rather than for a
    /// setting already in effect.
    static func rememberPasswordFooter(isOn: Bool) -> String {
        isOn
            ? String(localized: "Your password is stored in this device's Keychain and used to sign back in automatically if your session expires or you switch back to this server.")
            : String(localized: "Your password won't be saved on this device. You'll be asked to re-enter it if your session expires or you switch back to this server.")
    }
}

/// The one Audiobookshelf sign-in surface, shared by `LoginView` (first run) and
/// `AddServerView` (adding another server from Settings). Everything either screen can do
/// — username/password, OIDC/SSO, custom reverse-proxy headers with their reserved-name
/// and control-character warnings, the connection test with a specific diagnosis per
/// outcome, and the plain-HTTP-to-a-non-local-host confirmation — is available in both.
///
/// Laid out as two **pages**, one on screen at a time (device feedback, 14 Sep 2026 —
/// "hide the username/pwd, custom http headers and SSO until connection test passes...
/// reduce clutter", then "after pressing test connection and it succeeds it should only
/// show the next login page, should not be a scroll down. should be a live sign in
/// page"):
///
/// 1. **Server** (`serverForm`) — branding on first run, address, Test Connection, the
///    per-outcome diagnosis, a collapsed **Advanced: custom HTTP headers** disclosure,
///    the "Sign in anyway" hatch under a failed diagnosis, and "Where do I find this?".
/// 2. **Sign in** (`signInForm`) — a compact `serverSummarySection` (host, a lock/unlock/
///    question glyph matching how the connection was established, and "Change server"),
///    then username, password, "Remember password on this device", the primary button,
///    and a collapsed **Other sign-in options** disclosure holding SSO.
///
/// The flow moves forward on the rising edge of
/// `ServerConnectionRules.showsCredentials` — a passing test, an accepted insecure
/// connection, or the explicit bypass — and the rendered page is always filtered through
/// `ServerConnectionRules.resolvedPage`, so losing the result (any edit to the address)
/// can never leave anyone stranded on a sign-in page with nothing behind it. "Change
/// server" goes back without resetting anything; "Continue to sign in" comes forward
/// again if nothing was edited. A prefilled Add Server still starts on page 1.
///
/// SB-1 had removed the old stepper's gate outright because a server behind a
/// reverse-proxy gate answers `/ping` with the proxy's own block page, reported as
/// `.notAudiobookshelf` — and with the whole form gated, such a user could never reach
/// the header editor that would have let the ping through in the first place. That
/// lesson is kept: the header editor is in **step 1**, reachable with no passing test,
/// auto-expanded on exactly that outcome, and the `.notAudiobookshelf` copy points at
/// it. The test forwards the headers typed into this form (which
/// `ReachabilityStore.testConnection(rawURL:customHeaders:)` has always accepted but had
/// no caller for — see item 28 there), so supplying them and re-testing is what turns
/// that outcome into a pass. For the residual case headers can't fix — a gate that
/// blocks or rewrites `/ping` whatever is sent — "Sign in anyway" appears under a
/// `.notAudiobookshelf`/`.unreachable` diagnosis (`signInAnywayButton`,
/// `ServerConnectionRules.offersTestBypass`). Between the two, no server that can
/// actually be signed into is unreachable through this form.
///
/// Lives in this file rather than one of its own: the iOS app target still lists its
/// sources explicitly in `project.pbxproj` (only `ShelfHeadTests` and the Watch/widget
/// targets use synchronized folder groups), so a new source file there would need a
/// project change. `LoginView.swift` is a thin wrapper over this type.
struct ServerConnectionView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    /// Critique 2026-10-06 (harden): names the book a confirmed account switch stops.
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    let purpose: ServerConnectionPurpose

    @State private var serverURL: String
    @State private var username: String
    @State private var password = ""
    @State private var showPassword = false
    /// Batch 490 (REVIEW 2026-11-11 O6): which sign-in is running (`nil` when none), so
    /// only that control spins. `isConnecting` below is the old yes/no view of it.
    @State private var connectingMethod: ServerConnectionRules.SignInMethod?
    private var isConnecting: Bool { connectingMethod != nil }
    @State private var localError: String?
    /// Batch 490 (REVIEW 2026-11-11 O4): brief "Copied" state for the redirect URI.
    @State private var copiedRedirectURI = false

    /// "Remember password on this device" — the same setting as Account & Security's
    /// "Stay signed in (save password)" toggle (`SettingsKeys.storePassword`, default
    /// off), surfaced here too so a brand-new sign-in can opt in without a trip to
    /// Settings afterwards. Bound directly to the shared `@AppStorage` key rather than a
    /// local `@State` copied in at submit time: `@AppStorage` writes to `UserDefaults`
    /// synchronously on every toggle, so by the time the user taps Sign In/Connect —
    /// always a separate, later tap — `SettingsStore.storePassword` (read at
    /// `AuthViewModel.login(...)` line ~700 and again inside `AccountStore.upsert`) already
    /// sees the value this toggle just set. There's no async gap to guard against.
    ///
    /// Turning this off here does NOT clear any previously saved password for another
    /// account: that "wipe every saved password" side effect lives entirely in
    /// `AccountSecuritySettingsView`'s own `onChange(of: storePassword)`, which only runs
    /// while that view's own `Toggle` instance is on screen — never mounted during
    /// sign-in. `AccountStore.upsert` reads this same flag independently and, when off,
    /// only deletes the password for the account being signed into right now
    /// (`account.passwordKey`, scoped by account id) — never another saved account's.
    @AppStorage(SettingsKeys.storePassword) private var storePassword = false

    // Optional connection diagnostic (was Step 1 of the old first-run stepper).
    @State private var isTesting = false
    @State private var testResult: ReachabilityStore.ConnectionTestResult?
    @State private var showWhereDoIFindThis = false

    // VD-7 (docs/design-review.md, Round 4): `brandingSection`'s glyph sat directly
    // above the "ShelfHead" title (already Dynamic-Type-aware, see that title's own
    // HIG audit 2026-09-17 M6 comment) as a fixed `.font(.system(size: 64))` — the
    // same "splash glyph" role AX-5 fixed for `AppLockView`. Capped the same way
    // (`min(scaled, base * factor)`) so it grows with the title but doesn't balloon
    // past what still reads as an icon above it. Base value (64) is the screen's
    // original literal, so default-size rendering is unchanged.
    @ScaledMetric(relativeTo: .largeTitle) private var brandGlyphSize: CGFloat = 64
    private var cappedBrandGlyphSize: CGFloat { min(brandGlyphSize, 64 * 1.5) }

    /// Custom HTTP headers for a reverse proxy in front of this server (Cloudflare
    /// Access, Authelia forward-auth, an nginx `auth_request` gate). Optional — empty by
    /// default, and the disclosure in step 1 is collapsed unless the user opens it or
    /// `ServerConnectionRules.headersDisclosureStartsExpanded` opens it for them.
    // No default here: `init` sets it (prefilled headers). Under the iOS 27 SDK's `@State`
    // macro a declaration default would silently win over the init assignment (TN3211).
    @State private var headerPairs: [EditableHeaderPair]
    @State private var showHeadersSection = false

    /// "Other sign-in options" (SSO) inside step 2 — collapsed by default, per the same
    /// device feedback that moved the header editor behind a disclosure. Held at view
    /// level rather than inside the section, same as `showHeadersSection`, so it isn't
    /// implicitly reset by SwiftUI just from step 2 unmounting/remounting as pages swap —
    /// only an actual edit to the server address (`onChange(of: serverURL)` below) resets
    /// it on purpose, since an auto-expansion earned by one server's advertised OpenID
    /// shouldn't carry over to a different address that hasn't been tested yet.
    @State private var showOtherSignInOptions = false

    /// Set only by the "Sign in anyway" button under a failed diagnosis — the escape
    /// hatch for a gate that blocks the connection test no matter what headers are sent.
    /// Cleared by any edit to the address, alongside the test result itself, so it can
    /// never carry over from one server to another.
    @State private var bypassedTest = false

    /// Set only after the user explicitly accepts the insecure connection — either from
    /// the alert `AuthViewModel` raises, or from the inline "Continue Anyway" on a
    /// `.reachableInsecure` test result. Passed through to whichever login call needs it.
    @State private var acknowledgedInsecureConnection = false
    /// Which action to retry once the insecure-connection alert is confirmed —
    /// `connect()` or `signInWithSSO()` — since either can trigger the same block.
    @State private var pendingRetry: (() -> Void)?

    /// Critique 2026-10-06 (harden): a sign-in from Add Server while signed in to another
    /// server is an account switch (`AuthViewModel.addServerSignInKind`). Set when Connect
    /// or SSO is tapped in that case; the shared `ServerSwitchConfirmation` dialog runs the
    /// sign-in only once confirmed.
    @State private var pendingSwitch: PendingSwitch?
    private enum PendingSwitch: Equatable { case password, singleSignOn }

    /// The saved server (first-run screen's list) whose sign-in is in flight.
    @State private var signingInSavedAccountId: String?

    /// Critique 2026-10-06 (harden): set when the first-run list fills this form in for a
    /// saved server with no stored password: `ServerConnectionRules.passwordNeededPrompt`,
    /// shown at the top of both pages (`shownPasswordPrompt`).
    @State private var passwordNeededPrompt: String?
    /// The same line when the form was opened for such a server
    /// (`AddServerView(reauthenticating:)`). A plain `let`, not `@State` assigned in
    /// `init`, for the `@State` macro reason on `headerPairs`.
    private let initialPasswordPrompt: String?
    /// Editing the address to a different server drops `initialPasswordPrompt`.
    @State private var initialPasswordPromptDismissed = false
    /// Run a connection test once the address field's `onChange` has cleared the old
    /// result — the race that kept the first-run list from testing a filled-in address.
    @State private var testAfterAddressChange = false
    /// The running connection test, so the primary button can cancel it (Critique
    /// 2026-10-06: a test can take up to 16 s, https then http, and couldn't be stopped).
    @State private var testTask: Task<Void, Never>?
    /// Opened for a saved server (`AddServerView(reauthenticating:)`): test at once, so the
    /// form lands on the password.
    private let testsOnAppear: Bool

    /// Which page the user last asked for. Never rendered directly — `resolvedPage`
    /// filters it through `ServerConnectionRules.resolvedPage` so losing the test result
    /// can't strand anyone on a sign-in page with nothing behind it.
    @State private var page: ServerConnectionRules.Page = .server

    @FocusState private var focusedField: Field?
    private enum Field: Hashable {
        case serverURL, username, password
    }

    /// Moves VoiceOver to the top of whichever page just came in, which is what makes a
    /// page swap legible without sight of the animation.
    ///
    /// Deliberately `@AccessibilityFocusState` + `.accessibilityFocused` rather than
    /// posting `AccessibilityNotification.ScreenChanged` by hand: it's the SwiftUI-native
    /// spelling of the same thing, it names the element to land on instead of leaving
    /// that to VoiceOver, and it needs no UIKit import (see `CLAUDE.md` > Stack).
    @AccessibilityFocusState private var accessibilityFocusedPage: ServerConnectionRules.Page?

    init(purpose: ServerConnectionPurpose, prefillServerURL: String = "", prefillUsername: String = "",
         prefillHeaders: [String: String] = [:], passwordNeededPrompt: String? = nil) {
        // Plain stored properties first: the `@State` macro (iOS 27 SDK) rejects a
        // `@State` assignment before every other stored property is initialised.
        self.purpose = purpose
        self.initialPasswordPrompt = passwordNeededPrompt
        self.testsOnAppear = passwordNeededPrompt != nil && !prefillServerURL.isEmpty
        _serverURL = State(initialValue: prefillServerURL)
        _username = State(initialValue: prefillUsername)
        _headerPairs = State(initialValue: prefillHeaders.sorted { $0.key < $1.key }
            .map { EditableHeaderPair(key: $0.key, value: $0.value) })
    }

    /// The password-needed line on screen, if any.
    private var shownPasswordPrompt: String? {
        passwordNeededPrompt ?? (initialPasswordPromptDismissed ? nil : initialPasswordPrompt)
    }

    private var customHeadersDictionary: [String: String] {
        ServerConnectionRules.customHeaders(from: headerPairs)
    }

    private var isValid: Bool {
        ServerConnectionRules.canSubmitPassword(serverURL: serverURL, username: username, password: password)
    }

    private var isInsecureURL: Bool {
        ServerConnectionRules.isInsecureURLText(serverURL)
    }

    private var displayedError: String? {
        ServerConnectionRules.displayedError(localError: localError,
                                             viewModelError: authViewModel.errorMessage,
                                             purpose: purpose)
    }

    /// Step 2 is on screen only once the connection test has actually passed — see
    /// `ServerConnectionRules.showsCredentials`.
    private var showsCredentials: Bool {
        ServerConnectionRules.showsCredentials(for: testResult,
                                               insecureAccepted: acknowledgedInsecureConnection,
                                               bypassed: bypassedTest)
    }

    /// What the server said it accepts, when we know — see
    /// `ServerConnectionRules.advertisesSingleSignOn`. `ReachabilityStore.testConnection`
    /// now follows a passing `/ping` with an unauthenticated `GET /status` call and
    /// carries the result on `ConnectionTestResult.authMethods`, so this is just that
    /// field: `nil` until a test has run, `nil` again for a failing outcome or an older
    /// server that didn't report the field, and the actual list once one has. The SSO
    /// sign-in page's layout (`signInLayout`) is decided from this.
    private var advertisedAuthMethods: [String]? { testResult?.authMethods }

    /// Batch 495 (REVIEW 2026-11-11 O3): password fields, SSO button, or both.
    private var signInLayout: ServerConnectionRules.SignInLayout {
        ServerConnectionRules.signInLayout(authMethods: advertisedAuthMethods)
    }

    /// Batch 490 (REVIEW 2026-11-11 F8): the rest of what `/status` said.
    private var serverStatus: ServerStatusInfo? { testResult?.serverStatus }

    /// Batch 490 (REVIEW 2026-11-11 O6): see `ServerConnectionRules.statusRowShowsSpinner`.
    private var showsStatusSpinner: Bool {
        ServerConnectionRules.statusRowShowsSpinner(connecting: connectingMethod, page: resolvedPage,
                                                    ssoOptionsExpanded: ServerConnectionRules.ssoButtonVisible(
                                                        layout: signInLayout, disclosureExpanded: showOtherSignInOptions))
    }

    /// The page actually on screen. See `ServerConnectionRules.resolvedPage`.
    private var resolvedPage: ServerConnectionRules.Page {
        ServerConnectionRules.resolvedPage(requested: page, showsCredentials: showsCredentials)
    }

    private var serverSummaryStyle: ServerConnectionRules.ServerSummaryStyle {
        ServerConnectionRules.serverSummaryStyle(for: testResult,
                                                 insecureAccepted: acknowledgedInsecureConnection)
    }

    private var serverSummaryHost: String {
        ServerConnectionRules.serverSummaryHost(resolvedURL: testResult?.resolvedURL,
                                                typedURL: serverURL)
    }

    var body: some View {
        Group {
            switch purpose {
            case .firstRun: firstRunChrome
            case .addAccount: addAccountChrome
            }
        }
        // `login()`/`loginWithOIDC()` refuse to send anything to a plain-HTTP, non-local
        // server until this is confirmed — see `AuthViewModel.pendingInsecureConnection`.
        // Whichever action (password or SSO) triggered it is retried with the flag set
        // once the user explicitly opts in; declining just leaves the form as-is.
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .alert("Insecure Connection", isPresented: insecureConnectionAlertBinding) {
            Button("Cancel", role: .cancel) {
                authViewModel.pendingInsecureConnection = nil
                connectingMethod = nil
            }
            Button("Allow Insecure Connection", role: .destructive) {
                acknowledgedInsecureConnection = true
                authViewModel.pendingInsecureConnection = nil
                pendingRetry?()
            }
        } message: {
            // HIG audit 2026-09-17 L5: trimmed from three sentences to one — the fuller
            // explanation (what travels in the clear, who could read it) already appears
            // inline in `testResultView`'s `.reachableInsecure` case just above this alert
            // can fire, so the alert itself only needs the risk stated once, briefly.
            Text("This connection is unencrypted — anyone on the network path could read or alter your data.")
        }
        .systemChromeTint()
        // Critique 2026-10-06 (harden): Add Server was the one account switch with no
        // confirmation. Same dialog and copy as every other switch.
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .confirmationDialog(
            ServerSwitchConfirmation.title(host: serverSummaryHost),
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            titleVisibility: .visible
        ) {
            if let method = pendingSwitch {
                Button(ServerSwitchConfirmation.confirmButton(opensBook: false)) {
                    pendingSwitch = nil
                    switch method {
                    case .password: performConnect(endingCurrentSession: true)
                    case .singleSignOn: performSignInWithSSO(endingCurrentSession: true)
                    }
                }
                Button("Cancel", role: .cancel) { pendingSwitch = nil }
            }
        } message: {
            if let text = ServerSwitchConfirmation.message(currentBookTitle: playerViewModel.currentBook?.title) {
                Text(text)
            }
        }
        .systemChromeTint()
        .task {
            // The first-run screen lists saved servers (left by Sign Out); make sure the
            // list is current on a cold launch with no session.
            if purpose == .firstRun { await authViewModel.loadAccounts() }
        }
        .onAppear {
            // Critique 2026-10-06 (harden): opened for a saved server with no stored
            // password — test straight away so the form moves on to the password field.
            if testsOnAppear && testResult == nil && !isTesting { startTest() }
        }
        .onDisappear { testTask?.cancel() }
    }

    // MARK: - Chrome

    private var firstRunChrome: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            pages
        }
    }

    private var addAccountChrome: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                pages
            }
            // Follows the page rather than staying "Add Server" throughout: the sheet is
            // doing two different jobs and the title is the only chrome that can say
            // which. Matches how the app's other multi-step sheets retitle themselves.
            .navigationTitle(resolvedPage == .signIn ? Text("Sign In") : Text("Add Server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SheetCancelButton { dismiss() }
                        // Critique 2026-10-06 (harden): nav-bar chrome is monochrome.
                        .monochromeToolbarItem()
                }
                // Only on the sign-in page. On the server page there are no credential
                // fields to submit, and a permanently visible (if disabled) Connect reads
                // as a second, contradictory path out. Conditioned at the toolbar-content
                // level rather than inside the item, so the server page has no empty slot.
                if resolvedPage == .signIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        // iPhone Duo (§2): Connect isn't a form Save, so a symbol, not the checkmark.
                        // Batch 490 (REVIEW 2026-11-11 O2): titled "Sign In" like the in-form
                        // button it duplicates, with a "go" symbol rather than `link`.
                        // Batch 495 (O3): on an SSO-only server this starts SSO, not a password sign-in.
                        Button {
                            if signInLayout == .singleSignOnOnly { signInWithSSO() } else { connect() }
                        } label: {
                            Label("Sign In", systemImage: "arrow.right.circle")
                        }
                            .disabled(signInLayout == .singleSignOnOnly
                                      ? (!ServerConnectionRules.canStartSingleSignOn(serverURL: serverURL) || isConnecting)
                                      : (!isValid || isConnecting))
                            .monochromeToolbarItem()
                    }
                    .shelfVisibilityPriority(.high)
                }
            }
        }
    }

    // MARK: - Pages

    /// One page on screen at a time, not one scrolling form with a second half revealed
    /// underneath it (device feedback, 14 Sep 2026 — "should only show the next login
    /// page, should not be a scroll down. should be a live sign in page").
    ///
    /// Each page is its own `Form`, so the swap is a whole-screen transition rather than
    /// rows animating inside a list — which is where SwiftUI transitions inside a `Form`
    /// tend to look wrong. The two transitions are fixed rather than
    /// direction-dependent, and still read correctly both ways: the server page always
    /// enters and leaves by the leading edge, the sign-in page always by the trailing
    /// edge, so forward is "server slides out left, sign-in slides in from the right"
    /// and back is its exact mirror. `shelfAnimation` (not a bare `.animation`) is what
    /// drives them, so Reduce Motion suppresses the slide and the swap is instant.
    private var pages: some View {
        Group {
            switch resolvedPage {
            case .server:
                serverForm
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .signIn:
                signInForm
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .shelfAnimation(.easeInOut(duration: 0.28), value: resolvedPage)
        .onAppear { syncHeadersDisclosure() }
        // Auto-open Advanced when the test result says a proxy gate is the likely cause.
        .onChange(of: testResult) { _, _ in syncHeadersDisclosure() }
        // A passing test, an accepted insecure connection, or the "Sign in anyway"
        // bypass all express themselves through this one flag — so the rising edge of it
        // is the single place the flow moves forward, and there's exactly one animation.
        // A prefilled Add Server never trips it (there is no test result yet), so a
        // prefill still starts on the server page, as asked.
        .onChange(of: showsCredentials) { _, nowShowing in
            guard nowShowing else { return }
            page = .signIn
            focusCredentialsAfterReveal()
        }
        .onChange(of: resolvedPage) { _, newPage in
            // VoiceOver lands at the top of whatever just came in.
            accessibilityFocusedPage = newPage
        }
    }

    private var serverForm: some View {
        Form {
            if purpose.showsBranding {
                brandingSection
            }
            if shownPasswordPrompt != nil {
                passwordNeededSection
            }
            if purpose == .firstRun && !authViewModel.accounts.isEmpty {
                savedServersSection
            }
            serverSection
            if displayedError != nil || showsStatusSpinner {   // Batch 490 (REVIEW 2026-11-11 O6)
                statusSection
            }
            moreOptionsSection
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Saved servers (first run)

    /// Critique 2026-10-06 (harden): Sign Out is now this server only, so the sign-in
    /// screen can be reached with other servers still saved. They're listed here, one tap
    /// from signing in: a server with a stored password or SSO signs in straight away
    /// (`AuthViewModel.switchAccount`); one without fills in the form below, so only Test
    /// Connection and the password are left.
    private var savedServersSection: some View {
        Section {
            ForEach(authViewModel.accounts) { account in
                Button {
                    signInToSavedServer(account)
                } label: {
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(Color.shelfMuted)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.username)
                                .foregroundStyle(Color.shelfCream)
                            Typo.supporting(Text(account.displayHost))
                                .foregroundStyle(Color.shelfMuted)
                        }
                        Spacer()
                        if signingInSavedAccountId == account.id
                            || authViewModel.switchingAccountIdAfterSignOut == account.id {
                            ProgressView()
                                .shelfSpinner()
                                .accessibilityLabel("Signing in")
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(isConnecting || signingInSavedAccountId != nil
                          || authViewModel.switchingAccountIdAfterSignOut != nil)
                .accessibilityHint("Signs in to this server")
            }
        } header: {
            Text("Saved servers")
        } footer: {
            Typo.fine(Text("Or add a different server below."))
                .foregroundStyle(Color.shelfMuted)
        }
        .listRowBackground(Color.shelfCard)
    }

    private func signInToSavedServer(_ account: ServerAccount) {
        Haptics.selection()
        localError = nil
        authViewModel.errorMessage = nil
        Task {
            let method = await authViewModel.reauthenticationMethod(for: account)
            guard AuthViewModel.switchEntry(for: method) == .confirmSwitch else {
                fillInForPassword(account)
                return
            }
            // A saved plain-HTTP remote server can raise the insecure-connection prompt;
            // Allow then retries the switch with the acknowledgement stored.
            pendingRetry = {
                Task {
                    signingInSavedAccountId = account.id
                    let result = await authViewModel.confirmInsecureConnectionAndSwitch(account)
                    signingInSavedAccountId = nil
                    connectingMethod = nil
                    showSavedServerOutcome(result.outcome, for: account)
                }
            }
            signingInSavedAccountId = account.id
            let outcome = await authViewModel.switchAccount(account)
            signingInSavedAccountId = nil
            showSavedServerOutcome(outcome, for: account)
        }
    }

    /// Critique 2026-10-06 (harden): what a saved-server tap on the first-run screen
    /// shows. `switchAccount` returns the reason instead of leaving it in `errorMessage`.
    private func showSavedServerOutcome(_ outcome: AuthViewModel.AccountSwitchOutcome, for account: ServerAccount) {
        switch outcome {
        case .switched, .cancelled, .awaitingInsecureConfirmation:
            // Signed in (this screen goes away), the SSO sheet was closed, or the
            // Insecure Connection alert is up with `pendingRetry` set above.
            break
        case .needsPassword:
            fillInForPassword(account)
        case .failed(let failure):
            localError = ServerSwitchFailureCopy.inlineMessage(failure)
        }
    }

    /// Critique 2026-10-06 (harden): a saved server with nothing stored to sign in with.
    /// This used to fill in the address silently. It now says what's needed
    /// (`passwordNeededPrompt`) and tests the address, so the form moves on to the
    /// password with the keyboard up (`focusCredentialsAfterReveal` picks the password
    /// field when the username is filled in).
    private func fillInForPassword(_ account: ServerAccount) {
        localError = nil
        passwordNeededPrompt = ServerConnectionRules.passwordNeededPrompt(
            username: account.username, host: account.displayHost, switchesAccount: false)
        username = account.username
        password = ""
        headerPairs = (account.customHeaders ?? [:]).sorted { $0.key < $1.key }
            .map { EditableHeaderPair(key: $0.key, value: $0.value) }
        if serverURL == account.serverURL {
            // No address change, so no `onChange` to wait for. A result already in hand
            // for this address moves the form on by itself; otherwise test now.
            if showsCredentials {
                page = .signIn
                focusCredentialsAfterReveal()
            } else {
                startTest()
            }
        } else {
            testAfterAddressChange = true
            serverURL = account.serverURL
        }
    }

    /// Critique 2026-10-06 (harden + clarify): the line saying a password is needed. Info,
    /// not an error: muted glyph, readable ink.
    private var passwordNeededSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "key.fill")
                    .foregroundStyle(Color.shelfMuted)
                    .accessibilityHidden(true)
                Typo.supporting(Text(shownPasswordPrompt ?? ""))
                    .foregroundStyle(Color.shelfCream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.shelfCard)
    }

    private var signInForm: some View {
        Form {
            if shownPasswordPrompt != nil && signInLayout.showsPasswordFields {   // Batch 495 (O3)
                passwordNeededSection
            }
            serverSummarySection
            credentialsSection
            if displayedError != nil || showsStatusSpinner {   // Batch 490 (REVIEW 2026-11-11 O6)
                statusSection
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// Expand-only: never collapses a disclosure the user opened themselves.
    private func syncHeadersDisclosure() {
        if ServerConnectionRules.headersDisclosureStartsExpanded(result: testResult,
                                                                 hasHeaders: !headerPairs.isEmpty) {
            showHeadersSection = true
        }
    }

    // MARK: - Branding

    private var brandingSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "headphones.circle.fill")
                    .font(.system(size: cappedBrandGlyphSize))
                    // Batch 490 (REVIEW 2026-11-11 O6): solid accent text colour, as on the
                    // launch splash, not a raw `shelfAmber` gradient.
                    .foregroundStyle(Color.shelfAmberText)
                Text("ShelfHead")
                    // HIG audit 2026-09-17 M6: fixed 32pt didn't grow with Dynamic
                    // Type; a text-style-relative rounded font (matching
                    // `YearInReviewView`'s `.font(.system(.largeTitle, design:
                    // .rounded))` pattern) scales properly instead.
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.shelfCream)
                Text("Connect to your Audiobookshelf server")
                    .font(.subheadline)
                    .foregroundStyle(Color.shelfMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            // One VoiceOver stop for what is purely a title block, rather than three.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            TextField("https://your-server.com", text: $serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                // Return now runs the test rather than jumping to a username field that
                // isn't on screen until the test passes.
                .submitLabel(.go)
                .focused($focusedField, equals: .serverURL)
                .accessibilityLabel("Server address")
                .accessibilityFocused($accessibilityFocusedPage, equals: .server)
                .onSubmit {
                    guard !serverURL.trimmingCharacters(in: .whitespaces).isEmpty, !isTesting else { return }
                    startTest()
                }
                .onChange(of: serverURL) { _, _ in
                    // Any edit invalidates a previous test result — don't let a stale
                    // "reachable" linger against a changed URL — and re-arms the
                    // insecure-connection confirmation, so acknowledging one host never
                    // silently carries over to a different one. Since step 2 is derived
                    // from both of those, clearing them also re-hides the credential
                    // fields: a changed address has to be re-tested before it can be
                    // signed into. The "Sign in anyway" bypass goes with it — it was
                    // granted against one specific address and one specific failed
                    // diagnosis, neither of which still applies. Same for an opened
                    // "Other sign-in options" disclosure (Batch 495: nothing auto-opens
                    // it any more, so this only drops the listener's own expansion).
                    testResult = nil
                    acknowledgedInsecureConnection = false
                    bypassedTest = false
                    showOtherSignInOptions = false
                    // Keep the requested page in step with the derivation. `resolvedPage`
                    // would send us back here anyway now that `showsCredentials` is
                    // false, but leaving a stale `.signIn` request parked in state would
                    // make the next passing test jump forward without an animation.
                    page = .server
                    // A test still running is for the old address.
                    if isTesting { cancelTest() }
                    // Critique 2026-10-06 (harden): a saved server filled in by the
                    // first-run list is tested once its old result has gone.
                    if testAfterAddressChange {
                        testAfterAddressChange = false
                        startTest()
                    } else {
                        // Typing a different address leaves that saved server behind.
                        passwordNeededPrompt = nil
                        initialPasswordPromptDismissed = true
                    }
                }

            // Critique 2026-10-06 (clarify): page 1 had no primary-looking action — Test
            // Connection was a tinted row level with "Where do I find this?", Advanced
            // and Continue. Now it's the page's one `shelfButtonStyle` primary (the same
            // pinned-in-form pattern as Sign In on page 2). Once a passing result is in
            // hand (back here via "Change server"), the primary becomes "Continue to sign
            // in" instead, so there's still exactly one.
            primaryServerAction

            if let testResult {
                testResultView(testResult)
            }

            whereDoIFindThisDisclosure
        } header: {
            Text("1\u{2002}\u{2002}Server")
        } footer: {
            Typo.fine(VStack(alignment: .leading, spacing: Space.s) {
                Text("Test the address to check it answers and really is Audiobookshelf. Sign-in appears once it passes.")
                    .fixedSize(horizontal: false, vertical: true)
                // Advisory only, and shown before any test has run — the actual gate is
                // `AuthViewModel.requiresInsecureConnectionConfirmation`, which exempts
                // local/private hosts. Lives with the address it describes now that the
                // credentials section it used to sit under can be off screen.
                if isInsecureURL {
                    // Critique 2026-10-06 (harden): was raw `.orange` text. Alarm colour
                    // on the glyph only; the sentence stays in the footer's readable ink.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.shelfOrange)
                            .accessibilityHidden(true)
                        Text("This is an unencrypted (http) connection. Use https unless this server is on your trusted local network.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            })
            .foregroundStyle(Color.shelfMuted)
        }
        .listRowBackground(Color.shelfCard)
    }

    /// The page's single primary action. See the comment at its call site.
    @ViewBuilder
    private var primaryServerAction: some View {
        if showsCredentials {
            Button {
                Haptics.selection()
                page = .signIn
            } label: {
                Text("Continue to sign in")
                    .shelfButtonStyle()
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: Space.s, leading: Space.l, bottom: Space.s, trailing: Space.l))
        } else {
            let isEmpty = serverURL.trimmingCharacters(in: .whitespaces).isEmpty
            // Critique 2026-10-06 (harden): while testing, the primary cancels the test
            // (it can take up to 16 s, https then http). The spinner stays beside it, so
            // the button still says a test is running.
            Button {
                if isTesting {
                    Haptics.selection()
                    cancelTest()
                } else {
                    startTest()
                }
            } label: {
                HStack(spacing: Space.s) {
                    if isTesting {
                        ProgressView()
                            .tint(Color.onAccent)
                    }
                    Text(isTesting ? LocalizedStringKey("Cancel") : LocalizedStringKey("Test Connection"))
                }
                .shelfButtonStyle()
            }
            .buttonStyle(.plain)
            .disabled(isEmpty && !isTesting)
            .opacity(isEmpty && !isTesting ? 0.6 : 1)
            .listRowInsets(EdgeInsets(top: Space.s, leading: Space.l, bottom: Space.s, trailing: Space.l))
            .accessibilityLabel(isTesting ? Text("Cancel connection test") : Text("Test Connection"))
            .accessibilityValue(isTesting ? Text("Testing") : Text(verbatim: ""))
            .accessibilityHint(isTesting
                ? Text("Stops the test. You can test again or change the address.")
                : Text("Checks that this address answers and really is an Audiobookshelf server. Sign-in appears once it passes."))
        }
    }

    /// Critique 2026-10-06 (clarify): the quiet tail of page 1 — the Advanced header
    /// editor (moved down out of the primary flow; it still auto-opens on the
    /// `.notAudiobookshelf` outcome a gate produces, via `syncHeadersDisclosure`) and, on
    /// first run only, a "Don't have a server yet?" link for someone who installed the
    /// app before Audiobookshelf.
    private var moreOptionsSection: some View {
        Section {
            advancedHeadersDisclosure
            if purpose == .firstRun, let url = URL(string: "https://www.audiobookshelf.org") {
                Link(destination: url) {
                    HStack(spacing: Space.s) {
                        Typo.secondaryAction(Text("Don\u{2019}t have a server yet? Learn about Audiobookshelf"))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.shelfMuted)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityHint("Opens audiobookshelf.org in Safari.")
            }
        }
        .listRowBackground(Color.shelfCard)
    }

    /// One specific message per outcome, instead of the single generic error a failed
    /// login gives. Shows the resolved (normalized) address whenever
    /// `normalizedServerURL` managed to parse one, so the user can see what was actually
    /// tested — useful for catching a typo it corrected in a way they didn't expect.
    @ViewBuilder
    private func testResultView(_ result: ReachabilityStore.ConnectionTestResult) -> some View {
        switch result.outcome {
        case .reachable:
            resultMessage(
                icon: "checkmark.circle.fill",
                text: ServerConnectionRules.reachableMessage(usedPlainHTTPFallback: result.usedPlainHTTPFallback),
                resolved: result.resolvedURL,
                // Batch 490 (REVIEW 2026-11-11 V6): teal means finished only; "reachable"
                // is a cream checkmark.
                iconColor: Color.shelfCream
            )

        case .reachableInsecure:
            // Critique 2026-10-06 (harden): the risk paragraph was `Typo.fine` (Caption 2)
            // in raw orange — the smallest, lowest-contrast text on the page carrying the
            // most important sentence on it. Now `Typo.supporting` in readable ink, with
            // the alarm colour kept to the glyph.
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.shelfOrange)
                        .accessibilityHidden(true)
                    Typo.supporting(Text("Reachable, but only over plain HTTP."), weight: .semibold)
                        .foregroundStyle(Color.shelfCream)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let resolved = result.resolvedURL {
                    Typo.code(Text(resolved))
                        .foregroundStyle(Color.shelfMuted)
                }
                Typo.supporting(Text("This server isn\u{2019}t on your local network, so your username, password, tokens, and audiobook content would travel unencrypted. Anyone on the network path could read or alter them."))
                    .foregroundStyle(Color.shelfCream)
                    .fixedSize(horizontal: false, vertical: true)
                if acknowledgedInsecureConnection {
                    Typo.supporting(Text("You\u{2019}ve chosen to continue anyway."), weight: .semibold)
                        .foregroundStyle(Color.shelfMuted)
                } else {
                    // Pre-acknowledging here means `login()`/`loginWithOIDC()` don't have
                    // to raise their own alert a moment later for something the user has
                    // already been told about in context.
                    Button {
                        Haptics.selection()
                        // Accepting the risk is what flips `showsCredentials` for this
                        // outcome; the page swap and the focus both hang off that.
                        acknowledgedInsecureConnection = true
                    } label: {
                        Typo.secondaryAction(Text("Continue Anyway"))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                }
            }

        case .notAudiobookshelf:
            VStack(alignment: .leading, spacing: 6) {
                resultMessage(
                    icon: "questionmark.circle.fill",
                    text: String(localized: "This address responded, but doesn\u{2019}t look like an Audiobookshelf server."),
                    resolved: result.resolvedURL,
                    iconColor: Color.shelfOrange
                )
                // SB-1: the single most common cause of this outcome for a self-hosted
                // audience is exactly the case the header editor below exists for — a
                // proxy gate answering `/ping` with its own block page. Say so, rather
                // than leaving the user at a dead end.
                Typo.supporting(Text("If your server sits behind Cloudflare Access, Authelia, or a similar gate, add its headers under Advanced below and test again."))
                    .foregroundStyle(Color.shelfMuted)
                    .fixedSize(horizontal: false, vertical: true)
                signInAnywayButton
            }

        case .unreachable:
            // Critique 2026-10-06 (harden + clarify): one specific cause and next step per
            // failure (`ServerConnectionRules.failureAdvice`), with the one-tap recovery
            // that fits it, instead of a single "Can't reach this server" for all of them.
            let advice = ServerConnectionRules.failureAdvice(failure: result.failure,
                                                            resolvedURL: result.resolvedURL,
                                                            triedPlainHTTP: result.triedPlainHTTP)
            VStack(alignment: .leading, spacing: 6) {
                resultMessage(
                    icon: "wifi.exclamationmark",
                    text: advice.message,
                    resolved: result.resolvedURL,
                    iconColor: Color.shelfOrange
                )
                Typo.supporting(Text(advice.nextStep))
                    .foregroundStyle(Color.shelfMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if advice.offersPlainHTTP,
                   let httpAddress = ServerConnectionRules.plainHTTPRetryAddress(resolvedURL: result.resolvedURL) {
                    Button {
                        Haptics.selection()
                        // Rewriting the field clears the old result (`onChange(of:
                        // serverURL)`), then the re-test runs against the http address.
                        // A public host lands on `.reachableInsecure` and its existing
                        // acknowledgement; a private one passes straight through.
                        // The address change clears the old result, then tests the new one.
                        testAfterAddressChange = true
                        serverURL = httpAddress
                    } label: {
                        Typo.secondaryAction(Text("Use http:// instead"))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isTesting)
                    .accessibilityHint("Changes the address to \(httpAddress) and tests it again.")
                }
                if advice.offersLocalNetworkSettings,
                   let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    Button {
                        openURL(settingsURL)
                    } label: {
                        Typo.secondaryAction(Text("Open Settings"))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Opens ShelfHead\u{2019}s page in Settings, where Local Network access is turned on.")
                }
                signInAnywayButton
            }

        case .invalidURL:
            resultMessage(
                icon: "exclamationmark.triangle.fill",
                text: String(localized: "Enter a valid server address, e.g. https://library.example.com"),
                resolved: nil,
                iconColor: Color.shelfOrange
            )
        }
    }

    /// The escape hatch of last resort, under a `.notAudiobookshelf`/`.unreachable`
    /// diagnosis only (`ServerConnectionRules.offersTestBypass`). Deliberately
    /// low-emphasis — a borderless caption-sized button, not a second primary action —
    /// because for most people at this point the address really is wrong and re-reading
    /// the diagnosis is the right move; this exists for the minority whose gate blocks
    /// the test itself, for whom the alternative is being locked out of their own server.
    ///
    /// Once tapped it stays tapped for this address (`bypassedTest`), so the button
    /// disappearing and step 2 appearing is the whole feedback. It does NOT pre-accept an
    /// insecure connection: a plain-HTTP non-local host still raises
    /// `AuthViewModel`'s alert at sign-in time.
    @ViewBuilder
    private var signInAnywayButton: some View {
        // Consults the rule as well as the two call sites, so the view and
        // `offersTestBypass` can't drift apart if another outcome is ever added.
        if ServerConnectionRules.offersTestBypass(for: testResult), !bypassedTest {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    Haptics.selection()
                    // Same single path as everything else: this flips
                    // `showsCredentials`, which moves the page and the keyboard.
                    bypassedTest = true
                } label: {
                    Typo.secondaryAction(Text("Sign in anyway"))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Shows the username and password fields without a passing connection test.")
                Typo.fine(Text("Use this if your server is behind a gate that blocks the connection test."))
                    .foregroundStyle(Color.shelfMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Critique 2026-10-06 (harden): status colour on the glyph only (`iconColor`); the
    /// sentence is always readable ink. Raw `.red`/`.orange` text used to carry it, which
    /// fails contrast on Liner-Note Paper and broke DESIGN.md's Fill-or-Text Rule.
    private func resultMessage(icon: String, text: String, resolved: String?, iconColor: Color) -> some View {
        Typo.supporting(VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(text)
                    .foregroundStyle(Color.shelfCream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let resolved {
                Typo.code(Text(resolved))
                    .foregroundStyle(Color.shelfMuted)
            }
        })
        .accessibilityElement(children: .combine)
    }

    /// "Where do I find this?" — someone who just installed Audiobookshelf on a NAS
    /// doesn't necessarily know whether they have a LAN IP, a Tailscale address, or a
    /// reverse-proxy hostname. One example line each, collapsed by default so it doesn't
    /// compete with the field above for a user who already knows their address.
    private var whereDoIFindThisDisclosure: some View {
        DisclosureGroup(isExpanded: $showWhereDoIFindThis) {
            VStack(alignment: .leading, spacing: 10) {
                whereDoIFindThisRow(
                    title: "On your home network (LAN)",
                    example: "http://192.168.1.50:13378"
                )
                whereDoIFindThisRow(
                    title: "Over Tailscale / WireGuard",
                    example: "http://100.x.x.x:13378"
                )
                whereDoIFindThisRow(
                    title: "Through a reverse proxy (Nginx, Caddy, Cloudflare Tunnel)",
                    example: "https://audiobooks.yourdomain.com"
                )
            }
            .padding(.top, 8)
        } label: {
            Typo.secondaryAction(Text("Where do I find this?"))
                .foregroundStyle(Color.shelfAmberText)
                .frame(minHeight: 44)
        }
        .tint(Color.shelfAmberText)
    }

    private func whereDoIFindThisRow(title: LocalizedStringResource, example: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Typo.fine(Text(title), weight: .medium)
                .foregroundStyle(Color.shelfCream)
            Typo.code(Text(example))
                .foregroundStyle(Color.shelfMuted)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Server summary (sign-in page)

    /// The one-line reminder of what is being signed into, at the top of the sign-in
    /// page. It replaces the whole server step the user just left, so it has to carry the
    /// two things they'd otherwise scroll back for: which server, and how trustworthy the
    /// connection to it turned out to be.
    ///
    /// The glyph and caption are derived (`ServerConnectionRules.serverSummaryStyle`)
    /// from the same inputs as `showsCredentials`, so a sign-in reached through "Sign in
    /// anyway" says "Connection not verified" rather than showing a reassuring lock.
    private var serverSummarySection: some View {
        Section {
            let versionLine = ServerConnectionRules.serverVersionLine(serverStatus?.serverVersion)
            let baseLabel = ServerConnectionRules.serverSummaryAccessibilityLabel(
                host: serverSummaryHost, style: serverSummaryStyle)
            // Batch 490 (REVIEW 2026-11-11 F8): the version is read with the row.
            let label = versionLine.map { "\(baseLabel), \($0)" } ?? baseLabel
            let summary = HStack(spacing: Space.m) {
                Image(systemName: ServerConnectionRules.serverSummaryGlyph(for: serverSummaryStyle))
                    .font(.title3)
                    .foregroundStyle(serverSummaryTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(serverSummaryHost)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.shelfCream)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Critique 2026-10-06 (harden): caption was raw orange text when
                    // unverified; the glyph carries the colour now, the caption reads.
                    Typo.fine(Text(ServerConnectionRules.serverSummaryCaption(for: serverSummaryStyle)),
                              weight: serverSummaryStyle == .verified ? .regular : .semibold)
                        .foregroundStyle(serverSummaryStyle == .verified ? Color.shelfMuted : Color.shelfCream)
                    // Batch 490 (REVIEW 2026-11-11 F8): "Audiobookshelf ‹version›".
                    if let versionLine {
                        Typo.fine(Text(versionLine))
                            .foregroundStyle(Color.shelfMuted)
                    }
                }
            }
            // One VoiceOver stop for the status, with "Change server" left beside it as
            // its own actionable element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityFocused($accessibilityFocusedPage, equals: .signIn)

            let changeButton = Button {
                Haptics.selection()
                page = .server
            } label: {
                Typo.secondaryAction(Text("Change server"))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Go back to the server address, keeping what you\u{2019}ve already entered.")

            // Side by side normally; stacked at accessibility text sizes, where a
            // hostname and a button can't share a row without one of them vanishing.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Space.s) {
                    summary
                    changeButton
                }
            } else {
                HStack(spacing: Space.s) {
                    summary
                    Spacer(minLength: Space.s)
                    changeButton
                }
            }

            // HIG audit 2026-09-17 M17: "Sign in anyway" reaches this page with the
            // connection test never having passed — the plain-HTTP path already gets a
            // full one-time acknowledgement, but this one only got the caption under
            // the button, one screen back. One inline warning line here, where the
            // credential fields are actually about to be shown, matching the caption
            // style already used on this page rather than a second alert.
            if serverSummaryStyle == .unverified {
                Text("This server couldn\u{2019}t be verified as Audiobookshelf. Your username and password will still be sent to it.")
                    .font(.footnote)
                    .foregroundStyle(Color.shelfMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Batch 490 (REVIEW 2026-11-11 F8): `/status` said nobody can sign in yet
            // (`isInit: false`). Warning style: orange glyph, cream words.
            if ServerConnectionRules.serverNeedsSetup(serverStatus) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.shelfOrange)
                        .accessibilityHidden(true)
                    Typo.supporting(Text(ServerConnectionRules.serverNeedsSetupMessage), weight: .semibold)
                        .foregroundStyle(Color.shelfCream)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            // Batch 490 (REVIEW 2026-11-11 F8): the admin's custom login message, as one
            // quiet line (markup stripped and length capped in `ServerStatusInfo`).
            if let message = serverStatus?.loginMessage {
                Typo.supporting(Text(verbatim: message))
                    .foregroundStyle(Color.shelfMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("Message from the server: \(message)"))
            }
        }
        .listRowBackground(Color.shelfCard)
    }

    private var serverSummaryTint: Color {
        switch serverSummaryStyle {
        case .verified: return Color.shelfCream   // Batch 490 (REVIEW 2026-11-11 V6): was teal
        case .insecureAccepted, .unverified: return Color.shelfOrange
        }
    }

    // MARK: - Credentials

    /// Step 2, and now a page of its own (`signInForm`) rather than a section revealed
    /// below step 1. It is built only while `showsCredentials` is true, so everything
    /// here can assume the address has been tested and either passed, been accepted as
    /// insecure, or been explicitly bypassed — `serverSummarySection` above says which.
    private var credentialsSection: some View {
        Section {
            // Batch 495 (REVIEW 2026-11-11 O3): an OpenID-only server has no password sign-in,
            // so its fields and button aren't shown (`ServerConnectionRules.signInLayout`).
            if signInLayout.showsPasswordFields {
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .submitLabel(.next)
                .focused($focusedField, equals: .username)
                .accessibilityLabel("Username")
                .onSubmit { focusedField = .password }
                // UX-3 (docs/design-review.md): `connect()` runs with the values captured
                // when Connect was tapped, so editing them mid-sign-in would get a result
                // for text that's no longer on screen. Locked until the attempt finishes.
                .disabled(isConnecting)

            HStack {
                if showPassword {
                    TextField("Password", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .accessibilityLabel("Password")
                        .onSubmit { if isValid { connect() } }
                } else {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .accessibilityLabel("Password")
                        .onSubmit { if isValid { connect() } }
                }
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(Color.shelfMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showPassword ? Text("Hide password") : Text("Show password"))
            }
            // UX-3: the password field (either variant) and the show/hide toggle, for
            // the same reason as the username field above.
            .disabled(isConnecting)

            // Username/password only — SSO never has a password on this device to
            // remember (see `otherSignInOptionsDisclosure` below, and
            // `AuthViewModel.loginWithOIDC`, which always saves an empty string
            // regardless of this setting).
            VStack(alignment: .leading, spacing: 4) {
                // Critique 2026-10-06 (harden): no `.accessibilityHint` repeating the
                // footer — the footer below is its own VoiceOver element, so the same
                // sentence was being read twice.
                Toggle(isOn: $storePassword) {
                    Text("Remember password on this device")
                }
                Typo.fine(Text(ServerConnectionRules.rememberPasswordFooter(isOn: storePassword)))
                    .foregroundStyle(Color.shelfMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Batch 490 (REVIEW 2026-11-11 O2): the full-width Sign In button for both
            // purposes (it was first-run only, leaving the sheet with just a toolbar
            // item that the iPhone Duo side bar moves away). The sheet keeps its toolbar
            // item as well.
            Button {
                connect()
            } label: {
                HStack {
                    // Batch 490 (REVIEW 2026-11-11 O6): spins only for a password sign-in.
                    if connectingMethod == .password {
                        ProgressView()
                            .tint(Color.onAccent)
                            .accessibilityLabel(Text("Signing in"))
                    } else {
                        Text("Sign In")
                            .fontWeight(.semibold)
                    }
                }
                .shelfButtonStyle()
            }
            .buttonStyle(.plain)
            .disabled(!isValid || isConnecting)
            .opacity(isValid ? 1 : 0.6)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            switch signInLayout {
            case .passwordWithSSODisclosure:
                otherSignInOptionsDisclosure
            case .passwordAndSSO:
                singleSignOnButton(primary: false)
                singleSignOnHelp
            case .singleSignOnOnly:
                singleSignOnButton(primary: true)
                singleSignOnHelp
            }
        } header: {
            Text("2\u{2002}\u{2002}Sign in")
        }
        .listRowBackground(Color.shelfCard)
    }

    // MARK: - Status

    /// Errors and the in-flight indicator, as their own section rather than the step 2
    /// footer they used to live in — and included on BOTH pages, since either can
    /// produce one.
    ///
    /// Sign Out (`AuthViewModel.signOut`, and Remove All Servers) sets `errorMessage` *after* `isAuthenticated = false`
    /// precisely so a Keychain that wouldn't release an item is reported on the screen
    /// the user lands on (`ServerConnectionPurpose.rendersViewModelError`). With the
    /// credentials now on a page of their own behind a passing test, a footer down there
    /// would not be on screen at the one moment that message needs reading — a fresh
    /// first-run screen is the server page, with no test result yet.
    private var statusSection: some View {
        Section {
            if let displayedError {
                // Critique 2026-10-06 (harden): was raw `.red` text; alarm colour on
                // the glyph, the message in readable ink.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.shelfOrange)
                    Text(displayedError)
                        .foregroundStyle(Color.shelfCream)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                // Batch 490 (REVIEW 2026-11-11 O4): the redirect-URI error names the
                // address to allow; this puts it on the clipboard for the admin.
                if ServerConnectionRules.errorOffersRedirectURICopy(displayedError) {
                    HStack(spacing: Space.s) {
                        Typo.code(Text(verbatim: OIDCAuthService.redirectURI))
                            .foregroundStyle(Color.shelfCream)
                            .textSelection(.enabled)
                        Spacer(minLength: Space.s)
                        Button {
                            UIPasteboard.general.string = OIDCAuthService.redirectURI
                            Haptics.selection()
                            copiedRedirectURI = true
                        } label: {
                            Typo.secondaryAction(Label(copiedRedirectURI ? "Copied" : "Copy",
                                                       systemImage: copiedRedirectURI ? "checkmark" : "doc.on.doc"))
                                .foregroundStyle(Color.shelfAmberText)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(copiedRedirectURI ? Text("Copied sign-in address") : Text("Copy sign-in address"))
                    }
                    .onDisappear { copiedRedirectURI = false }
                }
            } else if showsStatusSpinner {   // Batch 490 (REVIEW 2026-11-11 O6)
                HStack(spacing: Space.s) {
                    // LS-13 (docs/design-review.md, Round 3): brand-tinted, was
                    // falling back to the system tint.
                    ProgressView()
                        .shelfSpinner()
                    Text("Connecting\u{2026}").foregroundStyle(Color.shelfMuted)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .listRowBackground(Color.shelfCard)
    }

    // MARK: - Custom headers

    /// Reverse-proxy headers, as a collapsed disclosure at the bottom of step 1 rather
    /// than the always-open top-level section it used to be — the device feedback names
    /// this as clutter for the large majority who don't need it.
    ///
    /// It sits in step 1, NOT step 2, and that placement is load-bearing: a proxy-gated
    /// server answers `/ping` with the gate's own block page, which the test reports as
    /// `.notAudiobookshelf`, so the test can never pass until these headers are supplied.
    /// Putting the editor behind the pass would reintroduce exactly the dead end SB-1
    /// fixed. `headersDisclosureStartsExpanded` opens it automatically on that outcome.
    private var advancedHeadersDisclosure: some View {
        DisclosureGroup(isExpanded: $showHeadersSection) {
            Typo.fine(Text("For a server behind a reverse proxy that needs its own header to let requests through — e.g. Cloudflare Access or Authelia. Most people can leave this empty."))
                .foregroundStyle(Color.shelfMuted)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($headerPairs) { $pair in
                VStack(alignment: .leading, spacing: 4) {
                    headerFields(for: $pair)
                    // Advisory only — mirrors `AuthStore.sanitizedCustomHeaders`,
                    // which is what actually strips these before any request goes
                    // out (see the finding write-up in `AuthStore.swift`: a header
                    // literally named `Authorization` would otherwise silently
                    // replace the real bearer token). Shown here so a header that
                    // quietly "does nothing" isn't a mystery — the user can still
                    // leave it as-is and keep filling in the rest of the form.
                    if !ServerConnectionRules.headerNameIsUsable(pair.key) {
                        headerWarning("This header name can't be used and will be ignored — it's reserved or contains invalid characters.")
                    }
                    // Item 30 (REVIEW-2026-09-09.md): `AuthStore.isValidCustomHeaderValue`
                    // existed with no UI caller — a pasted value with a trailing
                    // newline (or any other control character) was silently dropped
                    // by `AuthStore.sanitizedCustomHeaders` at send time, with
                    // nothing here explaining why. Same treatment as above.
                    if !ServerConnectionRules.headerValueIsUsable(pair.value) {
                        headerWarning("This header value contains a character that isn\u{2019}t allowed (such as a line break) and will be ignored.")
                    }
                }
            }

            Button {
                headerPairs.append(EditableHeaderPair())
            } label: {
                Label("Add Header", systemImage: "plus.circle.fill")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        } label: {
            // Critique 2026-10-06 (clarify): quiet, not accent — it's an advanced
            // option below the flow, not a peer of Test Connection.
            Typo.secondaryAction(Text("Advanced: custom HTTP headers"))
                .foregroundStyle(Color.shelfMuted)
                .frame(minHeight: 44)
        }
        .tint(Color.shelfMuted)
        .accessibilityHint("Headers for a reverse proxy in front of your server, such as Cloudflare Access or Authelia. Most servers don\u{2019}t need these.")
    }

    /// Name + value + remove for one header row. Two fields side by side get unusable at
    /// accessibility text sizes, so they stack there instead of shrinking to nothing.
    @ViewBuilder
    private func headerFields(for pair: Binding<EditableHeaderPair>) -> some View {
        let nameField = TextField("Header name", text: pair.key)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Header name")
        // Critique 2026-10-06 (harden): a proxy secret, hidden by default (was plain text).
        let valueField = HeaderValueField(value: pair.value)
        // Critique 2026-10-06 (harden): destructive role instead of a hand-painted
        // `.red` glyph — the system supplies the destructive colour.
        let removeButton = Button(role: .destructive) {
            let id = pair.wrappedValue.id
            headerPairs.removeAll { $0.id == id }
        } label: {
            Image(systemName: "minus.circle.fill")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Remove header")

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                nameField
                valueField
                HStack {
                    Spacer()
                    removeButton
                }
            }
        } else {
            HStack {
                nameField
                valueField
                removeButton
            }
        }
    }

    private func headerWarning(_ text: LocalizedStringResource) -> some View {
        // Critique 2026-10-06 (harden): was raw `.orange` Caption 2 text.
        Typo.supporting(HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.shelfOrange)
            Text(text)
                .foregroundStyle(Color.shelfCream)
        })
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    // MARK: - SSO

    /// OIDC/SSO — Audiobookshelf itself talks to the identity provider; this just needs
    /// the server address, not a username/password.
    ///
    /// Collapsed inside step 2 rather than a top-level section of its own: for the large
    /// majority of self-hosted servers there is no identity provider configured at all,
    /// and a permanently visible "Sign in with SSO" button next to the password field is
    /// the clutter the device feedback calls out. SB-1's actual requirement — that a
    /// first-run user can reach SSO *at all* — is met by it being in this form for both
    /// purposes; it doesn't require it to be always expanded.
    private var otherSignInOptionsDisclosure: some View {
        // Batch 495 (O3): only for servers that didn't advertise OpenID (local-only, or
        // `authMethods` unknown), so the title is always the neutral one and nothing
        // auto-expands; a server that advertises OpenID gets `singleSignOnButton` inline.
        DisclosureGroup(isExpanded: $showOtherSignInOptions) {
            singleSignOnButton(primary: nil)
            singleSignOnHelp
        } label: {
            Typo.secondaryAction(Text("Other sign-in options"))
                .foregroundStyle(Color.shelfAmberText)
                .frame(minHeight: 44)
        }
        .tint(Color.shelfAmberText)
        .accessibilityHint("Single sign-on (OpenID Connect), for servers configured to use it.")
    }

    /// Batch 495 (O3): the SSO button. `primary` true = the page's one amber button
    /// (SSO-only server), false = full-width outlined secondary under the Sign In button,
    /// nil = the plain row inside the disclosure.
    private func singleSignOnButton(primary: Bool?) -> some View {
        Button {
            signInWithSSO()
        } label: {
            HStack {
                if primary == nil { Spacer() }
                // Batch 490 (REVIEW 2026-11-11 O6): spins only for an SSO sign-in.
                if connectingMethod == .singleSignOn {
                    // LS-13 (docs/design-review.md, Round 3): brand-tinted, was
                    // falling back to the system tint.
                    if primary == true {
                        ProgressView()
                            .tint(Color.onAccent)
                            .accessibilityLabel(Text("Signing in"))
                    } else {
                        ProgressView()
                            .shelfSpinner()
                            .accessibilityLabel(Text("Signing in"))
                    }
                } else {
                    // Batch 490 (REVIEW 2026-11-11 F8): the admin's button text when set.
                    Label(ServerConnectionRules.singleSignOnButtonTitle(serverText: serverStatus?.openIDButtonText),
                          systemImage: "person.badge.key.fill")
                        .fontWeight(primary == nil ? nil : .semibold)
                }
                if primary == nil { Spacer() }
            }
            .modifier(SSOButtonChrome(primary: primary))
        }
        .buttonStyle(.plain)
        .disabled(!ServerConnectionRules.canStartSingleSignOn(serverURL: serverURL) || isConnecting)
        .listRowInsets(primary == nil ? nil : EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    /// Batch 495 (O3): the SSO explanation and the redirect-address setup line.
    @ViewBuilder private var singleSignOnHelp: some View {
        if signInLayout == .singleSignOnOnly {
            // No password fields on this page, so the usual "instead of username and password" line would misread.
            Typo.fine(Text("This server signs in with single sign-on only. You’ll finish signing in with your identity provider."))
                .foregroundStyle(Color.shelfMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Typo.fine(Text("For a server with OpenID Connect / Single Sign-On configured (Settings → Authentication on the server). Tap this instead of filling in username and password — Audiobookshelf runs the whole exchange with your identity provider."))
                .foregroundStyle(Color.shelfMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Batch 490 (REVIEW 2026-11-11 O4): the same setup sentence the
        // redirect-URI error uses, so an admin can allow the address up front.
        Typo.fine(Text(OIDCAuthService.redirectURISetupInstruction))
            .foregroundStyle(Color.shelfMuted)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// Chrome for `singleSignOnButton`: amber-ink primary (as `shelfButtonStyle`), outlined
    /// secondary, or the plain disclosure row.
    private struct SSOButtonChrome: ViewModifier {
        let primary: Bool?
        func body(content: Content) -> some View {
            switch primary {
            case .some(true):
                content.shelfButtonStyle()
            case .some(false):
                content
                    .font(.headline)
                    .foregroundStyle(Color.shelfAmberText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.shelfAmberText, lineWidth: 1.5))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
            case .none:
                content
                    .foregroundStyle(Color.shelfAmberText)   // plain style drops the tint the row had
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Actions

    /// True while `login()`/`loginWithOIDC()` has a connection blocked pending the
    /// insecure-connection confirmation.
    private var insecureConnectionAlertBinding: Binding<Bool> {
        Binding(
            get: { authViewModel.pendingInsecureConnection != nil },
            set: { if !$0 {
                authViewModel.pendingInsecureConnection = nil
                // Dismissing by tapping outside the alert (rather than Cancel or Allow)
                // skips both button actions, so this is the only place left to reset
                // `isConnecting` — otherwise the Connect/SSO button stays stuck showing
                // its spinner with no in-flight Task left to ever clear it.
                connectingMethod = nil
            } }
        )
    }

    /// Starts a connection test, replacing any still running.
    private func startTest() {
        testTask?.cancel()
        testTask = Task { await testConnection() }
    }

    /// Critique 2026-10-06 (harden): stops a running test. Its result, when the request
    /// does come back, is dropped (`testConnection` checks for cancellation).
    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
    }

    private func testConnection() async {
        Haptics.selection()
        focusedField = nil
        isTesting = true
        // Item 28 (`ReachabilityStore.testConnection`): pass the headers typed into THIS
        // form. Without them, a proxy-gated server 401s the unauthenticated ping and the
        // test reports `.notAudiobookshelf`/`.unreachable` for a server that is fine.
        let result = await ReachabilityStore.testConnection(rawURL: serverURL,
                                                            customHeaders: customHeadersDictionary)
        // Cancelled (the Cancel button, a newer test, or an address edit): this result is
        // for a test nobody is waiting on, and `isTesting` already belongs to whoever
        // cancelled it.
        guard !Task.isCancelled else { return }
        testResult = result
        isTesting = false
        testTask = nil
        // A pass flips `showsCredentials`, and the `onChange` on `pages` turns that into
        // the page swap and the keyboard move — nothing to do here. A
        // `.reachableInsecure` result deliberately doesn't flip it: the user has to
        // accept the plain-HTTP risk first.
    }

    /// Move the keyboard into the sign-in page just after it arrives. Deferred past the
    /// page transition on purpose: the credentials fields don't exist until the state
    /// change that precedes this call renders them, and focusing a field SwiftUI hasn't
    /// laid out yet is a no-op. Slightly longer than the 0.28s slide so the keyboard
    /// doesn't race the animation (and the guard re-checks, in case the result was
    /// invalidated in between).
    private func focusCredentialsAfterReveal() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard showsCredentials else { return }
            focusedField = username.trimmingCharacters(in: .whitespaces).isEmpty ? .username : .password
        }
    }

    /// Connect / Sign In. Critique 2026-10-06 (harden): over a live session on another
    /// server this is an account switch, so it confirms first (`pendingSwitch`).
    private func connect() {
        if signInKind(forPassword: true) == .switchesAccount {
            focusedField = nil
            pendingSwitch = .password
        } else {
            performConnect(endingCurrentSession: false)
        }
    }

    /// `AuthViewModel.addServerSignInKind` for what's in the form now.
    private func signInKind(forPassword: Bool) -> AuthViewModel.AddServerSignInKind {
        AuthViewModel.addServerSignInKind(
            isAuthenticated: authViewModel.isAuthenticated,
            currentServerURL: authViewModel.serverURL,
            currentUsername: authViewModel.username,
            newServerURL: ServerConnectionRules.signInAddress(typedURL: serverURL, resolvedURL: testResult?.resolvedURL),
            // Polish pass (J1-6): compared as it will be sent.
            newUsername: forPassword ? AuthViewModel.normalizedUsername(username) : nil)
    }

    private func performConnect(endingCurrentSession: Bool) {
        // The insecure-connection retry re-runs this, not `connect()`: the switch was
        // already confirmed.
        pendingRetry = { performConnect(endingCurrentSession: endingCurrentSession) }
        focusedField = nil
        connectingMethod = .password   // Batch 490 (REVIEW 2026-11-11 O6)
        localError = nil
        Task {
            // Critique 2026-10-06 (harden): the tested address, which may be the http
            // fallback for a scheme-less LAN address — see `signInAddress`.
            let address = ServerConnectionRules.signInAddress(typedURL: serverURL, resolvedURL: testResult?.resolvedURL)
            // Polish pass (J1-6): username trimmed (autofill/paste whitespace); password as typed.
            let succeeded = await authViewModel.login(serverURL: address,
                                                      username: AuthViewModel.normalizedUsername(username),
                                                      password: password,
                                                      customHeaders: customHeadersDictionary,
                                                      acknowledgedInsecureConnection: acknowledgedInsecureConnection,
                                                      endingCurrentSession: endingCurrentSession)
            switch ServerConnectionRules.signInOutcome(
                succeeded: succeeded,
                pendingInsecureConnection: authViewModel.pendingInsecureConnection != nil,
                errorMessage: authViewModel.errorMessage) {
            case .awaitingInsecureConfirmation:
                // The insecure-connection alert is showing — leave `isConnecting` as-is (the
                // button stays in its "connecting" state) rather than resetting it, so the
                // form doesn't flash back to idle while the alert is up.
                return
            case .succeeded:
                connectingMethod = nil
                finishOnSuccess()
            case .failed(let message):
                // UX-4: every failure lands on the form, never a silent dismissal. Moved
                // onto this view either way, so first run doesn't end up showing the same
                // string twice (once as `localError`, once as the view model's).
                connectingMethod = nil
                localError = message
                authViewModel.errorMessage = nil
            }
        }
    }

    /// SSO. Critique 2026-10-06 (harden): confirms first when it switches account, like
    /// `connect()`. An SSO sign-in over a live session always counts as a switch — the
    /// user isn't known until the identity provider answers.
    private func signInWithSSO() {
        if signInKind(forPassword: false) == .switchesAccount {
            focusedField = nil
            pendingSwitch = .singleSignOn
        } else {
            performSignInWithSSO(endingCurrentSession: false)
        }
    }

    private func performSignInWithSSO(endingCurrentSession: Bool) {
        pendingRetry = { performSignInWithSSO(endingCurrentSession: endingCurrentSession) }
        focusedField = nil
        connectingMethod = .singleSignOn   // Batch 490 (REVIEW 2026-11-11 O6)
        localError = nil
        Task {
            let address = ServerConnectionRules.signInAddress(typedURL: serverURL, resolvedURL: testResult?.resolvedURL)
            let succeeded = await authViewModel.loginWithOIDC(serverURL: address,
                                                              customHeaders: customHeadersDictionary,
                                                              acknowledgedInsecureConnection: acknowledgedInsecureConnection,
                                                              endingCurrentSession: endingCurrentSession)
            if authViewModel.pendingInsecureConnection != nil { return }
            connectingMethod = nil
            if succeeded {
                finishOnSuccess()
            } else if let message = authViewModel.errorMessage {
                // No message means the user simply cancelled the sign-in sheet —
                // nothing to show, just let them try again or fill in a password instead.
                localError = message
                authViewModel.errorMessage = nil
            }
        }
    }

    /// First run has nothing to dismiss to: `isAuthenticated` flipping is what replaces
    /// this screen with `MainTabView` (`ContentView`). The sheet dismisses itself.
    private func finishOnSuccess() {
        guard purpose.dismissesOnSuccess else { return }
        dismiss()
    }
}

/// Compact form to add (and switch to) another Audiobookshelf server, presented as a
/// sheet from Settings > Account & Security.
///
/// SB-1 (REVIEW_2026-09-14_DESIGN.md): the body of this screen — server address,
/// username/password, custom reverse-proxy headers, SSO, and the insecure-connection
/// confirmation — moved to `ServerConnectionView` (above in this file) so the first-run
/// `LoginView` can host exactly the same thing. This presentation keeps its Cancel/Connect
/// toolbar; it also gained the connection test that used to be first-run-only, and with
/// it the two-step progressive disclosure described on `ServerConnectionView`.
struct AddServerView: View {
    /// Prefilled from an imported connection (server URL + username only — the
    /// password is never exported, so this still always requires typing one).
    var prefillServerURL: String = ""
    var prefillUsername: String = ""
    /// Critique 2026-10-06 (harden): a saved server with no stored password, opened from
    /// a switch (`ServerSwitchFlow`). Prefills its address, username and headers, says a
    /// password is needed, and tests straight away. Connect then runs the same switch
    /// confirmation as any Add Server sign-in over a live session (`addServerSignInKind`).
    var reauthenticating: ServerAccount?
    @Environment(AuthViewModel.self) private var authViewModel

    init(prefillServerURL: String = "", prefillUsername: String = "") {
        self.prefillServerURL = prefillServerURL
        self.prefillUsername = prefillUsername
    }

    init(reauthenticating account: ServerAccount) {
        self.prefillServerURL = account.serverURL
        self.prefillUsername = account.username
        self.reauthenticating = account
    }

    var body: some View {
        if let account = reauthenticating {
            ServerConnectionView(purpose: .addAccount,
                                 prefillServerURL: account.serverURL,
                                 prefillUsername: account.username,
                                 prefillHeaders: account.customHeaders ?? [:],
                                 passwordNeededPrompt: ServerConnectionRules.passwordNeededPrompt(
                                    username: account.username, host: account.displayHost,
                                    switchesAccount: authViewModel.isAuthenticated))
        } else {
            ServerConnectionView(purpose: .addAccount,
                                 prefillServerURL: prefillServerURL,
                                 prefillUsername: prefillUsername)
        }
    }
}

#Preview {
    AddServerView()
        .environment(AuthViewModel())
        .environment(PlayerViewModel())
}
