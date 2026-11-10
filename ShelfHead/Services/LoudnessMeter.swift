import AVFoundation
import Foundation

/// Batch 438: offline integrated loudness in the style of ITU-R BS.1770 / EBU R128: K-weighting,
/// 400 ms blocks every 100 ms, an absolute gate at -70 LUFS and a relative gate 10 LU below the
/// absolute-gated mean. Pure value type fed with audio chunks, so tests can run it on synthetic tones.
///
/// Simplifications (documented, not hidden): every channel has weight 1 (no surround weighting, no LFE
/// exclusion; audiobooks are mono or stereo), and a mono stream is counted as dual mono (power x2),
/// which is how it is heard through two speakers or headphones.
nonisolated struct LoudnessMeter {
    let sampleRate: Double
    let channelCount: Int
    private let shelf: BiquadCoefficients
    private let highPass: BiquadCoefficients
    private var states: [BiquadState]
    private let hopFrames: Int
    private var hopSums: [Double] = []      // mean power of each completed 100 ms hop
    private var currentHopSum = 0.0
    private var currentHopFrames = 0
    private(set) var blockPowers: [Double] = []

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = max(channelCount, 1)
        shelf = .kWeightingShelf(sampleRate: sampleRate)
        highPass = .kWeightingHighPass(sampleRate: sampleRate)
        states = [BiquadState](repeating: BiquadState(), count: self.channelCount * 2)
        hopFrames = max(Int(sampleRate * 0.1), 1)
    }

    /// Appends one chunk: `channels[c][frame]`.
    mutating func append(_ channels: [[Float]]) {
        guard let frames = channels.map(\.count).min(), frames > 0 else { return }
        let n = min(channels.count, channelCount)
        for f in 0..<frames {
            var power = 0.0
            for c in 0..<n {
                let y = states[c * 2 + 1].process(states[c * 2].process(Double(channels[c][f]), shelf), highPass)
                power += y * y
            }
            if n == 1 { power *= 2 }
            currentHopSum += power
            currentHopFrames += 1
            if currentHopFrames == hopFrames { finishHop() }
        }
    }

    private mutating func finishHop() {
        hopSums.append(currentHopSum / Double(hopFrames))
        currentHopSum = 0
        currentHopFrames = 0
        if hopSums.count >= 4 {
            let last4 = hopSums.suffix(4)
            blockPowers.append(last4.reduce(0, +) / 4)
        }
    }

    /// Gated integrated loudness in LUFS, or nil if no block passed the absolute gate.
    var integratedLoudness: Double? {
        let absolute = blockPowers.filter { LoudnessLeveller.lufs(fromPower: $0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let meanAbs = absolute.reduce(0, +) / Double(absolute.count)
        let relativeThreshold = LoudnessLeveller.lufs(fromPower: meanAbs) - 10
        let gated = absolute.filter { LoudnessLeveller.lufs(fromPower: $0) > relativeThreshold }
        guard !gated.isEmpty else { return nil }
        return LoudnessLeveller.lufs(fromPower: gated.reduce(0, +) / Double(gated.count))
    }

    /// Measures the first `maxSeconds` of an audio file. Blocking; call from a background task.
    static func measure(fileURL: URL, maxSeconds: Double = 600) -> Double? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let format = file.processingFormat     // Float32, non-interleaved
        let rate = format.sampleRate
        var meter = LoudnessMeter(sampleRate: rate, channelCount: Int(format.channelCount))
        let limit = AVAudioFramePosition(maxSeconds * rate)
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        while file.framePosition < min(file.length, limit) {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            let channels = (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
            meter.append(channels)
            if Task.isCancelled { return nil }
        }
        return meter.integratedLoudness
    }
}
