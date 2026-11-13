import XCTest
@testable import ShelfHead

/// Batch 496 (REVIEW 2026-11-11 P3): the player's Sound sheet.
final class Batch496SoundSheetTests: XCTestCase {

    func testSpatialHiddenWithoutHeadphonesWhenOff() {
        let s = SoundSheetLayout.sections(spatialHeadphonesConnected: false, spatialEnabled: false)
        XCTAssertEqual(s, [.volumeAndTone, .voiceAndLevel, .ambientSound])
    }

    func testSpatialShownWithHeadphonesOrWhenAlreadyOn() {
        let all: [SoundSheetLayout.Section] = [.volumeAndTone, .voiceAndLevel, .spatialAudio, .ambientSound]
        XCTAssertEqual(SoundSheetLayout.sections(spatialHeadphonesConnected: true, spatialEnabled: false), all)
        XCTAssertEqual(SoundSheetLayout.sections(spatialHeadphonesConnected: false, spatialEnabled: true), all)
    }

    func testFormatNoticeNeedsABookAndAnUnsupportedFormat() {
        XCTAssertTrue(SoundSheetLayout.showsFormatNotice(hasBook: true, formatUnsupported: true))
        XCTAssertFalse(SoundSheetLayout.showsFormatNotice(hasBook: false, formatUnsupported: true))
        XCTAssertFalse(SoundSheetLayout.showsFormatNotice(hasBook: true, formatUnsupported: false))
    }
}
