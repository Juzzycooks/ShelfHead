import XCTest
import AVFoundation
@testable import ShelfHead

/// Batch 469: with "Add music" on, the Year in Review export hung at ~8% (one writer interleaving
/// a video and an audio input). These run the real export end to end and check the tracks in the
/// finished file.
///
/// Batch 495: from 11 November these hung the suite for 13+ minutes: the iOS 26+
/// `PixelBufferReceiver.append` stayed suspended mid-export and ignored cancellation, so the old
/// 120 s watchdog (which only cancelled the task) did nothing. Each test now races the export
/// against a hard deadline and fails with a message instead of blocking, whether or not the
/// export responds to cancellation.
@MainActor
final class YearInReviewVideoExportTests: XCTestCase {
    /// A normal run takes 3–15 s in the simulator, up to ~50 s on a heavily loaded Mac.
    private static let deadline: Duration = .seconds(180)

    func testExportWithMusicFinishesWithAudioAndVideo() async throws { try await export(music: true) }
    func testExportWithoutMusicFinishesWithVideoOnly() async throws { try await export(music: false) }

    /// Cancelling during the frames ends the export promptly with `CancellationError`.
    func testCancelDuringFramesStopsPromptly() async throws {
        let exporter = YearInReviewVideoExporter()
        let task = Task { try await exporter.export(data: Self.reelData, includeMusic: true) }
        let started = ContinuousClock.now
        while exporter.progress < 0.1 {
            if ContinuousClock.now - started > Self.deadline {
                task.cancel()
                return XCTFail("Export made no progress within \(Self.deadline); it is stuck.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        let outcome = await Self.race(task, limit: .seconds(15))
        switch outcome {
        case nil:
            XCTFail("Export didn't stop within 15 s of being cancelled.")
        case .success(let url)?:
            try? FileManager.default.removeItem(at: url)
            XCTFail("Export finished despite being cancelled at \(exporter.progress).")
        case .failure(let error)?:
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
    }

    private static let reelData = YearInReviewReelData(
        year: 2026, totalSeconds: 360_000, booksPlayed: 12,
        topBooks: [.init(id: "a", title: "A Book", author: "Someone", seconds: 36_000)],
        months: (1...12).map { .init(id: $0, label: "M\($0)", minutes: Double($0 * 100)) },
        finishedBooks: [])

    private func export(music: Bool) async throws {
        let exporter = YearInReviewVideoExporter()
        let task = Task { try await exporter.export(data: Self.reelData, includeMusic: music) }
        guard let outcome = await Self.race(task, limit: Self.deadline) else {
            task.cancel()
            return XCTFail("Export (music \(music ? "on" : "off")) didn't finish within \(Self.deadline); stuck at "
                           + "progress \(exporter.progress). The task was cancelled and abandoned.")
        }
        let url = try outcome.get()
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

    /// The task's result, or nil when `limit` passes first. Never waits on the task beyond the
    /// limit, so a task that ignores cancellation can't block the test.
    private static func race(_ task: Task<URL, Error>, limit: Duration) async -> Result<URL, Error>? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<URL, Error>?, Never>) in
            let once = Once(continuation)
            Task { @MainActor in
                do { once.fire(.success(try await task.value)) } catch { once.fire(.failure(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.fire(nil)
            }
        }
    }

    @MainActor
    private final class Once {
        private var continuation: CheckedContinuation<Result<URL, Error>?, Never>?
        init(_ continuation: CheckedContinuation<Result<URL, Error>?, Never>) { self.continuation = continuation }
        func fire(_ value: Result<URL, Error>?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
