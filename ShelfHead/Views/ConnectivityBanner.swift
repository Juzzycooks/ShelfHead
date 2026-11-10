import SwiftUI

// MARK: - Pure decision (Critique 2026-10-06, clarify + harden)

/// How loud the connectivity banner is. Critique 2026-10-06 (user decision): when offline or
/// the server is unreachable but a download is playing fine, the banner is a QUIET status
/// pill (neutral surface, small orange glyph, cream text). Solid `shelfOrange` is kept only
/// when listening or the user's position is at risk.
enum ConnectivityBannerStyle: Equatable {
    case quiet
    case alarm
}

enum ConnectivityBannerAction: Equatable {
    /// Re-runs the reachability check (`ReachabilityStore.checkNow()`).
    case retry
}

struct ConnectivityBannerState: Equatable {
    let style: ConnectivityBannerStyle
    let message: String
    let action: ConnectivityBannerAction?
}

/// The one place the offline / unreachable wording lives, shared by `ConnectivityBanner` and
/// Driving Mode's `PlayerView.drivingStatusLine` (they used to duplicate it by hand).
enum ConnectivityCopy {
    /// `nil` when everything is fine. "using your download" is true whether the book is
    /// playing or paused, so it never says "playing".
    static func message(for status: ReachabilityStore.Status, usingDownload: Bool) -> String? {
        switch status {
        case .ok: return nil
        case .offline:
            return usingDownload ? String(localized: "Offline \u{00B7} using your download", comment: "Connectivity banner: device has no network but the playing book is downloaded")
                : String(localized: "You're offline", comment: "Connectivity banner: device has no network")
        case .serverUnreachable:
            return usingDownload ? String(localized: "Can't reach your server \u{00B7} using your download", comment: "Connectivity banner: server unreachable but the playing book is downloaded")
                : String(localized: "Can't reach your server", comment: "Connectivity banner: server unreachable")
        }
    }

    /// Decision function: banner style + message + action for the current situation; `nil`
    /// when there is nothing to show.
    /// - hasBook / isLocal: a book is loaded and it plays from a download.
    /// - isPlaying: only matters for a streamed book — playing it is at risk now, a paused
    ///   one is only a heads-up until the user presses play.
    static func bannerState(status: ReachabilityStore.Status, hasBook: Bool, isLocal: Bool,
                            isPlaying: Bool, pendingCount: Int) -> ConnectivityBannerState? {
        guard status != .ok else { return nil }
        let usingDownload = hasBook && isLocal
        let action: ConnectivityBannerAction? = status == .serverUnreachable ? .retry : nil
        // Critique 2026-10-06 (colorize + clarify): the old 10+ queued "alarm" is gone. A queued
        // position is persisted on this phone (PRODUCT principle 2), so it is not at risk and
        // not an alarm; the alarm stays for listening that is at risk now (streaming, or
        // nothing local to play). The count is shown once, by the pending pill.
        let message = message(for: status, usingDownload: usingDownload) ?? ""
        let style: ConnectivityBannerStyle
        if usingDownload {
            style = .quiet
        } else if hasBook {
            style = isPlaying ? .alarm : .quiet
        } else {
            style = .alarm // nothing local to play
        }
        return ConnectivityBannerState(style: style, message: message, action: action)
    }

    /// The pending pill's line. Critique 2026-10-06 (clarify): "listening positions" rather
    /// than the internal word "positions".
    static func pendingMessage(count: Int) -> String {
        count == 1 ? String(localized: "1 listening position waiting to sync", comment: "Pending sync pill, singular")
            : String(localized: "\(count) listening positions waiting to sync", comment: "Pending sync pill; %lld is the number of queued positions (2 or more)")
    }

    /// Polish pass (DL-7): offline with downloads on the device, the way to the downloads
    /// list is one tap from the banner (`shelfhead://downloads`, the same link widgets and
    /// Shortcuts use). Not shown for an unreachable server (that pill already carries Retry)
    /// or when there is nothing downloaded to go to.
    static func showsDownloadsLink(status: ReachabilityStore.Status, hasDownloads: Bool) -> Bool {
        status == .offline && hasDownloads
    }

