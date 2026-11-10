// XCTest, not Swift Testing — `CLAUDE.md`'s Testing section, and the sibling
// `ShelfHead_Watch_App_Watch_AppTests.swift` in this same target.
//
// Everything pinned here is a `nonisolated static` pure decision function on the type
// that owns the behaviour, following this project's stated precedent (pin the pure
// decision; don't try to drive the stateful path — `DownloadManager
// .shouldReclaimOrphanDirectory` on the phone, `StandaloneAudioEngine.resumePosition`
// on the Watch). Every one of them backs a specific finding from the 9 September 2026
// review's Watch download-and-mode batch.
import XCTest
@testable import ShelfHead_Watch

// MARK: - Download state guard (review MEDIUM: "second Download tap re-queues the same item")

/// Pins `WatchLocalDownloadManager.shouldStartDownload(currentState:)`. The bug was a
/// value comparison (`states[itemId] != .downloading(progress: 0)`) standing in for a
/// case comparison, so anything other than *exactly zero* progress read as "not
/// downloading" and started a second, overlapping transfer for the same book.
final class WatchDownloadStateGuardTests: XCTestCase {

    func testNoRecordedStateStarts() {
        XCTAssertTrue(WatchLocalDownloadManager.shouldStartDownload(currentState: nil))
    }

    func testNotDownloadedStarts() {
        XCTAssertTrue(WatchLocalDownloadManager.shouldStartDownload(currentState: .notDownloaded))
    }

    func testFailedStartsBecauseThatIsRetry() {
        XCTAssertTrue(WatchLocalDownloadManager.shouldStartDownload(currentState: .failed("Server returned HTTP 502.")))
    }

    func testQueuedDoesNotStart() {
        XCTAssertFalse(WatchLocalDownloadManager.shouldStartDownload(currentState: .queued))
    }

    func testDownloadingAtZeroDoesNotStart() {
        // The one case the old guard did catch.
        XCTAssertFalse(WatchLocalDownloadManager.shouldStartDownload(currentState: .downloading(progress: 0)))
    }

    func testDownloadingPartwayDoesNotStart() {
        // The regression itself: any non-zero progress used to sail straight through.
        XCTAssertFalse(WatchLocalDownloadManager.shouldStartDownload(currentState: .downloading(progress: 0.4)))
        XCTAssertFalse(WatchLocalDownloadManager.shouldStartDownload(currentState: .downloading(progress: 0.999)))
    }

    func testDownloadedDoesNotStart() {
        XCTAssertFalse(WatchLocalDownloadManager.shouldStartDownload(currentState: .downloaded))
    }
}

// MARK: - Status-code acceptance (review HIGH: "an HTTP error body accepted as an audio track")

/// Pins `WatchLocalDownloadManager.acceptance(forStatusCode:)`. A background download
/// "succeeds" for any status code, so without this the 401/404/502 body was moved into
/// place as `track-N.audio` — and if it was the last track, the whole book was marked
/// downloaded and playable on the strength of it.
final class WatchDownloadAcceptanceTests: XCTestCase {

    func testTwoHundredRangeIsAccepted() {
        for code in [200, 201, 206, 299] {
            XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: code), .accept,
                           "HTTP \(code) should be accepted")
        }
    }

    func testUnauthorizedIsDistinct() {
        // Distinct so the session-expired path can be raised rather than the user
        // being offered an infinitely retryable "Server returned HTTP 401."
        XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: 401), .sessionExpired)
    }

    func testOtherErrorsAreRejectedWithTheirCode() {
        XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: 403), .rejected(statusCode: 403))
        XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: 404), .rejected(statusCode: 404))
        XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: 502), .rejected(statusCode: 502))
    }

    func testRedirectsAreRejectedRatherThanTrusted() {
        // `URLSession` follows redirects itself, so a 3xx arriving as the *final*
        // response is not something to write to disk.
        XCTAssertEqual(WatchLocalDownloadManager.acceptance(forStatusCode: 302), .rejected(statusCode: 302))
    }
}

// MARK: - Download 401 → session-expiry gate (Item 21, 9 September 2026 review:
// "a mid-download 401 hard-fails the item AND flips authState")

