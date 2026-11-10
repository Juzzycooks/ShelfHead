import XCTest
@testable import ShelfHead

/// Batch 444: filename fallback parsing and OPF metadata for the Upload screen.
final class UploadMetadataTests: XCTestCase {

    func testAuthorDashTitle() {
        let m = UploadFilenameParser.parse("Frank Herbert - Dune.m4b")
        XCTAssertEqual(m.author, "Frank Herbert")
        XCTAssertEqual(m.title, "Dune")
        XCTAssertNil(m.series)
    }

    func testTitleWithSeriesAndNumber() {
        let m = UploadFilenameParser.parse("The Name of the Wind (Kingkiller Chronicle 1).m4b")
        XCTAssertEqual(m.title, "The Name of the Wind")
        XCTAssertEqual(m.series, "Kingkiller Chronicle")
        XCTAssertEqual(m.sequence, "1")
    }

    func testAuthorTitleAndSeriesTogether() {
        let m = UploadFilenameParser.parse("Brandon Sanderson - The Way of Kings [Stormlight Archive #1].mp3")
        XCTAssertEqual(m.author, "Brandon Sanderson")
        XCTAssertEqual(m.title, "The Way of Kings")
        XCTAssertEqual(m.series, "Stormlight Archive")
        XCTAssertEqual(m.sequence, "1")
    }

    func testSeriesWithBookWordAndDecimal() {
        let m = UploadFilenameParser.parse("Title (Some Series, Book 2.5).m4b")
        XCTAssertEqual(m.series, "Some Series")
        XCTAssertEqual(m.sequence, "2.5")
    }

    func testYearInParenthesesIsNotASeries() {
        let m = UploadFilenameParser.parse("Some Book (2019).m4b")
        XCTAssertNil(m.series)
        XCTAssertEqual(m.title, "Some Book (2019)")
    }

    func testBareBookNumberIsNotASeries() {
        XCTAssertNil(UploadFilenameParser.parse("Title (Book 2).m4b").series)
    }

    func testTrackNumberIsNotAnAuthor() {
        let m = UploadFilenameParser.parse("01 - The Hobbit.mp3")
        XCTAssertNil(m.author)
        XCTAssertEqual(m.title, "The Hobbit")
        XCTAssertNil(UploadFilenameParser.parse("Track 3 - Intro.mp3").author)
    }

    func testUnderscoresAndWhitespace() {
        let m = UploadFilenameParser.parse("Ursula_K_Le_Guin  -  A_Wizard_of_Earthsea.m4b")
        XCTAssertEqual(m.author, "Ursula K Le Guin")
        XCTAssertEqual(m.title, "A Wizard of Earthsea")
    }

    func testEnDashSeparatorAndPlainTitle() {
        XCTAssertEqual(UploadFilenameParser.parse("A \u{2013} B.m4b").author, "A")
        let plain = UploadFilenameParser.parse("Just A Title.epub")
        XCTAssertEqual(plain.title, "Just A Title")
        XCTAssertNil(plain.author)
        XCTAssertEqual(UploadFilenameParser.parse("Well-Known.m4b").title, "Well-Known")
    }

    func testEmptyName() {
        XCTAssertEqual(UploadFilenameParser.parse("  "), UploadMetadata())
    }

    func testCommonOfNumberedParts() {
        let m = UploadFilenameParser.parseCommon(of: ["Frank Herbert - Dune - Part 01.mp3",
                                                      "Frank Herbert - Dune - Part 02.mp3",
                                                      "Frank Herbert - Dune - Part 10.mp3"])
        XCTAssertEqual(m.author, "Frank Herbert")
        XCTAssertEqual(m.title, "Dune")
    }

    func testCommonOfPlainPartsKeepsTitle() {
        XCTAssertEqual(UploadFilenameParser.parseCommon(of: ["Dune Part 1.mp3", "Dune Part 2.mp3"]).title, "Dune")
    }

    func testCommonKeepsFirstWhenNothingShared() {
        XCTAssertEqual(UploadFilenameParser.parseCommon(of: ["Alpha.mp3", "Omega.mp3"]).title, "Alpha")
        XCTAssertEqual(UploadFilenameParser.parseCommon(of: ["Only.mp3"]).title, "Only")
        XCTAssertEqual(UploadFilenameParser.parseCommon(of: []), UploadMetadata())
    }

    func testFillingPrefersOwnFields() {
        let a = UploadMetadata(title: "Tag Title", author: nil, series: nil, sequence: nil)
        let b = UploadMetadata(title: "File Title", author: "File Author", series: "S", sequence: "3")
        let merged = a.filling(from: b)
        XCTAssertEqual(merged.title, "Tag Title")
        XCTAssertEqual(merged.author, "File Author")
        XCTAssertEqual(merged.series, "S")
        XCTAssertEqual(merged.sequence, "3")
        XCTAssertEqual(UploadMetadata(title: "  ").filling(from: b).title, "File Title")
    }

    // MARK: OPF

    func testContainerRootfilePath() {
        let xml = """
        <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        XCTAssertEqual(OPFMetadataParser.rootfilePath(inContainer: Data(xml.utf8)), "OEBPS/content.opf")
    }

    func testOPFCalibreSeries() {
        let xml = """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Dune</dc:title><dc:creator opf:role="aut">Frank Herbert</dc:creator><dc:creator>Second</dc:creator>
        <meta name="calibre:series" content="Dune Chronicles"/><meta name="calibre:series_index" content="1.0"/>
        </metadata></package>
        """
        let m = OPFMetadataParser.parse(Data(xml.utf8))
        XCTAssertEqual(m.title, "Dune")
        XCTAssertEqual(m.author, "Frank Herbert")
        XCTAssertEqual(m.series, "Dune Chronicles")
        XCTAssertEqual(m.sequence, "1.0")
    }

    func testOPFEpub3Collection() {
        let xml = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Book</dc:title><dc:creator>A. Writer</dc:creator>
        <meta property="belongs-to-collection" id="c01">The Saga</meta>
        <meta refines="#c01" property="collection-type">series</meta>
        <meta refines="#c01" property="group-position">4</meta>
        </metadata></package>
        """
        let m = OPFMetadataParser.parse(Data(xml.utf8))
        XCTAssertEqual(m.series, "The Saga")
        XCTAssertEqual(m.sequence, "4")
    }

    func testOPFWithoutMetadataIsEmpty() {
        XCTAssertEqual(OPFMetadataParser.parse(Data("<package/>".utf8)), UploadMetadata())
        XCTAssertEqual(OPFMetadataParser.parse(Data("not xml".utf8)), UploadMetadata())
    }
}
