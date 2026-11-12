import SwiftUI
import UniformTypeIdentifiers

/// Account & Security page — servers, saved accounts, connection import/export,
/// reverse-proxy headers, and the two security trade-off toggles ("Stay signed in",
/// "Token in stream URL") plus Face ID and Sign Out.
///
/// Extracted out of `SettingsView` (previously the private `accountPage` computed
/// property) as part of UI-12's "Split SettingsView.swift into Views/Settings/"
/// (REVIEW_2026-08-12.md) — this was already reached via its own `NavigationLink` from
/// the root menu, so becoming its own top-level `View` type is a pure file/type
/// reorganization with no navigation change.
struct AccountSecuritySettingsView: View {
    var bottomInset: CGFloat = 0
    /// A `SettingsRow` id to scroll to and highlight (from Settings search).
    var focusRow: String? = nil
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel
    /// Critique 2026-10-06 (harden): what Sign Out will do (`AuthViewModel.signOutPlan`),
    /// worked out when the row is tapped so the alert can name the server it signs out of
    /// and the one it moves to. Non-nil presents the alert.
    @State private var signOutPlan: AuthViewModel.SignOutPlan?
    @State private var showRemoveAllConfirmation = false
    @State private var showAddServer = false
    /// Connection export/import (server URL + username only — see `ConnectionExport`).
    @State private var exportPayload: SharePayload?
    @State private var showImportPicker = false
    @State private var importedConnections: [ExportedConnection] = []
    @State private var showImportChooser = false
    @State private var importError: String?
    /// The connection chosen from an imported file, prefilling Add Server.
    @State private var prefillConnection: ExportedConnection?
    /// Custom HTTP headers for the *current* connection's reverse proxy (Cloudflare
    /// Access, Authelia, etc.) — see `EditableHeaderPair` in `AddServerView.swift`,
    /// reused here so adding one at sign-in and editing one later share the same row UI.
    @State private var currentHeaderPairs: [EditableHeaderPair] = []
    @State private var showCurrentHeadersSection = false
    /// Item 4 (REVIEW-2026-09-09-REMAINING.md): `AuthViewModel.updateCustomHeaders` now
    /// reports whether the edit actually reached the Keychain, and this is where that
    /// gets shown. It used to be discarded entirely, so a failed write left the headers
    /// working for the rest of the session and silently missing after the next account
    /// switch — the user's next clue was the proxy rejecting every request.
    ///
    /// Inline rather than an alert deliberately: the editor auto-saves as you edit, so an
    /// alert would fire repeatedly while typing. This matches the invalid-header-name
    /// warning a few lines below it.
    @State private var headerSaveFailed = false
    /// Critique 2026-10-06 (harden): header values are proxy secrets, and every keystroke
    /// used to write the Keychain. Edits now save after a pause (`headerSaveDebounce`), on
    /// Return, on removing a row, and when the screen goes away; this is the pending save.
    @State private var headerSaveTask: Task<Void, Never>?
    /// What was last handed to `updateCustomHeaders`, so an unchanged list (loading the
    /// editor, a no-op edit) doesn't write again (`ServerConnectionRules.headerSaveIsNeeded`).
    @State private var lastSavedHeaders: [String: String]?
    private static let headerSaveDebounce: UInt64 = 800_000_000

    /// UX-4: this screen's Insecure Connection alert belongs to a saved-account switch it
    /// started, never to the Add Server sheet's sign-in (which has its own alert). Pure, so
    /// the ownership rule is pinned by `AddServerInsecureFlowTests`. Critique 2026-10-06
    /// (harden): the alert now lives in `ServerSwitchFlow`, which keeps this rule by
    /// taking the prompt off the shared `pendingInsecureConnection` the moment its own
    /// switch raises it.
    static func showsAccountSwitchInsecureAlert(isSwitching: Bool,
                                                hasPendingInsecureConnection: Bool) -> Bool {
        isSwitching && hasPendingInsecureConnection
    }
    /// L2 (REVIEW_2026-08-20_UI_SECURITY.md): the swipe-to-delete "Remove" action on a
    /// saved account used to call `authViewModel.removeAccount(account)` immediately,
    /// with no confirmation at all — the one entry point in this file with no guard,
    /// even though it drops that account's stored credentials, strictly more
    /// consequential than Sign Out (which already confirms, below). Set on swipe,
    /// cleared once the alert resolves either way.
    @State private var accountToRemove: ServerAccount?
    /// Critique 2026-10-06 (harden): the shared server-switch flow (`ServerSwitchFlow`):
    /// the confirmation (tapping a row used to switch at once), a prefilled sign-in for a
    /// server with no stored password (it used to do nothing visible), the Insecure
    /// Connection alert, and a failure alert here, where the switch started (it used to
    /// fail silently). Its `switchingAccountId` is LS-4's in-flight state: the row's
    /// spinner, and the whole list disabled so a slow re-authentication can't be
    /// double-tapped into an overlapping teardown/reload.
    @State private var flow = ServerSwitchFlow()

