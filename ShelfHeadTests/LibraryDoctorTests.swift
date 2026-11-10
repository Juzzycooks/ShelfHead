import XCTest
@testable import ShelfHead

/// Batch 441: Library Doctor checks, and the `User` permission decode.
final class LibraryDoctorTests: XCTestCase {

    private func book(_ id: String, title: String? = nil, author: String? = nil, asin: String? = nil,
                      isbn: String? = nil, year: Int? = nil, cover: Bool = true,
                      series: [(String, Double?)] = [], issues: [ChapterHealthIssue] = [],
                      podcast: Bool = false, ebook: Bool = false) -> DoctorBook {
        DoctorBook(id: id, title: title ?? "Book \(id)", authorName: author, asin: asin, isbn: isbn,
                   publishedYear: year, hasCover: cover, isPodcast: podcast, isEbookOnly: ebook,
                   series: series.map { .init(name: $0.0, sequence: $0.1) }, chapterIssues: issues)
    }

    private func findings(_ books: [DoctorBook], _ kind: DoctorFindingKind) -> [DoctorFinding] {
        LibraryDoctor.diagnose(books: books).filter { $0.kind == kind }
    }

    // MARK: Normalisation and duplicates

    func testTitleNormalisation() {
        XCTAssertEqual(LibraryDoctor.normalizedTitle("The Name of the Wind (Unabridged)"), "name of the wind")
        XCTAssertEqual(LibraryDoctor.normalizedTitle("Café Müller - Unabridged"), "cafe muller")
        XCTAssertEqual(LibraryDoctor.normalizedTitle("A Game of Thrones!"), "game of thrones")
        XCTAssertEqual(LibraryDoctor.normalizedTitle("Anathem"), "anathem")
    }

    func testPrimaryAuthorNormalisation() {
        XCTAssertEqual(LibraryDoctor.normalizedPrimaryAuthor("Terry Pratchett, Neil Gaiman"), "terry pratchett")
        XCTAssertEqual(LibraryDoctor.normalizedPrimaryAuthor("Terry Pratchett & Neil Gaiman"), "terry pratchett")
        XCTAssertEqual(LibraryDoctor.normalizedPrimaryAuthor("José Saramago"), "jose saramago")
    }

    func testDuplicateByTitleAndAuthor() {
        let a = book("a", title: "The Hobbit (Unabridged)", author: "J.R.R. Tolkien")
        let b = book("b", title: "Hobbit", author: "J. R. R. Tolkien, Rob Inglis")
        let c = book("c", title: "Hobbit", author: "Someone Else")
        let result = findings([a, b, c], .duplicate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Set(result[0].itemIds), ["a", "b"])
        XCTAssertNil(result[0].fix)
    }

    func testDuplicateByAsinAndIsbnNotReportedTwice() {
        let a = book("a", title: "One", asin: "B001", isbn: "978-0-306-40615-7")
        let b = book("b", title: "Two", asin: "b001", isbn: "9780306406157")
        let result = findings([a, b], .duplicate)
        XCTAssertEqual(result.count, 1, "same pair via asin and isbn is one finding")
        if case .duplicate(let reason, _) = result[0].detail { XCTAssertEqual(reason, .asin) } else { XCTFail() }
    }

    func testEbookAndAudiobookAreNotDuplicates() {
        let a = book("a", title: "Dune", author: "Frank Herbert")
        let b = book("b", title: "Dune", author: "Frank Herbert", ebook: true)
        XCTAssertTrue(findings([a, b], .duplicate).isEmpty)
    }

    func testPodcastsAreSkipped() {
        let a = book("a", title: "Show", cover: false, podcast: true)
        let b = book("b", title: "Show", podcast: true)
        XCTAssertTrue(LibraryDoctor.diagnose(books: [a, b]).isEmpty)
    }

    // MARK: Cover

    func testMissingCover() {
        let result = findings([book("a", cover: false), book("b")], .missingCover)
        XCTAssertEqual(result.map(\.itemIds), [["a"]])
        XCTAssertEqual(result.first?.fix, .setCover(itemId: "a"))
    }

    // MARK: Series

    func testSeriesMissingDuplicateAndGap() {
        let s = "Saga"
        let books = [
            book("1", series: [(s, 1)]),
            book("2", series: [(s, 2)]),
            book("2b", series: [(s, 2)]),
            book("4", series: [(s, 4)]),
            book("x", series: [(s, nil)]),
        ]
        let missing = findings(books, .seriesMissingSequence)
        XCTAssertEqual(missing.map(\.itemIds), [["x"]])
        let dup = findings(books, .seriesDuplicateSequence)
        XCTAssertEqual(dup.count, 1)
        XCTAssertEqual(Set(dup[0].itemIds), ["2", "2b"])
        let gaps = findings(books, .seriesGap)
        XCTAssertEqual(gaps.count, 1)
        if case .seriesGap(_, let m) = gaps[0].detail { XCTAssertEqual(m, [3]) } else { XCTFail() }
        XCTAssertNil(gaps[0].fix, "gaps are informational, never renumbered")
    }

    func testSingleBookSeriesWithoutNumberIsFine() {
        XCTAssertTrue(findings([book("a", series: [("Solo", nil)])], .seriesMissingSequence).isEmpty)
    }

