import XCTest
@testable import ShelfHead

/// Tests for pure formatting helpers and lightweight model decoding.
final class FormattingAndModelsTests: XCTestCase {

    // MARK: - Double.formattedDuration ("2h 5m")

    func testFormattedDurationWithHours() {
        XCTAssertEqual(Double(2 * 3600 + 5 * 60).formattedDuration, "2h 5m")
    }

    func testFormattedDurationMinutesOnly() {
        XCTAssertEqual(Double(45 * 60).formattedDuration, "45m")
    }

    func testFormattedDurationZero() {
        XCTAssertEqual(0.0.formattedDuration, "0m")
    }

    func testFormattedDurationDropsSeconds() {
        // 1h 30m 59s → seconds are truncated, not rounded up.
        XCTAssertEqual(Double(3600 + 30 * 60 + 59).formattedDuration, "1h 30m")
    }

    // R6 (REVIEW_2026-09-04_UI.md): sub-minute durations (e.g. a 16s
    // "Opening Credits" chapter) used to floor to "0m".
    func testFormattedDurationSubMinuteShowsSeconds() {
        XCTAssertEqual(Double(16).formattedDuration, "16s")
    }

    func testFormattedDurationJustUnderAMinuteShowsSeconds() {
        XCTAssertEqual(Double(59).formattedDuration, "59s")
    }

    func testFormattedDurationExactlyOneMinute() {
        XCTAssertEqual(Double(60).formattedDuration, "1m")
    }

    func testFormattedDurationOverAnHour() {
        XCTAssertEqual(Double(3661).formattedDuration, "1h 1m")
    }

    // MARK: - Double.formattedTime ("1:02:03" / "2:05")

    func testFormattedTimeWithHours() {
        XCTAssertEqual(Double(3600 + 2 * 60 + 3).formattedTime, "1:02:03")
    }

    func testFormattedTimeMinutesSeconds() {
        XCTAssertEqual(Double(2 * 60 + 5).formattedTime, "2:05")
    }

    func testFormattedTimePadsZeroes() {
        XCTAssertEqual(65.0.formattedTime, "1:05")
        XCTAssertEqual(9.0.formattedTime, "0:09")
    }

    // MARK: - PlaybackSpeed labels

    func testPlaybackSpeedLabels() {
        XCTAssertEqual(PlaybackSpeed.x1_0.label, "1×")
        XCTAssertEqual(PlaybackSpeed.x2_0.label, "2×")
        XCTAssertEqual(PlaybackSpeed.x3_0.label, "3×")
        XCTAssertEqual(PlaybackSpeed.x0_5.label, "0.5×")
        XCTAssertEqual(PlaybackSpeed.x1_25.label, "1.25×")
        XCTAssertEqual(PlaybackSpeed.x1_75.label, "1.75×")
    }

    func testPlaybackSpeedRoundTripsFromRawValue() {
        XCTAssertEqual(PlaybackSpeed(rawValue: 1.5), .x1_5)
        XCTAssertNil(PlaybackSpeed(rawValue: 1.35))   // off-preset rate has no case
    }

    // MARK: - SleepTimerOption labels

    func testSleepTimerLabels() {
        XCTAssertEqual(SleepTimerOption.off.label, "Off")
        XCTAssertEqual(SleepTimerOption.minutes(15).label, "15 min")
        XCTAssertEqual(SleepTimerOption.endOfChapter.label, "End of chapter")
        XCTAssertEqual(SleepTimerOption.chapters(2).label, "End of chapter +2")
        XCTAssertEqual(SleepTimerOption.endOfBook.label, "End of book")
    }

    func testSleepTimerEquatable() {
        XCTAssertEqual(SleepTimerOption.minutes(30), .minutes(30))
        XCTAssertNotEqual(SleepTimerOption.minutes(30), .minutes(45))
        XCTAssertNotEqual(SleepTimerOption.endOfChapter, .endOfBook)
    }

    // MARK: - Series sequence parsing (MediaMetadata)

    private func decodeMetadata(_ json: String) throws -> MediaMetadata {
        try JSONDecoder().decode(MediaMetadata.self, from: Data(json.utf8))
    }

