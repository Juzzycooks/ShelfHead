import SwiftUI

/// Screen 9 — Settings. Play On (Critique 2026-10-06) is the one choice here; Playback Speed and Skip
/// Duration mirror the phone's current values in companion mode and show this Watch's
/// own in standalone (Critique 2026-10-06). These are shown as plain informational
/// rows, not navigation links — Connection Status is the one genuinely Watch-specific,
/// safety-relevant piece — it's how a user tells "is what I'm seeing actually current."
///
/// WATCH-3 (follow-up review, 14 Aug 2026): this used to also show an "Audio Quality"
/// row hardcoded to "Higher" — ShelfHead has no audio-quality/bitrate setting anywhere
/// in the app (phone or Watch) for that row to have ever actually mirrored, so it was
/// pure fiction rather than a stale-but-real value like the old "15 Seconds" skip
/// duration (WATCH-5, below) was. Removed rather than wired up, since there's no real
/// setting behind it to wire up. "Theme" was also hardcoded to "System," which is
/// actively wrong, not just unconfigurable: `ShelfHeadWatchApp.swift` forces
/// `.preferredColorScheme(.dark)` unconditionally, so the Watch app never actually
/// follows the system appearance. Changed the label to describe what the app really
/// does instead of a setting it doesn't have.
///
/// WATCH-6 (REVIEW_2026-08-12.md): these four rows used to each push a
/// placeholder screen explaining the setting isn't available here — a pattern
/// Apple reviewers specifically flag under Guideline 2.1 ("incomplete watchOS
/// functionality") when a watch app is mostly "open this on iPhone" dead ends. Since
/// there's nothing to actually wire up for a static-review-only pass with no Watch
/// hardware/simulator to verify a real settings UI against, the fix taken here is the
/// review's other suggested option: remove the dead-end navigation, not the
/// information itself — each row still shows its current value/status inline, it just
/// no longer taps through to a page whose only content is "not available."
struct SettingsView: View {
    // Stage 2 prototype (WATCH_STANDALONE_PROPOSAL_2026-08-28-ADDENDUM.md §8.1):
    // first of the thirteen WatchConnectivityStore-dependent files re-pointed at the
    // concrete `WatchStore` facade instead — chosen because this screen is read-only
    // and touches the smallest slice of the store surface (`playbackState`,
    // `isReachable`, `isStateStale`), making it the cheapest real-screen proof that a
    // concrete `@Observable` facade class (rather than a protocol existential) keeps
    // SwiftUI's view invalidation working correctly. See `WatchStore`'s own doc
    // comment for why the concrete-class shape was chosen over an existential.
    @Environment(WatchStore.self) private var store

