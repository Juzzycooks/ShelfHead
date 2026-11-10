import XCTest
@testable import ShelfHead

/// Batch 472: review Low (Playback) queue decoding and review Medium 14 next-chapter guard.
final class UpNextQueueFixesTests: XCTestCase {
    private func itemJSON(id: String) -> String { #"{"id":"\#(id)"}"# }

    func testDecodeQueueKeepsGoodEntries() throws {
        let data = Data("[\(itemJSON(id: "a")),\(itemJSON(id: "b"))]".utf8)
        XCTAssertEqual(PlayerViewModel.decodeQueue(data)?.map(\.id), ["a", "b"])
    }

    func testDecodeQueueDropsOnlyTheBadEntry() throws {
        let data = Data("[\(itemJSON(id: "a")),{\"id\":42},\(itemJSON(id: "c"))]".utf8)
        XCTAssertEqual(PlayerViewModel.decodeQueue(data)?.map(\.id), ["a", "c"])
    }

    func testDecodeQueueRejectsNonArray() {
        XCTAssertNil(PlayerViewModel.decodeQueue(Data("{}".utf8)))
    }

    func testHasNextChapter() throws {
        let json = #"[{"id":0,"start":0,"end":100,"title":"1"},{"id":1,"start":100,"end":200,"title":"2"}]"#
        let chapters = try JSONDecoder().decode([Chapter].self, from: Data(json.utf8))
        XCTAssertTrue(PlayerViewModel.hasNextChapter(chapters: chapters, currentTime: 50))
        XCTAssertFalse(PlayerViewModel.hasNextChapter(chapters: chapters, currentTime: 150))
        XCTAssertFalse(PlayerViewModel.hasNextChapter(chapters: [], currentTime: 0))
    }
}
