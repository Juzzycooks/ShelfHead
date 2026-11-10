import XCTest
@testable import ShelfHead

/// Library browse plan §6.2 / §8 step 1 (2026-10-05): pins the sparse page window.
@MainActor
final class LibraryPageWindowTests: XCTestCase {

    private func book(_ id: String) throws -> ShelfHead.LibraryItem {
        let json = #"{"id": "\#(id)", "mediaType": "book", "media": {"metadata": {"title": "\#(id)"}, "duration": 3600, "numAudioFiles": 1}}"#
        return try JSONDecoder().decode(ShelfHead.LibraryItem.self, from: Data(json.utf8))
    }

    /// Items "b<from>" ..< "b<to>".
    private func books(_ from: Int, _ to: Int) throws -> [ShelfHead.LibraryItem] {
        try (from..<to).map { try book("b\($0)") }
    }

    private func pageResults(_ page: Int, total: Int, size: Int = 50) throws -> [ShelfHead.LibraryItem] {
        try books(page * size, min(total, (page + 1) * size))
    }

    func testPageMath() {
        let w = LibraryPageWindow(total: 3000)
        XCTAssertEqual(w.page(containing: 0), 0)
        XCTAssertEqual(w.page(containing: 49), 0)
        XCTAssertEqual(w.page(containing: 50), 1)
        XCTAssertEqual(w.page(containing: 2999), 59)
        XCTAssertEqual(w.pageCount, 60)
        XCTAssertEqual(LibraryPageWindow(total: 101).pageCount, 3)
        XCTAssertEqual(LibraryPageWindow(total: 101).expectedCount(inPage: 2), 1)
    }

    func testSlotStates() throws {
        var w = LibraryPageWindow(total: 120)
        w.merge(page: 0, results: try pageResults(0, total: 120), reportedTotal: 120)
        XCTAssertEqual(w.slot(at: 49).item?.id, "b49")
        guard case .placeholder(let index, let state) = w.slot(at: 50) else { return XCTFail() }
        XCTAssertEqual(index, 50)
        XCTAssertEqual(state, .notRequested)
        w.markInFlight(1)
        if case .placeholder(_, let s) = w.slot(at: 60) { XCTAssertEqual(s, .loading) } else { XCTFail() }
        w.markFailed(1)
        if case .placeholder(_, let s) = w.slot(at: 60) { XCTAssertEqual(s, .failed) } else { XCTFail() }
        w.markInFlight(1)
        w.markCancelled(1)
        if case .placeholder(_, let s) = w.slot(at: 60) { XCTAssertEqual(s, .notRequested) } else { XCTFail() }
    }

    func testPagesToFetchNearestFirstWithInFlightCap() throws {
        var w = LibraryPageWindow(total: 3000)
        // Visible items 1450...1460 are on page 29; window is 28...30; nearest first = 29, then 28, 30.
        XCTAssertEqual(w.pagesToFetch(visible: 1450...1460, prefetch: 1, maxInFlight: 5), [29, 28, 30])
        XCTAssertEqual(w.pagesToFetch(visible: 1450...1460), [29, 28])
        w.markInFlight(29)
        XCTAssertEqual(w.pagesToFetch(visible: 1450...1460), [28])
        w.markInFlight(28)
        XCTAssertEqual(w.pagesToFetch(visible: 1450...1460), [])
        // Clamped at the start.
        let fresh = LibraryPageWindow(total: 3000)
        XCTAssertEqual(fresh.pagesToFetch(visible: 0...10, prefetch: 1, maxInFlight: 5), [0, 1])
    }

    func testPagesToFetchSkipsLoadedAndFailedButIncludesStale() throws {
        var w = LibraryPageWindow(total: 300)
        w.merge(page: 1, results: try pageResults(1, total: 300), reportedTotal: 300)
        w.markFailed(2)
        XCTAssertEqual(w.pagesToFetch(visible: 50...60, prefetch: 1, maxInFlight: 5), [0])
        w.retry(2)
        XCTAssertEqual(w.pagesToFetch(visible: 50...60, prefetch: 1, maxInFlight: 5), [0, 2])
        w.markStale(1)
        XCTAssertEqual(w.pagesToFetch(visible: 50...60, prefetch: 1, maxInFlight: 5), [1, 0, 2])
    }

