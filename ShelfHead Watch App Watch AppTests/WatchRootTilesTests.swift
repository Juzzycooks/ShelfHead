// XCTest, not Swift Testing — `CLAUDE.md`'s Testing section, and every sibling file in
// this target.
//
// Pins `WatchRootTiles`, the pure decision behind P-9's unified root grid
// (REVIEW_2026-09-14_DESIGN.md, "the Watch app is two different apps"). Same precedent
// as `WatchModeResolutionTests` next door: the stateful half (`WatchHomeView` rendering
// a `LazyVGrid`, `WatchStore.mode` flipping as a phone walks in and out of range) isn't
// driven here — the decision it's built on is.
import XCTest
@testable import ShelfHead_Watch

final class WatchRootTilesTests: XCTestCase {

    private func tiles(_ mode: WatchStore.Mode,
                       session: Bool = true,
                       mirror: Bool = true) -> [WatchRootTileState] {
        WatchRootTiles.tiles(mode: mode, hasWatchSession: session, hasMirroredRecentlyAdded: mirror)
    }

    private func state(_ destination: WatchRootDestination,
                       _ mode: WatchStore.Mode,
                       session: Bool = true,
                       mirror: Bool = true) -> WatchRootTileState {
        WatchRootTiles.state(for: destination, mode: mode,
                             hasWatchSession: session, hasMirroredRecentlyAdded: mirror)
    }

    // MARK: - The invariant P-9 is actually about

    /// The whole point: the grid does not gain or lose tiles when the phone walks out
    /// of the room. Every destination appears in both modes, in the same order.
    func testTileSetIsIdenticalInBothModes() {
        for session in [true, false] {
            for mirror in [true, false] {
                let companion = tiles(.companion, session: session, mirror: mirror).map(\.destination)
                let standalone = tiles(.standalone, session: session, mirror: mirror).map(\.destination)
                XCTAssertEqual(companion, standalone,
                               "session: \(session), mirror: \(mirror)")
                XCTAssertEqual(companion, WatchRootDestination.displayOrder)
            }
        }
    }

    func testEveryDestinationIsCoveredExactlyOnce() {
        let listed = Set(WatchRootDestination.displayOrder)
        XCTAssertEqual(listed.count, WatchRootDestination.displayOrder.count, "no duplicates")
        XCTAssertEqual(listed, Set(WatchRootDestination.allCases), "nothing omitted")
    }

    /// A dimmed tile with no reason on it is just a broken tile — the reason is the
    /// entire difference between this and the old disappearing-tile behaviour.
    func testAReasonIsPresentExactlyWhenATileIsUnavailable() {
        for mode in [WatchStore.Mode.companion, .standalone] {
            for session in [true, false] {
                for mirror in [true, false] {
                    for tile in tiles(mode, session: session, mirror: mirror) {
                        if tile.isAvailable {
                            XCTAssertNil(tile.unavailableReason, "\(tile.destination) in \(mode)")
                        } else {
                            XCTAssertNotNil(tile.unavailableReason, "\(tile.destination) in \(mode)")
                            XCTAssertFalse(tile.unavailableReason?.isEmpty ?? true)
                        }
                    }
                }
            }
        }
    }

    /// Neither mode may be left with nothing to browse — if this ever fires, a reason
    /// string has been made unconditional somewhere it shouldn't be.
    func testEachModeKeepsAtLeastOneLiveBrowseTile() {
        for mode in [WatchStore.Mode.companion, .standalone] {
            let browse = tiles(mode, session: true, mirror: false)
                .filter { [.recentlyAdded, .library].contains($0.destination) }
            XCTAssertTrue(browse.contains { $0.isAvailable }, "\(mode) has no browsable tile")
        }
    }

    // MARK: - Always on

    func testDownloadsIsAvailableInBothModes() {
        // One screen behind it since Batch 412 (`StandaloneDownloadsView`, with an
        // "On iPhone" section in companion mode), never a dead tile in either mode.
        XCTAssertTrue(state(.downloads, .companion).isAvailable)
        XCTAssertTrue(state(.downloads, .standalone).isAvailable)
        XCTAssertTrue(state(.downloads, .standalone, session: false, mirror: false).isAvailable)
    }

