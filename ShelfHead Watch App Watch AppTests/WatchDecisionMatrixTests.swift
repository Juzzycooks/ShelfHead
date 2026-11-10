import XCTest
@testable import ShelfHead_Watch

/// Review follow-up (30 October 2026): boundary and matrix coverage for the Watch's pure decisions
/// that the existing suites only spot-check (`WatchDownloadAndModeTests`, `WatchRefreshOutcomeTests`).
@MainActor
final class WatchDownloadDecisionMatrixTests: XCTestCase {
    func testAcceptanceBoundaries() {
        XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: 199), .rejected(statusCode: 199))
        XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: 200), .accept)
        XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: 206), .accept)
        XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: 299), .accept)
        XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: 300), .rejected(statusCode: 300))
    }

    /// Only 401 means "session expired"; a 403 is the server refusing the file, not a dead session.
    func testOnlyA401IsSessionExpired() {
        for code in [0, 100, 301, 400, 402, 403, 404, 408, 429, 500, 503] {
            XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: code), .rejected(statusCode: code), "\(code)")
        }
        XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: 401), .sessionExpired)
    }

    /// The two decisions compose: a 401 with a still-working API fails only the download.
    func testA401WithAWorkingAPIDoesNotSignOut() {
        guard case .sessionExpired = WatchLocalDownloadManager.acceptance(forStatusCode: 401) else { return XCTFail() }
        XCTAssertEqual(WatchLocalDownloadManager.downloadAuthFailureAction(sessionProbe: .authenticated), .failDownloadOnly)
        XCTAssertEqual(WatchLocalDownloadManager.downloadAuthFailureAction(sessionProbe: .rejected), .signOutAndFailDownload)
    }

    func testOnlyDownloadingAndQueuedAndDownloadedSuppressAStart() {
        let states: [(WatchLocalDownloadState?, Bool)] = [
            (nil, true), (.notDownloaded, true), (.failed("x"), true),
            (.queued, false), (.downloading(progress: 0.5), false), (.downloaded, false),
        ]
        for (state, expected) in states {
            XCTAssertEqual(WatchLocalDownloadManager.shouldStartDownload(currentState: state), expected, "\(String(describing: state))")
        }
    }
}

@MainActor
final class WatchModeMatrixTests: XCTestCase {
    /// Every preference x reachability x session combination, against the documented rules.
    func testResolvedModeFullMatrix() {
        for preference in WatchStore.ModePreference.allCases {
            for reachable in [true, false] {
                for session in [true, false] {
                    let expected: WatchStore.Mode
                    switch preference {
                    case .alwaysCompanion: expected = .companion
                    case .alwaysStandalone: expected = session ? .standalone : .companion
                    case .automatic: expected = (!reachable && session) ? .standalone : .companion
                    }
                    XCTAssertEqual(WatchStore.resolvedMode(preference: preference, phoneIsReachable: reachable, hasUsableSession: session),
                                   expected, "\(preference) reachable \(reachable) session \(session)")
                }
            }
        }
    }

    /// Standalone is never chosen without a usable session, whatever else is true.
    func testStandaloneNeverResolvesWithoutASession() {
        for preference in WatchStore.ModePreference.allCases {
            for reachable in [true, false] {
                XCTAssertEqual(WatchStore.resolvedMode(preference: preference, phoneIsReachable: reachable, hasUsableSession: false), .companion)
            }
        }
    }

    /// Playing without the engine being "loaded" (an inconsistent but possible edge) keeps the current mode.
    func testPlayingButNotLoadedKeepsTheCurrentMode() {
        for current in [WatchStore.Mode.companion, .standalone] {
            XCTAssertEqual(
                WatchStore.nextMode(current: current, preference: .alwaysCompanion, phoneIsReachable: true,
                                    hasUsableSession: true, standaloneIsLoaded: false, standaloneIsPlaying: true),
                current)
        }
    }

    func testAnIdleEngineFollowsTheResolvedModeFromEitherStartingMode() {
        for current in [WatchStore.Mode.companion, .standalone] {
            XCTAssertEqual(
                WatchStore.nextMode(current: current, preference: .alwaysStandalone, phoneIsReachable: true,
                                    hasUsableSession: true, standaloneIsLoaded: false, standaloneIsPlaying: false),
                .standalone)
            XCTAssertEqual(
                WatchStore.nextMode(current: current, preference: .alwaysCompanion, phoneIsReachable: false,
                                    hasUsableSession: true, standaloneIsLoaded: false, standaloneIsPlaying: false),
                .companion)
        }
    }

    func testRefreshOutcomeMatrixForRedirectsAndInformationalCodes() {
        for code in [0, 100, 204, 301, 302, 400, 404] {
            XCTAssertEqual(WatchAudiobookshelfAPI.classifyRefreshResult(statusCode: code, transportError: nil, decodedToken: true), .couldNotComplete, "\(code)")
        }
        // A transport error wins over any status or token.
        XCTAssertEqual(WatchAudiobookshelfAPI.classifyRefreshResult(statusCode: 401, transportError: URLError(.notConnectedToInternet), decodedToken: true), .couldNotComplete)
    }
}