    /// "Sync now" can only fail while the device is offline, so it is hidden then; the queue
    /// flushes by itself when the connection returns.
    static func showsSyncNow(status: ReachabilityStore.Status) -> Bool {
        status != .offline
    }

    /// Whether the "N positions waiting to sync" pill shows. Dismissing records the count at
    /// that moment; the pill returns only if the count grows past it.
    static func pendingPillVisible(count: Int, dismissedAt: Int?) -> Bool {
        guard count > 0 else { return false }
        guard let dismissedAt else { return true }
        return count > dismissedAt
    }

    /// The brief result line after "Sync now".
    static func syncOutcomeMessage(before: Int, after: Int) -> String {
        if after <= 0 { return String(localized: "All synced", comment: "Result line after Sync now succeeded") }
        if after < before { return String(localized: "\(after) still waiting to sync", comment: "Result line after Sync now; %lld is the number of positions still queued") }
        return String(localized: "Couldn't sync \u{00B7} will keep trying", comment: "Result line after Sync now failed")
    }
}

/// Critique 2026-10-06 (harden): the connectivity status as the UI should show it, debounced
/// once and shared. Follows `ReachabilityStore.status` immediately for `.offline` / `.ok`,
/// but adopts `.serverUnreachable` only if the store is still unreachable 1.5 s later (AN-4),
/// so one failed ping flashes neither the banner nor Driving Mode. `ContentView` drives
/// `follow(_:)` from a `.task(id:)`; Driving Mode only reads `status`.
@MainActor @Observable
final class DisplayedReachability {
    static let shared = DisplayedReachability()
    private(set) var status: ReachabilityStore.Status = .ok
    private init() {}

    func follow(_ store: ReachabilityStore) async {
        guard store.status == .serverUnreachable else {
            status = store.status
            return
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled, store.status == .serverUnreachable else { return }
        status = .serverUnreachable
    }
}

/// A persistent, dismissible banner distinguishing "you're offline" from "your server
/// is down" (F10) — unlike `ToastModifier` (Extensions.swift), which auto-dismisses on
/// a timer, this stays up for as long as the condition holds (or until the user
/// dismisses it), since a connectivity problem isn't a one-off event to flash and
/// forget.
struct ConnectivityBanner: View {
    let status: ReachabilityStore.Status
    /// Design review (14 Aug 2026), item 2 — "nothing tells the user whether their
    /// position is saved." `ContentView` passes the live
    /// `AudioPlayerService.shared.pendingProgressCount`.
    var pendingSyncCount: Int = 0
    /// Critique 2026-10-06 (harden): the playback situation the quiet-vs-alarm decision
    /// (`ConnectivityCopy.bannerState`) needs.
    var hasBook: Bool = false
    var isLocal: Bool = false
    var isPlaying: Bool = false

    private struct DismissKey: Equatable {
        let status: ReachabilityStore.Status
        let style: ConnectivityBannerStyle
    }
    // Keyed by status AND style so a dismissed quiet pill comes back if the situation
    // escalates to the alarm (e.g. the user presses play on a streamed book).
    @State private var dismissedKey: DismissKey?
    /// Critique 2026-10-06 (harden): the pending-sync pill is dismissible for the session
    /// (chosen over auto-collapse: it keeps one rule, "you closed it, it stays closed until
    /// there is more to sync"). Holds the queued count at dismissal; the pill returns only
    /// if the count grows. Dismissing empties the banner stack, so the tabs' top inset
    /// (`connectivityBannerHeight`) drops back to 0.
    @State private var pendingDismissedAt: Int?
    @State private var isSyncing = false
    @State private var syncOutcome: String?
    @State private var isRetrying = false
    // Polish pass (DL-7): routes through `ContentView.handleDeepLink`, so App Lock still gates it.
    @Environment(\.openURL) private var openURL
    @State private var downloadManager = DownloadManager.shared
    // AX-11: Dynamic Type-scaled glyph sizes.
    @ScaledMetric(relativeTo: .footnote) private var warningIconSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var pendingSyncIconSize: CGFloat = 11