    func testSequenceFromStructuredSeriesNumber() throws {
        let m = try decodeMetadata(#"{"seriesName":"Foo #9","series":[{"name":"Foo","sequence":3}]}"#)
        // Structured series wins over the display string.
        XCTAssertEqual(m.sequence(inSeriesNamed: "Foo"), 3)
    }

    func testSequenceFromStructuredSeriesString() throws {
        // Some servers send sequence as a string ("1.5").
        let m = try decodeMetadata(#"{"series":[{"name":"Bar","sequence":"1.5"}]}"#)
        XCTAssertEqual(m.sequence(inSeriesNamed: "Bar"), 1.5)
    }

    func testSequenceFallsBackToDisplayString() throws {
        let m = try decodeMetadata(#"{"seriesName":"The Primal Hunter #12"}"#)
        XCTAssertEqual(m.sequence(inSeriesNamed: "The Primal Hunter"), 12)
    }

    func testSequenceNilWhenAbsent() throws {
        let m = try decodeMetadata(#"{"seriesName":"No Number Here"}"#)
        XCTAssertNil(m.sequence(inSeriesNamed: "No Number Here"))
    }

    func testMultiSeriesUsesCorrectNumber() throws {
        let json = #"{"series":[{"name":"A","sequence":1},{"name":"B","sequence":7}]}"#
        let m = try decodeMetadata(json)
        XCTAssertEqual(m.sequence(inSeriesNamed: "A"), 1)
        XCTAssertEqual(m.sequence(inSeriesNamed: "B"), 7)
    }

    func testTolerantDecodeIgnoresUnexpectedShape() throws {
        // `series` arriving as an unexpected type must not fail the whole decode.
        let m = try decodeMetadata(#"{"title":"T","series":"not-an-array"}"#)
        XCTAssertEqual(m.title, "T")
        XCTAssertNil(m.series)
    }

    // MARK: - Blank metadata normalisation (F3, REVIEW_2026-09-04_UI.md)
    //
    // Audiobookshelf sends `""`, not `null`, for metadata a book doesn't have. That made
    // every `if let` downstream succeed on nothing — visibly, a "Narrated by" label with
    // no name after it, underlined and tappable through to a narrator browse view for the
    // empty string.

    func testBlankNarratorDecodesAsNilNotEmptyString() throws {
        let m = try decodeMetadata(#"{"title":"T","narratorName":""}"#)
        XCTAssertNil(m.narratorName, "an empty narrator must not survive as a present-but-blank String")
    }

    func testWhitespaceOnlyMetadataDecodesAsNil() throws {
        let m = try decodeMetadata(#"{"narratorName":"   ","publisher":"\t","seriesName":" "}"#)
        XCTAssertNil(m.narratorName)
        XCTAssertNil(m.publisher)
        XCTAssertNil(m.seriesName)
    }

    func testRealMetadataStillDecodes() throws {
        let m = try decodeMetadata(#"{"narratorName":"Travis Baldree","publisher":"Podium"}"#)
        XCTAssertEqual(m.narratorName, "Travis Baldree")
        XCTAssertEqual(m.publisher, "Podium")
    }

    func testBlankGenresAreDropped() throws {
        // Same defect class — a blank entry rendered as an empty genre chip.
        let m = try decodeMetadata(#"{"genres":["LitRPG","","  ","Fantasy"]}"#)
        XCTAssertEqual(m.genres, ["LitRPG", "Fantasy"])
    }

    func testBlankTitleStillFallsBackAtTheItemLevel() throws {
        // `LibraryItem.title` already guarded against blanks itself; normalising at the
        // decode site must not change what that guard produces.
        let m = try decodeMetadata(#"{"title":""}"#)
        XCTAssertNil(m.title)
    }

    // MARK: - Series label de-duplication (F6, REVIEW_2026-09-04_UI.md)
    //
    // The detail chip appended "· Book n" to a series name that frequently already ends
    // in "#n", rendering "The Primal Hunter #15 · Book 15".

    func testSeriesNameWithHashSuffixAlreadyStatesSequence() {
        XCTAssertTrue(MediaMetadata.seriesName("The Primal Hunter #15", alreadyStates: 15))
    }

    func testSeriesNameWithBookSuffixAlreadyStatesSequence() {
        XCTAssertTrue(MediaMetadata.seriesName("The Ripple System, Book 1", alreadyStates: 1))
        XCTAssertTrue(MediaMetadata.seriesName("Cradle Book 3", alreadyStates: 3))
    }

    func testSeriesNameToleratesSpacingAndCase() {
        XCTAssertTrue(MediaMetadata.seriesName("Dungeon Crawler Carl # 7", alreadyStates: 7))
        XCTAssertTrue(MediaMetadata.seriesName("Mother of Learning, BOOK 2  ", alreadyStates: 2))
    }

    func testSeriesNameWithoutPositionDoesNotSuppressSuffix() {
        XCTAssertFalse(MediaMetadata.seriesName("The Primal Hunter", alreadyStates: 15))
    }

    func testSeriesNameStatingADifferentNumberDoesNotSuppressSuffix() {
        // The name's number must actually match — otherwise the position is still news.
        XCTAssertFalse(MediaMetadata.seriesName("The Primal Hunter #14", alreadyStates: 15))
    }

    func testSeriesNameWithMidStringNumberIsNotTreatedAsAPosition() {
        // "1984" is part of the title, not a trailing position marker.
        XCTAssertFalse(MediaMetadata.seriesName("Book 1984 Chronicles", alreadyStates: 1984))
    }

    // MARK: - ListeningSession.date

    func testListeningSessionDateFromMillis() {
        let session = ListeningSession(
            id: "s1", libraryItemId: "li_1",
            displayTitle: "Title", displayAuthor: "Author",
            duration: 3600, timeListening: 600, currentTime: 1200,
            startedAt: 1_600_000_000_000, updatedAt: 1_600_000_600_000
        )
        // Prefers updatedAt; epoch millis → seconds.
        XCTAssertEqual(session.date?.timeIntervalSince1970 ?? 0, 1_600_000_600, accuracy: 1)
    }

    func testListeningSessionDateNilWhenNoTimestamp() {
        let session = ListeningSession(
            id: "s2", libraryItemId: nil,
            displayTitle: nil, displayAuthor: nil,
            duration: nil, timeListening: nil, currentTime: nil,
            startedAt: nil, updatedAt: nil
        )
        XCTAssertNil(session.date)
    }

    // MARK: - G2: "(Unabridged)" stripped from display titles

    func testDisplayTitleStripsParenthesisedUnabridged() {
        XCTAssertEqual(LibraryItem.displayTitle("Mark of the Fool 10 (Unabridged)"), "Mark of the Fool 10")
        XCTAssertEqual(LibraryItem.displayTitle("The Primal Hunter 13 (Unabridged)"), "The Primal Hunter 13")
    }

    func testDisplayTitleStripsBracketColonAndDashForms() {
        XCTAssertEqual(LibraryItem.displayTitle("Dungeon Crawler Carl [Unabridged]"), "Dungeon Crawler Carl")
        XCTAssertEqual(LibraryItem.displayTitle("Dungeon Crawler Carl: Unabridged"), "Dungeon Crawler Carl")
        XCTAssertEqual(LibraryItem.displayTitle("Dungeon Crawler Carl - Unabridged"), "Dungeon Crawler Carl")
        XCTAssertEqual(LibraryItem.displayTitle("Dungeon Crawler Carl \u{2014} Unabridged"), "Dungeon Crawler Carl")
    }

    func testDisplayTitleIsCaseInsensitiveAndTolerantOfSpacing() {
        XCTAssertEqual(LibraryItem.displayTitle("Project Hail Mary ( UNABRIDGED )  "), "Project Hail Mary")
        XCTAssertEqual(LibraryItem.displayTitle("Project Hail Mary(unabridged)"), "Project Hail Mary")
    }

    func testDisplayTitleLeavesOtherTitlesAlone() {
        XCTAssertEqual(LibraryItem.displayTitle("Project Hail Mary"), "Project Hail Mary")
        // The word elsewhere in the title is part of the title.
        XCTAssertEqual(LibraryItem.displayTitle("The Unabridged Journals of Sylvia Plath"),
                       "The Unabridged Journals of Sylvia Plath")
        XCTAssertEqual(LibraryItem.displayTitle("Unabridged Tales"), "Unabridged Tales")
        // A bare trailing word without punctuation is not treated as an edition marker.
        XCTAssertEqual(LibraryItem.displayTitle("Something Unabridged"), "Something Unabridged")
    }

    func testDisplayTitleNeverReturnsEmpty() {
        XCTAssertEqual(LibraryItem.displayTitle("(Unabridged)"), "(Unabridged)")
    }

    // MARK: - G3: chapter orientation as a remaining count

    func testChapterOrientationCountsRemainingChapters() {
        XCTAssertEqual(PlayerView.chapterOrientationLabel(index: 64, count: 82), "17 chapters left")
        XCTAssertEqual(PlayerView.chapterOrientationLabel(index: 0, count: 3), "2 chapters left")
    }

    func testChapterOrientationSingularAndLast() {
        XCTAssertEqual(PlayerView.chapterOrientationLabel(index: 80, count: 82), "1 chapter left")
        XCTAssertEqual(PlayerView.chapterOrientationLabel(index: 81, count: 82), "Last chapter")
        XCTAssertEqual(PlayerView.chapterOrientationLabel(index: 0, count: 1), "Last chapter")
    }

    func testChapterOrientationIsNilWithoutChapters() {
        XCTAssertNil(PlayerView.chapterOrientationLabel(index: 0, count: 0))
        XCTAssertNil(PlayerView.chapterOrientationLabel(index: 5, count: 5))
        XCTAssertNil(PlayerView.chapterOrientationLabel(index: -1, count: 5))
    }

    // MARK: - G7: month total from the per-day map

    private func stats(days: [String: Double]) -> ListeningStats {
        try! JSONDecoder().decode(ListeningStats.self, from: JSONSerialization.data(withJSONObject: ["days": days]))
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ ymd: String) -> Date {
        let f = DateFormatter()
        f.calendar = utc; f.timeZone = utc.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd)!
    }

    func testMonthTotalSumsOnlyTheContainingMonth() {
        let s = stats(days: ["2026-08-31": 600, "2026-09-01": 100, "2026-09-15": 250, "2026-09-30": 50, "2026-10-01": 999])
        XCTAssertEqual(s.monthTotal(containing: date("2026-09-04"), calendar: utc), 400)
        XCTAssertEqual(s.monthTotal(containing: date("2026-08-31"), calendar: utc), 600)
    }

    func testMonthTotalIgnoresNegativeAndUnparseableEntries() {
        let s = stats(days: ["2026-09-02": -30, "2026-09-03": 120, "not-a-date": 500])
        XCTAssertEqual(s.monthTotal(containing: date("2026-09-10"), calendar: utc), 120)
    }

    func testMonthTotalIsZeroWithoutDays() {
        let s = try! JSONDecoder().decode(ListeningStats.self, from: Data("{}".utf8))
        XCTAssertEqual(s.monthTotal(containing: date("2026-09-10"), calendar: utc), 0)
    }

    // MARK: - Pass 3 item 1: self-numbered chapter titles hide the index column
    //
    // The chapter sheet printed the array index beside the title, so a book whose
    // author numbers its own chapters read "65  63. Something Incredibly Questionable".

    func testSelfNumberedTitlesAreDetected() {
        XCTAssertTrue(Chapter.titlesAreSelfNumbered([
            "1. The Beginning", "2. The Middle", "3. The End"
        ]))
        // Every separator form seen in real libraries.
        XCTAssertTrue(Chapter.titlesAreSelfNumbered([
            "63. Something", "64: Something Else", "65) Another", "66 - Dash",
            "67 \u{2013} En Dash", "68 \u{2014} Em Dash", "69 Plain Space"
        ]))
    }

    func testChapterWordTitlesAreSelfNumbered() {
        XCTAssertTrue(Chapter.titlesAreSelfNumbered(["Chapter 1", "Chapter 2", "Chapter 3"]))
        XCTAssertTrue(Chapter.titlesAreSelfNumbered(["chapter 1: Dawn", "CHAPTER 2 - Dusk", "Chapter 3"]))
        // The word alone, or the word followed by a name, is not numbering.
        XCTAssertFalse(Chapter.titlesAreSelfNumbered(["Chapter", "Chapter One", "Chapter Two"]))
    }

    func testUnnumberedTitlesKeepTheIndex() {
        XCTAssertFalse(Chapter.titlesAreSelfNumbered([
            "Opening Credits", "The Long Road", "About the Author"
        ]))
        // Leading digits with nothing separating them from the name aren't numbering.
        XCTAssertFalse(Chapter.titlesAreSelfNumbered(["1984th Street", "2ndhand News"]))
    }

    func testSelfNumberingNeedsAClearMajority() {
        // A "Prologue" among numbered chapters must not bring the index column back...
        XCTAssertTrue(Chapter.titlesAreSelfNumbered([
            "Prologue", "1. One", "2. Two", "3. Three"
        ]))
        // ...and one stray numbered title must not take it away from an unnumbered book.
        XCTAssertFalse(Chapter.titlesAreSelfNumbered([
            "1. One", "The Long Road", "Opening Credits", "About the Author"
        ]))
        // Exactly half is not a clear majority.
        XCTAssertFalse(Chapter.titlesAreSelfNumbered(["1. One", "The Long Road"]))
    }

    func testSelfNumberingIgnoresBlankTitlesAndHandlesEmptyLists() {
        XCTAssertFalse(Chapter.titlesAreSelfNumbered([]))
        XCTAssertFalse(Chapter.titlesAreSelfNumbered(["", "   "]))
        // Blank titles (the decoder tolerates a missing one) don't dilute the majority.
        XCTAssertTrue(Chapter.titlesAreSelfNumbered(["", "  ", "1. One", "2. Two"]))
    }

    // MARK: - Pass 3 item 5: junk descriptions don't earn an About section
    //
    // Server metadata sometimes lands a scrap in `description`; one real library
    // rendered a whole About section whose body was the words "Chapter 84".

    func testJunkDescriptionIsNotMeaningful() {
        XCTAssertFalse(MediaMetadata.isMeaningfulDescription("Chapter 84"))
        XCTAssertFalse(MediaMetadata.isMeaningfulDescription("Book 1"))
        // Whitespace can't pad a scrap over the floor.
        XCTAssertFalse(MediaMetadata.isMeaningfulDescription("   Chapter 84        "))
    }

    func testNilOrBlankDescriptionIsNotMeaningful() {
        XCTAssertFalse(MediaMetadata.isMeaningfulDescription(nil))
        XCTAssertFalse(MediaMetadata.isMeaningfulDescription(""))
        XCTAssertFalse(MediaMetadata.isMeaningfulDescription("   \n\t "))
    }

    func testRealSynopsisIsMeaningful() {
        XCTAssertTrue(MediaMetadata.isMeaningfulDescription(
            "Jake was an office worker, until the world changed and the System arrived."))
        // Right at the twenty-character floor.
        XCTAssertTrue(MediaMetadata.isMeaningfulDescription("A short book synopsis"))
    }

    // MARK: - H1 (REVIEW_2026-09-04_UI.md Pass 3): the artwork square when the player scrolls
    //
    // At accessibility sizes the full player is allowed to scroll, so the cover stops being
    // "whatever vertical room is left over" and takes an explicit size instead. These pin
    // the clamps of that decision: the same 110…306pt range the fixed layout uses, a height
    // budget that keeps the title on the first screenful, and cassette's extra chrome coming
    // out of the budget before the square is solved for.

    func testAccessibilityArtworkKeepsFullSizeCoverWhenTheScreenHasRoom() {
        // iPhone 17 Pro-ish: a 354pt column (402 screen − 2×24 padding) on an 874pt screen.
        // 40% of 874 = 349.6, so the 306pt cap is what binds — the same maximum the
        // default-size layout aims for. This is H5's "the cover shrank to a thumbnail"
        // going away, not just H1's overlap.
        XCTAssertEqual(
            PlayerView.accessibilityArtworkSize(columnWidth: 354, availableHeight: 874,
                                                showsCassette: false),
            306, accuracy: 0.001)
    }

    func testAccessibilityArtworkTakesAtMostFortyPercentOfTheScreenHeight() {
        // A short screen: 40% of 500 = 200, under the 306 cap, so the budget binds and the
        // title is guaranteed to share the first screenful with the cover.
        XCTAssertEqual(
            PlayerView.accessibilityArtworkSize(columnWidth: 354, availableHeight: 500,
                                                showsCassette: false),
            200, accuracy: 0.001)
    }

    func testAccessibilityArtworkNeverDropsBelowTheRecognizableFloor() {
        // Below 110pt a cover stops being recognizable — the fixed layout's floor, kept.
        XCTAssertEqual(
            PlayerView.accessibilityArtworkSize(columnWidth: 354, availableHeight: 200,
                                                showsCassette: false),
            110, accuracy: 0.001)
        // A narrow column binds the same way.
        XCTAssertEqual(
            PlayerView.accessibilityArtworkSize(columnWidth: 90, availableHeight: 874,
                                                showsCassette: false),
            110, accuracy: 0.001)
    }

    func testAccessibilityArtworkPaysForCassetteChromeOutOfTheHeightBudget() {
        // The cassette renders taller than it is wide, so its fixed chrome (reel window +
        // paddings) comes off the budget before solving for the square, exactly as the
        // fixed layout does it — otherwise flipping the cover would resize it.
        let plain = PlayerView.accessibilityArtworkSize(columnWidth: 354, availableHeight: 700,
                                                        showsCassette: false)
        let cassette = PlayerView.accessibilityArtworkSize(columnWidth: 354, availableHeight: 700,
                                                           showsCassette: true)
        XCTAssertEqual(plain, 280, accuracy: 0.001)
        XCTAssertEqual(cassette, 280 - CassetteView.extraHeightBeyondWidth, accuracy: 0.001)
        XCTAssertLessThan(cassette, plain)
    }

    // MARK: - H2 (REVIEW_2026-09-04_UI.md Pass 3): the bottom toolbar's shared icon slot
    //
    // Every column in the row — the four SF Symbols and AirPlay's real `AVRoutePickerView`
    // — sits in this square. It has to stay ≥44pt (the HIG hit target, which the route
    // picker must physically be, since it hit-tests itself) and it has to be identical for
    // all five, or `HStack` centres each column on its own height and the icons misalign.

    func testToolbarIconSlotIsUnchangedAtTheDefaultTextSize() {
        // The 17pt glyph of `.large` (15pt before HL-7) must return exactly the literal 44 this replaced.
        XCTAssertEqual(PlayerView.toolbarIconSlotSide(forIconSize: 17), 44, accuracy: 0.001)
    }

    func testToolbarIconSlotNeverDropsBelowTheHitTargetFloor() {
        // The small end of Dynamic Type shrinks the glyph; the tap target may not follow.
        XCTAssertEqual(PlayerView.toolbarIconSlotSide(forIconSize: 7.4), 44, accuracy: 0.001)
        XCTAssertEqual(PlayerView.toolbarIconSlotSide(forIconSize: 0), 44, accuracy: 0.001)
    }

    func testToolbarIconSlotGrowsWithTheGlyphButIsCapped() {
        // Between the floor and the cap it tracks the glyph proportionally…
        XCTAssertEqual(PlayerView.toolbarIconSlotSide(forIconSize: 20), 44 * 20 / 17, accuracy: 0.001)
        // …and stops at 1.5×, so this secondary row can't grow taller than the transport
        // controls above it. AX1's ≈24.7pt glyph already wants 72pt; AX5's ≈46.8pt wants 137.
        XCTAssertEqual(PlayerView.toolbarIconSlotSide(forIconSize: 28), 66, accuracy: 0.001)
        XCTAssertEqual(PlayerView.toolbarIconSlotSide(forIconSize: 46.8), 66, accuracy: 0.001)
    }
}