    @AppStorage(SettingsKeys.streamWithURLToken) private var streamWithURLToken = false
    @AppStorage(SettingsKeys.storePassword) private var storePassword = false
    @AppStorage(SettingsKeys.appLockEnabled) private var appLockEnabled = false
    /// SEC-3: surfaces a warning when the device has no passcode/Face ID/Touch ID
    /// enrolled, since `AppLockManager.authenticate()` silently unlocks immediately in
    /// that case — the toggle would otherwise look like it's protecting something it
    /// isn't.
    @State private var appLock = AppLockManager.shared

    /// AX-13: the App Lock caption, worded for whatever `AppLockManager` reports.
    /// Passcode-only devices get their own sentence rather than "Passcode (or your
    /// device passcode as a fallback)".
    private var appLockCaption: String {
        guard appLock.hasBiometrics else {
            return String(localized: "Your device passcode is asked for every time ShelfHead returns to the foreground.")
        }
        return String(localized: "\(appLock.biometryDisplayName) (or your device passcode as a fallback) is asked for every time ShelfHead returns to the foreground.", comment: "%@ is the biometry name, e.g. Face ID or Touch ID.")
    }

    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    var body: some View {
        SettingsAnchoredList(focusRow: focusRow) {
            Section {
                // Batch 490 (REVIEW 2026-11-11 O1): while the server has ended this
                // session (and after "Not Now"), say so here too, one tap from signing in.
                if authViewModel.sessionNeedsSignIn {
                    Button {
                        Haptics.selection()
                        authViewModel.reopenSessionExpiredPrompt()
                    } label: {
                        HStack(spacing: Space.s) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.shelfOrange)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text("Session ended")
                                .foregroundStyle(Color.shelfCream)
                            Spacer(minLength: Space.s)
                            Typo.secondaryAction(Text("Sign In Again"))
                                .foregroundStyle(Color.shelfAmberText)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(authViewModel.sessionExpiredPrompt != nil || authViewModel.isReauthenticating)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(Text("The server ended this session. Opens Sign In Again."))
                }

                HStack {
                    Image(systemName: "server.rack")
                        .foregroundStyle(Color.shelfAmberText)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Typo.supporting(Text("Server"))
                            .foregroundStyle(Color.shelfMuted)
                        Text(authViewModel.serverURL)
                            .font(.subheadline)
                            .foregroundStyle(Color.shelfCream)
                    }
                }

                HStack {
                    Image(systemName: "person.fill")
                        .foregroundStyle(Color.shelfAmberText)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Typo.supporting(Text("Username"))
                            .foregroundStyle(Color.shelfMuted)
                        Text(authViewModel.username)
                            .font(.subheadline)
                            .foregroundStyle(Color.shelfCream)
                    }
                }

                NavigationLink(destination: ActiveSessionsView(bottomInset: bottomInset)) {
                    settingRow("key.horizontal", "Active sessions")
                }
                .settingsRowAnchor(SettingsRow.activeSessions)

                // Batch 492 (REVIEW 2026-11-11 N2): Server backups, Library Doctor and Upload
                // moved to Settings > Server Tools (`ServerToolsSettingsSection`).
            } header: {
                RetroSectionHeader(title: "Current Account")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                ForEach(authViewModel.accounts) { account in
                    Button {
                        if account.id != authViewModel.currentAccountId {
                            // Critique 2026-10-06 (harden): confirm (or ask for the
                            // password), then switch — `ServerSwitchFlow.start`.
                            flow.start(account, authViewModel: authViewModel)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundStyle(Color.shelfMuted)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.username)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.shelfCream)
                                HStack(spacing: 4) {
                                    Typo.supporting(Text(account.displayHost))
                                        .foregroundStyle(Color.shelfMuted)
                                    // Persistent warning, independent of whether it's been
                                    // acknowledged — a stated risk doesn't stop being one
                                    // just because it was accepted once.
                                    if account.isInsecureRemoteConnection {
                                        // Critique 2026-10-06 (colour): the app's alarm hue
                                        // (DESIGN.md Burnt Orange), not raw system orange.
                                        Typo.fine(Image(systemName: "exclamationmark.triangle.fill"))
                                            .foregroundStyle(Color.shelfOrange)
                                            .accessibilityLabel("Insecure connection")
                                    }
                                }
                            }
                            Spacer()
                            // LS-4: in-flight feedback for the row being switched to, so
                            // the tap doesn't look ignored during teardown/re-auth.
                            if flow.switchingAccountId == account.id {
                                ProgressView()
                                    .tint(Color.shelfAmberText)
                                    .accessibilityLabel("Switching account")
                            } else if account.id == authViewModel.currentAccountId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.shelfAmberText)
                                    // Batch 490 (REVIEW 2026-11-11 A5): the checkmark had no
                                    // spoken meaning; the row now carries the value
                                    // "Current server" (below), so the glyph itself is hidden.
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .disabled(flow.switchingAccountId != nil)
                    // Batch 490 (REVIEW 2026-11-11 A5): Remove without the swipe (the swipe
                    // stays); same confirmation alert via `accountToRemove`.
                    .contextMenu {
                        Button(role: .destructive) {
                            accountToRemove = account
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .accessibilityValue(account.id == authViewModel.currentAccountId ? Text("Current server") : Text(verbatim: ""))
                }
                .onDelete { indexSet in
                    // L2: confirm before removing — see `accountToRemove` and the
                    // `.alert` in `body`. A swipe-to-delete gesture on this list only
                    // ever produces one index at a time (no multi-select edit mode
                    // here), so the first is the one that was actually swiped.
                    if let index = indexSet.first {
                        accountToRemove = authViewModel.accounts[index]
                    }
                }

                Button {
                    showAddServer = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.shelfAmberText)
                            .frame(width: 24)
                        Text("Add Server")
                            .foregroundStyle(Color.shelfAmberText)
                    }
                }
                .settingsRowAnchor(SettingsRow.servers)
            } header: {
                RetroSectionHeader(title: "Servers")
            }
            .listRowBackground(Color.shelfCard)

            // Export/import connection *settings* only — server URL + username, never
            // the password (that stays in the Keychain, never leaves the device). For
            // a self-hosted app where onboarding means typing a URL and credentials
            // into every family member's phone, this removes the URL-typing part;
            // whoever imports it still enters their own password once.
            Section {
                Button {
                    exportPayload = ConnectionExport.writeExportFile(accounts: authViewModel.accounts)
                        .map { SharePayload(url: $0) }
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Color.shelfAmberText)
                            .frame(width: 24)
                        Text("Export Connections")
                            .foregroundStyle(Color.shelfCream)
                    }
                }
                .disabled(authViewModel.accounts.isEmpty)
                .settingsRowAnchor(SettingsRow.importExport)

                Button {
                    showImportPicker = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(Color.shelfAmberText)
                            .frame(width: 24)
                        Text("Import Connections")
                            .foregroundStyle(Color.shelfCream)
                    }
                }
            } header: {
                RetroSectionHeader(title: "Import & Export")
            } footer: {
                // Batch 492 (N2): Export/Import Settings now lives on System & Privacy.
                Typo.supporting(Text("Exports server addresses and usernames only — never passwords or custom HTTP headers. Importing prefills the Add Server form; you’ll still need to enter that account’s password, and re-add any reverse-proxy header by hand if that server needs one."))
                    .foregroundStyle(Color.shelfMuted)
            }
            .listRowBackground(Color.shelfCard)

            // Custom headers for a reverse proxy in front of the *current* server
            // (Cloudflare Access, Authelia forward-auth, an nginx auth_request gate).
            // Editing here applies immediately (AuthStore + Keychain mirror) and updates
            // the saved account entry, without a full re-login — see
            // `AuthViewModel.updateCustomHeaders`.
            Section {
                DisclosureGroup("Custom HTTP Headers", isExpanded: $showCurrentHeadersSection) {
                    ForEach($currentHeaderPairs) { $pair in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                // HIG audit 2026-09-17 L9: labels mirror
                                // `AddServerView.headerFields(for:)` — these fields were
                                // otherwise unlabeled for VoiceOver beyond their placeholder.
                                TextField("Header name", text: $pair.key)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .accessibilityLabel("Header name")
                                    .onSubmit { saveCurrentHeaders() }
                                // Critique 2026-10-06 (harden): a proxy secret, so hidden
                                // by default with a show/hide toggle (was a plain field).
                                HeaderValueField(value: $pair.value) { saveCurrentHeaders() }
                                // Critique 2026-10-06 (colour): a destructive role
                                // instead of a raw `.red` glyph, so the system draws the
                                // removal colour.
                                Button(role: .destructive) {
                                    currentHeaderPairs.removeAll { $0.id == pair.id }
                                    saveCurrentHeaders()
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        // Batch 490 (REVIEW 2026-11-11 A5): 44 pt target.
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove header")
                            }
                            // Advisory only — `AuthStore.sanitizedCustomHeaders` is what
                            // actually strips a reserved/malformed header name before it
                            // ever reaches a request (a header named `Authorization`, for
                            // instance, would otherwise silently replace the real bearer
                            // token). This just explains why a saved header appears to do
                            // nothing, without blocking editing the rest of the list.
                            if !currentHeaderNameIsUsable(pair.key) {
                                Typo.fine(HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(Color.shelfOrange)
                                    Text("This header name can’t be used and will be ignored — it’s reserved or contains invalid characters.")
                                })
                                .foregroundStyle(Color.shelfCream) // DESIGN.md (orange rule): orange glyph, cream sentence — Burnt Orange is ~4.4:1 as text
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            // Item 30 (REVIEW-2026-09-09.md): `AuthStore.isValidCustomHeaderValue`
                            // existed with no UI caller — a pasted value with a trailing
                            // newline (or any other control character) was silently dropped
                            // by `AuthStore.sanitizedCustomHeaders` at send time, with nothing
                            // here explaining why the header appeared to do nothing. Same
                            // visual treatment as the invalid-name warning above.
                            if !currentHeaderValueIsUsable(pair.value) {
                                Typo.fine(HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(Color.shelfOrange)
                                    Text("This header value contains a character that isn\u{2019}t allowed (such as a line break) and will be ignored.")
                                })
                                .foregroundStyle(Color.shelfCream) // DESIGN.md (orange rule): orange glyph, cream sentence — Burnt Orange is ~4.4:1 as text
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Button {
                        currentHeaderPairs.append(EditableHeaderPair())
                    } label: {
                        Label("Add Header", systemImage: "plus.circle.fill")
                    }

                    // Item 4: the save reported a Keychain failure. Same visual treatment
                    // as the invalid-header-name warning above — an inline caption, not a
                    // blocking alert, since the section auto-saves as you type.
                    if headerSaveFailed {
                        Typo.fine(HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.shelfOrange)
                            Text("Couldn\u{2019}t save to the Keychain. These headers are in use now, but won\u{2019}t be remembered for this server — try again.")
                        })
                        .foregroundStyle(Color.shelfCream) // DESIGN.md (orange rule): orange glyph, cream sentence — Burnt Orange is ~4.4:1 as text
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onChange(of: showCurrentHeadersSection) { _, isExpanded in
                    // Loaded lazily on first expand rather than every appearance of the
                    // whole Account page.
                    if isExpanded && currentHeaderPairs.isEmpty {
                        currentHeaderPairs = authViewModel.customHeaders.map { EditableHeaderPair(key: $0.key, value: $0.value) }
                    }
                }
                // Review 7 Low (headers): another account has its own headers; drop the old pairs.
                .onReceive(NotificationCenter.default.publisher(for: .shelfheadAccountChanged)) { _ in
                    headerSaveTask?.cancel()
                    headerSaveTask = nil
                    lastSavedHeaders = nil
                    currentHeaderPairs = showCurrentHeadersSection
                        ? authViewModel.customHeaders.map { EditableHeaderPair(key: $0.key, value: $0.value) }
                        : []
                    lastSavedHeaders = ServerConnectionRules.customHeaders(from: currentHeaderPairs)
                    headerSaveFailed = false
                }
                .onChange(of: currentHeaderPairs) { _, _ in
                    // Critique 2026-10-06 (harden): debounced, not per keystroke.
                    scheduleHeaderSave()
                }
                // HIG audit 2026-09-17 L9: mirrors `AddServerView.advancedHeadersDisclosure`'s
                // hint on its DisclosureGroup.
                .accessibilityHint("Headers for a reverse proxy in front of this server, such as Cloudflare Access or Authelia. Most servers don\u{2019}t need these.")
                .settingsRowAnchor(SettingsRow.customHeaders)
            } header: {
                RetroSectionHeader(title: "Reverse Proxy Headers")
            } footer: {
                Typo.supporting(Text("For a server behind a proxy that needs its own header — most people can leave this empty."))
                    .foregroundStyle(Color.shelfMuted)
            }
            .listRowBackground(Color.shelfCard)

            // Security: both of these are the same kind of decision (convenience vs.
            // exposure) even though one used to live on the Downloads page and the
            // other on a separate Privacy page — grouped here since they're both
            // "how much does ShelfHead trust this device/network" choices, not
            // downloads or diagnostics settings.
            Section {
                // T8 (REVIEW_2026-09-04_UI.md): each toggle now explains itself with an
                // inline caption directly underneath, matching the pattern used elsewhere
                // in this screen, instead of stacking all three explanations into one
                // dense section footer below.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $storePassword) {
                        settingRow("key.fill", "Stay signed in (save password)")
                    }
                    .settingsRowAnchor(SettingsRow.staySignedIn)
                    .onChange(of: storePassword) { _, on in
                        // Turning it off drops the stored password immediately — both the
                        // primary `.password` entry AND every saved server's password
                        // (`AccountStore`), which is otherwise a separate copy that this
                        // toggle didn't used to touch. Turning it back on re-saves on the
                        // next successful login/switch.
                        if !on {
                            Task {
                                try? await KeychainService.shared.save("", for: .password)
                                await AccountStore.deleteAllPasswords()
                            }
                        }
                    }
                    Typo.supporting(Text("When off, no password is kept for automatic re-login — for this server or any other saved server. Switching between saved servers, or a session that expires, will ask you to re-enter it."))
                        .foregroundStyle(Color.shelfMuted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $streamWithURLToken) {
                        settingRow("link.badge.plus", "Add token to stream URL (compatibility)")
                    }
                    .settingsRowAnchor(SettingsRow.streamToken)
                    // Item 29 (REVIEW-2026-09-09.md): this footer used to describe the
                    // URL-token mode as what "most servers need," with the header-only
                    // path (the actual default — `streamWithURLToken` starts `false`,
                    // see `AudioPlayerService.assetURL`) framed as the exception that
                    // "can break playback." That's inverted from both the real default
                    // and the intent: header-only is the normal, private path for
                    // everyone; this toggle is a narrow opt-in escape hatch for the
                    // specific proxy/AVPlayer setups where it's needed.
                    Typo.supporting(Text("Off by default: your auth token goes in a request header, never in the URL — safer if your server or a reverse proxy logs full request URLs. Turn this on only if playback stalls or fails partway through a book on your setup — some proxy/AVPlayer combinations drop the header on the range requests AVPlayer makes mid-stream, and adding the token to the URL as well works around that."))
                        .foregroundStyle(Color.shelfMuted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    // AX-13 (docs/design-review.md): label, glyph and caption follow the
                    // device's real biometry through AX-12's shared helpers, so a Touch ID
                    // or passcode-only device isn't told it will be asked for Face ID.
                    Toggle(isOn: $appLockEnabled) {
                        settingRow(appLock.biometrySymbolName, "Require \(appLock.biometryDisplayName) to open ShelfHead")
                    }
                    .settingsRowAnchor(SettingsRow.appLock)
                    Typo.supporting(Text(appLockCaption))
                        .foregroundStyle(Color.shelfMuted)

                    if appLockEnabled && appLock.deviceHasNoProtection {
                        Typo.supporting(Label {
                            Text("Your device has no passcode set, so this won’t actually protect anything — anyone can open it.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.shelfOrange)
                        })
                        // DESIGN.md (orange rule): orange glyph, cream sentence.
                        .foregroundStyle(Color.shelfCream)
                    }
                }
            } header: {
                RetroSectionHeader(title: "Security")
            }
            .listRowBackground(Color.shelfCard)
            .task { appLock.refreshDeviceProtectionStatus() }

            Section {
                // Critique 2026-10-06 (colour): `role: .destructive` draws the system's
                // destructive colour for text and glyph, replacing two raw `.red`s.
                // Critique 2026-10-06 (harden): Sign Out is this server only (user
                // decision), and the label says which one.
                Button(role: .destructive) {
                    Task { signOutPlan = await authViewModel.signOutPlan() }
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.forward")
                            .frame(width: 24)
                        Text(Self.signOutLabel(serverURL: authViewModel.serverURL))
                    }
                }
                .settingsRowAnchor(SettingsRow.signOut)
                // The full wipe Sign Out used to be, as its own named act. Only offered
                // when there is more than one saved server; with one, it is Sign Out.
                if authViewModel.accounts.count > 1 {
                    Button(role: .destructive) {
                        showRemoveAllConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                                .frame(width: 24)
                            Text("Remove All Servers from This Device")
                        }
                    }
                    .settingsRowAnchor(SettingsRow.removeAllServers)
                }
            } footer: {
                if authViewModel.accounts.count > 1 {
                    Typo.supporting(Text("Sign Out leaves your other saved servers here. Remove All Servers signs out of every one and deletes their saved passwords. Downloads stay either way."))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            .listRowBackground(Color.shelfCard)
        }
        .scrollContentBackground(.hidden)
        .background(Color.shelfBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomClearance) }
        .navigationTitle("Account & Security")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddServer) {
            AddServerView()
        }
        // CO-7 pilot (Batch 353): this list's toggles inherit the tint (CO-8), so amber is
        // re-applied inside, before the alert, and the alert's Cancel takes the outer
        // neutral tint. Every alert below repeats the same pair.
        .tint(Color.shelfAmberText)
        .alert(signOutPlan.map { Self.signOutTitle(host: $0.host) } ?? "",
               isPresented: Binding(get: { signOutPlan != nil }, set: { if !$0 { signOutPlan = nil } }),
               presenting: signOutPlan) { _ in
            Button("Cancel", role: .cancel) { }
            Button("Sign Out", role: .destructive) {
                Task { await authViewModel.signOut() }
            }
        } message: { plan in
            // Critique 2026-10-06 (harden): say what Sign Out does to this server, its
            // downloads and progress, and where it lands, instead of "Are you sure" (see
            // `signOutMessage`).
            Text(Self.signOutMessage(
                plan: plan,
                unsyncedPositions: AudioPlayerService.shared.pendingProgressCount,
                offlineWithBookLoaded: playerViewModel.currentBook != nil
                    && ReachabilityStore.shared.status != .ok
            ))
        }
        .systemChromeTint()
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .alert("Remove All Servers from This Device?", isPresented: $showRemoveAllConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove All Servers", role: .destructive) {
                Task { await authViewModel.removeAllServersFromThisDevice() }
            }
        } message: {
            Text(Self.removeAllServersMessage(
                serverCount: authViewModel.accounts.count,
                unsyncedPositions: AudioPlayerService.shared.pendingProgressCount,
                offlineWithBookLoaded: playerViewModel.currentBook != nil
                    && ReachabilityStore.shared.status != .ok
            ))
        }
        .systemChromeTint()
        // Critique 2026-10-06 (harden): the shared server-switch flow — confirmation,
        // prefilled sign-in, Insecure Connection, failure alert.
        .serverSwitchFlow(flow)
        // L2 (REVIEW_2026-08-20_UI_SECURITY.md): mirrors Sign Out's confirmation just
        // above, naming the specific account so the user knows which row they swiped.
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .alert("Remove Account", isPresented: Binding(
            get: { accountToRemove != nil },
            set: { if !$0 { accountToRemove = nil } }
        ), presenting: accountToRemove) { account in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await authViewModel.removeAccount(account) }
            }
        } message: { account in
            // T1 (REVIEW_2026-09-04_UI.md): removing the currently active account also
            // signs the user out (see `AuthViewModel.removeAccount`) — say so up front
            // rather than letting them discover it via a suddenly-stale "Current
            // Account" section.
            Text(Self.removeAccountMessage(username: account.username, host: account.displayHost,
                                           isCurrent: account.id == authViewModel.currentAccountId))
        }
        .systemChromeTint()
        // Export: hand the freshly-written temp JSON to the system share sheet.
        .sheet(item: $exportPayload) { payload in
            ActivityView(items: [payload.url])
        }
        // Import: a standard document picker rather than a custom drop zone — this is a
        // rare, one-off action (setting up a new device/family member), not worth a
        // bespoke UI.
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let connections = ConnectionExport.parseImportFile(at: url) else {
                    importError = String(localized: "That file isn\u{2019}t a ShelfHead connections export.")
                    return
                }
                guard !connections.isEmpty else {
                    importError = String(localized: "That file doesn\u{2019}t contain any connections.")
                    return
                }
                if connections.count == 1 {
                    prefillConnection = connections[0]
                } else {
                    importedConnections = connections
                    showImportChooser = true
                }
            case .failure(let error):
                // Polish pass (ST-5): friendly sentence; raw error goes to the log.
                ShelfLog.error(.servers, "Couldn't read the connections import file: \(error.localizedDescription)")
                importError = String(localized: "Couldn\u{2019}t open that file. Choose a ShelfHead export and try again.")
            }
        }
        // More than one connection in the imported file — let the user pick which one
        // to prefill Add Server with (still one at a time; each needs its own password).
        .sheet(isPresented: $showImportChooser) {
            NavigationStack {
                List(importedConnections) { conn in
                    Button {
                        showImportChooser = false
                        prefillConnection = conn
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conn.username)
                                .foregroundStyle(Color.shelfCream)
                            Typo.supporting(Text(URL(string: conn.serverURL)?.host ?? conn.serverURL))
                                .foregroundStyle(Color.shelfMuted)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.shelfBackground.ignoresSafeArea())
                .navigationTitle("Choose a Connection")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        SheetCancelButton { showImportChooser = false }
                            // Critique 2026-10-06 (harden): nav-bar chrome is monochrome.
                            .monochromeToolbarItem()
                    }
                }
            }
        }
        .sheet(item: $prefillConnection) { conn in
            AddServerView(prefillServerURL: conn.serverURL, prefillUsername: conn.username)
        }
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .systemChromeTint()
        // Switching to a saved account that's a plain-HTTP, non-local connection and
        // hasn't been acknowledged yet is blocked the same way a brand-new Add Server
        // attempt is — see `AuthViewModel.pendingInsecureConnection`. Its alert, and the
        // "Couldn't Remember That Choice" follow-up (Item 4), moved into
        // `ServerSwitchFlow` with the rest of the switch (Critique 2026-10-06).
        //
        // Critique 2026-10-06 (harden): the header editor saves after a pause, so flush a
        // pending edit when the screen goes away rather than drop it.
        .onDisappear { flushPendingHeaderSave() }
        .reexpandsTabBarOnAppear()
    }

    /// Critique 2026-10-06 (harden): "Sign Out of <host>" — Sign Out is this server only.
    static func signOutLabel(serverURL: String) -> String {
        guard let host = URL(string: serverURL)?.host, !host.isEmpty else { return String(localized: "Sign Out") }
        return String(localized: "Sign Out of \(host)", comment: "Button title. %@ is the server host.")
    }

    static func signOutTitle(host: String) -> String {
        host.isEmpty
            ? String(localized: "Sign Out?")
            : String(localized: "Sign Out of \(host)?", comment: "Alert title. %@ is the server host.")
    }

    /// Critique 2026-10-06 (harden): the Sign Out alert, stated from what Sign Out actually
    /// does (`AuthViewModel.signOut`):
    /// - playback stops (its position is flushed first) and Up Next is cleared;
    /// - this server's saved sign-in and password are removed from this device; other
    ///   saved servers stay;
    /// - downloaded files are kept, and the account id is retained (Batch 382,
    ///   `AccountStore.removeForSignOut`), so they come back on a sign-in to the same server
    ///   with the same username;
    /// - where it lands: the next saved server when it can sign in silently
    ///   (`plan.nextHost`), otherwise the sign-in screen with the saved servers listed;
    /// - progress still in `PendingProgressQueue` is scoped to this account and waits for a
    ///   sign-in back to it (30 days), and so is the current book's final position when the
    ///   server can't be reached.
    /// Pure, pinned by `HardenCopyTests`.
    static func signOutMessage(plan: AuthViewModel.SignOutPlan, unsyncedPositions: Int,
                               offlineWithBookLoaded: Bool) -> String {
        var text = String(localized: "Playback stops, Up Next is cleared and this server\u{2019}s saved sign-in is removed from this device. Downloaded books stay here and come back when you sign in to it again with the same username.")
        if let next = plan.nextHost {
            text += " " + String(localized: "ShelfHead then switches to \(next).", comment: "%@ is the host of the next saved server.")
        } else if plan.remainingServers > 0 {
            text += plan.remainingServers == 1
                ? " " + String(localized: "Your other saved server stays, ready to sign in to.")
                : " " + String(localized: "Your other saved servers stay, ready to sign in to.")
        }
        text += unsyncedSentence(unsyncedPositions: unsyncedPositions,
                                 offlineWithBookLoaded: offlineWithBookLoaded,
                                 server: String(localized: "this server", comment: "Fallback noun phrase for the current server, used inside a sentence."))
        return text
    }

    /// Critique 2026-10-06 (harden): Remove All Servers from This Device — the full wipe
    /// (`AuthViewModel.removeAllServersFromThisDevice`). Every saved account's id is
    /// retained first, so downloads still come back per server. Pure, pinned by
    /// `HardenCopyTests`.
    static func removeAllServersMessage(serverCount: Int, unsyncedPositions: Int,
                                        offlineWithBookLoaded: Bool) -> String {
        // Whole sentences per case (not a spliced fragment) so word order can differ per language.
        var text = serverCount == 1
            ? String(localized: "Signs out and removes your saved server and its password from this device. Playback stops and Up Next is cleared. Downloaded books stay here and come back when you sign in to each server again with the same username.")
            : String(localized: "Signs out and removes all \(serverCount) saved servers and their passwords from this device. Playback stops and Up Next is cleared. Downloaded books stay here and come back when you sign in to each server again with the same username.", comment: "%lld is the number of saved servers (2 or more).")
        text += unsyncedSentence(unsyncedPositions: unsyncedPositions,
                                 offlineWithBookLoaded: offlineWithBookLoaded,
                                 server: String(localized: "that server", comment: "Fallback noun phrase for a previously saved server, used inside a sentence."))
        return text
    }

    /// Critique 2026-10-06 (harden): removing the current server ends its session only
    /// (`AuthViewModel.removeAccount`); unlike Sign Out, its downloads go too.
    static func removeAccountMessage(username: String, host: String, isCurrent: Bool) -> String {
        let base = String(localized: "\u{201C}\(username) on \(host)\u{201D} and its downloads are removed from this device.", comment: "First %@ is the username, second is the server host.")
        return isCurrent ? base + " " + String(localized: "You\u{2019}re signed out of it; your other saved servers stay.") : base
    }

    /// The unsynced-positions warning shared by Sign Out, Remove All Servers and Sign Out
    /// All Devices (`ActiveSessionsView`). Empty when there's nothing to warn about.
    static func unsyncedSentence(unsyncedPositions: Int, offlineWithBookLoaded: Bool,
                                 server: String) -> String {
        if unsyncedPositions > 0 {
            // Whole sentences per case (not spliced fragments) so grammar can differ per language.
            if unsyncedPositions == 1 {
                return " " + String(localized: "1 listening position hasn\u{2019}t reached your server yet. It\u{2019}ll sync if you sign back in to \(server) within 30 days.", comment: "%@ is a noun phrase for the server, e.g. 'this server'.")
            }
            return " " + String(localized: "\(unsyncedPositions) listening positions haven\u{2019}t reached your server yet. They\u{2019}ll sync if you sign back in to \(server) within 30 days.", comment: "First %lld is the count; %@ is a noun phrase for the server, e.g. 'this server'.")
        } else if offlineWithBookLoaded {
            return " " + String(localized: "You\u{2019}re offline, so your place in the current book won\u{2019}t reach your server.")
        }
        return ""
    }

    /// Whether a header name the user is currently editing will actually make it onto a
    /// request — mirrors `AddServerView.headerNameIsUsable`. A blank name (a row that
    /// isn't filled in yet) isn't flagged; enforcement itself happens in
    /// `AuthStore.sanitizedCustomHeaders` regardless of this UI hint.
    private func currentHeaderNameIsUsable(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return AuthStore.isValidCustomHeaderName(trimmed)
    }

    /// Whether a header value the user is currently editing will actually reach a
    /// request — mirrors `currentHeaderNameIsUsable`/`AddServerView.headerValueIsUsable`,
    /// but for the value side. Item 30 (REVIEW-2026-09-09.md): `AuthStore.
    /// isValidCustomHeaderValue` existed with no UI caller at all, so a pasted value
    /// with a trailing newline (or any other control character) was silently stripped
    /// by `AuthStore.sanitizedCustomHeaders` at send time with no explanation here.
    /// Deliberately does NOT trim first the way the name check does: a leading/
    /// trailing space is a harmless, valid header-value byte, but a leading/trailing
    /// newline is exactly the case this exists to catch — trimming it away before
    /// checking would hide the warning instead of surfacing it. An empty value is
    /// already valid per `isValidCustomHeaderValue` (no control characters to find),
    /// so it needs no separate blank-row carve-out the way the name check does.
    private func currentHeaderValueIsUsable(_ value: String) -> Bool {
        AuthStore.isValidCustomHeaderValue(value)
    }

    /// Critique 2026-10-06 (harden): saves after `headerSaveDebounce` without further
    /// edits, instead of on every keystroke.
    private func scheduleHeaderSave() {
        headerSaveTask?.cancel()
        headerSaveTask = Task {
            try? await Task.sleep(nanoseconds: Self.headerSaveDebounce)
            guard !Task.isCancelled else { return }
            saveCurrentHeaders()
        }
    }

    /// Saves now if an edit is still waiting for its debounce.
    private func flushPendingHeaderSave() {
        guard headerSaveTask != nil else { return }
        saveCurrentHeaders()
    }

    /// Collapses `currentHeaderPairs` into a dictionary (dropping blank-named rows) and
    /// pushes it to `AuthViewModel.updateCustomHeaders`, which applies it immediately
    /// and persists it for the active connection. Skipped when nothing changed since the
    /// last save (Critique 2026-10-06), e.g. the editor's own first load.
    private func saveCurrentHeaders() {
        headerSaveTask?.cancel()
        headerSaveTask = nil
        let result = ServerConnectionRules.customHeaders(from: currentHeaderPairs)
        guard ServerConnectionRules.headerSaveIsNeeded(result,
                                                       lastSaved: lastSavedHeaders ?? authViewModel.customHeaders,
                                                       lastSaveFailed: headerSaveFailed) else { return }
        lastSavedHeaders = result
        Task {
            // Item 4: the return value used to be discarded. Assigned (not `||`-ed) so a
            // later successful save clears a stale warning without needing its own reset.
            let saved = await authViewModel.updateCustomHeaders(result)
            headerSaveFailed = !saved
        }
    }
}

