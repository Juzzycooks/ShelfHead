import XCTest
@testable import ShelfHead

/// Batch 433: the pure decisions behind the "Previously On…" montage render and playback.
final class RecapPlaybackTests: XCTestCase {

    private func marks(_ spec: [(Double, Double)]) -> [RecapAudioManifest.Mark] {
        spec.map { RecapAudioManifest.Mark(offset: $0.0, duration: $0.1, item: .speech("x")) }
    }

    // MARK: Timeline

    func testLayoutPutsGapsBetweenItemsOnly() {
        let result = RecapTimeline.layout(durations: [10, 5, 8], gap: 0.6)
        XCTAssertEqual(result.slots[0].offset, 0)
        XCTAssertEqual(result.slots[1].offset, 10.6, accuracy: 0.0001)
        XCTAssertEqual(result.slots[2].offset, 16.2, accuracy: 0.0001)
        XCTAssertEqual(result.slots.map(\.duration), [10, 5, 8])
        XCTAssertEqual(result.total, 24.2, accuracy: 0.0001)
    }

    func testLayoutEmptyAndSingle() {
        XCTAssertEqual(RecapTimeline.layout(durations: []).total, 0)
        let single = RecapTimeline.layout(durations: [4])
        XCTAssertEqual(single.slots, [.init(offset: 0, duration: 4)])
        XCTAssertEqual(single.total, 4)
    }

    func testLayoutTreatsBadDurationsAsZero() {
        let result = RecapTimeline.layout(durations: [-3, .nan, 2], gap: 1)
        XCTAssertEqual(result.slots.map(\.duration), [0, 0, 2])
        XCTAssertEqual(result.total, 4, accuracy: 0.0001)
    }

    func testMarksPairItemsWithSlots() {
        let items: [RecapProgramItem] = [.speech("a"), .clip(start: 1, end: 2, text: "t")]
        let slots = RecapTimeline.layout(durations: [3, 7]).slots
        let marks = RecapTimeline.marks(items: items, slots: slots)
        XCTAssertEqual(marks[0].offset, 0)
        XCTAssertEqual(marks[1].offset, 3.6, accuracy: 0.0001)
        XCTAssertEqual(marks.map(\.duration), [3, 7])
        XCTAssertEqual(marks[1].item, items[1])
    }

    func testFadeRampsFullAndShortClips() {
        let long = RecapTimeline.fadeRamps(offset: 10, duration: 8)
        XCTAssertEqual(long, .init(inStart: 10, inDuration: 0.25, outStart: 17.75, outDuration: 0.25))
        let short = RecapTimeline.fadeRamps(offset: 0, duration: 0.3)
        XCTAssertEqual(short.inDuration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(short.outStart, 0.15, accuracy: 0.0001)
        XCTAssertEqual(RecapTimeline.fadeRamps(offset: 0, duration: 0).inDuration, 0)
    }

    // MARK: Clip source

    func testClipSourcePrefersLocalThenStream() {
        XCTAssertEqual(RecapClipSource.choose(hasLocalFile: true, hasStream: true), .local)
        XCTAssertEqual(RecapClipSource.choose(hasLocalFile: true, hasStream: false), .local)
        XCTAssertEqual(RecapClipSource.choose(hasLocalFile: false, hasStream: true), .stream)
        XCTAssertEqual(RecapClipSource.choose(hasLocalFile: false, hasStream: false), .none)
    }

    // MARK: Marks and skipping

    func testCurrentMarkIndex() {
        let m = marks([(0, 5), (5.6, 5), (11.2, 5)])
        XCTAssertEqual(RecapTimeline.currentMarkIndex(at: 0, marks: m), 0)
        XCTAssertEqual(RecapTimeline.currentMarkIndex(at: 5.3, marks: m), 0)   // in the gap: still the previous one
        XCTAssertEqual(RecapTimeline.currentMarkIndex(at: 5.6, marks: m), 1)
        XCTAssertEqual(RecapTimeline.currentMarkIndex(at: 99, marks: m), 2)
        XCTAssertNil(RecapTimeline.currentMarkIndex(at: 1, marks: []))
    }

    func testSkipForwardGoesToNextMarkOrFinishes() {
        let m = marks([(0, 5), (5.6, 5), (11.2, 5)])
        XCTAssertEqual(RecapTimeline.skipTarget(forward: true, elapsed: 2, marks: m), 5.6)
        XCTAssertEqual(RecapTimeline.skipTarget(forward: true, elapsed: 6, marks: m), 11.2)
        XCTAssertNil(RecapTimeline.skipTarget(forward: true, elapsed: 12, marks: m))
        XCTAssertNil(RecapTimeline.skipTarget(forward: true, elapsed: 0, marks: []))
    }

    func testSkipBackRestartsCurrentMarkAfterThreeSeconds() {
        let m = marks([(0, 5), (5.6, 8), (14.2, 5)])
        // 3.1 s into mark 1: restart it.
        XCTAssertEqual(RecapTimeline.skipTarget(forward: false, elapsed: 8.7, marks: m), 5.6)
        // Under 3 s in: counts as "just started", goes to the previous mark.
        XCTAssertEqual(RecapTimeline.skipTarget(forward: false, elapsed: 8.5, marks: m), 0)
        // First mark, just started: stays at the start.
        XCTAssertEqual(RecapTimeline.skipTarget(forward: false, elapsed: 1, marks: m), 0)
        // First mark, well in: restart.
        XCTAssertEqual(RecapTimeline.skipTarget(forward: false, elapsed: 4.5, marks: m), 0)
    }

    // MARK: Auto-play

    func testShouldAutoPlayTruthTable() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let away = now.addingTimeInterval(-4 * 86_400)
        let recent = now.addingTimeInterval(-3_600)
        func decide(setting: Bool = true, last: Date? = away, frontier: Double = 1_800,
                    offered: Date? = nil, rendered: Bool = true) -> Bool {
            RecapPlaybackController.shouldAutoPlay(settingOn: setting, lastListened: last, now: now,
                                                   frontier: frontier, lastOfferedAt: offered,
                                                   hasRenderedRecap: rendered)
        }
        XCTAssertTrue(decide())
        XCTAssertFalse(decide(setting: false), "setting off")
        XCTAssertFalse(decide(rendered: false), "never wait for rendering")
        XCTAssertFalse(decide(last: recent), "not away long enough")
        XCTAssertFalse(decide(last: nil), "unknown last listen")
        XCTAssertFalse(decide(frontier: 300), "too little heard")
        XCTAssertFalse(decide(offered: away.addingTimeInterval(60)), "already offered since that listen")
        XCTAssertTrue(decide(offered: away.addingTimeInterval(-60)), "offered before that listen")
    }

    func testCacheUsableUnlessSpeechOnlyFallbackNowImprovable() {
        XCTAssertTrue(RecapPlaybackController.cacheIsUsable(hasNarratorAudio: true, programHasClips: true, canCutNow: true))
        XCTAssertTrue(RecapPlaybackController.cacheIsUsable(hasNarratorAudio: false, programHasClips: false, canCutNow: true))
        XCTAssertTrue(RecapPlaybackController.cacheIsUsable(hasNarratorAudio: false, programHasClips: true, canCutNow: false))
        XCTAssertFalse(RecapPlaybackController.cacheIsUsable(hasNarratorAudio: false, programHasClips: true, canCutNow: true))
    }
}
