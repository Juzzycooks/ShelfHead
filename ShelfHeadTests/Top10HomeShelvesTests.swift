import XCTest
@testable import ShelfHead

/// N1 (REVIEW 2026-11-11): which opt-in shelves Customise Home lists under "More Shelves".
final class Top10HomeShelvesTests: XCTestCase {
    private func kinds(_ rows: [HomeMoreShelves.Row]) -> [HomeMoreShelves.Row.Kind] { rows.map(\.kind) }

    func testReleaseRadarAlwaysListed() {
        for enabled in [false, true] {
            for entries in [false, true] {
                let rows = HomeMoreShelves.rows(releaseRadarEnabled: enabled, releaseRadarHasEntries: entries,
                                                isInHousehold: true, isKidProfile: false)
                XCTAssertEqual(kinds(rows), [.releaseRadar])
            }
        }
    }

    func testReleaseRadarStateTextDiffersByState() {
        func text(_ enabled: Bool, _ entries: Bool) -> String {
            HomeMoreShelves.rows(releaseRadarEnabled: enabled, releaseRadarHasEntries: entries,
                                 isInHousehold: true, isKidProfile: false)[0].stateText
        }
        XCTAssertEqual(Set([text(false, false), text(true, false), text(true, true)]).count, 3)
    }

    func testHouseholdListedOnlyWhenNotInOne() {
        let notIn = HomeMoreShelves.rows(releaseRadarEnabled: false, releaseRadarHasEntries: false,
                                         isInHousehold: false, isKidProfile: false)
        XCTAssertEqual(kinds(notIn), [.releaseRadar, .household])
        let isIn = HomeMoreShelves.rows(releaseRadarEnabled: false, releaseRadarHasEntries: false,
                                        isInHousehold: true, isKidProfile: false)
        XCTAssertEqual(kinds(isIn), [.releaseRadar])
    }

    func testHouseholdHiddenOnKidProfile() {
        let rows = HomeMoreShelves.rows(releaseRadarEnabled: false, releaseRadarHasEntries: false,
                                        isInHousehold: false, isKidProfile: true)
        XCTAssertEqual(kinds(rows), [.releaseRadar])
    }

    func testRowsOpenTheirSettingsPages() {
        let rows = HomeMoreShelves.rows(releaseRadarEnabled: false, releaseRadarHasEntries: false,
                                        isInHousehold: false, isKidProfile: false)
        XCTAssertEqual(rows.map(\.settingsPage), [.releaseRadar, .household])
    }
}
