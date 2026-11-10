import Foundation

/// P-9 (REVIEW_2026-09-14_DESIGN.md, "the Watch app is two different apps").
///
/// The Watch used to have two entirely separate root screens — `LibraryOverviewView`
/// (companion: Recently Added / Downloaded / Collections / Settings) and
/// `StandaloneRootView` (standalone: Library / Downloads / Settings) — and the app
/// silently swapped one for the other as the phone came and went. Tiles appeared and
/// disappeared with no explanation, so the same app looked like it had gained or lost
/// features depending on which room the user's iPhone was in. `WatchModeSettingsView`
/// then asked them to reason about which of those two apps they wanted.
///
/// The replacement is one root (`WatchHomeView`) showing one tile set, in one fixed
/// order, in both modes. A destination that genuinely cannot work in the current mode
/// is still *there*, dimmed, with a one-line reason — never absent.
///
/// This type is the decision half of that, kept pure and free of SwiftUI so the Watch
/// test target can pin the whole matrix (`WatchRootTilesTests`) instead of it only
/// ever being exercised on a real paired device. Same precedent as
/// `WatchStore.resolvedMode(preference:phoneIsReachable:hasUsableSession:)` and
/// `WatchLocalDownloadManager.shouldStartDownload(currentState:)`.
enum WatchRootDestination: String, CaseIterable, Sendable {
    /// The phone's "Recently Added" shelf, mirrored over WatchConnectivity
    /// (`RecentlyAddedView`). Works in standalone mode too — that screen already
    /// branches on `WatchStore.mode` and pushes `StandaloneNowPlayingView` instead of
    /// relaying a play command — but only for as long as a mirror is actually in hand.
    case recentlyAdded
    /// This Watch's own paged/searchable library over its own server session
    /// (`StandaloneLibraryView`). Critique 2026-10-06 (harden): live in *both* modes
    /// whenever this Watch holds a session, because preparing for a run (browse, then
    /// Download to Watch) happens with the iPhone in the room. Rows open
    /// `WatchBookDetailView`, which plays on the iPhone in companion mode and on the
    /// Watch in standalone — never a second player behind the phone's back.
    case library
    /// This Watch's own downloads, "On This Watch" (`StandaloneDownloadsView`), in both
    /// modes. Critique 2026-10-06 (harden): companion mode used to open the iPhone's
    /// downloads mirror here instead, so with the phone nearby there was no way to see
    /// or manage what the Watch would play on a run. The mirror is the "On iPhone"
    /// section at the bottom of that screen in companion mode (Batch 412).
    case downloads
    /// The phone's collections, mirrored (`WatchCollectionsView`).
    case collections
    case settings

    /// Fixed display order — deliberately the same in both modes, so a tile doesn't
    /// move under the user's thumb when the phone goes out of range. `recentlyAdded`
    /// and `library` are adjacent on purpose: they're the two browse entry points, and
    /// pairing them means the first row of the grid always holds exactly one live
    /// browse tile whichever mode is active.
    ///
    /// `nonisolated` and spelled out rather than `allCases`: the Watch target builds
    /// with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so both this property and the
    /// synthesized `allCases` would otherwise be main-actor-isolated and unreadable
    /// from the `nonisolated` `WatchRootTiles.tiles(...)` (PM compile fix, Batch 319;
    /// `WatchRootTilesTests` pins that this list still covers every case).
    nonisolated static let displayOrder: [WatchRootDestination] = [
        .recentlyAdded, .library, .downloads, .collections, .settings
    ]
}

/// Whether one root tile can be tapped right now, and if not, the single line shown in
/// its subtitle slot explaining why.
struct WatchRootTileState: Equatable, Sendable {
    let destination: WatchRootDestination
    let isAvailable: Bool
    /// Non-`nil` exactly when `isAvailable` is `false`.
    let unavailableReason: String?
    /// Critique 2026-10-06 (onboard): unavailable only because this Watch has no session
    /// of its own. The tile isn't a dead end: it opens setup (`WatchAccountView`), with
    /// the reason as its subtitle. Never true for an available tile.
    var opensSetup: Bool = false
}

enum WatchRootTiles {

