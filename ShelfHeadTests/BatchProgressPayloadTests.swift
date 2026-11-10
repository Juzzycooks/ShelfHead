import XCTest
@testable import ShelfHead

final class BatchProgressPayloadTests: XCTestCase {
    private typealias P = AudiobookshelfAPI.BatchProgressPayload

    private func decode(_ data: Data) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testBodyContainsExactlyTheExpectedKeys() throws {
        let body = AudiobookshelfAPI.batchProgressBody([
            P(libraryItemId: "a", isFinished: true, currentTime: 10, progress: 1, duration: 10)
        ])
        let json = try decode(body)
        XCTAssertEqual(Set(json[0].keys), ["libraryItemId", "isFinished", "currentTime", "progress", "duration"])
        XCTAssertEqual(json[0]["libraryItemId"] as? String, "a")
        XCTAssertEqual(json[0]["isFinished"] as? Bool, true)
    }

    func testNilFieldsAreOmitted() throws {
        let body = AudiobookshelfAPI.batchProgressBody([P(libraryItemId: "a", isFinished: false)])
        let json = try decode(body)
        XCTAssertEqual(Set(json[0].keys), ["libraryItemId", "isFinished"])
    }

    func testChunkingAtFifty() {
        let items = (0..<120).map { P(libraryItemId: "\($0)", isFinished: true) }
        let chunks = AudiobookshelfAPI.batchChunks(items, size: 50)
        XCTAssertEqual(chunks.map(\.count), [50, 50, 20])
        XCTAssertEqual(chunks.flatMap { $0 }, items)
        XCTAssertEqual(AudiobookshelfAPI.batchChunks(Array(items.prefix(50)), size: 50).count, 1)
        XCTAssertEqual(AudiobookshelfAPI.batchChunks(Array(items.prefix(51)), size: 50).count, 2)
    }

    func testEmptyYieldsNoChunks() {
        XCTAssertTrue(AudiobookshelfAPI.batchChunks([], size: 50).isEmpty)
    }
}