    private var state: ConnectivityBannerState? {
        ConnectivityCopy.bannerState(status: status, hasBook: hasBook, isLocal: isLocal,
                                     isPlaying: isPlaying, pendingCount: pendingSyncCount)
    }

    private var showsConnectivityPill: Bool {
        guard let state else { return false }
        return DismissKey(status: status, style: state.style) != dismissedKey
    }

    private var showsPendingPill: Bool {
        ConnectivityCopy.pendingPillVisible(count: pendingSyncCount, dismissedAt: pendingDismissedAt)
            || syncOutcome != nil || isSyncing
    }

    private var isShowingAnything: Bool { showsConnectivityPill || showsPendingPill }

    var body: some View {
        VStack(spacing: 6) {
            connectivityWarning
            pendingSyncLine
        }
        // Critique 2026-10-06 (harden): the tabs get a top inset the height of this stack, and
        // scroll content could show in the gap around the capsule above the nav bar. A
        // solid page-colour band behind the stack (extended up under the status bar) covers
        // it; nothing is drawn while the stack is empty.
        .background(alignment: .top) {
            if isShowingAnything {
                Color.shelfBackground.ignoresSafeArea(edges: .top)
            }
        }
        .onChange(of: pendingSyncCount) { _, new in
            if new == 0 { pendingDismissedAt = nil }
        }
    }

    @ViewBuilder private var connectivityWarning: some View {
        Group {
            if let state, showsConnectivityPill {
                let isAlarm = state.style == .alarm
                // Alarm: solid orange with ink. Quiet: neutral surface, cream text, a small
                // orange glyph only (DESIGN.md orange rule).
                let ink: Color = isAlarm ? Color.shelfOrangeInk : Color.shelfCream
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: status == .offline ? "wifi.slash" : "exclamationmark.triangle.fill")
                        .font(.system(size: warningIconSize, weight: .semibold))
                        .foregroundStyle(isAlarm ? Color.shelfOrangeInk : Color.shelfOrange)
                        .accessibilityHidden(true)
                    // AX-11: scales with Dynamic Type; no line limit so it wraps.
                    Typo.metadata(Text(state.message))
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if state.action == .retry {
                        Button {
                            retry()
                        } label: {
                            // Critique 2026-10-06 (polish): on the quiet pill, amber text like
                            // the sync pill's "Sync now"; on the alarm fill amber can't show,
                            // so the ink is underlined to read as an action.
                            Typo.metadata(Text(isRetrying ? LocalizedStringKey("Checking\u{2026}") : LocalizedStringKey("Retry")))
                                .fontWeight(.bold)
                                .underline(isAlarm)
                                .foregroundStyle(isAlarm ? ink : Color.shelfAmberTextOnSurface) // Critique 2026-10-06 (colorize): on shelfSurface
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(isRetrying)
                        .accessibilityLabel(isRetrying ? Text("Checking connection") : Text("Retry connection"))
                    }
                    if ConnectivityCopy.showsDownloadsLink(status: status, hasDownloads: !downloadManager.downloadedItems.isEmpty),
                       let url = URL(string: "shelfhead://downloads") {
                        Button {
                            Haptics.selection()
                            openURL(url)
                        } label: {
                            Typo.metadata(Text("Downloads"))
                                .fontWeight(.bold)
                                .underline(isAlarm)
                                .foregroundStyle(isAlarm ? ink : Color.shelfAmberTextOnSurface)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("Open downloads"))
                    }
                    Button {
                        Haptics.selection()
                        dismissedKey = DismissKey(status: status, style: state.style)
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(11, weight: .bold, relativeTo: .caption)
                            // UI-12: 44x44 pt minimum target.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Dismiss")
                }
                .foregroundStyle(ink)
                .padding(.leading, 14)
                .padding(.trailing, 2)
                // Solid fills only (Code review fix 26 Aug 2026: the legibility guarantee
                // can't depend on the backdrop for a status element).
                .background(isAlarm ? Color.shelfOrange : Color.shelfSurface, in: Capsule())
                // Light gets a hairline, Dark the shadow, via shelfElevation.
                .shelfElevation(.floating, in: Capsule())
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .contain)
            }
        }
        // This `.onChange` has to live outside the `if` above: attached to the banner
        // content itself it would vanish with it on dismissal and nothing would listen for
        // the later return to `.ok` (the "silenced forever" failure mode).
        .onChange(of: status) { old, new in
            if new == .ok { dismissedKey = nil }
            // HIG audit 2026-09-17 M10: tell VoiceOver about each transition.
            switch new {
            case .offline, .serverUnreachable:
                if let text = state?.message {
                    AccessibilityNotification.Announcement(text).post()
                }
            case .ok:
                if old != .ok {
                    AccessibilityNotification.Announcement(String(localized: "Connection restored")).post()
                }
            }
        }
    }

