import XCTest
@testable import ShelfHead

@MainActor
final class RetroComponentsTests: XCTestCase {
    func testFinishedSaysFinishedNotPercent() {
        let l = CassetteTile.a11yLabel(title: "Dune", subtitle: "Frank Herbert", progress: 1, isFinished: true)
        XCTAssertEqual(l, "Dune, Frank Herbert, finished")
    }

    func testInProgressSaysPercent() {
        let l = CassetteTile.a11yLabel(title: "Dune", subtitle: "FH", progress: 0.42)
        XCTAssertEqual(l, "Dune, FH, 42 percent through")
    }

    func testDownloadedAndPlayingState() {
        let l = CassetteTile.a11yLabel(title: "T", subtitle: "S", downloaded: true, isNowPlaying: true, isPlaying: false)
        XCTAssertEqual(l, "T, S, paused, downloaded")
    }

    func testReelBandOnlyWhilePlaying() {
        XCTAssertTrue(CassetteTile.showsReelBand(isNowPlaying: true, isPlaying: true))
        XCTAssertFalse(CassetteTile.showsReelBand(isNowPlaying: true, isPlaying: false))
        XCTAssertFalse(CassetteTile.showsReelBand(isNowPlaying: false, isPlaying: true))
    }

    // Critique 2026-10-05 (shared tiles, 2nd): progress line is an in-cover overlay.
    func testProgressLineVisibility() {
        XCTAssertTrue(CassetteTile.showsProgressLine(progress: 0.3, isFinished: false))
        XCTAssertFalse(CassetteTile.showsProgressLine(progress: 0, isFinished: false))
        XCTAssertFalse(CassetteTile.showsProgressLine(progress: 1, isFinished: true))
    }

    // Library selection + position scrubber (plan 2026-10-05 §3.1, §3.2)
    func testSelectionHints() {
        XCTAssertNil(CassetteTile.selectionHint(nil))
        XCTAssertEqual(CassetteTile.selectionHint(.unselected), "Double-tap to select")
        XCTAssertEqual(CassetteTile.selectionHint(.selected), "Double-tap to deselect")
    }

    func testSelectionLabel() {
        XCTAssertEqual(CassetteTile.selectionAccessibilityLabel(base: "T, S", state: nil), "T, S")
        XCTAssertEqual(CassetteTile.selectionAccessibilityLabel(base: "T, S", state: .unselected), "T, S, not selected")
        XCTAssertEqual(CassetteTile.selectionAccessibilityLabel(base: "T, S", state: .selected), "T, S")
    }

    func testScrubberAccessibilityValue() {
        XCTAssertEqual(LibraryPositionScrubber.accessibilityValue(index: 1449, total: 3000, locale: Locale(identifier: "en_US")),
                       "Book 1,450 of 3,000")
    }

    func testScrubberSteppedIndexClamps() {
        XCTAssertEqual(LibraryPositionScrubber.steppedIndex(from: 10, total: 300, increment: true), 60)
        XCTAssertEqual(LibraryPositionScrubber.steppedIndex(from: 10, total: 300, increment: false), 0)
        XCTAssertEqual(LibraryPositionScrubber.steppedIndex(from: 290, total: 300, increment: true), 299)
        XCTAssertEqual(LibraryPositionScrubber.steppedIndex(from: 0, total: 0, increment: true), 0)
    }

    func testScrubberVisibility() {
        XCTAssertFalse(LibraryPositionScrubber.isShown(count: 119, isVisible: true, isDragging: true))
        XCTAssertFalse(LibraryPositionScrubber.isShown(count: 500, isVisible: false, isDragging: false))
        XCTAssertTrue(LibraryPositionScrubber.isShown(count: 500, isVisible: true, isDragging: false))
        XCTAssertTrue(LibraryPositionScrubber.isShown(count: 500, isVisible: false, isDragging: true))
    }
}
