import SwiftUI

/// A read-only snapshot of the current connection: server, transport, token state,
/// selected library, active account and background-download counts. Nothing here
/// mutates state, so it's safe to open any time to sanity-check a flaky setup.
///
/// Moved out of `SettingsView.swift` into its own file under `Views/Diagnostics/`
/// (UI-12, REVIEW_2026-08-12.md, "Split SettingsView.swift into Views/Settings/") — its
/// content and behavior are unchanged, only its location and the fact that it's now a
/// top-level file rather than a second struct appended to `SettingsView.swift`.
struct ServerDiagnosticsView: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel
    /// Height reserved so content clears the floating mini-player + tab bar.
    var bottomInset: CGFloat = 0
    /// Critique 2026-10-06 (harden): result of the live "Check now" ping. `nil` until run.
    @State private var checkOutcome: ReachabilityStore.ConnectionTestResult.Outcome?
    /// Critique 2026-10-06 (clarify): the classified failure behind an unreachable result.
    @State private var checkResult: ReachabilityStore.ConnectionTestResult?
    @State private var checkedAt: Date?
    @State private var isChecking = false
    @Environment(\.openURL) private var openURL
    /// R8 (REVIEW_2026-09-04_UI.md): saved accounts, loaded once so the "Active account"
    /// row can resolve `AccountStore.currentAccountId` to a username/host instead of
    /// showing the raw id (or "—" for a legacy single-account session that has no saved
    /// `ServerAccount` at all).
    @State private var accounts: [ServerAccount] = []

    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    var body: some View {
        List {
            Section {
                // Critique 2026-10-06 (harden): the page showed nothing until Check now.
                // The app's own background check (`ReachabilityStore`, the source of the
                // connectivity banner) is live, so show it on arrival.
                diagRow("Status", value: Self.liveStatusCopy(ReachabilityStore.shared.status))
                // Critique 2026-10-06 (harden): the old "Connection" row only inspected the
                // URL prefix and never contacted the server. This runs the same `/ping`
                // test the Add Server screen uses, against the active account.
                Button {
                    runCheck()
                } label: {
                    HStack(spacing: Space.m) {
                        if isChecking {
                            ProgressView().shelfSpinner().frame(width: 24)
                        } else {
                            Image(systemName: "network").foregroundStyle(Color.shelfMuted).frame(width: 24)
                        }
                        Text(isChecking ? "Checking\u{2026}" : "Check now")
                            .foregroundStyle(Color.shelfAmberText)
                    }
                    .frame(minHeight: 44)
                }
                .disabled(isChecking || !AuthStore.shared.isConfigured)
                if let checkOutcome {
                    diagRow("Result", value: Self.checkOutcomeCopy(checkOutcome))
                    if checkOutcome == .notAudiobookshelf {
                        // Critique 2026-10-06 (harden): this outcome had no advice at all.
                        Typo.supporting(Text(Self.notAudiobookshelfAdvice))
                            .foregroundStyle(Color.shelfMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if checkOutcome == .unreachable, let checkResult {
                        // Critique 2026-10-06 (clarify): the check used to drop the failure and
                        // always say "Couldn't reach your server". Same advice as Add Server.
                        let advice = ServerConnectionRules.failureAdvice(
                            failure: checkResult.failure, resolvedURL: checkResult.resolvedURL,
                            triedPlainHTTP: checkResult.triedPlainHTTP)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(advice.message).foregroundStyle(Color.shelfCream)
                            Typo.supporting(Text(advice.nextStep))
                                .foregroundStyle(Color.shelfMuted)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        if advice.offersLocalNetworkSettings,
                           let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                            Button("Open Settings") { openURL(settingsURL) }
                                .foregroundStyle(Color.shelfAmberText)
                                .frame(minHeight: 44)
                        }
                    }
                    if let checkedAt {
                        diagRow("Checked", value: checkedAt.formatted(.relative(presentation: .named)))
                    }
                }
            } header: {
                RetroSectionHeader(title: "Live check")
            } footer: {
                Typo.supporting(Text("Status comes from ShelfHead\u{2019}s automatic check. Check now contacts your server straight away."))
                    .foregroundStyle(Color.shelfMuted)
            }
            .listRowBackground(Color.shelfCard)

            Section {
                diagRow("Server", value: serverDisplay)
                diagRow("Address type", value: connectionDisplay)
                // Critique 2026-10-06 (distill): the "Signed in: Yes" row duplicated the
                // Session row below, which already says signed in or out.
            } header: {
                RetroSectionHeader(title: "Connection")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                // Critique 2026-10-06 (clarify): plain words instead of token jargon.
                diagRow("Session", value: Self.sessionLabel(
                    hasAccessToken: !AuthStore.shared.accessToken.isEmpty,
                    hasRefreshToken: AuthStore.shared.refreshToken?.isEmpty == false,
                    expiry: tokenExpiryDate,
                    now: Date()))
                diagRow("Token in stream URL", value: SettingsStore.streamWithURLToken ? String(localized: "On", comment: "Diagnostics value for an enabled setting.") : String(localized: "Off", comment: "Diagnostics value for a disabled setting."))
                diagRow("Password saved", value: SettingsStore.storePassword ? String(localized: "On", comment: "Diagnostics value for an enabled setting.") : String(localized: "Off", comment: "Diagnostics value for a disabled setting."))
            } header: {
                RetroSectionHeader(title: "Authentication")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                diagRow("Active account", value: accountDisplay)
                diagRow("Selected library", value: libraryDisplay)
            } header: {
                RetroSectionHeader(title: "Account")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                diagRow("Downloaded books", value: "\(DownloadManager.shared.downloadedItems.count)")
                diagRow("Active downloads", value: "\(DownloadManager.shared.activeDownloads.count)")
            } header: {
                RetroSectionHeader(title: "Downloads")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                // T6 (REVIEW_2026-09-04_UI.md); Critique 2026-10-06 (clarify): the key is only
                // useful in a support conversation, so it sits behind a disclosure.
                DisclosureGroup("Support details") {
                    diagRow("Downloads folder ID", value: Self.storageScopeLabel(DownloadManager.shared.currentScopeKey()))
                }
                .foregroundStyle(Color.shelfCream)
            } footer: {
                Typo.supporting(Text("The folder ID keeps each account\u{2019}s downloads separate on this device."))
                    .foregroundStyle(Color.shelfMuted)
            }
            .listRowBackground(Color.shelfCard)
        }
        .scrollContentBackground(.hidden)
        .background(Color.shelfBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomClearance) }
        .navigationTitle("Server Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { accounts = await AccountStore.accounts() }
        .reexpandsTabBarOnAppear()
    }

    // R8 (REVIEW_2026-09-04_UI.md)
    private var accountDisplay: String {
        let current = accounts.first { $0.id == AccountStore.currentAccountId }
        return Self.accountLabel(account: current, isSignedIn: AuthStore.shared.isConfigured)
    }

    // R8 (REVIEW_2026-09-04_UI.md)
    private var libraryDisplay: String {
        Self.libraryLabel(id: SettingsStore.selectedLibraryId, libraries: libraryViewModel.libraries)
    }

    /// R8 (REVIEW_2026-09-04_UI.md): a saved account resolves to "username on host"; no
    /// saved account but still signed in (a legacy single-account session, or one that was
    /// never switched via multi-account) says so explicitly instead of just "—"; otherwise
    /// "—" (not signed in at all).
    static func accountLabel(account: ServerAccount?, isSignedIn: Bool) -> String {
        if let account {
            return String(localized: "\(account.username) on \(account.displayHost)", comment: "Account label. First %@ is the username, second is the server host.")
        }
        if isSignedIn {
            return String(localized: "Signed in (not saved as an account)")
        }
        return "\u{2014}"
    }

    /// R8 (REVIEW_2026-09-04_UI.md): resolves the selected library id to its human-readable
    /// name instead of a raw UUID; falls back to a truncated id if the library list hasn't
    /// loaded yet or no longer contains a match, rather than showing nothing useful.
    static func libraryLabel(id: String?, libraries: [Library]) -> String {
        guard let id else { return "\u{2014}" }
        if let match = libraries.first(where: { $0.id == id }) {
            return match.name
        }
        return String(localized: "Unknown (\(String(id.prefix(8)))\u{2026})", comment: "Library label when its name is not known. %@ is a short library id.")
    }

    /// T6 (REVIEW_2026-09-04_UI.md): `currentScopeKey()` is
    /// `DownloadPaths.scopeKey(serverURL:accountId:)` — base64 (with `/+=` swapped for
    /// path-safety) of `"<serverURL>|<accountId>"`. Useful in a support conversation
    /// ("which account's downloads am I looking at") but meaningless as raw base64, so
    /// this decodes it back to the server's host plus a short suffix of the key itself
    /// (not reversible to the account id, just enough to tell two scopes apart).
    /// Falls back to returning the key unchanged for anything that doesn't decode to
    /// the expected `"<serverURL>|<accountId>"` shape (e.g. "unscoped").
    static func storageScopeLabel(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        var b64 = key
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "+")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let raw = String(data: data, encoding: .utf8),
              let pipeIndex = raw.firstIndex(of: "|") else {
            return key
        }
        let serverURL = String(raw[raw.startIndex..<pipeIndex])
        guard let host = URL(string: serverURL)?.host, !host.isEmpty else {
            return key
        }
        let suffix = String(key.suffix(6))
        return String(localized: "\(host) \u{00B7} \u{2026}\(suffix)")
    }

    private var serverDisplay: String {
        let s = AuthStore.shared.serverURL
        return s.isEmpty ? "\u{2014}" : s
    }

    private var connectionDisplay: String {
        let s = AuthStore.shared.serverURL.lowercased()
        if s.hasPrefix("https://") { return String(localized: "HTTPS (encrypted)") }
        if s.hasPrefix("http://") { return String(localized: "HTTP (not encrypted)") }
        return "\u{2014}"
    }

    private func runCheck() {
        isChecking = true
        Task {
            let result = await ReachabilityStore.testConnection(
                rawURL: AuthStore.shared.serverURL, customHeaders: AuthStore.shared.customHeaders)
            checkOutcome = result.outcome
            checkResult = result
            checkedAt = Date()
            isChecking = false
            // Critique 2026-10-06 (polish): the result row appears out of VoiceOver focus.
            AccessibilityNotification.Announcement(Self.checkOutcomeCopy(result.outcome)).post()
        }
    }

    /// Critique 2026-10-06 (harden): plain-words outcome of the live check. Server version
    /// isn't offered: `ConnectionTestResult` doesn't carry it and `ReachabilityStore` isn't
    /// owned by this change.
    static func checkOutcomeCopy(_ outcome: ReachabilityStore.ConnectionTestResult.Outcome) -> String {
        switch outcome {
        case .reachable: return String(localized: "Your server answered.")
        case .reachableInsecure: return String(localized: "Your server answered, but the connection isn\u{2019}t encrypted.")
        case .notAudiobookshelf: return String(localized: "Something answered, but it doesn\u{2019}t look like Audiobookshelf.")
        case .unreachable: return String(localized: "Couldn\u{2019}t reach your server.")
        case .invalidURL: return String(localized: "The saved server address isn\u{2019}t valid.")
        }
    }

    /// Critique 2026-10-06 (harden): the live background status, in plain words. Pure,
    /// pinned by `SettingsClarityTests`.
    static func liveStatusCopy(_ status: ReachabilityStore.Status) -> String {
        switch status {
        case .ok: return String(localized: "Connected")
        case .offline: return String(localized: "This iPhone is offline")
        case .serverUnreachable: return String(localized: "Your server isn\u{2019}t answering")
        }
    }

    /// Critique 2026-10-06 (harden): what to do when something other than Audiobookshelf
    /// answers — usually a reverse proxy's sign-in or block page.
    static let notAudiobookshelfAdvice = String(localized: "Check that the address points to Audiobookshelf itself. If a sign-in page such as Cloudflare Access or Authelia sits in front, add its headers in Account & Security under Reverse Proxy Headers.")

    /// Critique 2026-10-06 (clarify): one row for token state. A valid session with a
    /// refresh token renews itself, so an elapsed expiry only reads "expired" when it can't.
    static func sessionLabel(hasAccessToken: Bool, hasRefreshToken: Bool, expiry: Date?, now: Date) -> String {
        guard hasAccessToken else { return String(localized: "Signed out") }
        guard let expiry else { return String(localized: "Signed in") }
        if expiry < now {
            return hasRefreshToken
                ? String(localized: "Signed in \u{00B7} renews automatically")
                : String(localized: "Session expired \u{00B7} sign in again")
        }
        let when = expiry.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Signed in \u{00B7} valid until \(when)")
    }

    /// Decodes the JWT `exp` claim from the access token, if present.
    private var tokenExpiryDate: Date? {
        let token = AuthStore.shared.accessToken
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func diagRow(_ label: LocalizedStringResource, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(Color.shelfCream)
            Spacer(minLength: 12)
            Typo.supporting(Text(value))
                .foregroundStyle(Color.shelfMuted)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
