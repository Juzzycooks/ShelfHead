import XCTest
import UserNotifications
@testable import ShelfHead

/// Batch 495 (REVIEW 2026-11-11 Y1): where a notification tap or action lands. The delegate
/// (`NotificationResponder`) only extracts strings and hands the URL from `NotificationRoute.url`
/// to `IncomingLinkInbox`, so these pin the whole decision.
@MainActor
final class Batch495NotificationsRouteTests: XCTestCase {
    private let tap = UNNotificationDefaultActionIdentifier
    private let here = "fp-here"

    private func url(_ category: NotificationRoute.Category, _ action: String,
                     _ payload: NotificationRoute.Payload = .init(), server: String = "fp-here") -> String? {
        NotificationRoute.url(categoryIdentifier: category.rawValue, actionIdentifier: action,
                              payload: payload, currentServerFingerprint: server)?.absoluteString
    }

    // MARK: Daily reminder

    func testDailyReminderTapOpensNowPlaying() {
        XCTAssertEqual(url(.dailyReminder, tap), "shelfhead://nowplaying")
    }

    func testDailyReminderResumeActionResumes() {
        XCTAssertEqual(url(.dailyReminder, NotificationRoute.resumeAction), "shelfhead://resume")
    }

    func testDailyReminderDismissDoesNothing() {
        XCTAssertNil(url(.dailyReminder, UNNotificationDismissActionIdentifier))
    }

    // MARK: Download complete

    func testDownloadCompleteTapOpensTheBook() {
        XCTAssertEqual(url(.downloadComplete, tap, .init(itemId: "li_123")), "shelfhead://book/li_123")
    }

    func testDownloadCompletePlayActionAddsPlayFlag() {
        XCTAssertEqual(url(.downloadComplete, NotificationRoute.playAction, .init(itemId: "li_123")),
                       "shelfhead://book/li_123?play=1")
    }

    func testDownloadCompleteWithoutIdFallsBackToDownloads() {
        XCTAssertEqual(url(.downloadComplete, tap), "shelfhead://downloads")
    }

    func testDownloadCompleteIgnoresOtherActions() {
        XCTAssertNil(url(.downloadComplete, NotificationRoute.resumeAction, .init(itemId: "li_123")))
    }

    // MARK: Release reminder

    // Batch 497: the reminder now names the series; `MainTabView` falls back to the search.
    func testReleaseReminderNamesTheSeries() throws {
        let link = try XCTUnwrap(NotificationRoute.url(
            categoryIdentifier: NotificationRoute.Category.releaseReminder.rawValue, actionIdentifier: tap,
            payload: .init(seriesName: "The Expanse & Friends"), currentServerFingerprint: here))
        XCTAssertEqual(link.host, "series")
        XCTAssertEqual(DeepLinkParser.seriesName(in: link), "The Expanse & Friends")
    }

    func testReleaseReminderWithoutSeriesOpensTheApp() {
        XCTAssertNil(url(.releaseReminder, tap))
    }

    // MARK: Household recommendation

    func testRecommendationOnThisServerOpensTheBook() {
        XCTAssertEqual(url(.householdRecommendation, tap, .init(itemId: "li_9", serverFingerprint: here)),
                       "shelfhead://book/li_9")
    }

    func testRecommendationOnAnotherServerOpensHousehold() {
        XCTAssertEqual(url(.householdRecommendation, tap, .init(itemId: "li_9", serverFingerprint: "fp-other")),
                       "shelfhead://household")
    }

    func testRecommendationWhenSignedOutOpensHousehold() {
        XCTAssertEqual(url(.householdRecommendation, tap, .init(itemId: "li_9", serverFingerprint: ""), server: ""),
                       "shelfhead://household")
    }

    func testUnknownCategoryRoutesNowhere() {
        XCTAssertNil(NotificationRoute.url(categoryIdentifier: "someone.else", actionIdentifier: tap,
                                           payload: .init(itemId: "x"), currentServerFingerprint: here))
    }

    // MARK: Payload and presentation

    func testPayloadRoundTripsAndDropsEmptyStrings() {
        let payload = NotificationRoute.Payload(itemId: "a", seriesName: "S", serverFingerprint: "f")
        XCTAssertEqual(NotificationRoute.Payload(userInfo: payload.userInfo), payload)
        XCTAssertEqual(NotificationRoute.Payload(userInfo: ["itemId": "", "seriesName": 3]),
                       NotificationRoute.Payload())
    }

    func testOnlyTheDailyReminderSkipsTheForegroundBanner() {
        XCTAssertFalse(NotificationRoute.showsBannerInForeground(
            categoryIdentifier: NotificationRoute.Category.dailyReminder.rawValue))
        for category in [NotificationRoute.Category.downloadComplete, .releaseReminder, .householdRecommendation] {
            XCTAssertTrue(NotificationRoute.showsBannerInForeground(categoryIdentifier: category.rawValue))
        }
    }

    func testEveryCategoryIsRegistered() {
        let registered = Set(NotificationManager.categories.map(\.identifier))
        XCTAssertEqual(registered, Set([NotificationRoute.Category.dailyReminder, .downloadComplete,
                                        .releaseReminder, .householdRecommendation].map(\.rawValue)))
    }

    // MARK: The ?play=1 deep link

    func testWantsPlayOnlyForBookLinksWithTheFlag() throws {
        XCTAssertTrue(DeepLinkParser.wantsPlay(in: try XCTUnwrap(URL(string: "shelfhead://book/li_1?play=1"))))
        XCTAssertFalse(DeepLinkParser.wantsPlay(in: try XCTUnwrap(URL(string: "shelfhead://book/li_1"))))
        XCTAssertFalse(DeepLinkParser.wantsPlay(in: try XCTUnwrap(URL(string: "shelfhead://book/li_1?play=0"))))
        XCTAssertFalse(DeepLinkParser.wantsPlay(in: try XCTUnwrap(URL(string: "shelfhead://series/s1?play=1"))))
    }
}
