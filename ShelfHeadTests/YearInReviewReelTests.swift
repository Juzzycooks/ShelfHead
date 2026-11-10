import XCTest
@testable import ShelfHead

/// Batch 462: the Year in Review video timeline.
final class YearInReviewReelTests: XCTestCase {
    func testFrameCountIs900() {
        XCTAssertEqual(ReelTimeline.frameCount, 900)
        XCTAssertEqual(ReelTimeline.fps, 30)
    }

    func testFrameTimes() {
        XCTAssertEqual(ReelTimeline.time(forFrame: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(ReelTimeline.time(forFrame: 30), 1, accuracy: 1e-9)
        XCTAssertEqual(ReelTimeline.time(forFrame: 899), 899.0 / 30.0, accuracy: 1e-9)
        XCTAssertLessThan(ReelTimeline.time(forFrame: ReelTimeline.frameCount - 1), ReelTimeline.duration)
    }

    func testSceneBoundaries() {
        XCTAssertEqual(ReelTimeline.scene(at: 0).scene, .title)
        XCTAssertEqual(ReelTimeline.scene(at: 4.999).scene, .title)
        XCTAssertEqual(ReelTimeline.scene(at: 5).scene, .hours)
        XCTAssertEqual(ReelTimeline.scene(at: 10).scene, .topBooks)
        XCTAssertEqual(ReelTimeline.scene(at: 15).scene, .months)
        XCTAssertEqual(ReelTimeline.scene(at: 20).scene, .finished)
        XCTAssertEqual(ReelTimeline.scene(at: 25).scene, .closing)
        XCTAssertEqual(ReelTimeline.scene(at: 30).scene, .closing)
        XCTAssertEqual(ReelTimeline.scene(at: 99).scene, .closing)
        XCTAssertEqual(ReelTimeline.scene(at: -3).scene, .title)
    }

    func testLocalProgress() {
        XCTAssertEqual(ReelTimeline.scene(at: 0).localProgress, 0, accuracy: 1e-9)
        XCTAssertEqual(ReelTimeline.scene(at: 7.5).localProgress, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ReelTimeline.scene(at: 30).localProgress, 1, accuracy: 1e-9)
    }

    func testWeightsSumToOneEverywhere() {
        for frame in 0..<ReelTimeline.frameCount {
            let sum = ReelTimeline.weights(at: ReelTimeline.time(forFrame: frame)).reduce(0) { $0 + $1.weight }
            XCTAssertEqual(sum, 1, accuracy: 1e-9, "frame \(frame)")
        }
    }

    func testCrossFadeOnlyInLastHalfSecond() {
        XCTAssertEqual(ReelTimeline.weights(at: 4.4).count, 1)
        XCTAssertEqual(ReelTimeline.weights(at: 4.75).count, 2)
        let mid = ReelTimeline.weights(at: 4.75)
        XCTAssertEqual(mid[0].scene, .title)
        XCTAssertEqual(mid[1].scene, .hours)
        XCTAssertEqual(mid[0].weight, 0.5, accuracy: 1e-9)
        // The last scene never fades into anything.
        XCTAssertEqual(ReelTimeline.weights(at: 29.9).count, 1)
        XCTAssertEqual(ReelTimeline.weights(at: 30).first?.scene, .closing)
    }

    func testEaseAndReveal() {
        XCTAssertEqual(ReelTimeline.ease(-1), 0)
        XCTAssertEqual(ReelTimeline.ease(2), 1)
        XCTAssertEqual(ReelTimeline.ease(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ReelTimeline.reveal(0.1, delay: 0.2, length: 0.2), 0)
        XCTAssertEqual(ReelTimeline.reveal(0.5, delay: 0.2, length: 0.2), 1)
    }

    func testProgressClamps() {
        XCTAssertEqual(ReelTimeline.progress(of: .hours, at: 2), 0)
        XCTAssertEqual(ReelTimeline.progress(of: .hours, at: 7.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ReelTimeline.progress(of: .hours, at: 20), 1)
    }

    func testSoundtrackLengthAndHeadroom() {
        let samples = YearInReviewSoundtrack.samples(duration: 2)
        XCTAssertEqual(samples.count, 2 * YearInReviewSoundtrack.sampleRate)
        XCTAssertLessThan(Int(samples.map { abs(Int($0)) }.max() ?? 0), Int(Int16.max) / 2)
        XCTAssertEqual(YearInReviewSoundtrack.chords.count, ReelTimeline.Scene.allCases.count)
    }
}