/// Pins `WatchLocalDownloadManager.downloadAuthFailureAction(apiStillAuthenticates:)`.
/// A 401 on a track/media download used to raise `WatchStore.signalSessionExpired()`
/// unconditionally; this is the decision that now gates that on a cheap authenticated
/// probe (`WatchAudiobookshelfAPI.verifySessionStillAuthenticates()`) run first, so a
/// reverse proxy that gates media URLs differently from the JSON API doesn't sign the
/// user out — and, since Batch 312, doesn't trigger a needless automatic re-handoff
/// from the phone either.
final class WatchDownloadAuthFailureActionTests: XCTestCase {

    func testGenuineExpiryStillSignsOutAndFailsTheDownload() {
        XCTAssertEqual(
            WatchLocalDownloadManager.downloadAuthFailureAction(sessionProbe: .rejected),
            .signOutAndFailDownload)
    }

    /// Review 2 Medium 6: a probe that couldn't tell (offline, refresh couldn't complete)
    /// must never sign out; the download fails with Retry.
    func testUnknownProbeNeverSignsOut() {
        XCTAssertEqual(
            WatchLocalDownloadManager.downloadAuthFailureAction(sessionProbe: .unknown),
            .failDownloadAskRetry)
    }

    func testProbeClassification() {
        XCTAssertEqual(WatchAudiobookshelfAPI.sessionProbeResult(forError: WatchAPIError.sessionExpired), .rejected)
        XCTAssertEqual(WatchAudiobookshelfAPI.sessionProbeResult(forError: WatchAPIError.transportError(URLError(.timedOut))), .unknown)
        XCTAssertEqual(WatchAudiobookshelfAPI.sessionProbeResult(forError: WatchAPIError.forbidden), .unknown)
        XCTAssertEqual(WatchAudiobookshelfAPI.sessionProbeResult(forError: WatchAPIError.serverError(503)), .unknown)
        XCTAssertEqual(WatchAudiobookshelfAPI.sessionProbeResult(forError: URLError(.notConnectedToInternet)), .unknown)
    }

    func testStillAuthenticatingFailsOnlyTheDownload() {
        // The regression this function exists to fix: a media-URL-only 401 while the
        // JSON API still authenticates must not sign the user out.
        XCTAssertEqual(
            WatchLocalDownloadManager.downloadAuthFailureAction(sessionProbe: .authenticated),
            .failDownloadOnly)
    }
}

// MARK: - Eviction victims (review MEDIUM: "eviction can delete the currently-playing download")

/// Pins `WatchLocalDownloadManager.evictionVictims(...)`. Oldest-finished-first is
/// exactly wrong for the book being listened to right now: a download from weeks ago
/// only now being played is the oldest candidate there is.
///
/// Critique 2026-10-06 (third pass): the signature now takes every protected id and each
/// book's listening state. These cases are all unstarted books, so the original
/// oldest-first expectations still hold; `WatchEvictionOrderTests` pins the new order.
final class WatchDownloadEvictionTests: XCTestCase {

    private func download(_ id: String, bytes: Int64, ageDays: Double) -> WatchLocalDownload {
        WatchLocalDownload(
            id: id, title: id, author: "Author", duration: 3600,
            tracks: [], totalBytes: bytes,
            downloadedAt: Date(timeIntervalSince1970: 1_700_000_000 - ageDays * 86_400))
    }

