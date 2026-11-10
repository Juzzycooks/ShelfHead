import XCTest
import WatchConnectivity
@testable import ShelfHead_Watch

/// Review follow-up (30 October 2026): the phone->Watch wire payloads. `WatchConnectivityStore.apply(context:)`
/// is private, so these pin the two halves around it: the decoding contract (what the phone sends and the
/// Watch's `try? decode` tolerates) and the real delegate entry points, driven with `WCSession.default`.
@MainActor
final class WatchWirePayloadDecodingTests: XCTestCase {
    private let scope = WatchAccountScope(serverURL: "https://abs.example.com", accountId: "acct-1")

    private func state(itemId: String = "li_1", isPlaying: Bool = true) -> WatchPlaybackState {
        WatchPlaybackState(scope: scope, itemId: itemId, sessionId: "s1", title: "Dune", author: "Frank Herbert",
                           chapterTitle: "One", duration: 7200, currentTime: 100, playbackRate: 1.25,
                           isPlaying: isPlaying, lastUpdated: Date(timeIntervalSince1970: 1_000), coverData: nil)
    }

    func testPlaybackStateRoundTrips() throws {
        let original = state()
        let decoded = try JSONDecoder().decode(WatchPlaybackState.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// An older phone build omits every later-added key; the whole snapshot must still decode (NEW-13).
    func testOlderPhonePayloadMissingNewerKeysStillDecodes() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state())) as? [String: Any])
        for key in ["lastConfirmedUpdate", "skipBackwardInterval", "skipForwardInterval", "sleepTimerOption",
                    "sleepTimerRemaining", "accentHex", "isBuffering"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(WatchPlaybackState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.skipBackwardInterval, 15)
        XCTAssertEqual(decoded.skipForwardInterval, 30)
        XCTAssertEqual(decoded.sleepTimerOption, .off)
        XCTAssertEqual(decoded.sleepTimerRemaining, 0)
        XCTAssertEqual(decoded.accentHex, "E8A838")
        XCTAssertFalse(decoded.isBuffering)
        XCTAssertEqual(decoded.lastConfirmedUpdate, decoded.lastUpdated)
    }

    func testPayloadMissingARequiredKeyFailsToDecode() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state())) as? [String: Any])
        object.removeValue(forKey: "itemId")
        XCTAssertThrowsError(try JSONDecoder().decode(WatchPlaybackState.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testIdleSnapshotHasNoActiveItem() {
        XCTAssertFalse(WatchPlaybackState.idle(scope: scope).hasActiveItem)
        XCTAssertTrue(state().hasActiveItem)
    }

    func testListPayloadsRoundTrip() throws {
        let chapters = [WatchChapterSummary(id: 0, title: "A", start: 0, end: 10), WatchChapterSummary(id: 1, title: "B", start: 10, end: 20)]
        let bookmarks = [WatchBookmarkSummary(id: "b1", title: "Here", time: 12.5)]
        let downloads = [WatchDownloadSummary(id: "li_1", title: "T", author: "A", status: .downloading(progress: 0.4), coverData: nil),
                         WatchDownloadSummary(id: "li_2", title: "T2", author: "A2", status: .failed, coverData: nil)]
        XCTAssertEqual(try JSONDecoder().decode([WatchChapterSummary].self, from: JSONEncoder().encode(chapters)), chapters)
        XCTAssertEqual(try JSONDecoder().decode([WatchBookmarkSummary].self, from: JSONEncoder().encode(bookmarks)), bookmarks)
        XCTAssertEqual(try JSONDecoder().decode([WatchDownloadSummary].self, from: JSONEncoder().encode(downloads)), downloads)
    }

    func testChapterSkipSettingsResolveAndPersist() throws {
        let suite = "WatchConnectivityPayloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(WatchChapterSkipSettings.load(from: defaults), WatchChapterSkipSettings(), "nothing saved loads the defaults")

        let settings = WatchChapterSkipSettings(defaultStart: 5, defaultEnd: 8, overrides: ["li_1": [20, 30], "bad": [1]])
        settings.save(to: defaults)
        let loaded = WatchChapterSkipSettings.load(from: defaults)
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.resolved(forItem: "li_1").start, 20)
        XCTAssertEqual(loaded.resolved(forItem: "li_1").end, 30)
        XCTAssertEqual(loaded.resolved(forItem: "other").start, 5)
        XCTAssertEqual(loaded.resolved(forItem: "bad").end, 8, "a malformed override falls back to the default")
    }

    func testCorruptSavedChapterSkipSettingsLoadDefaults() throws {
        let suite = "WatchConnectivityPayloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("nope".utf8), forKey: WatchChapterSkipSettings.defaultsKey)
        XCTAssertEqual(WatchChapterSkipSettings.load(from: defaults), WatchChapterSkipSettings())
    }
}