    func testWholeNumberGaps() {
        XCTAssertEqual(LibraryDoctor.wholeNumberGaps([1, 2, 4]), [3])
        XCTAssertEqual(LibraryDoctor.wholeNumberGaps([1, 1.5, 2]), [])
        XCTAssertEqual(LibraryDoctor.wholeNumberGaps([2, 5]), [3, 4])
        XCTAssertEqual(LibraryDoctor.wholeNumberGaps([3]), [])
    }

    func testProposedSequence() {
        typealias C = LibraryDoctor.SequenceCandidate
        let books = [C(id: "1", sequence: 1, publishedYear: 2010), C(id: "2", sequence: 2, publishedYear: 2012),
                     C(id: "new", sequence: nil, publishedYear: 2014)]
        XCTAssertEqual(LibraryDoctor.proposedSequence(for: "new", among: books), 3)
        // Unknown year: one past the highest.
        let noYear = [C(id: "1", sequence: 1, publishedYear: 2010), C(id: "3", sequence: 3, publishedYear: 2012),
                      C(id: "new", sequence: nil, publishedYear: nil)]
        XCTAssertEqual(LibraryDoctor.proposedSequence(for: "new", among: noYear), 4)
        // Earliest book, but 1 is taken: skip past it.
        let early = [C(id: "1", sequence: 1, publishedYear: 2012), C(id: "new", sequence: nil, publishedYear: 2005)]
        XCTAssertEqual(LibraryDoctor.proposedSequence(for: "new", among: early), 2)
        XCTAssertEqual(LibraryDoctor.proposedSequence(for: "new", among: [C(id: "new", sequence: nil, publishedYear: nil)]), 1)
    }

    func testSeriesDisplayParsing() {
        let one = LibraryDoctor.parseSeriesDisplay("Stormlight Archive #2")
        XCTAssertEqual(one, [.init(name: "Stormlight Archive", sequence: 2)])
        let two = LibraryDoctor.parseSeriesDisplay("Discworld #1, Witches #1.5")
        XCTAssertEqual(two, [.init(name: "Discworld", sequence: 1), .init(name: "Witches", sequence: 1.5)])
        XCTAssertEqual(LibraryDoctor.parseSeriesDisplay("Earth, Wind and Fire"),
                       [.init(name: "Earth, Wind and Fire", sequence: nil)])
    }

    func testSequenceFormat() {
        XCTAssertEqual(SeriesSequenceFormat.string(3), "3")
        XCTAssertEqual(SeriesSequenceFormat.string(1.5), "1.5")
    }

    // MARK: Chapters

    func testChapterIssuesPassThrough() {
        let result = findings([book("a", issues: [.none]), book("b", issues: [.overlong, .dropped]), book("c")], .badChapters)
        XCTAssertEqual(result.map(\.itemIds), [["a"], ["b"]])
        XCTAssertEqual(result[0].severity, .info)
        XCTAssertEqual(result[1].severity, .warning)
        XCTAssertEqual(result[1].fix, .chapters(itemId: "b"))
    }

    @MainActor
    func testSnapshotFromMinifiedItemUsesChapterHealth() throws {
        let json = """
        {"id":"i1","mediaType":"book","media":{"coverPath":null,"duration":36000,"numChapters":1,
        "metadata":{"title":"Long","authorName":"A","seriesName":"Saga #2","publishedYear":"2011"}}}
        """
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
        let snapshot = DoctorBook(item: item)
        XCTAssertFalse(snapshot.hasCover)
        XCTAssertEqual(snapshot.publishedYear, 2011)
        XCTAssertEqual(snapshot.series, [.init(name: "Saga", sequence: 2)])
        XCTAssertEqual(snapshot.chapterIssues, ChapterHealth.issues(
            chapters: [Chapter(id: 0, start: 0, end: 36000, title: "")], droppedCount: 0, bookDuration: 36000))
        XCTAssertTrue(snapshot.chapterIssues.contains(.single))
    }

    // MARK: User permissions

    func testUserDecodeWithPermissions() throws {
        let json = """
        {"id":"u","username":"root","type":"root","permissions":{"download":true,"update":true,"delete":false,
        "upload":true,"createEreader":true,"accessAllLibraries":true,"selectedTagsNotAccessible":false}}
        """
        let user = try JSONDecoder().decode(User.self, from: Data(json.utf8))
        XCTAssertTrue(user.isAdmin)
        XCTAssertTrue(user.canUpdateLibrary)
        XCTAssertTrue(user.canUpload)
        XCTAssertEqual(user.permissions?.delete, false)
    }

    func testUserDecodeWithoutPermissionsOrWithBadOnes() throws {
        let plain = try JSONDecoder().decode(User.self, from: Data(#"{"id":"u","username":"x","type":"user"}"#.utf8))
        XCTAssertNil(plain.permissions)
        XCTAssertFalse(plain.isAdmin)
        XCTAssertFalse(plain.canUpdateLibrary)
        let bad = try JSONDecoder().decode(User.self, from: Data(#"{"id":"u","username":"x","type":"user","permissions":"nope"}"#.utf8))
        XCTAssertNil(bad.permissions)
        let editor = try JSONDecoder().decode(User.self, from: Data(#"{"id":"u","username":"x","type":"user","permissions":{"update":true,"upload":"x"}}"#.utf8))
        XCTAssertTrue(editor.canUpdateLibrary)
        XCTAssertFalse(editor.canUpload)
    }
}
