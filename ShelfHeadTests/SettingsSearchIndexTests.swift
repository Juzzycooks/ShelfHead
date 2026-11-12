import XCTest
@testable import ShelfHead

/// Pins `SettingsSearchIndex.results(for:)` — the pure title/keyword matcher behind the
/// Settings search box (UI-12, REVIEW_2026-08-12.md).
///
/// Batch 295 note: this file was overwritten by an edit-only agent adding the T2 cases
/// below; the eight original cases were reconstructed from their names and the matcher's
/// documented behaviour (empty query → nothing; case-insensitive substring over title
/// and keywords; every entry routes to a real `SettingsPage`).
final class SettingsSearchIndexTests: XCTestCase {

    // MARK: - Original coverage

    func testEmptyQueryReturnsNoResults() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "").isEmpty)
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "zzqx-not-a-setting").isEmpty)
    }

    func testMatchesByTitleCaseInsensitively() {
        let results = SettingsSearchIndex.results(for: "SLEEP TIMER")
        XCTAssertTrue(results.contains { $0.title == "Sleep timer" })
    }

    func testMatchesByKeywordNotJustTitle() {
        // "equalizer" appears only in keywords, never in a title.
        let results = SettingsSearchIndex.results(for: "equalizer")
        XCTAssertEqual(results.map(\.title), ["Volume boost / bass / treble"])
    }

    func testMatchIsSubstringNotExactWord() {
        // "wif" is a prefix of the keyword "wifi".
        let results = SettingsSearchIndex.results(for: "wif")
        XCTAssertTrue(results.contains { $0.title == "Wi-Fi only downloads" })
    }

    func testMultiWordQueryMatchesKeywordPhrase() {
        let results = SettingsSearchIndex.results(for: "add server")
        XCTAssertTrue(results.contains { $0.title == "Servers & accounts" })
    }

    func testNoDuplicateTitles() {
        let titles = SettingsSearchIndex.entries.map(\.title)
        XCTAssertEqual(titles.count, Set(titles).count, "Duplicate search titles: \(titles)")
    }

    func testEveryEntryRoutesToAKnownPage() {
        // Every `SettingsPage` case resolves to a real view in `SettingsView.destination(for:)`
        // (its exhaustive `switch` makes a missing destination a compile error); this pins
        // that no entry is left pointing at a case the routing doesn't know about.
        let known = Set(SettingsPage.allCases)
        for entry in SettingsSearchIndex.entries {
            XCTAssertTrue(known.contains(entry.page), "\(entry.title) routes to unknown page \(entry.page)")
        }
    }

    // MARK: - T2 / T3 (REVIEW_2026-09-04_UI.md)

    func testFaceIDFindsAccountSecurityPage() {
        let results = SettingsSearchIndex.results(for: "face id")
        XCTAssertTrue(results.contains { $0.page == .account },
                      "\"face id\" should surface the Account & Security page.")
    }

    func testCommuteFindsPlaybackPage() {
        let results = SettingsSearchIndex.results(for: "commute")
        XCTAssertTrue(results.contains { $0.page == .playback },
                      "\"commute\" should surface the renamed Listening Profile preset.")
    }

    func testDrivingReturnsBothPlaybackAndFeaturesTipsHits() {
        let results = SettingsSearchIndex.results(for: "driving")
        XCTAssertTrue(results.contains { $0.page == .playback },
                      "\"driving\" should still surface the Listening Profile picker.")
        XCTAssertTrue(results.contains { $0.page == .featuresTips },
                      "\"driving\" should still surface Driving Mode (the player UI).")
    }

    // Cleanup 2026-10-30: this entry pointed at the Household page's first section, and
    // the `householdSharing` anchor it should use had no entry at all.
    func testShareWhatImListeningToLandsOnTheSharingRow() {
        let entry = SettingsSearchIndex.entries.first { $0.title == "Share what I\u{2019}m listening to" }
        XCTAssertEqual(entry?.page, .household)
        XCTAssertEqual(entry?.row, SettingsRow.householdSharing)
    }

    // Polish pass (ST-4): straight and curly apostrophes match each other.
    func testApostropheStyleDoesNotMatterInSearch() {
        let straight = SettingsSearchIndex.results(for: "what I'm listening")
        let curly = SettingsSearchIndex.results(for: "what I\u{2019}m listening")
        XCTAssertTrue(straight.contains { $0.row == SettingsRow.householdSharing })
        XCTAssertEqual(straight.map(\.title), curly.map(\.title))
    }

    // T3 (REVIEW_2026-09-04_UI.md)
    func testDownloadedBooksFindsDownloadsPage() {
        let results = SettingsSearchIndex.results(for: "offline books")
        XCTAssertTrue(results.contains { $0.page == .downloads },
                      "\"offline books\" should surface the Downloaded Books list on the Downloads page.")
    }

    // T7 (REVIEW_2026-09-04_UI.md): `downloadsNotifications` and `downloadsStorage` were
    // collapsed into one `.downloads` case since Batch 266 already routed both to the
    // same `DownloadsSettingsView` — pin that every download/storage/notification-ish
    // search term still resolves to that single page. Uses "downloads" rather than the
    // bare "download" since the latter also substring-matches the unrelated "Download
    // health" entry, which intentionally lives on `.diagnostics`.
    // Critique 2026-10-06 (distill): "cellular" and "notification" dropped from this list —
    // Stream on cellular moved to Playback and the daily reminder to System & Privacy
    // (pinned in `testMovedSettingsRouteToTheirNewPages`).
    // Batch 431 (Phase 1 suite): "storage" also finds Delete all transcripts, whose storage
    // lives on the Transcripts page (Batch 422) — both answers are right for that query.
    func testDownloadRelatedQueriesAllRouteToDownloadsPage() {
        for query in ["downloads", "storage", "cache", "wifi"] {
            let results = SettingsSearchIndex.results(for: query)
            XCTAssertFalse(results.isEmpty, "\"\(query)\" should match at least one entry.")
            XCTAssertTrue(results.contains { $0.page == .downloads }, "\"\(query)\" should reach the Downloads page.")
            let allowed: Set<SettingsPage> = query == "storage" ? [.downloads, .transcripts] : [.downloads]
            for entry in results {
                XCTAssertTrue(allowed.contains(entry.page),
                              "\"\(query)\" matched \(entry.title), which routes to \(entry.page) instead of .downloads.")
            }
        }
    }
    // MARK: - Critique 2026-10-06 (clarify)

    func testQueryIsTrimmed() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "sleep ").contains { $0.title == "Sleep timer" })
        XCTAssertTrue(SettingsSearchIndex.results(for: "  Sleep\n").contains { $0.title == "Sleep timer" })
        XCTAssertTrue(SettingsSearchIndex.results(for: "   ").isEmpty)
        XCTAssertFalse(SettingsSearchIndex.isSearching("   "))
        XCTAssertTrue(SettingsSearchIndex.isSearching(" a "))
    }

    func testRecentChangesAndICloudSyncHaveEntries() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "recent changes").map(\.page), [.recentChanges])
        XCTAssertTrue(SettingsSearchIndex.results(for: "undo").contains { $0.title == "Recent Changes" })
        XCTAssertTrue(SettingsSearchIndex.results(for: "icloud").contains {
            $0.title == "Sync positions with iCloud" && $0.page == .systemPrivacy
        })
    }

    func testRemoveAllServersHasAnEntry() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "remove all servers", savedServerCount: 2)
            .contains { $0.page == .account })
    }

    func testClassicLockScreenIsOnlyIndexedWhereTheRowExists() {
        let withRow = SettingsSearchIndex.entries(includesClassicLockScreen: true)
        let withoutRow = SettingsSearchIndex.entries(includesClassicLockScreen: false)
        XCTAssertTrue(withRow.contains { $0.title == SettingsSearchIndex.classicLockScreenTitle })
        XCTAssertFalse(withoutRow.contains { $0.title == SettingsSearchIndex.classicLockScreenTitle })
        XCTAssertEqual(withRow.count, withoutRow.count + 1)
        XCTAssertTrue(withRow.first { $0.title == SettingsSearchIndex.classicLockScreenTitle }?.page == .systemPrivacy)
        // Batch 406: "dynamic island" now also finds the Live Activities row, so pin only
        // that the Classic row can't be reached where it doesn't exist.
        XCTAssertFalse(SettingsSearchIndex.results(for: "dynamic island", in: withoutRow)
            .contains { $0.title == SettingsSearchIndex.classicLockScreenTitle })
        XCTAssertTrue(SettingsSearchIndex.results(for: "dynamic island", in: withoutRow)
            .contains { $0.row == SettingsRow.liveActivities })
    }

    func testEveryPageHasItsNavigationTitleForTheSubtitle() {
        XCTAssertEqual(SettingsPage.account.title, "Account & Security")
        XCTAssertEqual(SettingsPage.playback.title, "Playback")
        XCTAssertEqual(SettingsPage.sleepTimer.title, "Sleep Timer")
        XCTAssertEqual(SettingsPage.sound.title, "Sound")
        XCTAssertEqual(SettingsPage.appearance.title, "Appearance")
        XCTAssertEqual(SettingsPage.systemPrivacy.title, "System & Privacy")
        XCTAssertEqual(SettingsPage.downloads.title, "Downloads")
        XCTAssertEqual(SettingsPage.diagnostics.title, "Diagnostics")
        XCTAssertEqual(SettingsPage.recentChanges.title, "Recent Changes")
        XCTAssertEqual(SettingsPage.featuresTips.title, "Features & Tips")
    }

    // MARK: - Critique 2026-10-06 (clarify + distill): row anchors and live-state filtering

    /// Search results scroll to the row they name: every result on a page that supports
    /// anchors has a row id, and row ids are namespaced to the page's own prefix.
    func testEveryAnchorablePageEntryHasARowID() {
        let all = SettingsSearchIndex.entries(includesClassicLockScreen: true)
        for entry in all where entry.page.supportsRowAnchors {
            XCTAssertNotNil(entry.row, "\(entry.title) on \(entry.page) has no row id, so search would land at the top of the page.")
        }
    }

    func testEntryIDsAreUnique() {
        let ids = SettingsSearchIndex.entries(includesClassicLockScreen: true).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate entry ids: \(ids)")
    }

    func testRowIDsMatchTheirPage() {
        let prefixes: [SettingsPage: String] = [
            .account: "account.", .playback: "playback.", .sleepTimer: "sleep.",
            .sound: "sound.", .appearance: "appearance.", .systemPrivacy: "system.",
            .downloads: "downloads.", .diagnostics: "diagnostics.", .featuresTips: "features.",
            .transcripts: "transcripts.", .readingSites: "readingSites.", .household: "household.",
            // Batch 492 (REVIEW 2026-11-11 N2/N1): the pages the rows moved to.
            .serverTools: "serverTools.", .kids: "kids.", .releaseRadar: "releaseRadar.",
        ]
        for entry in SettingsSearchIndex.entries(includesClassicLockScreen: true) {
            guard let row = entry.row else { continue }
            guard let prefix = prefixes[entry.page] else {
                XCTFail("\(entry.title) has a row id on \(entry.page), which has no anchors"); continue
            }
            XCTAssertTrue(row.hasPrefix(prefix), "\(entry.title): row \(row) isn't on \(entry.page)")
        }
    }

    func testRemoveAllServersIsHiddenWithOneSavedServer() {
        XCTAssertFalse(SettingsSearchIndex.results(for: "remove all servers", savedServerCount: 1)
            .contains { $0.row == SettingsRow.removeAllServers })
        XCTAssertFalse(SettingsSearchIndex.results(for: "wipe", savedServerCount: 0)
            .contains { $0.row == SettingsRow.removeAllServers })
        XCTAssertTrue(SettingsSearchIndex.results(for: "wipe", savedServerCount: 3)
            .contains { $0.row == SettingsRow.removeAllServers })
    }

    func testLiveStateFilterOnlyRemovesConditionalEntries() {
        let one = SettingsSearchIndex.entries(includesClassicLockScreen: true, savedServerCount: 1)
        let many = SettingsSearchIndex.entries(includesClassicLockScreen: true, savedServerCount: 2)
        XCTAssertEqual(many.count, one.count + 1)
        XCTAssertEqual(Set(many.map(\.id)).subtracting(one.map(\.id)),
                       Set(many.filter { $0.row == SettingsRow.removeAllServers }.map(\.id)))
    }

    func testMovedSettingsRouteToTheirNewPages() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "stream on cellular").map(\.page), [.playback])
        XCTAssertEqual(SettingsSearchIndex.results(for: "daily reminder").map(\.page), [.systemPrivacy])
        XCTAssertEqual(SettingsSearchIndex.results(for: "spotlight").map(\.page), [.systemPrivacy])
        XCTAssertEqual(SettingsSearchIndex.results(for: "equalizer").map(\.page), [.sound])
        XCTAssertEqual(SettingsSearchIndex.results(for: "shake").map(\.page), [.sleepTimer])
        XCTAssertEqual(SettingsSearchIndex.results(for: "dark mode").map(\.page), [.appearance])
        XCTAssertEqual(SettingsSearchIndex.results(for: "recent changes").first?.page, .recentChanges)
        XCTAssertNil(SettingsSearchIndex.results(for: "recent changes").first?.row,
                     "Recent Changes is owned elsewhere and has no anchors.")
    }

    func testDownloadedBooksLandsOnTheLinkToTheDownloadsPage() {
        let hit = SettingsSearchIndex.results(for: "offline books").first
        XCTAssertEqual(hit?.row, SettingsRow.downloadedBooksLink)
    }

    func testOnlyRecentChangesLacksAnchors() {
        XCTAssertTrue(SettingsPage.account.supportsRowAnchors)
        XCTAssertFalse(SettingsPage.recentChanges.supportsRowAnchors)
        XCTAssertTrue(SettingsPage.playback.supportsRowAnchors)
    }

    // MARK: - Localized keywords

    func testLocalizedKeywordParsingHandlesAllSeparators() {
        XCTAssertEqual(SettingsSearchEntry.parseKeywordList(" Speed ,倍速，播放速度、 Rate ,, "),
                       ["speed", "倍速", "播放速度", "rate"])
        XCTAssertTrue(SettingsSearchEntry.parseKeywordList("").isEmpty)
    }

    func testQueryMatchingOnlyLocalizedKeywordReturnsEntry() {
        let entry = SettingsSearchEntry(title: "Default speed", keywords: ["speed"],
                                        localizedKeywords: "speed, 倍速，定时、蓝牙",
                                        page: .playback, row: SettingsRow.defaultSpeed)
        for q in ["倍速", "定时", "蓝牙", " 倍速 "] {
            XCTAssertEqual(SettingsSearchIndex.results(for: q, in: [entry]), [entry], q)
        }
        XCTAssertTrue(SettingsSearchIndex.results(for: "不存在", in: [entry]).isEmpty)
    }

    func testEveryIndexedEntryHasLocalizedKeywords() {
        for entry in SettingsSearchIndex.entries(includesClassicLockScreen: true) {
            XCTAssertFalse(entry.localizedKeywords.isEmpty, "\(entry.title) has no localized keywords")
        }
    }
}