    private func unstarted(_ items: [WatchLocalDownload]) -> [String: WatchDownloadListening] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, WatchDownloadListening.unstarted) })
    }

    func testNothingIsEvictedUnderTheCap() {
        let items = [download("a", bytes: 100, ageDays: 30), download("b", bytes: 100, ageDays: 1)]
        XCTAssertEqual(
            WatchLocalDownloadManager.evictionVictims(
                downloads: items, totalBytesUsed: 200, capBytes: 500, protectedItemIds: [], listening: unstarted(items)),
            [])
    }

    func testEvictsOldestFirstUntilUnderTheCap() {
        let items = [
            download("oldest", bytes: 100, ageDays: 30),
            download("middle", bytes: 100, ageDays: 20),
            download("newest", bytes: 100, ageDays: 1)
        ]
        XCTAssertEqual(
            WatchLocalDownloadManager.evictionVictims(
                downloads: items, totalBytesUsed: 300, capBytes: 150, protectedItemIds: [], listening: unstarted(items)),
            ["oldest", "middle"])
    }

    func testCurrentItemIsSkippedEvenWhenItIsTheOldest() {
        let items = [
            download("playing-now", bytes: 100, ageDays: 30),
            download("middle", bytes: 100, ageDays: 20),
            download("newest", bytes: 100, ageDays: 1)
        ]
        let victims = WatchLocalDownloadManager.evictionVictims(
            downloads: items, totalBytesUsed: 300, capBytes: 150, protectedItemIds: ["playing-now"],
            listening: unstarted(items))
        XCTAssertFalse(victims.contains("playing-now"))
        XCTAssertEqual(victims, ["middle", "newest"])
    }

    func testCapStaysExceededRatherThanEvictingTheCurrentItem() {
        // The documented trade: overshooting a soft, free-space-derived cap by one
        // book beats deleting the files out from under a live `AVQueuePlayer`.
        let items = [download("playing-now", bytes: 400, ageDays: 30)]
        XCTAssertEqual(
            WatchLocalDownloadManager.evictionVictims(
                downloads: items, totalBytesUsed: 400, capBytes: 150, protectedItemIds: ["playing-now"],
                listening: unstarted(items)),
            [])
    }

    func testProtectedIdThatIsNotDownloadedChangesNothing() {
        // Streaming an item that isn't downloaded shouldn't shield anything.
        let items = [download("oldest", bytes: 100, ageDays: 30), download("newest", bytes: 100, ageDays: 1)]
        XCTAssertEqual(
            WatchLocalDownloadManager.evictionVictims(
                downloads: items, totalBytesUsed: 200, capBytes: 150, protectedItemIds: ["streamed-item"],
                listening: unstarted(items)),
            ["oldest"])
    }
}

// MARK: - Mode resolution (review MEDIUM: "mode can flip out from under a paused standalone book")

/// Pins `WatchStore.shouldDeferModeChange(...)` and `WatchStore.resolvedMode(...)`.
/// `WatchRootView` swaps roots live on `mode`, so a mode change during a *loaded*
/// standalone book — playing or paused — orphans a live `AVQueuePlayer` and an open
/// server session behind a screen that can no longer reach them.
final class WatchModeResolutionTests: XCTestCase {

    func testIdleEngineAllowsAModeChange() {
        XCTAssertFalse(WatchStore.shouldDeferModeChange(standaloneIsLoaded: false, standaloneIsPlaying: false))
    }

    func testPlayingDefers() {
        XCTAssertTrue(WatchStore.shouldDeferModeChange(standaloneIsLoaded: true, standaloneIsPlaying: true))
    }

    func testLoadedButPausedAlsoDefers() {
        // The regression: the guard used to be `!isPlaying` alone.
        XCTAssertTrue(WatchStore.shouldDeferModeChange(standaloneIsLoaded: true, standaloneIsPlaying: false))
    }

    // MARK: preference × reachability × session

    func testAlwaysCompanionIsAlwaysCompanion() {
        for reachable in [true, false] {
            for session in [true, false] {
                XCTAssertEqual(
                    WatchStore.resolvedMode(preference: .alwaysCompanion, phoneIsReachable: reachable, hasUsableSession: session),
                    .companion)
            }
        }
    }

    func testAlwaysStandaloneNeedsAUsableSession() {
        XCTAssertEqual(
            WatchStore.resolvedMode(preference: .alwaysStandalone, phoneIsReachable: true, hasUsableSession: true),
            .standalone)
        XCTAssertEqual(
            WatchStore.resolvedMode(preference: .alwaysStandalone, phoneIsReachable: false, hasUsableSession: false),
            .companion)
    }

    func testAutomaticGoesStandaloneOnlyWithNoPhoneAndASession() {
        XCTAssertEqual(
            WatchStore.resolvedMode(preference: .automatic, phoneIsReachable: false, hasUsableSession: true),
            .standalone)
        XCTAssertEqual(
            WatchStore.resolvedMode(preference: .automatic, phoneIsReachable: true, hasUsableSession: true),
            .companion)
        XCTAssertEqual(
            WatchStore.resolvedMode(preference: .automatic, phoneIsReachable: false, hasUsableSession: false),
            .companion)
    }

