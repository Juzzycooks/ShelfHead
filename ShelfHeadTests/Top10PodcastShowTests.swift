import XCTest
@testable import ShelfHead

/// L3: podcast show page decisions.
final class Top10PodcastShowTests: XCTestCase {

    private func ep(_ id: String, _ at: Int?) -> PodcastEpisode {
        PodcastEpisode(id: id, title: id, subtitle: nil, description: nil, publishedAt: at,
                       audioFile: nil, duration: nil)
    }

    func testNewestAndOldestOrder() {
        let eps = [ep("a", 100), ep("b", 300), ep("c", 200)]
        XCTAssertEqual(PodcastEpisodeList.visible(eps, filter: .all, order: .newestFirst, isFinished: { _ in false }).map(\.id), ["b", "c", "a"])
        XCTAssertEqual(PodcastEpisodeList.visible(eps, filter: .all, order: .oldestFirst, isFinished: { _ in false }).map(\.id), ["a", "c", "b"])
    }

    func testUnplayedFilterDropsFinished() {
        let eps = [ep("a", 100), ep("b", 300), ep("c", 200)]
        let out = PodcastEpisodeList.visible(eps, filter: .unplayed, order: .newestFirst, isFinished: { $0.id == "b" })
        XCTAssertEqual(out.map(\.id), ["c", "a"])
    }

    func testMissingDateSortsAsOldestAndTiesAreStable() {
        let eps = [ep("x", nil), ep("y", nil), ep("z", 5)]
        XCTAssertEqual(PodcastEpisodeList.visible(eps, filter: .all, order: .newestFirst, isFinished: { _ in false }).map(\.id), ["z", "x", "y"])
    }

    func testPlainDescription() {
        XCTAssertEqual(PodcastEpisodeList.plainDescription("<p>Hello &amp; <b>welcome</b></p>\n<p>Again</p>"), "Hello & welcome Again")
        XCTAssertNil(PodcastEpisodeList.plainDescription("<p> </p>"))
        XCTAssertNil(PodcastEpisodeList.plainDescription(nil))
    }

    func testPlaylistEntryIdIsUniquePerEpisode() {
        XCTAssertEqual(PlaylistEntry.makeID(itemId: "show", episodeId: nil), "show")
        XCTAssertEqual(PlaylistEntry.makeID(itemId: "show", episodeId: ""), "show")
        XCTAssertNotEqual(PlaylistEntry.makeID(itemId: "show", episodeId: "e1"),
                          PlaylistEntry.makeID(itemId: "show", episodeId: "e2"))
    }
}
