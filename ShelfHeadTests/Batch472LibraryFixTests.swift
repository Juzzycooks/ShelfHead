import XCTest
@testable import ShelfHead

/// Batch 472 review fixes (30 October 2026): Medium 31, LibraryDoctor loop, description newlines.
final class Batch472LibraryFixTests: XCTestCase {
    func testPlainTextDescriptionKeepsParagraphBreaks() {
        XCTAssertEqual("One\n\nTwo".strippingHTML, "One\n\nTwo")
        XCTAssertFalse("One\n\nTwo".looksLikeHTML)
    }

    func testHTMLDescriptionIsStillStripped() {
        XCTAssertTrue("<p>Hi <b>there</b></p>".looksLikeHTML)
        XCTAssertEqual("<p>Hi <b>there</b></p>".strippingHTML, "Hi there")
        XCTAssertTrue("Tom &amp; Jerry".looksLikeHTML)
    }

    func testProposedSequenceSurvivesHugeAndNonFiniteNumbers() {
        let books: [LibraryDoctor.SequenceCandidate] = [
            .init(id: "a", sequence: 1e300, publishedYear: 2000),
            .init(id: "b", sequence: .infinity, publishedYear: 2001),
            .init(id: "c", sequence: 2, publishedYear: 2002),
            .init(id: "x", sequence: nil, publishedYear: nil),
        ]
        XCTAssertEqual(LibraryDoctor.proposedSequence(for: "x", among: books), 3)
    }

    func testItemsInLibraryDropsOtherLibrariesAndUnknown() {
        func item(_ id: String, _ lib: String?) -> ShelfHead.LibraryItem {
            ShelfHead.LibraryItem(id: id, ino: nil, libraryId: lib, mediaType: "book", media: nil, numFiles: nil,
                        size: nil, addedAt: nil, updatedAt: nil, mediaProgress: nil)
        }
        let out = LibraryViewModel.itemsInLibrary([item("1", "L1"), item("2", "L2"), item("3", nil)], libraryId: "L1")
        XCTAssertEqual(out.map(\.id), ["1"])
    }
}