    // MARK: remote-command ownership

    func testRemoteCommandOwnerFollowsMode() {
        XCTAssertEqual(WatchRemoteCommandRouter.owner(for: .companion), .companion)
        XCTAssertEqual(WatchRemoteCommandRouter.owner(for: .standalone), .standalone)
    }
}

// MARK: - Sign-in gate (review HIGH: "no URL validation and no plain-HTTP gate")

/// Pins `ServerURLRules` (as the Watch target compiles it) and `WatchStore.signInGate(...)`. Item 7 of this same batch
/// removed `NSAllowsLocalNetworking` from the Watch's `Info.plist`, which makes this
/// gate the only cleartext control left on the Watch.
///
/// Kept in step with the phone's `AuthViewModel.normalizedServerURL(_:)` /
/// `isLocalOrPrivateHost(_:)` / `requiresInsecureConnectionConfirmation(for:)` — see
/// `ServerURLRules`'s doc comment — since Batch 314 it is one shared file, not a copy.
final class WatchServerURLTests: XCTestCase {

    // MARK: normalisation

    func testBareHostDefaultsToHTTPS() {
        XCTAssertEqual(ServerURLRules.normalizedServerURL("abs.example.com"), "https://abs.example.com")
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(ServerURLRules.normalizedServerURL("  https://abs.example.com  "), "https://abs.example.com")
    }

    func testEmptyIsRejected() {
        XCTAssertNil(ServerURLRules.normalizedServerURL(""))
        XCTAssertNil(ServerURLRules.normalizedServerURL("   "))
    }

    func testTrailingSlashesAreDropped() {
        XCTAssertEqual(ServerURLRules.normalizedServerURL("https://abs.example.com///"), "https://abs.example.com")
    }

    func testSubpathDeploymentIsPreserved() {
        XCTAssertEqual(ServerURLRules.normalizedServerURL("https://example.com/audiobookshelf/"),
                       "https://example.com/audiobookshelf")
    }

    func testHostIsLowercased() {
        XCTAssertEqual(ServerURLRules.normalizedServerURL("https://ABS.EXAMPLE.COM"), "https://abs.example.com")
    }

    func testPortIsKept() {
        XCTAssertEqual(ServerURLRules.normalizedServerURL("192.168.1.10:13378"), "https://192.168.1.10:13378")
    }

    func testExplicitHTTPIsKept() {
        XCTAssertEqual(ServerURLRules.normalizedServerURL("http://192.168.1.10:13378"), "http://192.168.1.10:13378")
    }

    func testNonHTTPSchemeIsRejectedRatherThanPrefixed() {
        // Prepending would produce host "ftp" with path "//books.example.com", which
        // passes every later guard and yields a silently mangled address.
        XCTAssertNil(ServerURLRules.normalizedServerURL("ftp://books.example.com"))
    }

    func testUserinfoIsRejected() {
        XCTAssertNil(ServerURLRules.normalizedServerURL("https://user:pass@example.com"))
    }

    func testQueryAndFragmentAreRejected() {
        XCTAssertNil(ServerURLRules.normalizedServerURL("https://example.com/?token=abc"))
        XCTAssertNil(ServerURLRules.normalizedServerURL("https://example.com/#/library"))
    }

    // MARK: local vs. public hosts

    func testLoopbackAndMDNSAreLocal() {
        XCTAssertTrue(ServerURLRules.isLocalOrPrivateHost("localhost"))
        XCTAssertTrue(ServerURLRules.isLocalOrPrivateHost("shelf.local"))
        XCTAssertTrue(ServerURLRules.isLocalOrPrivateHost("127.0.0.1"))
        XCTAssertTrue(ServerURLRules.isLocalOrPrivateHost("::1"))
    }

