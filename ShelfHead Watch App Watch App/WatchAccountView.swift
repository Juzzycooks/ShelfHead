import SwiftUI

/// Screen — Account (Stage 2, standalone Watch app). Reached from `SettingsView`'s
/// new "Account" row. Shows this Watch's own on-device session state
/// (`WatchStore.authState`) and the two recovery actions the addendum's §2.1/§7.3
/// specify: re-handoff from a reachable iPhone, or manual sign-in. Always reachable
/// from Settings — not just from a fresh install or a dead-end — so the on-device
/// test plan's "reachable from the dead-end state" requirement holds regardless of
/// how the user got here.
struct WatchAccountView: View {
    @Environment(WatchStore.self) private var store
    @State private var isRequestingHandoff = false
    /// Critique 2026-10-06 (colorize/harden): the Watch had no way to sign itself out.
    @State private var showsSignOutConfirmation = false
    @State private var isSigningOut = false

    var body: some View {
        List {
            // Visual polish pass (31 August 2026), direct user request ("make the
            // app look nicer") — see `WatchSettingsView.connectionStatusRow`'s
            // identical comment on this same date: this is the most
            // safety-relevant content on this screen ("am I actually signed in"),
            // wrapped in `WatchCard` so it reads as a deliberate status panel
            // instead of a plain section row.
            Section {
                WatchCard {
                    VStack(alignment: .leading, spacing: 6) {
                        statusRow
                        if let message = store.authFailureMessage {
                            // Critique 2026-10-06 (colorize): an expired session gets the
                            // alert glyph; the sentence stays cream either way.
                            if store.authState == .sessionExpired {
                                WatchAlertNotice(text: .verbatim(message), font: WatchMetrics.secondaryFont())
                            } else {
                                Text(message)
                                    .font(WatchMetrics.secondaryFont())
                                    .foregroundStyle(WatchTheme.secondaryText)
                            }
                        }
                        // §9.1 item 3 — an informational heads-up, not an error: the
                        // sign-in itself succeeded, this just sets expectations about
                        // reconnecting later on an older server.
                        if let warning = store.noRefreshTokenWarning {
                            Text(warning)
                                .font(WatchMetrics.secondaryFont())
                                .foregroundStyle(WatchTheme.secondaryText)
                        }
                    }
                }
            }

            // Item 10 (10 September 2026): also offered while the session is *active*
            // but `.shared` — a borrowed access token from a phone that couldn't mint
            // this Watch a session of its own (SSO account, no stored password). That
            // token expires in about an hour and can't be renewed away from the phone,
            // so "top it up while my iPhone is right here, before I go out" is a real
            // thing to want and previously had no button at all: the user had to wait
            // for it to fail first. Every other kind of session (`.dedicated`,
            // `.durable`) renews itself or never expires, so nothing is offered there.
            // The `isReachable` half of the second clause keeps the existing
            // not-signed-in rendering byte-for-byte identical: with an active shared
            // session and no phone in range there is nothing to show, so the section
            // (and its "only manual sign-in is available" footer, which would read as
            // an error for a session that is working fine) doesn't appear at all.
            if store.authState != .active || (store.sessionKind == .shared && store.isReachable) {
                Section {
                    // Item 3 of Stage 2's build instructions: new screens read
                    // `WatchStore`, never `WatchConnectivityStore` directly — this
                    // reachability check is `store.isReachable`, which already
                    // forwards to `companion.isReachable` on the facade.
                    if store.isReachable {
                        Button {
                            Task {
                                isRequestingHandoff = true
                                _ = await store.requestHandoffFromPhone()
                                isRequestingHandoff = false
                            }
                        } label: {
                            HStack {
                                // LS-13 (docs/design-review.md, Round 3): the handoff
                                // row used to show only the "Connecting…" text with no
                                // spinner — swap the leading icon for one in place,
                                // keeping the same column width so the row doesn't
                                // reflow.
                                if isRequestingHandoff {
                                    ProgressView()
                                        .tint(WatchTheme.accent)
                                        .watchIconColumn()
                                } else {
                                    Image(systemName: "iphone.and.arrow.forward")
                                        .watchIconColumn()
                                }
                                // Critique 2026-10-06 (onboard): said "Reconnect" on a
                                // Watch that had never been connected.
                                if isRequestingHandoff {
                                    Text("Connecting…")
                                } else {
                                    Text(WatchAccountCopy.handoffTitle(hasNoSession: store.authState == .noSession))
                                }
                            }
                        }
                        .disabled(isRequestingHandoff)
                    }
                } footer: {
                    if !store.isReachable {
                        Text("Your iPhone isn\u{2019}t nearby, so only manual sign-in is available right now.")
                    } else if store.authState == .noSession {
                        // Critique 2026-10-06 (onboard): what setting up is for.
                        Text("Uses your iPhone\u{2019}s sign-in, so this Watch can play downloads on a run without it.")
                    }
                }
            }

            // User-requested (29 August 2026): manual username/password sign-in used
            // to only be reachable while `authState != .active` — so once the Watch
            // believed it already had a working session (even one established via a
            // flaky handoff), there was no way to just sign in directly with
            // credentials instead of troubleshooting the handoff/token path. Always
            // showing this row, regardless of `authState`, means a real login is
            // always one tap away as a deliberate bypass of the whole handoff
            // mechanism — `WatchStore.loginManually()` doesn't guard on the current
            // state, so calling it while already "active" just replaces the session
            // with a freshly-issued one, same as it does from the not-signed-in case.
            Section {
                NavigationLink {
                    WatchManualSignInView()
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.key")
                            .watchIconColumn()
                        Text(store.authState == .active ? "Sign In with a Different Account" : "Sign In Manually")
                    }
                }
            } footer: {
                if store.authState == .active {
                    Text("Sign in directly with your username and password instead of relying on your iPhone.")
                }
            }

            if store.authState == .active && store.serverSupportsAuthSessions != false {
                // §9.1 items 1–2: hidden outright (not shown-then-erroring) when the
                // capability probe comes back a definitive `false` — `GET
                // /api/me/sessions` requires Audiobookshelf 2.36.0+, and every row on
                // this screen would otherwise 404. `!= false` rather than `== true`
                // is deliberate: `nil` (not yet probed, or the one probe attempt
                // failed for an unrelated reason) shows the row, matching
                // `probeSessionsAPISupported()`'s own doc comment on why an
                // inconclusive probe shouldn't hide a screen that might genuinely work.
                Section {
                    NavigationLink {
                        WatchAuthSessionsView()
                    } label: {
                        WatchRow(systemImage: "list.bullet.rectangle", title: "Manage Sessions",
                                 subtitle: "View and revoke logins")
                    }
                }
            }

            // Critique 2026-10-06 (harden): Sign Out on the Watch itself. Reuses the
            // phone-initiated sign-out path (`WatchStore.wipeCredentials()`), which stops
            // playback and writes the place out while the token still works, closes this
            // Watch's own server session, and clears queued positions and bookmarks for
            // the account. Downloads stay. Confirmed: uncommon, and it can't be undone
            // from the wrist without signing in again (HIG, Alerts).
            if store.authState == .active || store.authState == .sessionExpired {
                Section {
                    Button(role: .destructive) {
                        showsSignOutConfirmation = true
                    } label: {
                        HStack {
                            if isSigningOut {
                                ProgressView().tint(WatchTheme.accent).watchIconColumn()
                            } else {
                                Image(systemName: "rectangle.portrait.and.arrow.right").watchIconColumn()
                            }
                            Text(isSigningOut ? "Signing Out\u{2026}" : "Sign Out of This Watch")
                        }
                    }
                    .disabled(isSigningOut)
                } footer: {
                    Text("Your iPhone stays signed in. Downloads stay on this Watch.")
                }
            }
        }
        .confirmationDialog("Sign Out of This Watch?", isPresented: $showsSignOutConfirmation, titleVisibility: .visible) {
            // Not styled destructive: the person chose Sign Out deliberately (HIG, Alerts).
            Button("Sign Out") {
                Task {
                    isSigningOut = true
                    await store.wipeCredentials()
                    isSigningOut = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything playing on this Watch stops, and your place is saved first.")
        }
        // Batch 490 (REVIEW 2026-11-11 W14): default list style; the No-Carousel Rule
        // (DESIGN.md) missed this screen in Batch 412.
        .navigationTitle("Account")
        .task { await store.bootstrapAuth() }
    }

    private var statusRow: some View {
        let (icon, title, tint): (String, LocalizedStringResource, Color) = {
            switch store.authState {
            case .checking:
                return ("hourglass", "Checking…", WatchTheme.secondaryText)
            case .noSession:
                return ("person.crop.circle.badge.questionmark", "Not Signed In", WatchTheme.secondaryText)
            case .active:
                // Critique 2026-10-06 (colorize): neutral — signed in is the normal state.
                return ("checkmark.circle.fill", "Signed In", WatchTheme.icon)
            case .sessionExpired:
                return ("exclamationmark.triangle.fill", "Session Expired", WatchTheme.danger)
            }
        }()
        return WatchRow(systemImage: icon, title: title, tintColor: tint)
    }
}

#Preview {
    NavigationStack { WatchAccountView() }
        .environment(WatchStore.shared)
}