    /// Critique 2026-10-06 (harden): re-runs the reachability check; the debounced display
    /// status then follows the store.
    private func retry() {
        guard !isRetrying else { return }
        Haptics.selection()
        isRetrying = true
        Task { @MainActor in
            await ReachabilityStore.shared.checkNow()
            isRetrying = false
        }
    }

    /// Critique 2026-10-06 (harden): the same flush Settings > Diagnostics > Sync Now runs,
    /// then a brief outcome line (also announced, since it appears outside VoiceOver focus).
    private func syncNow() {
        guard !isSyncing else { return }
        Haptics.selection()
        isSyncing = true
        syncOutcome = nil
        let before = AudioPlayerService.shared.pendingProgressCount
        Task { @MainActor in
            await AudioPlayerService.shared.awaitPendingWrites()
            await BookmarkSyncService.shared.flush()
            // `pendingProgressCount` is republished by a trailing Task inside the flush.
            try? await Task.sleep(nanoseconds: 250_000_000)
            let message = ConnectivityCopy.syncOutcomeMessage(
                before: before, after: AudioPlayerService.shared.pendingProgressCount)
            syncOutcome = message
            isSyncing = false
            AccessibilityNotification.Announcement(message).post()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            syncOutcome = nil
        }
    }

    /// Design review (14 Aug 2026), item 2: a quiet muted pill reflecting current fact
    /// (an unsynced position isn't a problem to alarm about). Critique 2026-10-06 (harden):
    /// now carries a "Sync now" action and a session dismissal (see `pendingDismissedAt`).
    @ViewBuilder private var pendingSyncLine: some View {
        if showsPendingPill {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: pendingSyncIconSize, weight: .semibold))
                    .accessibilityHidden(true)
                Typo.supporting(Text(syncOutcome ?? ConnectivityCopy.pendingMessage(count: pendingSyncCount)), weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if syncOutcome == nil {
                    if ConnectivityCopy.showsSyncNow(status: status) || isSyncing {
                    Button {
                        syncNow()
                    } label: {
                        Typo.supporting(Text(isSyncing ? LocalizedStringKey("Syncing\u{2026}") : LocalizedStringKey("Sync now")), weight: .bold)
                            .foregroundStyle(Color.shelfAmberTextOnSurface) // Critique 2026-10-06 (colorize): on shelfSurface
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(isSyncing)
                    .accessibilityLabel(isSyncing ? Text("Syncing positions") : Text("Sync positions now"))
                    }
                    Button {
                        Haptics.selection()
                        pendingDismissedAt = pendingSyncCount
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(11, weight: .bold, relativeTo: .caption)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Dismiss sync notice")
                }
            }
            .foregroundStyle(Color.shelfCream)
            .padding(.leading, 12)
            .padding(.trailing, 2)
            // Solid `shelfSurface` (Code review fix 26 Aug 2026): no backdrop-dependent legibility.
            .background(Color.shelfSurface, in: Capsule())
            .shelfElevation(.floating, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }
}
