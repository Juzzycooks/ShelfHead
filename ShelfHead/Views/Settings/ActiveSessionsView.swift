import SwiftUI

/// Lists this account's active login sessions (Audiobookshelf 2.36+'s `/api/me/sessions`)
/// with per-session sign-out and a "Sign Out All Devices" footer action. Reached from
/// Account & Security's "Current Account" section.
struct ActiveSessionsView: View {
    var bottomInset: CGFloat = 0
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(AuthViewModel.self) private var authViewModel

    private enum LoadState { case loading, unsupported, failed(String), loaded }

    @State private var state: LoadState = .loading
    @State private var sessions: [AuthSession] = []
    @State private var actionError: String?
    /// Critique 2026-10-06 (harden): what signing this device out of this server leads to
    /// (`AuthViewModel.signOutPlan`), read when Sign Out All Devices is tapped. Non-nil
    /// presents the confirmation.
    @State private var signOutAllPlan: AuthViewModel.SignOutPlan?
    @State private var isSigningOutAll = false
    /// Critique 2026-10-06 (harden): the device whose swipe Sign Out is waiting on its
    /// confirmation. It used to be a full-swipe destructive action that fired at once.
    @State private var pendingSessionSignOut: AuthSession?

    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingView("Loading sessions…")
            case .unsupported:
                EmptyStateView(icon: "key.horizontal", title: LocalizedStringResource("Not supported"),
                               subtitle: LocalizedStringResource("Session management needs Audiobookshelf 2.36 or later."))
            case .failed(let message):
                EmptyStateView(icon: "exclamationmark.triangle", title: LocalizedStringResource("Couldn\u{2019}t load sessions"), subtitle: .verbatim(message),
                               actionTitle: LocalizedStringResource("Retry"), action: { Task { await load() } })
            case .loaded:
                if sessions.isEmpty {
                    EmptyStateView(icon: "key.horizontal", title: LocalizedStringResource("No active sessions"), subtitle: LocalizedStringResource("Nothing to show here."))
                } else {
                    list
                }
            }
        }
        .background(Color.shelfBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomClearance) }
        .navigationTitle("Active Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .alert("Couldn\u{2019}t Sign Out That Device", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(actionError ?? "")
        }
        .systemChromeTint()
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .alert("Sign Out All Devices?",
               isPresented: Binding(get: { signOutAllPlan != nil }, set: { if !$0 { signOutAllPlan = nil } }),
               presenting: signOutAllPlan) { _ in
            Button("Cancel", role: .cancel) { }
            Button("Sign Out All", role: .destructive) { Task { await signOutAllDevices() } }
        } message: { plan in
            Text(Self.signOutAllMessage(
                plan: plan, username: authViewModel.username,
                unsyncedPositions: AudioPlayerService.shared.pendingProgressCount,
                offlineWithBookLoaded: playerViewModel.currentBook != nil
                    && ReachabilityStore.shared.status != .ok))
        }
        .systemChromeTint()
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .confirmationDialog(
            Self.sessionSignOutTitle(deviceName: pendingSessionSignOut?.displayName ?? ""),
            isPresented: Binding(get: { pendingSessionSignOut != nil },
                                 set: { if !$0 { pendingSessionSignOut = nil } }),
            titleVisibility: .visible,
            presenting: pendingSessionSignOut
        ) { session in
            Button("Sign Out Device", role: .destructive) { Task { await signOut(session) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("That device will need to sign in again to keep listening.")
        }
        .systemChromeTint()
        .reexpandsTabBarOnAppear()
    }

    /// Critique 2026-10-06 (harden): names the device in the confirmation. Pure, pinned
    /// by `SettingsClarityTests`.
    static func sessionSignOutTitle(deviceName: String) -> String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? String(localized: "Sign Out This Device?")
            : String(localized: "Sign Out \u{201C}\(name)\u{201D}?", comment: "Confirmation title. %@ is the device name.")
    }

    private var list: some View {
        List {
            Section {
                ForEach(sessions) { session in
                    sessionRow(session)
                }
            } header: {
                RetroSectionHeader(title: "Sessions")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                Button(role: .destructive) {
                    Task { signOutAllPlan = await authViewModel.signOutPlan() }
                } label: {
                    if isSigningOutAll {
                        // LS-13 (docs/design-review.md, Round 3): brand-tinted, was
                        // falling back to the system tint.
                        HStack { Spacer(); ProgressView().shelfSpinner(); Spacer() }
                    } else {
                        Text("Sign Out All Devices")
                    }
                }
                .disabled(isSigningOutAll)
            } footer: {
                Typo.supporting(Text("Ends every session for this account on this server, including this one. Your other saved servers stay on this device."))
                    .foregroundStyle(Color.shelfMuted)
            }
            .listRowBackground(Color.shelfCard)
        }
        .scrollContentBackground(.hidden)
    }

    private func sessionRow(_ session: AuthSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.symbolName)
                .foregroundStyle(Color.shelfAmberText)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayName)
                        .foregroundStyle(Color.shelfCream)
                    if session.isThisDevice {
                        Typo.fine(Text("This device"), weight: .bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.shelfAmberText.opacity(0.2)))
                            .foregroundStyle(Color.shelfAmberText)
                    }
                }
                Typo.supporting(Text(captionText(for: session)))
                    .foregroundStyle(Color.shelfMuted)
            }
        }
        // Critique 2026-10-06 (harden): no full swipe, and the button asks first.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !session.isThisDevice {
                Button(role: .destructive) {
                    pendingSessionSignOut = session
                } label: {
                    Label("Sign Out", systemImage: "xmark.circle")
                }
            }
        }
    }

    private func captionText(for session: AuthSession) -> String {
        let ip = session.ipAddress ?? String(localized: "Unknown IP")
        guard let updatedAt = session.updatedAt else { return ip }
        let date = Date(timeIntervalSince1970: Double(updatedAt) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return String(localized: "\(ip) \u{00B7} last active \(formatter.localizedString(for: date, relativeTo: Date()))",
                      comment: "Session caption. First %@ is the IP address, second is a relative time such as '2 hr. ago'.")
    }

    private func load() async {
        state = .loading
        do {
            let page = try await AudiobookshelfAPI.shared.getAuthSessions()
            sessions = page.sessions
            state = .loaded
        } catch APIError.notFound {
            state = .unsupported
        } catch {
            // Critique 2026-10-06 (clarify): plain copy instead of the raw error text.
            ShelfLog.error(.auth, "Couldn't load active sessions: \(error.localizedDescription)")
            state = .failed(Self.loadFailureMessage(for: error))
        }
    }

    private func signOut(_ session: AuthSession) async {
        do {
            try await AudiobookshelfAPI.shared.deleteAuthSession(id: session.id)
            sessions.removeAll { $0.id == session.id }
        } catch {
            // Critique 2026-10-06 (clarify): plain copy instead of the raw error text.
            ShelfLog.error(.auth, "Couldn't end a session: \(error.localizedDescription)")
            actionError = Self.endSessionFailureMessage(for: error)
        }
    }

    /// Critique 2026-10-06 (harden): ends every session for this account on this server,
    /// then signs this device out of this server only — Sign Out's semantics, not the full
    /// wipe it used to call (`logout()` removed every saved server). `AuthViewModel.signOut`
    /// flushes the current book's position *before* revoking the sessions; this used to
    /// revoke first, so the final position was sent with a dead token.
    private func signOutAllDevices() async {
        isSigningOutAll = true
        await authViewModel.signOut(scope: .everyDevice)
        isSigningOutAll = false
    }

    /// Critique 2026-10-06 (harden): what Sign Out All Devices does, from
    /// `AuthViewModel.signOut(scope: .everyDevice)`, with the unsynced-position warning
    /// Account & Security's Sign Out uses. Pure, pinned by `HardenCopyTests`.
    static func signOutAllMessage(plan: AuthViewModel.SignOutPlan, username: String,
                                  unsyncedPositions: Int, offlineWithBookLoaded: Bool) -> String {
        // Whole sentences per case (not fragments) so word order can differ per language.
        var text = username.isEmpty
            ? String(localized: "Ends every session for this account on \(plan.host), including this one. Other devices will need to sign in again.", comment: "Sign Out All Devices explanation. %@ is the server host.")
            : String(localized: "Ends every session for \u{201C}\(username)\u{201D} on \(plan.host), including this one. Other devices will need to sign in again.", comment: "Sign Out All Devices explanation. First %@ is the username, second is the server host.")
        if let next = plan.nextHost {
            text += " " + String(localized: "This device switches to \(next); downloads stay.", comment: "%@ is the host of the next saved server.")
        } else {
            text += " " + String(localized: "This device signs out of \(plan.host); downloads stay.", comment: "%@ is the server host.")
        }
        text += AccountSecuritySettingsView.unsyncedSentence(
            unsyncedPositions: unsyncedPositions, offlineWithBookLoaded: offlineWithBookLoaded,
            server: String(localized: "this server", comment: "Fallback noun phrase for the current server, used inside a sentence."))
        return text
    }

    /// Plain copy for a failed session list. Pure, pinned by `HardenCopyTests`.
    static func loadFailureMessage(for error: Error) -> String {
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(urlError.code) {
            return String(localized: "You\u{2019}re offline. Connect to the internet and try again.")
        }
        if let apiError = error as? APIError, case .unauthorized = apiError {
            return String(localized: "Your sign-in to this server has expired. Sign in again to see its sessions.")
        }
        return String(localized: "Your server didn\u{2019}t answer. Try again in a moment.")
    }

    /// Plain copy for a session that couldn't be ended. Pure, pinned by `HardenCopyTests`.
    static func endSessionFailureMessage(for error: Error) -> String {
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(urlError.code) {
            return String(localized: "You\u{2019}re offline, so that device is still signed in. Connect and try again.")
        }
        return String(localized: "Your server didn\u{2019}t end that session, so the device is still signed in. Try again in a moment.")
    }
}
