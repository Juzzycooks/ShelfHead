import XCTest
@testable import ShelfHead

/// Batch 492 (REVIEW 2026-11-11 N2): the Settings root is four groups of at most four rows, and
/// the children's Bedtime Story profile is offered only when a child profile exists.
final class Top10SettingsGroupingTests: XCTestCase {

    private func titles(_ groups: [SettingsView.RootGroup]) -> [String] {
        groups.map { String(localized: $0.title) }
    }

    func testRootHasFourGroupsOfAtMostFourRows() {
        for tools in [true, false] {
            for watch in [true, false] {
                let groups = SettingsView.rootGroups(showsServerTools: tools, showsAppleWatch: watch)
                XCTAssertEqual(titles(groups), ["Server", "Listening", "Sharing & Services", "App"])
                for group in groups {
                    XCTAssertLessThanOrEqual(group.pages.count, 4, "\(group.id) has too many rows")
                    XCTAssertFalse(group.pages.isEmpty)
                }
            }
        }
    }

    func testGroupMembership() {
        let groups = SettingsView.rootGroups(showsServerTools: true)
        XCTAssertEqual(groups[0].pages, [.account, .downloads, .serverTools, .kids])
        XCTAssertEqual(groups[1].pages, [.playback, .sleepTimer, .sound, .transcripts])
        // Batch 496 (REVIEW 2026-11-11 W13): Apple Watch, with a Watch paired.
        XCTAssertEqual(groups[2].pages, [.household, .readingSites, .releaseRadar, .appleWatch])
        XCTAssertEqual(groups[3].pages, [.appearance, .systemPrivacy, .recentChanges, .diagnostics])
    }

    /// Batch 496 (W13): no Watch paired and no Watch app installed, no Apple Watch row.
    func testAppleWatchRowNeedsAWatch() {
        let groups = SettingsView.rootGroups(showsServerTools: true, showsAppleWatch: false)
        XCTAssertEqual(groups[2].pages, [.household, .readingSites, .releaseRadar])
    }

    func testServerToolsRowIsHiddenWithoutPermissions() {
        let groups = SettingsView.rootGroups(showsServerTools: false)
        XCTAssertEqual(groups[0].pages, [.account, .downloads, .kids])
        XCTAssertFalse(ServerToolsSettingsSection.isAvailable(canUpdateLibrary: false, canUpload: false))
        XCTAssertTrue(ServerToolsSettingsSection.isAvailable(canUpdateLibrary: true, canUpload: false))
        XCTAssertTrue(ServerToolsSettingsSection.isAvailable(canUpdateLibrary: false, canUpload: true))
    }

    func testEveryPageIsOnTheRootOnceExceptFeaturesTips() {
        let listed = SettingsView.rootGroups(showsServerTools: true).flatMap(\.pages)
        XCTAssertEqual(listed.count, Set(listed).count, "A page is listed twice.")
        XCTAssertEqual(Set(listed), Set(SettingsPage.allCases).subtracting([.featuresTips]))
    }

    func testBedtimeStoryOnlyWithAChildProfile() {
        XCTAssertFalse(ListeningProfile.available(hasChildProfile: false).contains(.bedtimeStory))
        XCTAssertTrue(ListeningProfile.available(hasChildProfile: true).contains(.bedtimeStory))
        let others: [ListeningProfile] = [.off, .driving, .sleep, .work]
        XCTAssertEqual(ListeningProfile.available(hasChildProfile: false), others)
        XCTAssertEqual(ListeningProfile.available(hasChildProfile: true), others + [.bedtimeStory])
        XCTAssertEqual(ListeningProfile.allCases, ListeningProfile.available(hasChildProfile: true))
        // An active Bedtime Story stays listed after the child profile goes, so no picker loses its selection.
        XCTAssertTrue(ListeningProfile.available(hasChildProfile: false, active: .bedtimeStory).contains(.bedtimeStory))
    }
}
