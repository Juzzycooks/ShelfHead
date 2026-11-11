import SwiftUI

/// Session-revocation UI (Stage 2, addendum §3/§7.2) — lists this account's active
/// *login* sessions (`GET /api/me/sessions`) and lets the user revoke one
/// (`DELETE /api/me/sessions/:id`). This is the control that makes handing this
/// Watch a refresh token defensible at all per §3's threat model: an old pairing, a
/// lost Watch, or just cleaning up is now something the user can act on themselves,
/// not something that requires a password change to fix.
///
/// Distinct from, and has nothing to do with, the phone app's "Recent Sessions"
/// listening-history card (`AudiobookshelfAPI.getListeningSessions()` /
/// `/api/me/listening-sessions`) — see `WatchAudiobookshelfAPI.getAuthSessions()`'s
/// own doc comment for why the naming here is deliberately kept clear of that.
struct WatchAuthSessionsView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [WatchAuthSession] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var revokingId: String?
    @State private var pendingRevoke: WatchAuthSession?

    var body: some View {
        List {
            if isLoading {
                // LS-13 (docs/design-review.md, Round 3): brand-tinted, was falling
                // back to the system tint.
                ProgressView().tint(WatchTheme.accent)
            } else if let errorMessage {
                // Critique 2026-10-06 (colorize): alert glyph, cream sentence.
                WatchAlertNotice(text: .verbatim(errorMessage), font: WatchMetrics.secondaryFont())
            } else if sessions.isEmpty {
                Text("No active sessions.")
                    .font(WatchMetrics.contentRowTitleFont())
                    .foregroundStyle(WatchTheme.secondaryText)
            } else {
                ForEach(sessions) { session in
                    sessionRow(session)
                }
            }
        }
        // Real on-device bug fix (29 August 2026): reverted `.listStyle(.carousel)`
        // (added in the Batch 264 UI polish pass) on this screen specifically —
        // found proactively while fixing the identical, user-reported conflict on
        // `StandaloneLibraryView.swift`/`StandaloneDownloadsView.swift`. This
        // screen's own `.swipeActions` "Revoke" action (below) is the only way to
        // revoke a session here, and `.carousel`'s gesture competes with the
        // swipe-to-reveal gesture `.swipeActions` needs. (The forced black bar background was removed in V5 / PS-2.)
        .navigationTitle("Sessions")
        // Critique 2026-10-06 (harden): revoke ran straight from the swipe button, and the
        // row for this watch gave no hint it would sign the watch out.
        .confirmationDialog(
            "Revoke this session?",
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke Session", role: .destructive) {
                if let session = pendingRevoke { Task { await revoke(session) } }
                pendingRevoke = nil
            }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        } message: {
            if pendingRevoke?.current == true {
                Text("This is this Watch\u{2019}s session. Revoking it signs this Watch out.")
            }
        }
        .task { await load() }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func sessionRow(_ session: WatchAuthSession) -> some View {
        VStack(alignment: .leading, spacing: WatchMetrics.titleSubtitleSpacing) {
            HStack {
                // Batch 490 (REVIEW 2026-11-11 W14): a readable name from the User-Agent
                // (the iPhone's Sessions rule), two lines, not the raw string cut to one.
                Text(WatchSessionLabel.deviceName(userAgent: session.userAgent) ?? String(localized: "Unknown device"))
                    .font(WatchMetrics.contentRowTitleFont(weight: .medium))
                    .foregroundStyle(WatchTheme.primaryText)
                    .lineLimit(2)
                if session.current {
                    // Critique 2026-10-06 (colorize): neutral — green isn't in the palette
                    // and "this device" isn't a success.
                    Text("This device")
                        .font(WatchMetrics.captionFont(weight: .semibold))
                        .foregroundStyle(WatchTheme.icon)
                }
            }
            if let ip = session.ipAddress, !ip.isEmpty {
                Text(ip)
                    .font(WatchMetrics.subtitleFont())
                    .foregroundStyle(WatchTheme.secondaryText)
            }
            // Batch 490 (REVIEW 2026-11-11 W14): when it was last used, like the iPhone.
            if let lastUsed = WatchSessionLabel.lastUsedDate(updatedAtMs: session.updatedAt, createdAtMs: session.createdAt) {
                Text("Last active \(Self.relativeFormatter.localizedString(for: lastUsed, relativeTo: Date()))")
                    .font(WatchMetrics.captionFont())
                    .foregroundStyle(WatchTheme.secondaryText)
            }
        }
        .swipeActions(allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingRevoke = session
            } label: {
                if revokingId == session.id {
                    // LS-13 (docs/design-review.md, Round 3): brand-tinted, was
                    // falling back to the system tint. This sits on the system's
                    // red destructive swipe-action background, not an accent fill,
                    // so the brand tint stays readable here.
                    ProgressView().tint(WatchTheme.accent)
                } else {
                    Label("Revoke", systemImage: "xmark.circle")
                }
            }
            .disabled(revokingId != nil)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            sessions = try await store.getAuthSessions()
        } catch WatchAPIError.sessionExpired {
            // `store.getAuthSessions()` already called `signalSessionExpired()`
            // before rethrowing — `WatchAccountView` (this screen's parent) will
            // reactively show the dead-end recovery UI the moment `authState`
            // changes. Popping back to it now, rather than leaving this now-useless
            // list on screen, is what makes that dead-end state actually reachable
            // from here instead of only in theory.
            dismiss()
        } catch {
            errorMessage = String(localized: "Couldn't load sessions. Check your connection and try again.")
        }
        isLoading = false
    }

    private func revoke(_ session: WatchAuthSession) async {
        revokingId = session.id
        do {
            try await store.revokeAuthSession(id: session.id)
            sessions.removeAll { $0.id == session.id }
        } catch WatchAPIError.sessionExpired {
            dismiss()
        } catch {
            errorMessage = String(localized: "Couldn't revoke that session. Try again.")
        }
        revokingId = nil
    }
}

#Preview {
    NavigationStack { WatchAuthSessionsView() }
        .environment(WatchStore.shared)
}

/// Batch 490 (REVIEW 2026-11-11 W14): the Sessions row's wording, pure so it is pinned
/// by tests (`QuickWinsWatchLibraryTests`). `deviceName` mirrors the iPhone's
/// `AuthSession.displayName` User-Agent fallback: everything before the first "(" or
/// "/", trimmed ("ShelfHead/7.5 CFNetwork/…" → "ShelfHead"). The Watch doesn't decode
/// `deviceInfo`, so the iPhone's client-name and vendor/model steps don't apply here.
nonisolated enum WatchSessionLabel {
    /// nil when there is nothing readable; the row says "Unknown device".
    static func deviceName(userAgent: String?) -> String? {
        guard let userAgent, !userAgent.isEmpty else { return nil }
        let cutoff = userAgent.firstIndex(where: { $0 == "(" || $0 == "/" }) ?? userAgent.endIndex
        let prefix = userAgent[userAgent.startIndex..<cutoff].trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? nil : prefix
    }

    /// The last time the session was used (`updatedAt`, else `createdAt`; epoch ms).
    static func lastUsedDate(updatedAtMs: Int64?, createdAtMs: Int64?) -> Date? {
        guard let ms = updatedAtMs ?? createdAtMs, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