    func testRFC1918RangesAreLocal() {
        XCTAssertTrue(ServerURLRules.isLocalOrPrivateHost("10.1.2.3"))
        XCTAssertTrue(ServerURLRules.isLocalOrPrivateHost("172.16.0.1"))
        XCTAssertTrue(ServerURLRules.isLocalOrPrivateHost("172.31.255.254"))
        XCTAssertTrue(ServerURLRules.isLocalOrPrivateHost("192.168.1.10"))
        XCTAssertTrue(ServerURLRules.isLocalOrPrivateHost("169.254.10.1"))
        XCTAssertTrue(ServerURLRules.isLocalOrPrivateHost("fd00::1"))
        XCTAssertTrue(ServerURLRules.isLocalOrPrivateHost("fe80::1"))
    }

    func testPublicHostsAndNearMissRangesAreNotLocal() {
        XCTAssertFalse(ServerURLRules.isLocalOrPrivateHost("books.example.com"))
        XCTAssertFalse(ServerURLRules.isLocalOrPrivateHost("8.8.8.8"))
        XCTAssertFalse(ServerURLRules.isLocalOrPrivateHost("172.15.0.1"))
        XCTAssertFalse(ServerURLRules.isLocalOrPrivateHost("172.32.0.1"))
        XCTAssertFalse(ServerURLRules.isLocalOrPrivateHost("192.167.1.1"))
        XCTAssertFalse(ServerURLRules.isLocalOrPrivateHost("2001:4860:4860::8888"))
    }

    // MARK: the acknowledgement decision

    func testHTTPSNeverNeedsAcknowledgement() {
        XCTAssertFalse(ServerURLRules.requiresInsecureConnectionConfirmation(for: "https://books.example.com"))
    }

    func testPlainHTTPToALANHostNeedsNoAcknowledgement() {
        XCTAssertFalse(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://192.168.1.10:13378"))
        XCTAssertFalse(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://shelf.local"))
    }

    func testPlainHTTPToAPublicHostNeedsAcknowledgement() {
        XCTAssertTrue(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://books.example.com"))
    }

    // UX-4 follow-up (Batch 355): Tailscale is exempt on the Watch too (same shared rule).
    func testTailscaleAddressesAndMagicDNSNeedNoAcknowledgement() {
        XCTAssertFalse(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://100.64.0.1"))
        XCTAssertFalse(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://100.127.255.254"))
        XCTAssertFalse(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://nas.tailnet-1234.ts.net"))
    }

    func testJustOutsideTheTailscaleRangeAndBareHostnamesStillNeedAcknowledgement() {
        XCTAssertTrue(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://100.63.255.255"))
        XCTAssertTrue(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://100.128.0.1"))
        XCTAssertTrue(ServerURLRules.requiresInsecureConnectionConfirmation(for: "http://nas"))
    }

    // MARK: the gate as `loginManually` sees it

    func testGateRejectsAnUnusableAddress() {
        XCTAssertEqual(WatchStore.signInGate(rawServerURL: "https://user:pass@example.com",
                                             acknowledgedInsecureConnection: false),
                       .invalidURL)
    }

    func testGateProceedsForHTTPS() {
        XCTAssertEqual(WatchStore.signInGate(rawServerURL: "abs.example.com",
                                             acknowledgedInsecureConnection: false),
                       .proceed(cleanURL: "https://abs.example.com"))
    }

    func testGateProceedsForPlainHTTPOnTheLAN() {
        XCTAssertEqual(WatchStore.signInGate(rawServerURL: "http://192.168.1.10:13378",
                                             acknowledgedInsecureConnection: false),
                       .proceed(cleanURL: "http://192.168.1.10:13378"))
    }

    func testGateAsksBeforeSendingCredentialsInTheClear() {
        XCTAssertEqual(WatchStore.signInGate(rawServerURL: "http://books.example.com",
                                             acknowledgedInsecureConnection: false),
                       .needsInsecureAcknowledgement(cleanURL: "http://books.example.com"))
    }

    func testGateProceedsOnceAcknowledged() {
        XCTAssertEqual(WatchStore.signInGate(rawServerURL: "http://books.example.com",
                                             acknowledgedInsecureConnection: true),
                       .proceed(cleanURL: "http://books.example.com"))
    }

    func testAcknowledgementCannotRescueAnInvalidAddress() {
        XCTAssertEqual(WatchStore.signInGate(rawServerURL: "ftp://books.example.com",
                                             acknowledgedInsecureConnection: true),
                       .invalidURL)
    }
}