/// Batch 492 (REVIEW 2026-11-11 N2): the Settings > Server Tools page. Server backups, Library
/// Doctor and Upload used to sit in Account & Security's "Current Account" section; the rows,
/// destinations and permission checks are unchanged. Like `TranscriptsSettingsView`, the body is
/// a `Section` for `SettingsCategoryPage` to host.
struct ServerToolsSettingsSection: View {
    var bottomInset: CGFloat = 0
    @Environment(AuthViewModel.self) private var authViewModel

    /// Whether the Settings root offers the page at all: an account that can update the library
    /// (admins always can) or upload. Server backups additionally needs an admin.
    static func isAvailable(canUpdateLibrary: Bool, canUpload: Bool) -> Bool {
        canUpdateLibrary || canUpload
    }

    var body: some View {
        let user = authViewModel.currentUser
        Section {
            // Critique 2026-10-06 (distill): moved here from Diagnostics, next to the server it
            // backs up. `ServerBackupsView` also handles non-admins itself.
            if user?.isAdmin == true {
                NavigationLink(destination: ServerBackupsView(bottomInset: bottomInset)) {
                    settingRow("externaldrive.badge.timemachine", "Server backups")
                }
                .settingsRowAnchor(SettingsRow.serverBackups)
            }
            // Batch 441: admins, or accounts allowed to update items.
            if user?.canUpdateLibrary == true {
                NavigationLink(destination: LibraryDoctorView(bottomInset: bottomInset)) {
                    settingRow("stethoscope", "Library Doctor")
                }
                .settingsRowAnchor(SettingsRow.libraryDoctor)
            }
            // Batch 444: accounts with the server's Upload permission.
            if user?.canUpload == true {
                NavigationLink(destination: UploadView(bottomInset: bottomInset)) {
                    settingRow("square.and.arrow.up", "Upload")
                }
                .settingsRowAnchor(SettingsRow.upload)
            }
        } header: {
            RetroSectionHeader(title: "Server Tools")
        }
        .listRowBackground(Color.shelfCard)
    }
}