    /// The one decision function. Inputs are deliberately narrow and all of them are
    /// things the root screen already knows:
    ///
    /// - `mode`: `WatchStore.mode`, i.e. which playback/networking stack is live. This
    ///   is *not* the user's preference — with the mode override buried under
    ///   diagnostics (see `WatchDiagnosticsView`), Automatic is what everyone sees, and
    ///   the reasons below are written for it.
    /// - `hasWatchSession`: `WatchStore.authState == .active`. Library browsing needs
    ///   this Watch to hold its own server session, in either mode; nothing else here does.
    /// - `hasMirroredRecentlyAdded`: whether the last WatchConnectivity snapshot
    ///   actually carried that list. A mirror survives relaunches, so this can be true
    ///   with no phone in range — which is exactly why Recently Added is offered in
    ///   standalone mode rather than assumed dead. There is deliberately no
    ///   `hasMirroredCollections` twin: Collections is unreachable in standalone mode
    ///   whether or not a mirror exists (see that case below), so the mirror would
    ///   never change the answer.
    ///
    /// Deliberately *not* an input: reachability. `mode` already folds it in
    /// (`WatchStore.resolvedMode`), and taking both would let this function disagree
    /// with the stack that's actually running.
    nonisolated static func state(
        for destination: WatchRootDestination,
        mode: WatchStore.Mode,
        hasWatchSession: Bool,
        hasMirroredRecentlyAdded: Bool
    ) -> WatchRootTileState {
        func available() -> WatchRootTileState {
            WatchRootTileState(destination: destination, isAvailable: true, unavailableReason: nil)
        }
        func unavailable(_ reason: String) -> WatchRootTileState {
            WatchRootTileState(destination: destination, isAvailable: false, unavailableReason: reason)
        }
        func needsSetup(_ reason: String) -> WatchRootTileState {
            WatchRootTileState(destination: destination, isAvailable: false, unavailableReason: reason, opensSetup: true)
        }

        switch destination {
        case .recentlyAdded:
            switch mode {
            case .companion:
                // Unconditionally live in companion mode, mirror or not: the screen's
                // own empty state ("Open ShelfHead on iPhone to sync recently added
                // titles") is actionable when the phone is right there, and this is
                // exactly how the tile behaved before the unification.
                return available()
            case .standalone:
                return hasMirroredRecentlyAdded
                    ? available()
                    : unavailable(String(localized: "Needs your iPhone nearby"))
            }

        case .library:
            // Critique 2026-10-06 (harden): was dead in companion mode ("Available when
            // your iPhone isn't nearby"), because every row tapped straight into
            // playback on this Watch, a second player behind the phone's back. Rows now
            // open `WatchBookDetailView`, which plays on the iPhone in companion mode, so
            // the only real requirement is this Watch's own session (browsing and
            // downloading use it in either mode). Without one, the tile opens setup.
            return hasWatchSession ? available() : needsSetup(String(localized: "Set up to browse"))

        case .downloads:
            // Live in both modes: "On This Watch" (`StandaloneDownloadsView`), whose
            // empty state explains setup when there's no session, with the iPhone's
            // mirror one row away in companion mode.
            return available()

        case .collections:
            switch mode {
            case .companion:
                return available()
            case .standalone:
                // `WatchCollectionsView`/`CollectionBooksView` read the mirror but play
                // through `store.playItem(itemId:)`, which relays to the phone
                // unconditionally. With no phone there is nothing to relay to, so even a
                // populated mirror is a dead end here — unlike Recently Added, whose row
                // already branches on mode.
                return unavailable(String(localized: "Needs your iPhone nearby"))
            }

        case .settings:
            return available()
        }
    }

    /// Every tile, in `WatchRootDestination.displayOrder`, for the given mode. The
    /// count and the order are mode-independent by construction — that invariant is
    /// the whole point of P-9, and `WatchRootTilesTests` pins it.
    nonisolated static func tiles(
        mode: WatchStore.Mode,
        hasWatchSession: Bool,
        hasMirroredRecentlyAdded: Bool
    ) -> [WatchRootTileState] {
        WatchRootDestination.displayOrder.map {
            state(for: $0,
                  mode: mode,
                  hasWatchSession: hasWatchSession,
                  hasMirroredRecentlyAdded: hasMirroredRecentlyAdded)
        }
    }
}

// MARK: - Presentation constants

extension WatchRootDestination {
    /// Tile title. Mode-independent on purpose. Since Critique 2026-10-06 "Downloads"
    /// always opens this Watch's own list ("On This Watch").
    var title: String {
        switch self {
        case .recentlyAdded: return String(localized: "Recently Added")
        case .library: return String(localized: "Library")
        case .downloads: return String(localized: "Downloads")
        case .collections: return String(localized: "Collections")
        case .settings: return String(localized: "Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyAdded: return "sparkles"
        case .library: return "book.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .collections: return "folder"
        case .settings: return "gearshape"
        }
    }
}
