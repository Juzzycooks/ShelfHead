import SwiftUI

/// "Diagnostics" settings page — three links into read-only/repair screens. Split out
/// of `SettingsView` (UI-12, REVIEW_2026-08-12.md); the "Stay signed in" toggle that
/// used to live on this page moved to Account & Security some time ago, so this page is
/// just the navigation links.
struct DiagnosticsSettingsView: View {
    var bottomInset: CGFloat = 0
    /// Critique 2026-10-06 (clarify): the `SettingsRow` a search result opened, if any.
    var focusRow: String? = nil
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    /// Design review (14 Aug 2026), item 2 — "nothing tells the user whether their
    /// position is saved." `AudioPlayerService.shared.pendingProgressCount` is
    /// `@Observable`, so reading it here (rather than through `@Environment`) still
    /// keeps this row live — same reasoning as `ConnectivityBanner`'s call site.
    private var pendingCount: Int { AudioPlayerService.shared.pendingProgressCount }
    /// Bookmarks made with no usable connection, queued by `BookmarkSyncService`. Read the
    /// same way `pendingCount` above is, for the same `@Observable` reason. Its own row
    /// rather than folded into the positions count — a queued position is routine and
    /// self-correcting, a queued bookmark is something the user deliberately made and would
    /// want to know is still only on this device.
    private var pendingBookmarks: Int { BookmarkSyncService.shared.pendingCount }
    @State private var isSyncing = false
    /// Plain-words outcome of the last "Sync Now", shown under the row.
    @State private var syncResult: String?

    /// Critique 2026-10-06 (adapt): the sync row's status and its Sync Now button shared
    /// one line and crushed each other at AX5. At accessibility sizes they stack.
    private var syncRowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(HStackLayout())
    }

    var body: some View {
        SettingsAnchoredList(focusRow: focusRow) {
            Section {
                syncRowLayout {
                    settingRow("arrow.triangle.2.circlepath", pendingCount == 0
                        ? "All positions synced"
                        : (pendingCount == 1 ? "1 position waiting to sync" : "\(pendingCount) positions waiting to sync"))
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Button {
                        Haptics.selection()
                        isSyncing = true
                        syncResult = nil
                        // Critique 2026-10-06 (harden): was a fixed 1.5s "Sync requested".
                        // `awaitPendingWrites()` is the awaitable flush (it waits for the
                        // queue drain's real network writes), so the outcome is measured by
                        // comparing the queued counts before and after.
                        let positionsBefore = pendingCount
                        let bookmarksBefore = pendingBookmarks
                        Task {
                            await AudioPlayerService.shared.awaitPendingWrites()
                            await BookmarkSyncService.shared.flush()
                            // `pendingProgressCount` is republished by a trailing Task inside
                            // the flush; let it land before reading.
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            let result = SyncNowResult(
                                positionsBefore: positionsBefore, positionsAfter: pendingCount,
                                bookmarksBefore: bookmarksBefore, bookmarksAfter: pendingBookmarks)
                            syncResult = result.message
                            isSyncing = false
                            // Critique 2026-10-06 (polish): the outcome appears below the
                            // row, out of VoiceOver focus, so say it.
                            AccessibilityNotification.Announcement(result.message).post()
                        }
                    } label: {
                        if isSyncing {
                            HStack(spacing: 6) {
                                ProgressView().tint(Color.shelfAmberText)
                                Text("Syncing\u{2026}")
                            }
                        } else {
                            Text("Sync Now")
                        }
                    }
                    .disabled((pendingCount == 0 && pendingBookmarks == 0) || isSyncing)
                    .foregroundStyle(Color.shelfAmberText)
                    .frame(minHeight: 44)
                    // Its own tap target beside the status text in the same List row.
                    .buttonStyle(.borderless)
                    .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 36 : 0)
                }
                .settingsRowAnchor(SettingsRow.syncStatus)

                if let syncResult {
                    Typo.supporting(Text(syncResult))
                        .foregroundStyle(Color.shelfMuted)
                }

                if pendingBookmarks > 0 {
                    settingRow("bookmark", pendingBookmarks == 1
                        ? "1 bookmark waiting to sync"
                        : "\(pendingBookmarks) bookmarks waiting to sync")
                }

                NavigationLink(destination: ServerDiagnosticsView(bottomInset: bottomInset)) {
                    settingRow("stethoscope", "Server diagnostics")
                }
                .settingsRowAnchor(SettingsRow.serverDiagnostics)

                // Server backups moved to Account & Security, next to the server.

                NavigationLink(destination: DownloadHealthView(bottomInset: bottomInset)) {
                    settingRow("arrow.down.circle", "Download health")
                }
                .settingsRowAnchor(SettingsRow.downloadHealth)

                // Critique 2026-10-06 (distill): Recent Changes (an undo log of Mark
                // Finished / Reset, not a diagnostic) moved to the Settings root's
                // Listening group.
            } header: {
                RetroSectionHeader(title: "Diagnostics")
            }
            .listRowBackground(Color.shelfCard)
        }
        .background(Color.shelfBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomClearance) }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .reexpandsTabBarOnAppear()
    }
}

/// Critique 2026-10-06 (harden): pure outcome wording for Diagnostics > Sync Now, so the
/// copy is unit-testable. Derived from queued-item counts before and after the flush.
struct SyncNowResult: Equatable {
    let positionsBefore: Int
    let positionsAfter: Int
    let bookmarksBefore: Int
    let bookmarksAfter: Int

    var syncedCount: Int {
        max(positionsBefore - positionsAfter, 0) + max(bookmarksBefore - bookmarksAfter, 0)
    }
    var remainingCount: Int { positionsAfter + bookmarksAfter }

    var message: String {
        let before = positionsBefore + bookmarksBefore
        if before == 0 && remainingCount == 0 { return String(localized: "Nothing waiting to sync.") }
        if remainingCount == 0 {
            return syncedCount == 1
                ? String(localized: "Synced 1 item.")
                : String(localized: "Synced \(syncedCount) items.", comment: "Sync Now result. %lld is the number of items synced.")
        }
        // Whole sentences (not an assembled fragment) so word order can differ per language.
        if syncedCount > 0 {
            return remainingCount == 1
                ? String(localized: "Synced \(syncedCount) \u{2014} 1 still waiting.", comment: "Sync Now partial result. %lld is the number of items synced.")
                : String(localized: "Synced \(syncedCount) \u{2014} \(remainingCount) still waiting.", comment: "Sync Now partial result. First %lld is items synced, second is items still waiting.")
        }
        return remainingCount == 1
            ? String(localized: "Couldn\u{2019}t reach your server \u{2014} 1 still waiting.")
            : String(localized: "Couldn\u{2019}t reach your server \u{2014} \(remainingCount) still waiting.", comment: "Sync Now failure. %lld is the number of items still waiting.")
    }
}
