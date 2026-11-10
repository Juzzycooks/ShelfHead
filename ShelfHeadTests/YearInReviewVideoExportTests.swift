import XCTest
import AVFoundation
@testable import ShelfHead

/// Batch 469: with "Add music" on, the Year in Review export hung at ~8% (one writer interleaving
/// a video and an audio input). These run the real export end to end, with a watchdog, and check
/// the tracks in the finished file.
@MainActor
final class YearInReviewVideoExportTests: XCTestCase {
    func testExportWithMusicFinishesWithAudioAndVideo() async throws { try await export(music: true) }
    func testExportWithoutMusicFinishesWithVideoOnly() async throws { try await export(music: false) }

    private func export(music: Bool) async throws {
        let data = YearInReviewReelData(year: 2026, totalSeconds: 360_000, booksPlayed: 12,
                                        topBooks: [.init(id: "a", title: "A Book", author: "Someone", seconds: 36_000)],
                                        months: (1...12).map { .init(id: $0, label: "M\($0)", minutes: Double($0 * 100)) },
                                        finishedBooks: [])
        let exporter = YearInReviewVideoExporter()
        let task = Task { try await exporter.export(data: data, includeMusic: music) }
        let watchdog = Task { try await Task.sleep(for: .seconds(120)); task.cancel() }
        defer { watchdog.cancel() }

        let url = try await task.value
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, music ? 1 : 0)
        XCTAssertEqual(duration, ReelTimeline.duration, accuracy: 0.1)
        XCTAssertEqual(exporter.progress, 1, accuracy: 0.001)
    }
}
