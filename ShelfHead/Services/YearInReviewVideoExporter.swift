import AVFoundation
import CoreMedia
import CoreVideo
import Observation
import SwiftUI
import UIKit

/// Batch 462: the optional soundtrack for the Year in Review video: a gentle synthesised pad
/// (sine chords that change with each scene, cross-faded on the same weights as the visuals).
/// Pure and deterministic. It is only ever *written into the exported file* when the user turns
/// "Add music" on in the sheet (default off); nothing plays.
nonisolated enum YearInReviewSoundtrack {
    static let sampleRate = 44_100

    /// One chord per scene, in `ReelTimeline.Scene` order (Hz).
    static let chords: [[Double]] = [
        [110.00, 164.81, 220.00, 261.63],   // Am
        [87.31, 130.81, 220.00, 329.63],    // Fmaj7
        [130.81, 196.00, 246.94, 329.63],   // Cmaj7
        [98.00, 146.83, 246.94, 369.99],    // Gmaj7
        [110.00, 164.81, 220.00, 329.63],   // Am
        [130.81, 196.00, 261.63, 329.63]    // C
    ]

    /// Mono 16-bit samples for the whole reel. Peak amplitude stays well under full scale.
    static func samples(duration: Double = ReelTimeline.duration) -> [Int16] {
        let count = Int(duration * Double(sampleRate))
        var out = [Int16](repeating: 0, count: count)
        let twoPi = 2 * Double.pi
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            var value = 0.0
            for (scene, weight) in ReelTimeline.weights(at: t) {
                let chord = chords[scene.rawValue]
                var chordValue = 0.0
                for (n, f) in chord.enumerated() {
                    // A slow shimmer per voice, so the pad breathes.
                    let tremolo = 0.75 + 0.25 * sin(twoPi * (0.11 + 0.03 * Double(n)) * t + Double(n))
                    chordValue += sin(twoPi * f * t) * tremolo
                }
                value += chordValue / Double(chord.count) * weight
            }
            let fadeIn = min(t / 1.5, 1)
            let fadeOut = min((duration - t) / 2.5, 1)
            let gain = 0.28 * ReelTimeline.ease(min(fadeIn, fadeOut))
            out[i] = Int16(max(-1, min(1, value * gain)) * Double(Int16.max))
        }
        return out
    }
}

/// Batch 462: renders the Year in Review reel frame by frame (`ImageRenderer`, on the main
/// actor) into a 1080×1920, 30 fps H.264 MP4 in the temp directory through `AVAssetWriter`.
///
/// Apple docs checked (scripts/appledoc.sh, 28 Oct 2026): `AVAssetWriterInputPixelBufferAdaptor`
/// is deprecated in iOS 27; its replacement `AVAssetWriter.inputPixelBufferReceiver(for:
/// pixelBufferAttributes:)` returning `AVAssetWriterInput.PixelBufferReceiver` is iOS 26+. So
/// iOS 26+ writes through the receiver, earlier systems through the adaptor. Swift only warns
/// about a deprecation at or above the deployment target (17.6), so the adaptor path is
/// warning-free on the iOS 27 SDK.
///
/// Cancellation is cooperative: cancel the `Task` running `export`; the writer is cancelled and
/// the half-written file deleted.
@MainActor
@Observable
final class YearInReviewVideoExporter {
    enum ExportError: Error {
        case cannotCreateWriter
        case cannotCreatePixelBuffer
        case writerFailed(String?)
    }

    /// 0…1 across the frames.
    private(set) var progress: Double = 0
    private(set) var isExporting = false

    static let width = 1080
    static let height = 1920

