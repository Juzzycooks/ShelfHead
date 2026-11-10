import XCTest
@testable import ShelfHead

/// Batch 443: CSV reader, Goodreads/StoryGraph parsers, export and library matching.
final class ReadingListCSVTests: XCTestCase {

    func testReaderHandlesQuotesCommasNewlinesAndBOM() {
        let text = "\u{FEFF}a,b,c\r\n\"x, y\",\"he said \"\"hi\"\"\",\"line1\nline2\"\r\n1,,3"
        let rows = ReadingListCSV.parse(text)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ["a", "b", "c"])
        XCTAssertEqual(rows[1], ["x, y", "he said \"hi\"", "line1\nline2"])
        XCTAssertEqual(rows[2], ["1", "", "3"])
    }

    func testCleanISBNStripsGoodreadsWrapping() {
        XCTAssertEqual(ReadingListCSV.cleanISBN("=\"0441013597\""), "0441013597")
        XCTAssertEqual(ReadingListCSV.cleanISBN("=\"9780441013593\""), "9780441013593")
        XCTAssertNil(ReadingListCSV.cleanISBN("=\"\""))
        XCTAssertNil(ReadingListCSV.cleanISBN("12345"))
    }

    func testGoodreadsWantToRead() {
        let csv = #"""
        Book Id,Title,Author,Author l-f,Additional Authors,ISBN,ISBN13,My Rating,Exclusive Shelf
        1,"Dune (Dune, #1)",Frank Herbert,"Herbert, Frank",,"=""0441013597""","=""9780441013593""",0,to-read
        2,Emma,Jane Austen,"Austen, Jane",,"=""""","=""""",4,read
        3,"Hail Mary, Project",Andy Weir,"Weir, Andy",,"=""""","=""""",0,to-read
        """#
        let entries = ReadingListCSV.wantToRead(fromCSV: csv)
        XCTAssertEqual(entries.map(\.title), ["Dune (Dune, #1)", "Hail Mary, Project"])
        XCTAssertEqual(entries[0].isbn, "9780441013593")
        XCTAssertNil(entries[1].isbn)
        XCTAssertEqual(entries[0].source, .goodreads)
    }

    func testStoryGraphWantToRead() {
        let csv = """
        Title,Authors,Contributors,ISBN/UID,Format,Read Status,Date Added
        Piranesi,Susanna Clarke,,9781635575637,digital,to-read,2026/01/02
        Dune,Frank Herbert,,,,read,2026/01/03
        """
        let entries = ReadingListCSV.wantToRead(fromCSV: csv)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "Piranesi")
        XCTAssertEqual(entries[0].isbn, "9781635575637")
        XCTAssertEqual(entries[0].source, .storygraph)
    }

    func testUnknownFileGivesNothing() {
        XCTAssertTrue(ReadingListCSV.wantToRead(fromCSV: "foo,bar\n1,2").isEmpty)
        XCTAssertTrue(ReadingListCSV.wantToRead(fromCSV: "").isEmpty)
    }

    func testMergedDoesNotDuplicate() {
        let a = WantToReadEntry(title: "Dune", author: "Frank Herbert", isbn: nil, source: .goodreads, url: nil)
        let merged = ReadingListCSV.merged([a], with: [a, WantToReadEntry(title: "Emma", author: "Jane Austen", isbn: nil, source: .goodreads, url: nil)])
        XCTAssertEqual(merged.count, 2)
    }

    func testExportFinishedGoodreadsFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC
        let csv = ReadingListCSV.exportFinished(items: [
            FinishedBookRow(title: "Hail Mary, Project", author: "Andy Weir", isbn: "9780593135204", rating: 5, dateRead: date),
            FinishedBookRow(title: "Say \"Hi\"", author: "A", isbn: nil, rating: nil, dateRead: nil)
        ], calendar: cal)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Title,Author,ISBN,My Rating,Date Read,Exclusive Shelf")
        XCTAssertEqual(lines[1], "\"Hail Mary, Project\",Andy Weir,9780593135204,5,2026/01/01,read")
        XCTAssertEqual(lines[2], "\"Say \"\"Hi\"\"\",A,,0,,read")
        // Round trip through the reader.
        XCTAssertEqual(ReadingListCSV.parse(csv)[1][0], "Hail Mary, Project")
    }

    func testOwnedMatchesLibraryByTitleAuthorAndIsbn() {
        let lib = [
            ReadingSiteMatcher.Candidate(id: "a", title: "Dune (Unabridged)", author: "Frank Herbert", isbn: nil, asin: nil),
            ReadingSiteMatcher.Candidate(id: "b", title: "Other", author: "Someone", isbn: "9781635575637", asin: nil)
        ]
        let entries = [
            WantToReadEntry(title: "Dune", author: "Frank Herbert", isbn: nil, source: .goodreads, url: nil),
            WantToReadEntry(title: "Piranesi", author: "Susanna Clarke", isbn: "1635575637", source: .storygraph, url: nil),
            WantToReadEntry(title: "Emma", author: "Jane Austen", isbn: nil, source: .goodreads, url: nil)
        ]
        let owned = ReadingListCSV.owned(entries, in: lib)
        XCTAssertEqual(owned[entries[0].id], "a")
        XCTAssertEqual(owned[entries[1].id], "b")
        XCTAssertNil(owned[entries[2].id])
    }
}
