import XCTest
import CoreSpotlight
@testable import ShelfHead

/// Batch 406: pins the pure LibraryItem -> AudiobookEntity/Spotlight field mapping.
final class IndexedEntityTests: XCTestCase {

    func testFullFieldsMapToKeywordsAndDescription() {
        let f = AudiobookEntityFields(title: "Dune", authorName: "Frank Herbert",
                                      narratorName: "Scott Brick", seriesName: "Dune Chronicles")
        XCTAssertEqual(f.keywords, ["Frank Herbert", "Scott Brick", "Dune Chronicles"])
        XCTAssertTrue(f.contentDescription.hasPrefix("Frank Herbert · "))
        XCTAssertTrue(f.contentDescription.contains("Scott Brick"))
    }

    func testBlankNarratorAndSeriesBecomeNil() {
        let f = AudiobookEntityFields(title: "T", authorName: "A", narratorName: "  ", seriesName: "")
        XCTAssertNil(f.narrator)
        XCTAssertNil(f.series)
        XCTAssertEqual(f.keywords, ["A"])
        XCTAssertEqual(f.contentDescription, "A")
    }

    func testEntityRoundTripsFields() {
        let f = AudiobookEntityFields(title: "T", authorName: "A", narratorName: "N", seriesName: nil)
        let e = AudiobookEntity(id: "li_1", fields: f)
        XCTAssertEqual(e.id, "li_1")
        XCTAssertEqual(e.fields, f)
    }

    func testAttributeSetCarriesTextFields() {
        let f = AudiobookEntityFields(title: "T", authorName: "A", narratorName: "N", seriesName: "S")
        let a = SpotlightIndexer.attributeSet(for: f)
        XCTAssertEqual(a.title, "T")
        XCTAssertEqual(a.keywords ?? [], ["A", "N", "S"])
    }

    func testDeepLinkURL() {
        XCTAssertEqual(AudiobookEntity.deepLinkURL(forID: "li_abc")?.absoluteString, "shelfhead://book/li_abc")
    }
}
