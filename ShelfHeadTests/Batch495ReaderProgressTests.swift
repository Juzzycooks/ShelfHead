import XCTest
@testable import ShelfHead

/// Batch 495 (REVIEW 2026-11-11 L12): the server's `ebookProgress` is decoded, shown on
/// ebook-only records through `progress`, and drives Book Detail's Continue Reading label.
final class Batch495ReaderProgressTests: XCTestCase {

    private func decode(_ json: String) throws -> MediaProgress {
        try JSONDecoder().decode(MediaProgress.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    func testDecodesEbookFieldsFromServerShape() throws {
        // Shape of `MediaProgress.getOldMediaProgress()` for an ebook-only record.
        let mp = try decode("""
        {"id":"p1","libraryItemId":"li1","episodeId":null,"duration":0,"progress":0,"currentTime":0,
         "isFinished":false,"ebookLocation":"epubcfi(/6/4!/4/2)","ebookProgress":0.6,"lastUpdate":1700000000000}
        """)
        XCTAssertEqual(mp.ebookProgress, 0.6)
        XCTAssertEqual(mp.ebookLocation, "epubcfi(/6/4!/4/2)")
        XCTAssertEqual(mp.readingFraction, 0.6)
        // Batch 497: `progress` is exactly what the server sent; tiles pick the reading
        // fraction through `LibraryItem.shownProgress` (Batch497LibraryHomeTests).
        XCTAssertEqual(mp.progress, 0, "progress stays the listening fraction")
    }

    func testOlderServerWithoutEbookFieldsStillDecodes() throws {
        let mp = try decode(#"{"libraryItemId":"li1","progress":0.25,"currentTime":900,"duration":3600}"#)
        XCTAssertNil(mp.ebookProgress)
        XCTAssertNil(mp.ebookLocation)
        XCTAssertNil(mp.readingFraction)
        XCTAssertEqual(mp.progress, 0.25)
    }

    func testLenientEbookFields() throws {
        let numericString = try decode(#"{"libraryItemId":"li1","ebookProgress":"0.4"}"#)
        XCTAssertEqual(numericString.ebookProgress, 0.4)
        let garbage = try decode(#"{"libraryItemId":"li1","ebookProgress":"abc","ebookLocation":12}"#)
        XCTAssertNil(garbage.ebookProgress)
        XCTAssertNil(garbage.ebookLocation)
        let nulls = try decode(#"{"libraryItemId":"li1","ebookProgress":null,"ebookLocation":null}"#)
        XCTAssertNil(nulls.ebookProgress)
        XCTAssertNil(nulls.progress)
    }

    func testAudioProgressWinsOverReading() throws {
        let mp = try decode("""
        {"libraryItemId":"li1","duration":3600,"progress":0.1,"currentTime":360,"ebookProgress":0.8}
        """)
        XCTAssertEqual(mp.progress, 0.1)
        XCTAssertEqual(mp.readingFraction, 0.8)
    }

    func testEncodeDecodeRoundTripKeepsEbookFields() throws {
        let original = try decode(#"{"libraryItemId":"li1","ebookProgress":0.3,"ebookLocation":"12"}"#)
        let again = try JSONDecoder().decode(MediaProgress.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(again.ebookProgress, 0.3)
        XCTAssertEqual(again.ebookLocation, "12")
        XCTAssertNil(again.progress, "Batch 497: no listening progress was sent, none is invented")
    }

    // Batch 497: `displayProgress` (the decode-time substitution) is gone; its replacement,
    // `LibraryItem.shownProgress`, is pinned in Batch497LibraryHomeTests.

    func testMemberwiseInitDefaultsHaveNoReading() {
        let mp = MediaProgress(id: "a", libraryItemId: "a", episodeId: nil, duration: 100, progress: 0.5,
                               currentTime: 50, isFinished: false, lastUpdate: nil, startedAt: nil, finishedAt: nil)
        XCTAssertNil(mp.ebookProgress)
        XCTAssertNil(mp.readingFraction)
    }

    // MARK: Book Detail label

    func testReadingPercentForButton() {
        XCTAssertNil(BookDetailView.readingPercent(fraction: nil))
        XCTAssertNil(BookDetailView.readingPercent(fraction: 0.004))
        XCTAssertNil(BookDetailView.readingPercent(fraction: 1))
        XCTAssertNil(BookDetailView.readingPercent(fraction: .infinity))
        XCTAssertEqual(BookDetailView.readingPercent(fraction: 0.6), 0.6)
        XCTAssertEqual(BookDetailView.readingPercent(fraction: 0.019), 0.01)
        XCTAssertEqual(BookDetailView.readingPercent(fraction: 0.29), 0.29, "binary 28.999… must not show as 28%")
        XCTAssertEqual(BookDetailView.readingPercent(fraction: 0.996), 0.99, "never rounds up to 100%")
    }

    // MARK: When the EPUB reader sends ebookProgress

    func testShouldSendReadingProgress() {
        // Nothing known: send once the reader has moved off the very start.
        XCTAssertFalse(EbookStore.shouldSendReadingProgress(current: 0, lastSent: nil, isFinal: false))
        XCTAssertTrue(EbookStore.shouldSendReadingProgress(current: 0.02, lastSent: nil, isFinal: false))
        // While reading: a whole percent.
        XCTAssertFalse(EbookStore.shouldSendReadingProgress(current: 0.405, lastSent: 0.40, isFinal: false))
        XCTAssertTrue(EbookStore.shouldSendReadingProgress(current: 0.41, lastSent: 0.40, isFinal: false))
        XCTAssertTrue(EbookStore.shouldSendReadingProgress(current: 0.30, lastSent: 0.40, isFinal: false))
        // On close: any visible change; none when unchanged.
        XCTAssertTrue(EbookStore.shouldSendReadingProgress(current: 0.406, lastSent: 0.40, isFinal: true))
        XCTAssertFalse(EbookStore.shouldSendReadingProgress(current: 0.40, lastSent: 0.40, isFinal: true))
        XCTAssertFalse(EbookStore.shouldSendReadingProgress(current: .nan, lastSent: nil, isFinal: true))
    }
}
