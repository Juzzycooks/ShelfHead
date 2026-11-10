import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • CarPlayIndexingTests
// =============================================================================
//
// P-10 (REVIEW_2026-09-14_DESIGN.md): pins the two pure functions behind the
// alphabetical `sectionIndexTitle` rail and the Home "Continue Listening" promotion
// — `CarPlayCoordinator.alphabeticalBuckets(_:titleKey:)` and
// `.promotingContinueListening(_:)` — both `nonisolated static` on a `@MainActor`
// type, same extract-a-pure-function precedent as `CarPlayListWindowingTests`
// (`capShelvesToSystemLimit`, `listWindow`, …). The rendering half
// (`applyIndexedSections`, which turns these into live `CPListSection`s) isn't
// unit-tested here since it needs a live `CPListTemplate`.
final class CarPlayIndexingTests: XCTestCase {

    // MARK: - alphabeticalBuckets

    func testAlphabeticalBucketsGroupsByUppercasedFirstLetter() {
        let items = ["apple", "Avocado", "Banana", "cherry"]
        let buckets = CarPlayCoordinator.alphabeticalBuckets(items, titleKey: { $0 })
        XCTAssertEqual(buckets.map { $0.header }, ["A", "B", "C"])
        XCTAssertEqual(buckets[0].items, ["apple", "Avocado"], "grouping is case-insensitive but preserves original order within a bucket")
        XCTAssertEqual(buckets[1].items, ["Banana"])
        XCTAssertEqual(buckets[2].items, ["cherry"])
    }

    func testAlphabeticalBucketsSortsBucketsAlphabetically() {
        // Fed out of order on purpose — the function must sort the buckets
        // themselves even though it doesn't sort within a bucket.
        let items = ["Zulu", "Alpha", "Mike"]
        let buckets = CarPlayCoordinator.alphabeticalBuckets(items, titleKey: { $0 })
        XCTAssertEqual(buckets.map { $0.header }, ["A", "M", "Z"])
    }

    func testAlphabeticalBucketsCollapsesNonLetterLeadersIntoAHashBucket() {
        let items = ["1984", "Zebra", "42 Reasons", ""]
        let buckets = CarPlayCoordinator.alphabeticalBuckets(items, titleKey: { $0 })
        XCTAssertEqual(buckets.map { $0.header }, ["Z", "#"])
        XCTAssertEqual(buckets.last?.items, ["1984", "42 Reasons", ""], "digits, symbols, and an empty string all collapse into '#', in original order")
    }

    func testAlphabeticalBucketsHashBucketSortsLast() {
        let items = ["9 to 5", "Aardvark"]
        let buckets = CarPlayCoordinator.alphabeticalBuckets(items, titleKey: { $0 })
        XCTAssertEqual(buckets.map { $0.header }, ["A", "#"], "the '#' bucket must always sort after every lettered bucket")
    }

    func testAlphabeticalBucketsOnEmptyInputReturnsNoBuckets() {
        let buckets = CarPlayCoordinator.alphabeticalBuckets([String](), titleKey: { $0 })
        XCTAssertTrue(buckets.isEmpty)
    }

    func testAlphabeticalBucketsDoesNotDropOrDuplicateAnyItem() {
        let items = ["Beta", "beta", "Alpha", "1", "Zulu", "zzz"]
        let buckets = CarPlayCoordinator.alphabeticalBuckets(items, titleKey: { $0 })
        let flattened = buckets.flatMap { $0.items }
        XCTAssertEqual(flattened.count, items.count)
        XCTAssertEqual(Set(flattened), Set(items))
    }

    func testAlphabeticalBucketsTrimsWhitespaceBeforeReadingTheFirstCharacter() {
        let items = ["  Whitespace Leading"]
        let buckets = CarPlayCoordinator.alphabeticalBuckets(items, titleKey: { $0 })
        XCTAssertEqual(buckets.map { $0.header }, ["W"])
    }

    // MARK: - promotingContinueListening

    func testPromotingContinueListeningMovesItToTheFront() {
        let shelves: [(header: String, items: [Int])] = [
            (header: "Recently Added", items: [1, 2]),
            (header: "Continue Listening", items: [3, 4]),
            (header: "Discover", items: [5])
        ]
        let promoted = CarPlayCoordinator.promotingContinueListening(shelves)
        XCTAssertEqual(promoted.map { $0.header }, ["Continue Listening", "Recently Added", "Discover"])
        XCTAssertEqual(promoted[0].items, [3, 4], "the shelf's own items must travel with it, unchanged")
    }

    func testPromotingContinueListeningIsANoOpWhenAlreadyFirst() {
        let shelves: [(header: String, items: [Int])] = [
            (header: "Continue Listening", items: [1]),
            (header: "Recently Added", items: [2])
        ]
        let promoted = CarPlayCoordinator.promotingContinueListening(shelves)
        XCTAssertEqual(promoted.map { $0.header }, ["Continue Listening", "Recently Added"])
    }

    func testPromotingContinueListeningIsANoOpWhenAbsent() {
        let shelves: [(header: String, items: [Int])] = [
            (header: "Recently Added", items: [1]),
            (header: "Discover", items: [2])
        ]
        let promoted = CarPlayCoordinator.promotingContinueListening(shelves)
        XCTAssertEqual(promoted.map { $0.header }, ["Recently Added", "Discover"])
    }

    func testPromotingContinueListeningOnEmptyShelvesReturnsEmpty() {
        let shelves: [(header: String, items: [Int])] = []
        XCTAssertTrue(CarPlayCoordinator.promotingContinueListening(shelves).isEmpty)
    }

    func testPromotingContinueListeningPreservesRelativeOrderOfEverythingElse() {
        let shelves: [(header: String, items: [Int])] = [
            (header: "Recently Added", items: [1]),
            (header: "Discover", items: [2]),
            (header: "Continue Listening", items: [3]),
            (header: "Listen Again", items: [4])
        ]
        let promoted = CarPlayCoordinator.promotingContinueListening(shelves)
        XCTAssertEqual(promoted.map { $0.header }, ["Continue Listening", "Recently Added", "Discover", "Listen Again"])
    }
}