    func testMergeTotalDriftMarksOtherPagesStale() throws {
        var w = LibraryPageWindow(total: 200)
        XCTAssertEqual(w.merge(page: 0, results: try pageResults(0, total: 200), reportedTotal: 200), .ok)
        XCTAssertEqual(w.merge(page: 1, results: try pageResults(1, total: 200), reportedTotal: 200), .ok)
        let outcome = w.merge(page: 2, results: try books(100, 150), reportedTotal: 201)
        XCTAssertEqual(outcome, .totalChanged(old: 200, new: 201))
        XCTAssertEqual(w.total, 201)
        XCTAssertEqual(w.stale, [0, 1])
        XCTAssertFalse(w.stale.contains(2))
    }

    func testMergeShrinkDropsPagesPastTheEnd() throws {
        var w = LibraryPageWindow(total: 200)
        w.merge(page: 3, results: try books(150, 200), reportedTotal: 200)
        w.merge(page: 0, results: try books(0, 50), reportedTotal: 60)
        XCTAssertNil(w.pages[3])
        XCTAssertEqual(w.pageCount, 2)
    }

    func testFirstMergeSetsTotalWithoutStale() throws {
        var w = LibraryPageWindow()
        XCTAssertEqual(w.merge(page: 0, results: try books(0, 50), reportedTotal: 3000), .ok)
        XCTAssertEqual(w.total, 3000)
        XCTAssertTrue(w.stale.isEmpty)
    }

    func testDuplicateIdsDroppedAndPageMarkedStale() throws {
        var w = LibraryPageWindow(total: 200)
        w.merge(page: 0, results: try books(0, 50), reportedTotal: 200)
        // An insert shifted the boundary: page 1 repeats b49.
        let outcome = w.merge(page: 1, results: try books(49, 99), reportedTotal: 200)
        XCTAssertEqual(outcome, .duplicateIds)
        XCTAssertEqual(w.pages[1]?.count, 49)
        XCTAssertFalse(w.pages[1]?.contains { $0.id == "b49" } ?? true)
        XCTAssertEqual(w.stale, [1])
    }

    func testEvictionOnlyAboveCeiling() throws {
        var small = LibraryPageWindow(total: 5000)
        for p in [0, 30, 99] { small.merge(page: p, results: try pageResults(p, total: 5000), reportedTotal: 5000) }
        small.evict(keepingAround: 50, radius: 10, ceiling: 5000)
        XCTAssertEqual(Set(small.pages.keys), [0, 30, 99])

        var big = LibraryPageWindow(total: 6000)
        for p in [0, 38, 40, 50, 60, 62, 119] { big.merge(page: p, results: try pageResults(p, total: 6000), reportedTotal: 6000) }
        big.evict(keepingAround: 50, radius: 10, ceiling: 5000)
        XCTAssertEqual(Set(big.pages.keys), [40, 50, 60])
        if case .placeholder = big.slot(at: 0) {} else { XCTFail("evicted slot should be a placeholder") }
    }

    func testLoadedInOrderIsByPage() throws {
        var w = LibraryPageWindow(total: 150)
        w.merge(page: 2, results: try books(100, 150), reportedTotal: 150)
        w.merge(page: 0, results: try books(0, 50), reportedTotal: 150)
        let ids = w.loadedInOrder.map(\.id)
        XCTAssertEqual(ids.count, 100)
        XCTAssertEqual(ids.first, "b0")
        XCTAssertEqual(ids[49], "b49")
        XCTAssertEqual(ids[50], "b100")
        XCTAssertEqual(ids.last, "b149")
    }

    func testLocalWindowIsFullyLoaded() throws {
        let items = try books(0, 120)
        let w = LibraryPageWindow(local: items)
        XCTAssertEqual(w.total, 120)
        XCTAssertEqual(w.pageCount, 3)
        XCTAssertEqual(w.loadedInOrder.map(\.id), items.map(\.id))
        XCTAssertEqual(w.slot(at: 119).item?.id, "b119")
        XCTAssertEqual(w.pagesToFetch(visible: 0...10, prefetch: 2, maxInFlight: 5), [])
        XCTAssertEqual(LibraryPageWindow(local: []).total, 0)
    }
}