    var body: some View {
        List {
            // Critique 2026-10-06 (shape → harden): the "Play On" choice (was Settings >
            // Diagnostics > Troubleshooting > Watch Mode, with "Companion/Standalone"
            // labels). It's a real product choice now that the Watch is a player for runs:
            // Automatic, This Watch, or iPhone. Tinted only when moved off Automatic.
            Section {
                NavigationLink {
                    WatchModeSettingsView()
                } label: {
                    WatchRow(
                        systemImage: playOnSystemImage,
                        title: "Play On",
                        subtitle: .verbatim(store.modePreference.title))
                }
            } footer: {
                Text("Downloaded books always offer Play on Watch.")
            }

            // Stage 2 (standalone Watch app): new section, one row, pushing
            // `WatchAccountView`. Always present regardless of `store.authState` —
            // reachable from a fresh install (no session yet) just as much as from
            // an already-active one, per the on-device test plan's explicit
            // "reachable ... rather than only from a fresh install" requirement.
            Section("Account") {
                NavigationLink {
                    WatchAccountView()
                } label: {
                    WatchRow(
                        systemImage: accountSystemImage,
                        title: "Account",
                        subtitle: accountSubtitle,
                        tintColor: store.authState == .sessionExpired ? WatchTheme.danger : nil)
                }
            }

            // Batch 411 (Watch redesign): Downloads left the root with the tiles. The user's
            // decision: it lives here and in Library, not on the Shelf, where downloaded
            // books already appear as sleeves.
            Section {
                NavigationLink {
                    StandaloneDownloadsView()
                } label: {
                    WatchRow(
                        systemImage: "arrow.down.circle.fill",
                        title: "Downloads",
                        subtitle: downloadsSubtitle)
                }

                // Batch 490 (REVIEW 2026-11-11 F29): how much ShelfHead may keep on this Watch.
                NavigationLink {
                    WatchStorageLimitView()
                } label: {
                    WatchRow(
                        systemImage: "internaldrive",
                        title: "Storage Limit",
                        subtitle: .verbatim(store.localDownloads.storageLimit.label))
                }

                // Batch 490 (REVIEW 2026-11-11 W12): off by default, so a Watch with cellular
                // keeps downloading away from Wi-Fi as it does today. Applies per request
                // (`URLRequest.allowsCellularAccess`): the background session's own
                // configuration can't change after it is made.
                Toggle(isOn: Binding(get: { store.localDownloads.wifiOnly },
                                     set: { store.localDownloads.setWiFiOnly($0) })) {
                    Text("Wi\u{2011}Fi Only")
                        .font(WatchMetrics.contentRowTitleFont(weight: .medium))
                        .foregroundStyle(WatchTheme.primaryText)
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Wi\u{2011}Fi Only applies to downloads you start after turning it on.")
            }

            // Critique 2026-10-06 (colorize/harden): these rows only show values, so they
            // no longer sit on tappable-looking platters (clear row background) and the
            // footer says where each one is changed. "Theme: Always Dark" is gone: it
            // described the only option there is.
            Section {
                WatchRow(
                    systemImage: "speedometer",
                    title: "Playback Speed",
                    subtitle: .verbatim(speedSubtitle))
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)

                // WATCH-5 (REVIEW_2026-08-12.md): this used to be a literal
                // "15 Seconds" regardless of what was actually configured on iPhone,
                // directly contradicting this screen's own header comment claiming it
                // mirrors the phone. Now reads the real synced values
                // (`WatchPlaybackState.skipBackwardInterval`/`skipForwardInterval`,
                // pushed by `WatchSessionManager`) — shown as a single "15s" when both
                // directions match (the common case), or "back 15s / fwd 30s" when the
                // user has configured them differently on iPhone.
                WatchRow(systemImage: "timer", title: "Skip Duration", subtitle: .verbatim(skipDurationSubtitle))
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
            } header: {
                Text("Playback")
            } footer: {
                Text(store.mode == .standalone
                     // Batch 495 (W7): skip times follow the iPhone; speed is per book.
                     ? "Skip times follow your iPhone. Speed changes from Now Playing and is kept for each book."
                     : "Set on your iPhone. Speed also changes from Now Playing.")
            }

            Section("Connection") {
                connectionStatusRows
                // Polish pass (WA-4): whether this Watch's own listening has reached the server.
                if store.authState == .active {
                    progressSyncRow
                }
            }

            // Diagnostics is a readout again (connection, session, what's playing where);
            // the Play On choice moved up to the top of this screen (Critique 2026-10-06).
            Section {
                NavigationLink {
                    WatchDiagnosticsView()
                } label: {
                    WatchRow(
                        systemImage: "stethoscope",
                        title: "Diagnostics",
                        subtitle: "Connection and sign-in")
                }
            }
        }
        // Batch 412 (Watch redesign): default grouped list (was `.carousel`).
        .navigationTitle("Settings")
        .task { await store.progressSync.refreshPendingCount() }
    }

    private var downloadsSubtitle: LocalizedStringResource? {
        let count = store.localDownloads.downloads.count
        return count > 0 ? "\(count) on Watch" : nil
    }

    private var playOnSystemImage: String {
        switch store.modePreference {
        case .automatic: return "arrow.triangle.2.circlepath"
        case .alwaysCompanion: return "iphone"
        case .alwaysStandalone: return "applewatch"
        }
    }

    private var accountSystemImage: String {
        switch store.authState {
        case .checking: return "person.crop.circle"
        case .noSession: return "person.crop.circle.badge.questionmark"
        case .active: return "person.crop.circle.fill.badge.checkmark"
        case .sessionExpired: return "person.crop.circle.badge.exclamationmark"
        }
    }

    private var accountSubtitle: LocalizedStringResource {
        switch store.authState {
        case .checking: return "Checking…"
        case .noSession: return "Not signed in"
        case .active: return "Signed in"
        case .sessionExpired: return "Session expired — tap to reconnect"
        }
    }

    /// Critique 2026-10-06 (clarify): this Watch's own speed in standalone mode (what
    /// its player uses, `StandaloneAudioEngine.playbackRate`), the iPhone's in companion.
    private var speedSubtitle: String {
        if store.mode == .standalone {
            return WatchSpeedCycler.label(for: store.standalone.playbackRate)
        }
        return store.playbackState.map { WatchSpeedCycler.label(for: $0.playbackRate) } ?? "—"
    }