/// Drives the real `WCSessionDelegate` entry points on the shared store. `WCSession.default` is only used as
/// the (ignored) session argument. Each test restores nothing beyond the playback state it set, so they
/// assert on relative changes.
@MainActor
final class WatchConnectivityApplyTests: XCTestCase {
    private let scopeA = WatchAccountScope(serverURL: "https://abs.example.com", accountId: "a")
    private let scopeB = WatchAccountScope(serverURL: "https://abs.example.com", accountId: "b")

    private func state(scope: WatchAccountScope, itemId: String) -> WatchPlaybackState {
        WatchPlaybackState(scope: scope, itemId: itemId, sessionId: nil, title: "T-\(itemId)", author: "A",
                           chapterTitle: nil, duration: 100, currentTime: 1, playbackRate: 1,
                           isPlaying: false, lastUpdated: Date(timeIntervalSince1970: 5), coverData: nil)
    }

    private func blob<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    /// `apply(context:)` runs in a `Task { @MainActor }` hopped from the nonisolated delegate method.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testApplicationContextAppliesPlaybackStateAndLists() async throws {
        let store = WatchConnectivityStore.shared
        let chapters = [WatchChapterSummary(id: 0, title: "C", start: 0, end: 50)]
        let context: [String: Any] = [
            "playbackState": try blob(state(scope: scopeA, itemId: "ctx_1")),
            "chapters": try blob(chapters),
        ]
        store.session(WCSession.default, didReceiveApplicationContext: context)
        await settle { store.playbackState?.itemId == "ctx_1" && store.chapters == chapters }
        XCTAssertEqual(store.playbackState?.itemId, "ctx_1")
        XCTAssertEqual(store.chapters, chapters)
    }

    func testChangingBookDropsStaleChaptersAndBookmarks() async throws {
        let store = WatchConnectivityStore.shared
        let chapters = [WatchChapterSummary(id: 0, title: "C", start: 0, end: 50)]
        let bookmarks = [WatchBookmarkSummary(id: "b", title: "B", time: 3)]
        store.session(WCSession.default, didReceiveMessage: [
            "playbackState": try blob(state(scope: scopeA, itemId: "same_1")),
            "chapters": try blob(chapters), "bookmarks": try blob(bookmarks),
        ])
        await settle { store.playbackState?.itemId == "same_1" && store.bookmarks == bookmarks }
        XCTAssertEqual(store.bookmarks, bookmarks)

        // Same account, different book: book-specific caches must clear.
        store.session(WCSession.default, didReceiveMessage: ["playbackState": try blob(state(scope: scopeA, itemId: "other_1"))])
        await settle { store.playbackState?.itemId == "other_1" }
        XCTAssertEqual(store.playbackState?.itemId, "other_1")
        XCTAssertTrue(store.chapters.isEmpty)
        XCTAssertTrue(store.bookmarks.isEmpty)
    }

    func testChangingAccountAtTheSameItemIdAlsoDropsCaches() async throws {
        let store = WatchConnectivityStore.shared
        let bookmarks = [WatchBookmarkSummary(id: "b", title: "B", time: 3)]
        store.session(WCSession.default, didReceiveUserInfo: [
            "playbackState": try blob(state(scope: scopeA, itemId: "x_1")), "bookmarks": try blob(bookmarks),
        ])
        await settle { store.playbackState?.scope == self.scopeA && store.bookmarks == bookmarks }
        XCTAssertEqual(store.bookmarks, bookmarks)

        store.session(WCSession.default, didReceiveUserInfo: ["playbackState": try blob(state(scope: scopeB, itemId: "x_1"))])
        await settle { store.playbackState?.scope == self.scopeB }
        XCTAssertEqual(store.playbackState?.scope, scopeB)
        XCTAssertTrue(store.bookmarks.isEmpty)
    }

    func testUndecodableAndNonDataValuesAreIgnored() async throws {
        let store = WatchConnectivityStore.shared
        store.session(WCSession.default, didReceiveApplicationContext: ["playbackState": try blob(state(scope: scopeA, itemId: "keep_1"))])
        await settle { store.playbackState?.itemId == "keep_1" }

        // Garbage bytes and a non-Data value must neither crash nor replace the good state.
        store.session(WCSession.default, didReceiveApplicationContext: ["playbackState": Data("{".utf8), "chapters": "not data", "downloads": 7])
        let marker = [WatchDownloadSummary(id: "m", title: "M", author: "A", status: .queued, coverData: nil)]
        store.session(WCSession.default, didReceiveApplicationContext: ["downloads": try blob(marker)])
        await settle { store.downloads == marker }
        XCTAssertEqual(store.downloads, marker, "later valid keys still apply")
        XCTAssertEqual(store.playbackState?.itemId, "keep_1")
    }
}