    /// A fresh temp URL for one export.
    nonisolated static func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfHead-Year-in-Review-\(UUID().uuidString.prefix(8)).mp4")
    }

    func export(data: YearInReviewReelData, includeMusic: Bool) async throws -> URL {
        isExporting = true
        progress = 0
        defer { isExporting = false }

        // Batch 469: with music on, the export hung at ~8%. One writer with a video and an audio
        // input interleaves the two, and the iOS 26 receiver's `append` waited on audio for good
        // (feeding audio ahead of every frame didn't free it, and the wait ignores cancellation).
        // So the tracks are now written apart and combined afterwards: the video alone (the path
        // that already worked), the soundtrack alone into an .m4a, then a passthrough export that
        // copies both into the final MP4 without re-encoding.
        let videoURL = try await writeVideo(data: data, progressShare: includeMusic ? 0.9 : 1)
        guard includeMusic else { return videoURL }
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let samples = await Task.detached(priority: .userInitiated) { YearInReviewSoundtrack.samples() }.value
        let audioURL = try await Self.writeSoundtrack(samples)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        progress = 0.95
        let url = try await Self.combine(videoURL: videoURL, audioURL: audioURL)
        progress = 1
        return url
    }

    /// The silent video track, rendered frame by frame. `progressShare` is how much of the
    /// 0…1 progress bar the frames fill.
    private func writeVideo(data: YearInReviewReelData, progressShare: Double) async throws -> URL {
        let url = Self.makeOutputURL()
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            throw ExportError.cannotCreateWriter
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.width,
            AVVideoHeightKey: Self.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: ReelTimeline.fps,
                AVVideoMaxKeyFrameIntervalKey: ReelTimeline.fps
            ] as [String: Any]
        ])
        videoInput.expectsMediaDataInRealTime = false

        let sink: FrameSink
        if #available(iOS 26.0, *) {
            sink = ReceiverFrameSink(writer: writer, input: videoInput)
        } else {
            sink = AdaptorFrameSink(writer: writer, input: videoInput)
        }

        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription) }
        writer.startSession(atSourceTime: .zero)

        do {
            let renderer = ImageRenderer(content: YearInReviewReel(data: data, time: 0))
            renderer.scale = 1
            renderer.isOpaque = true
            let total = ReelTimeline.frameCount
            for frame in 0..<total {
                try Task.checkCancellation()
                renderer.content = YearInReviewReel(data: data, time: ReelTimeline.time(forFrame: frame))
                let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(ReelTimeline.fps))
                try await sink.append(at: time) { buffer in
                    if let cg = renderer.cgImage { Self.draw(cg, into: buffer) }
                }
                progress = Double(frame + 1) / Double(total) * progressShare
                await Task.yield()
            }
            sink.finish()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writerFailed(writer.error?.localizedDescription)
        }
        return url
    }

    /// Encodes the soundtrack on its own (AAC, mono, 44.1 kHz) into a temp .m4a.
    private static func writeSoundtrack(_ samples: [Int16]) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfHead-Year-in-Review-\(UUID().uuidString.prefix(8)).m4a")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { throw ExportError.cannotCreateWriter }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: YearInReviewSoundtrack.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ExportError.cannotCreateWriter }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription) }
        writer.startSession(atSourceTime: .zero)
        do {
            var offset = 0
            while offset < samples.count {
                let end = min(offset + YearInReviewSoundtrack.sampleRate, samples.count)
                try await appendAudio(samples[offset..<end], startFrame: offset, to: input, writer: writer)
                offset = end
            }
            input.markAsFinished()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writerFailed(writer.error?.localizedDescription)
        }
        return url
    }

    /// Copies the video track and the soundtrack into one MP4 without re-encoding.
    /// Apple docs checked (scripts/appledoc.sh, 28 Oct 2026): `AVAssetExportSession.export(to:as:
    /// isolation:)` lists iOS 13.0+, throws on cancel, and cancels with its parent task.
    private static func combine(videoURL: URL, audioURL: URL) async throws -> URL {
        let video = AVURLAsset(url: videoURL)
        let audio = AVURLAsset(url: audioURL)
        guard let videoTrack = try await video.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audio.loadTracks(withMediaType: .audio).first else {
            throw ExportError.writerFailed("Missing track")
        }
        let duration = try await video.load(.duration)
        let audioDuration = try await audio.load(.duration)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.cannotCreateWriter
        }
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration)),
                                      of: audioTrack, at: .zero)

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.cannotCreateWriter
        }
        let url = makeOutputURL()
        try? FileManager.default.removeItem(at: url)
        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    // MARK: - Drawing

    /// Draws `image` into a locked BGRA pixel buffer.
    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base,
                                  width: CVPixelBufferGetWidth(buffer),
                                  height: CVPixelBufferGetHeight(buffer),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
    }

    // MARK: - Audio

    private static func appendAudio(_ samples: ArraySlice<Int16>, startFrame: Int,
                                    to input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        guard let buffer = makeAudioSampleBuffer(samples, startFrame: startFrame) else { return }
        try await waitUntilReady(input, writer: writer)
        guard input.append(buffer) else { throw ExportError.writerFailed(writer.error?.localizedDescription) }
    }

    /// Polls `isReadyForMoreMediaData`, failing rather than spinning forever when the writer has
    /// failed or the input stays stalled for 10 s (Batch 469: the old loop could wait for good).
    static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        var waited = 0
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw ExportError.writerFailed(writer.error?.localizedDescription) }
            guard waited < 2_000 else { throw ExportError.writerFailed("Timed out waiting for the writer") }
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
    }

    nonisolated private static func makeAudioSampleBuffer(_ samples: ArraySlice<Int16>, startFrame: Int) -> CMSampleBuffer? {
        let rate = Double(YearInReviewSoundtrack.sampleRate)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr, let format else { return nil }
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { return nil }
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(YearInReviewSoundtrack.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }
}

// MARK: - Frame sinks

/// Where finished frames go: the iOS 26+ pixel-buffer receiver or the older adaptor. The buffer
/// is created inside `append` (from a pool) and filled by the caller's closure, so a new buffer
/// is never shared across the two sides.
@MainActor
private protocol FrameSink: AnyObject {
    func append(at time: CMTime, fill: (CVPixelBuffer) -> Void) async throws
    func finish()
}

/// A BGRA pool for 1080×1920 frames.
@MainActor
private final class FramePool {
    private var pool: CVPixelBufferPool?

    init() {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: YearInReviewVideoExporter.width,
            kCVPixelBufferHeightKey as String: YearInReviewVideoExporter.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw YearInReviewVideoExporter.ExportError.cannotCreatePixelBuffer }
        return buffer
    }
}

@available(iOS 26.0, *)
@MainActor
private final class ReceiverFrameSink: FrameSink {
    private let receiver: AVAssetWriterInput.PixelBufferReceiver
    private let pool = FramePool()

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        // Attaches `input` to the writer (no `add(_:)`), as documented.
        receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
    }

    func append(at time: CMTime, fill: (CVPixelBuffer) -> Void) async throws {
        let buffer = try pool.makeBuffer()
        fill(buffer)
        // Suspends until the encoder can take another frame.
        try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: buffer), with: time)
    }

    func finish() { receiver.finish() }
}

@MainActor
private final class AdaptorFrameSink: FrameSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pool = FramePool()

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
    }

    func append(at time: CMTime, fill: (CVPixelBuffer) -> Void) async throws {
        let buffer = try pool.makeBuffer()
        fill(buffer)
        try await YearInReviewVideoExporter.waitUntilReady(input, writer: writer)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw YearInReviewVideoExporter.ExportError.writerFailed(nil)
        }
    }

    func finish() { input.markAsFinished() }
}