    /// WATCH-5: "—" only if no snapshot has ever arrived (fresh install) — the fields
    /// themselves default to the phone's own real defaults (15/30) once a
    /// `WatchPlaybackState` exists at all, even an idle one, so this reads real values
    /// far more often than not.
    private var skipDurationSubtitle: String {
        // Critique 2026-10-06 (clarify): standalone used to show the iPhone's values,
        // which aren't what this Watch's own player uses.
        if store.mode == .standalone {
            // Batch 495 (REVIEW 2026-11-11 W7): the engine now uses the iPhone's intervals.
            let back = Int(store.standalone.skipBackwardInterval), fwd = Int(store.standalone.skipForwardInterval)
            return back == fwd
                ? String(localized: "\(back)s", comment: "Skip interval in seconds, like 15s")
                : String(localized: "back \(back)s / fwd \(fwd)s", comment: "Skip intervals differ: %1$lld seconds back, %2$lld seconds forward")
        }
        guard let state = store.playbackState else { return "—" }
        let back = Int(state.skipBackwardInterval), fwd = Int(state.skipForwardInterval)
        return back == fwd
                ? String(localized: "\(back)s", comment: "Skip interval in seconds, like 15s")
                : String(localized: "back \(back)s / fwd \(fwd)s", comment: "Skip intervals differ: %1$lld seconds back, %2$lld seconds forward")
    }

    /// Polish pass (WA-4): "All progress synced" or "2 updates waiting to sync". The dot turns to the
    /// alert colour only when the last attempt failed with something still waiting.
    @ViewBuilder
    private var progressSyncRow: some View {
        let sync = store.progressSync
        HStack(spacing: 8) {
            Circle()
                .fill(sync.pendingCount > 0 && sync.lastFlushFailed ? WatchTheme.alert : WatchTheme.icon)
                .frame(width: 10, height: 10)
            Text(WatchProgressSyncCoordinator.statusText(pendingCount: sync.pendingCount))
                .font(WatchMetrics.secondaryFont())
                .foregroundStyle(WatchTheme.secondaryText)
        }
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    // Batch 412 (Watch redesign): was a `WatchCard` inside a list row (card-in-card). Now two
    // plain read-only rows, each a status dot and a line of text.
    @ViewBuilder
    private var connectionStatusRows: some View {
        HStack(spacing: 8) {
            Circle()
                // Critique 2026-10-06 (colorize): neutral when fine (was green).
                .fill(store.isReachable ? WatchTheme.icon : WatchTheme.secondaryText)
                .frame(width: 10, height: 10)
            Text(store.isReachable ? "Connected to iPhone" : "iPhone Unreachable")
                .font(WatchMetrics.secondaryFont(weight: .medium))
                .foregroundStyle(WatchTheme.primaryText)
        }
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        HStack(spacing: 8) {
            Circle()
                .fill(store.isStateStale ? WatchTheme.alert : WatchTheme.icon)
                .frame(width: 10, height: 10)
            Text(store.isStateStale ? "Playback state may be out of date" : "Playback state is fresh")
                .font(WatchMetrics.secondaryFont())
                .foregroundStyle(WatchTheme.secondaryText)
        }
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }
}

/// Batch 490 (REVIEW 2026-11-11 F29): Settings › Downloads › Storage Limit. The cap on
/// this Watch is the smaller of this and half the free space (`WatchDownloadCap`).
/// Lowering it removes nothing straight away; the next download makes room as usual.
/// Same checkmark-row shape as `WatchModeSettingsView`.
struct WatchStorageLimitView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        List {
            Section {
                ForEach(WatchDownloadStorageLimit.allCases) { limit in
                    limitRow(limit)
                }
            } footer: {
                Text("ShelfHead never uses more than half of the Watch\u{2019}s free space, whatever this says.")
            }
        }
        .navigationTitle("Storage Limit")
    }

    private func limitRow(_ limit: WatchDownloadStorageLimit) -> some View {
        let isSelected = store.localDownloads.storageLimit == limit
        return Button {
            store.localDownloads.setStorageLimit(limit)
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: limit.label)
                    .font(WatchMetrics.contentRowTitleFont(weight: .medium))
                    .foregroundStyle(WatchTheme.primaryText)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(WatchMetrics.secondaryFont(weight: .semibold))
                        .foregroundStyle(WatchTheme.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .padding(.vertical, WatchMetrics.rowVerticalPadding)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(WatchStore.shared)
}