    func testSettingsIsAvailableInBothModes() {
        // Settings is also the only route to Account and to Diagnostics (where the
        // buried mode override lives), so it must never be gated on session or phone.
        XCTAssertTrue(state(.settings, .companion, session: false, mirror: false).isAvailable)
        XCTAssertTrue(state(.settings, .standalone, session: false, mirror: false).isAvailable)
    }

    // MARK: - Library (both modes, with this Watch's own session)

    /// Critique 2026-10-06 (harden): preparing for a run happens with the iPhone in the
    /// room, so Library is live in companion mode too. Its rows open
    /// `WatchBookDetailView`, which plays on the iPhone there, not on this Watch.
    func testLibraryIsLiveInBothModesWithASession() {
        XCTAssertTrue(state(.library, .standalone, session: true).isAvailable)
        XCTAssertTrue(state(.library, .companion, session: true).isAvailable)
    }

    /// Without a session the tile isn't a dead end: it says why and opens setup.
    func testLibraryWithoutASessionOpensSetup() {
        for mode in [WatchStore.Mode.companion, .standalone] {
            let tile = state(.library, mode, session: false)
            XCTAssertFalse(tile.isAvailable, "\(mode)")
            XCTAssertTrue(tile.opensSetup, "\(mode)")
            XCTAssertEqual(tile.unavailableReason, "Set up to browse")
        }
    }

    /// Only a missing session sends a tile to setup; a tile that needs the phone doesn't.
    func testOnlyMissingSessionOpensSetup() {
        for mode in [WatchStore.Mode.companion, .standalone] {
            for session in [true, false] {
                for mirror in [true, false] {
                    for tile in tiles(mode, session: session, mirror: mirror) where tile.opensSetup {
                        XCTAssertEqual(tile.destination, .library)
                        XCTAssertFalse(session)
                        XCTAssertFalse(tile.isAvailable)
                    }
                }
            }
        }
    }

    // MARK: - Collections (companion-only)

    func testCollectionsIsLiveOnlyInCompanion() {
        XCTAssertTrue(state(.collections, .companion).isAvailable)
        XCTAssertTrue(state(.collections, .companion, mirror: false).isAvailable)
        XCTAssertFalse(state(.collections, .standalone).isAvailable)
    }

    func testCollectionsStaysUnavailableInStandaloneEvenWithAMirror() {
        // `CollectionBooksView` plays via `store.playItem(itemId:)`, which relays to
        // the phone unconditionally — a populated mirror doesn't make it work.
        XCTAssertEqual(state(.collections, .standalone, mirror: true).unavailableReason,
                       "Needs your iPhone nearby")
    }

    // MARK: - Recently Added (mirror-dependent in standalone)

    func testRecentlyAddedIsAlwaysLiveInCompanion() {
        // Including with an empty mirror: the screen's own "Open ShelfHead on iPhone to
        // sync" empty state is actionable while the phone is right there, which is how
        // the tile behaved before the unification.
        XCTAssertTrue(state(.recentlyAdded, .companion, mirror: true).isAvailable)
        XCTAssertTrue(state(.recentlyAdded, .companion, mirror: false).isAvailable)
    }

    func testRecentlyAddedSurvivesIntoStandaloneWhenAMirrorExists() {
        // `RecentlyAddedView` already branches on mode and pushes
        // `StandaloneNowPlayingView`, and a WatchConnectivity mirror outlives the
        // connection that delivered it — so this is a real tile, not a courtesy one.
        XCTAssertTrue(state(.recentlyAdded, .standalone, mirror: true).isAvailable)
    }

    func testRecentlyAddedIsDimmedInStandaloneWithNoMirror() {
        XCTAssertEqual(state(.recentlyAdded, .standalone, mirror: false).unavailableReason,
                       "Needs your iPhone nearby")
    }

    // MARK: - Session state doesn't leak where it shouldn't

    func testOnlyLibraryCaresAboutTheWatchSession() {
        for mode in [WatchStore.Mode.companion, .standalone] {
            for destination in WatchRootDestination.allCases where destination != .library {
                XCTAssertEqual(state(destination, mode, session: true),
                               state(destination, mode, session: false),
                               "\(destination) in \(mode) changed with the session flag")
            }
        }
    }
}
