import AVFoundation
import CoreMedia
import MediaToolbox
import os

// Batch 438: the tap's DSP, rebuilt. Real RBJ-cookbook biquads (the old one-pole tone control
// was chosen because a biquad "couldn't be verified here"; the coefficients are now pinned by
// `DialogueDSPTests`), plus dialogue enhancement (HP 90 Hz, -3 dB at 300 Hz, +4 dB presence at
// 2.8 kHz, soft compressor) and a slow K-weighted loudness leveller. Everything in this file down
// to `AudioTapContext` is pure, `nonisolated` and allocation-free on the render path.

// MARK: - Biquad

/// One second-order section, RBJ "Audio EQ Cookbook" coefficients, normalised so a0 == 1.
nonisolated struct BiquadCoefficients: Equatable {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    private static func normalised(_ b0: Double, _ b1: Double, _ b2: Double,
                                   _ a0: Double, _ a1: Double, _ a2: Double) -> BiquadCoefficients {
        BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let c = cos(w0), alpha = sin(w0) / (2 * q)
        return normalised((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let c = cos(w0), alpha = sin(w0) / (2 * q)
        return normalised(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
    }

    /// Shelf slope S = 1 is the steepest monotonic shelf (the cookbook default).
    static func lowShelf(frequency: Double, gainDB: Double, slope: Double = 1, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let c = cos(w0)
        let alpha = sin(w0) / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2)
        let t = 2 * sqrt(a) * alpha
        return normalised(a * ((a + 1) - (a - 1) * c + t),
                          2 * a * ((a - 1) - (a + 1) * c),
                          a * ((a + 1) - (a - 1) * c - t),
                          (a + 1) + (a - 1) * c + t,
                          -2 * ((a - 1) + (a + 1) * c),
                          (a + 1) + (a - 1) * c - t)
    }

    static func highShelf(frequency: Double, gainDB: Double, slope: Double = 1, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let c = cos(w0)
        let alpha = sin(w0) / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2)
        let t = 2 * sqrt(a) * alpha
        return normalised(a * ((a + 1) + (a - 1) * c + t),
                          -2 * a * ((a - 1) + (a + 1) * c),
                          a * ((a + 1) + (a - 1) * c - t),
                          (a + 1) - (a - 1) * c + t,
                          2 * ((a - 1) - (a + 1) * c),
                          (a + 1) - (a - 1) * c - t)
    }

    /// |H(e^jw)| at `frequency`, for tests and sanity checks.
    func magnitude(atFrequency frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return (nr * nr + ni * ni).squareRoot() / (dr * dr + di * di).squareRoot()
    }

    /// K-weighting stage 1 (the "head" high shelf, +4 dB) from ITU-R BS.1770, derived for any rate.
    static func kWeightingShelf(sampleRate: Double) -> BiquadCoefficients {
        let f0 = 1681.974450955533, q = 0.7071752369554196, g = 3.999843853973347
        let k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return BiquadCoefficients(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                                  b2: (vh - vb * k / q + k * k) / a0,
                                  a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }

    /// K-weighting stage 2 (the RLB high-pass at ~38 Hz).
    static func kWeightingHighPass(sampleRate: Double) -> BiquadCoefficients {
        let f0 = 38.13547087602444, q = 0.5003270373238773
        let k = tan(Double.pi * f0 / sampleRate)
        let a0 = 1 + k / q + k * k
        return BiquadCoefficients(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }
}

/// Per-channel delay state (transposed direct form II, Double).
nonisolated struct BiquadState {
    var z1 = 0.0
    var z2 = 0.0

    @inline(__always)
    mutating func process(_ x: Double, _ c: BiquadCoefficients) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

// MARK: - Compressor

/// Soft-knee downward compressor: a static gain curve plus an attack/release gain smoother.
nonisolated struct SoftKneeCompressor {
    var thresholdDB = -24.0
    var ratio = 2.5
    var kneeDB = 12.0
    var makeupDB = 2.0
    var attackSeconds = 0.010
    var releaseSeconds = 0.160

    /// Output level in dB for an input level in dB (Giannoulis/Massberg/Reiss soft knee).
    static func outputLevelDB(inputDB x: Double, thresholdDB t: Double, ratio r: Double, kneeDB w: Double) -> Double {
        let over = x - t
        if 2 * over < -w { return x }
        if 2 * over > w { return t + over / r }
        return x + (1 / r - 1) * pow(over + w / 2, 2) / (2 * w)
    }

    /// Gain (dB, <= 0 before make-up) the static curve applies at `inputDB`.
    func staticGainDB(inputDB: Double) -> Double {
        Self.outputLevelDB(inputDB: inputDB, thresholdDB: thresholdDB, ratio: ratio, kneeDB: kneeDB) - inputDB
    }

    /// Smoothed gain-reduction state, dB (<= 0).
    private(set) var smoothedGainDB = 0.0

    mutating func reset() { smoothedGainDB = 0 }

    /// Linear gain (including make-up) for one frame whose linked peak is `peak`.
    @inline(__always)
    mutating func gain(forPeak peak: Float, attackCoeff: Double, releaseCoeff: Double) -> Float {
        let levelDB = peak > 1e-6 ? 20 * log10(Double(peak)) : -120
        let target = staticGainDB(inputDB: levelDB)
        let coeff = target < smoothedGainDB ? attackCoeff : releaseCoeff
        smoothedGainDB = coeff * smoothedGainDB + (1 - coeff) * target
        return Float(pow(10, (smoothedGainDB + makeupDB) / 20))
    }

    static func smoothingCoefficient(seconds: Double, sampleRate: Double) -> Double {
        exp(-1 / max(seconds * sampleRate, 1))
    }
}

// MARK: - Leveller

/// Slow loudness leveller: tracks the K-weighted short-term (~3 s) loudness of the input and moves a
/// gain toward `targetLUFS - measured`, limited to +/-`maxGainDB`, slew limited, and frozen while the
/// input is below the silence gate. Pure state machine: the tap feeds it block powers.
nonisolated struct LoudnessLeveller {
    var targetLUFS = -18.0
    var maxGainDB = 9.0
    var slewDBPerSecond = 1.5
    var silenceGateLUFS = -55.0
    var windowSeconds = 3.0

    private(set) var meanPower = 0.0
    private(set) var primed = false
    private(set) var gainDB = 0.0

    static func lufs(fromPower p: Double) -> Double { p > 0 ? -0.691 + 10 * log10(p) : -.infinity }
    static func power(fromLUFS l: Double) -> Double { pow(10, (l + 0.691) / 10) }

    /// Short-term loudness estimate (nil before any audible block).
    var measuredLUFS: Double? { primed ? Self.lufs(fromPower: meanPower) : nil }

    /// Starts from a measured whole-book loudness so the first seconds are already matched.
    mutating func seed(loudnessLUFS: Double) {
        meanPower = Self.power(fromLUFS: loudnessLUFS)
        primed = true
        gainDB = Self.clampedGain(target: targetLUFS, measured: loudnessLUFS, max: maxGainDB)
    }

    static func clampedGain(target: Double, measured: Double, max m: Double) -> Double {
        Swift.max(-m, Swift.min(m, target - measured))
    }

    /// Feed the mean K-weighted power of one block and the block's duration; returns the gain in dB.
    @discardableResult
    mutating func ingest(blockPower: Double, blockSeconds: Double) -> Double {
        guard Self.lufs(fromPower: blockPower) >= silenceGateLUFS else { return gainDB }  // frozen
        if primed {
            let alpha = 1 - exp(-blockSeconds / windowSeconds)
            meanPower += alpha * (blockPower - meanPower)
        } else {
            meanPower = blockPower
            primed = true
        }
        let desired = Self.clampedGain(target: targetLUFS, measured: Self.lufs(fromPower: meanPower), max: maxGainDB)
        let step = slewDBPerSecond * blockSeconds
        gainDB += Swift.max(-step, Swift.min(step, desired - gainDB))
        return gainDB
    }

    mutating func reset() {
        meanPower = 0
        primed = false
        gainDB = 0
    }
}

// MARK: - Settings

extension SettingsKeys {
    /// Batch 438: both default off; nothing changes the sound until the user turns one on.
    nonisolated static let dialogueEnhance = "settings_dialogueEnhance"
    nonisolated static let matchLoudness = "settings_matchLoudness"
}

extension SettingsStore {
    /// Clearer voices: high-pass, mid cut, presence lift and gentle compression.
    static var dialogueEnhance: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.dialogueEnhance) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.dialogueEnhance) }
    }
    /// Even volume across books: the slow leveller toward -18 LUFS.
    static var matchLoudness: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.matchLoudness) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.matchLoudness) }
    }
    /// True when the tap has something to do. A tap forces software processing for the whole
    /// track, so it is only attached when this is true.
    static var audioProcessingNeeded: Bool {
        volumeBoostDB != 0 || bassBoostDB != 0 || trebleBoostDB != 0 || dialogueEnhance || matchLoudness
    }
}

// MARK: - Render-path processor

/// Everything the tap does to one buffer, with all state preallocated in `init` (called from
/// `tapPrepare`, never from the render callback). Up to 8 channels; extra channels pass through.
nonisolated final class AudioChainProcessor: @unchecked Sendable {
    static let maxChannels = 8
    private static let filterStages = 5   // 0 HP, 1 mid cut, 2 presence, 3 bass shelf, 4 treble shelf

    struct Parameters: Equatable {
        var volumeLinear: Float = 1
        var bassDB: Double = 0
        var trebleDB: Double = 0
        var dialogue = false
        var level = false
        var seedGeneration = 0
        var seedLUFS = -18.0
    }

    let channelCount: Int
    let sampleRate: Double
    private var params = Parameters()
    private var applied = false
    private var coeffs = [BiquadCoefficients](repeating: .identity, count: AudioChainProcessor.filterStages)
    private let states: UnsafeMutablePointer<BiquadState>
    private let kShelf: BiquadCoefficients
    private let kHighPass: BiquadCoefficients
    private let kStates: UnsafeMutablePointer<BiquadState>
    private var compressor = SoftKneeCompressor()
    private let attackCoeff: Double
    private let releaseCoeff: Double
    private(set) var leveller = LoudnessLeveller()
    private var lastGain: Float = 1
    private var appliedSeedGeneration = 0
    private var primedGain = false

    init(channelCount: Int, sampleRate: Double) {
        self.channelCount = min(max(channelCount, 1), Self.maxChannels)
        self.sampleRate = sampleRate > 0 ? sampleRate : 44_100
        let n = Self.maxChannels * Self.filterStages
        states = .allocate(capacity: n)
        states.initialize(repeating: BiquadState(), count: n)
        kStates = .allocate(capacity: Self.maxChannels * 2)
        kStates.initialize(repeating: BiquadState(), count: Self.maxChannels * 2)
        kShelf = .kWeightingShelf(sampleRate: self.sampleRate)
        kHighPass = .kWeightingHighPass(sampleRate: self.sampleRate)
        attackCoeff = SoftKneeCompressor.smoothingCoefficient(seconds: compressor.attackSeconds, sampleRate: self.sampleRate)
        releaseCoeff = SoftKneeCompressor.smoothingCoefficient(seconds: compressor.releaseSeconds, sampleRate: self.sampleRate)
    }

    deinit {
        states.deallocate()
        kStates.deallocate()
    }

    /// Cheap (a few trig calls only when something actually changed); safe on the render thread.
    func apply(_ p: Parameters) {
        if applied, p == params { return }
        let dialogueTurnedOn = p.dialogue && !(applied && params.dialogue)
        if dialogueTurnedOn {
            compressor.reset()
            for i in 0..<(Self.maxChannels * 3) { states[i] = BiquadState() }
        }
        if !applied || p.dialogue != params.dialogue {
            coeffs[0] = .highPass(frequency: 90, q: 0.707, sampleRate: sampleRate)
            coeffs[1] = .peaking(frequency: 300, q: 1, gainDB: -3, sampleRate: sampleRate)
            coeffs[2] = .peaking(frequency: 2800, q: 0.9, gainDB: 4, sampleRate: sampleRate)
        }
        if !applied || p.bassDB != params.bassDB {
            coeffs[3] = p.bassDB == 0 ? .identity : .lowShelf(frequency: 120, gainDB: p.bassDB, sampleRate: sampleRate)
        }
        if !applied || p.trebleDB != params.trebleDB {
            coeffs[4] = p.trebleDB == 0 ? .identity : .highShelf(frequency: 6000, gainDB: p.trebleDB, sampleRate: sampleRate)
        }
        if p.level, !(applied && params.level) { leveller.reset(); primedGain = false }
        if p.level, p.seedGeneration != appliedSeedGeneration {
            appliedSeedGeneration = p.seedGeneration
            if !leveller.primed { leveller.seed(loudnessLUFS: p.seedLUFS) }
        }
        params = p
        applied = true
    }

    @inline(__always)
    private func run(stage: Int, channel: Int, data: UnsafeMutablePointer<Float>, frames: Int) {
        let c = coeffs[stage]
        var s = states[stage * Self.maxChannels + channel]
        for f in 0..<frames { data[f] = Float(s.process(Double(data[f]), c)) }
        states[stage * Self.maxChannels + channel] = s
    }

    /// Processes `frames` samples of each of `channels` non-interleaved float buffers in place.
    /// No allocation, no locks.
    func process(channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, count: Int, frames: Int) {
        let n = min(count, channelCount)
        guard n > 0, frames > 0 else { return }

        // 1. Measure the raw input for the leveller (K-weighted power, mono counted as dual mono).
        if params.level {
            var power = 0.0
            for ch in 0..<n {
                guard let d = channels[ch] else { continue }
                var s1 = kStates[ch * 2], s2 = kStates[ch * 2 + 1]
                var sum = 0.0
                for f in 0..<frames {
                    let y = s2.process(s1.process(Double(d[f]), kShelf), kHighPass)
                    sum += y * y
                }
                kStates[ch * 2] = s1; kStates[ch * 2 + 1] = s2
                power += sum / Double(frames)
            }
            if n == 1 { power *= 2 }
            leveller.ingest(blockPower: power, blockSeconds: Double(frames) / sampleRate)
        }

        // 2. Dialogue chain: HP, mid cut, presence per channel, then a linked compressor.
        if params.dialogue {
            for ch in 0..<n {
                guard let d = channels[ch] else { continue }
                run(stage: 0, channel: ch, data: d, frames: frames)
                run(stage: 1, channel: ch, data: d, frames: frames)
                run(stage: 2, channel: ch, data: d, frames: frames)
            }
            for f in 0..<frames {
                var peak: Float = 0
                for ch in 0..<n { if let d = channels[ch] { peak = max(peak, abs(d[f])) } }
                let g = compressor.gain(forPeak: peak, attackCoeff: attackCoeff, releaseCoeff: releaseCoeff)
                for ch in 0..<n { channels[ch]?[f] *= g }
            }
        }

        // 3. Tone shelves.
        if params.bassDB != 0 || params.trebleDB != 0 {
            for ch in 0..<n {
                guard let d = channels[ch] else { continue }
                if params.bassDB != 0 { run(stage: 3, channel: ch, data: d, frames: frames) }
                if params.trebleDB != 0 { run(stage: 4, channel: ch, data: d, frames: frames) }
            }
        }

        // 4. Volume boost x leveller gain, ramped across the block so changes never click.
        let levelLinear = params.level ? Float(pow(10, leveller.gainDB / 20)) : 1
        let target = params.volumeLinear * levelLinear
        if !primedGain { lastGain = target; primedGain = true }
        if target != 1 || lastGain != 1 {
            let step = (target - lastGain) / Float(frames)
            for ch in 0..<n {
                guard let d = channels[ch] else { continue }
                var g = lastGain
                for f in 0..<frames {
                    d[f] = max(-1, min(1, d[f] * g))
                    g += step
                }
            }
        } else if params.dialogue || params.bassDB != 0 || params.trebleDB != 0 {
            for ch in 0..<n { if let d = channels[ch] { for f in 0..<frames { d[f] = max(-1, min(1, d[f])) } } }
        }
        lastGain = target
    }
}

// MARK: - Tap context

/// Owns the parameters the main thread publishes and the processor the audio thread runs.
///
/// Thread-safety: parameters are written from the main thread and read on the Media Toolbox render
/// thread via `OSAllocatedUnfairLock.withLockIfAvailable` (never blocks: on a lost trylock race the
/// audio thread reuses the previous buffer's parameters, inaudible). `processor` is created in
/// `tapPrepare` and dropped in `tapUnprepare`, both sequenced by Media Toolbox before/after
/// `process` for a tap session (the same lifecycle guarantee the old `lpStates` buffer relied on).
final class AudioTapContext {
    private let paramsLock = OSAllocatedUnfairLock(initialState: AudioChainProcessor.Parameters())
    /// Read only from the audio thread; reused when the trylock is contended.
    private var lastKnown = AudioChainProcessor.Parameters()
    fileprivate var processor: AudioChainProcessor?

    /// Rebuilds the parameters from the current settings. Safe from the main thread at any time.
    func refreshFromSettings() {
        let volume = Float(pow(10, SettingsStore.volumeBoostDB / 20))
        let bass = SettingsStore.bassBoostDB, treble = SettingsStore.trebleBoostDB
        let dialogue = SettingsStore.dialogueEnhance, level = SettingsStore.matchLoudness
        paramsLock.withLock {
            $0.volumeLinear = volume; $0.bassDB = bass; $0.trebleDB = treble
            $0.dialogue = dialogue; $0.level = level
        }
    }

    /// Starts the leveller from a whole-book measurement (applies only if it hasn't heard audio yet).
    func seedLoudness(_ lufs: Double) {
        paramsLock.withLock { $0.seedLUFS = lufs; $0.seedGeneration += 1 }
    }

    fileprivate func currentParameters() -> AudioChainProcessor.Parameters {
        if let value = paramsLock.withLockIfAvailable({ $0 }) {
            lastKnown = value
            return value
        }
        return lastKnown
    }

    /// Set once by `tapPrepare` after validating the negotiated format; read only by `tapProcess`.
    fileprivate var isSampleFormatSupported = true
    /// Pointer table for the render callback, allocated in prepare.
    fileprivate var channelTable: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?

    fileprivate func prepare(channelCount: Int, sampleRate: Double) {
        release()
        processor = AudioChainProcessor(channelCount: channelCount, sampleRate: sampleRate)
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: AudioChainProcessor.maxChannels)
        table.initialize(repeating: nil, count: AudioChainProcessor.maxChannels)
        channelTable = table
    }

    fileprivate func release() {
        processor = nil
        channelTable?.deallocate()
        channelTable = nil
    }

    deinit { release() }
}

/// L3 (REVIEW_2026-08-20_UI_SECURITY.md): when the tap's format-reject path below
/// trips, volume boost/bass/treble silently stop working for the rest of the playback
/// session — previously logged only (`ShelfLog.error`), discoverable solely via
/// Settings → Diagnostics → Export. This is the one place that state is surfaced for a
/// View to read (`AudioSettingsSection` shows an inline note when it's set). Written
/// from `tapPrepare`, a Media Toolbox C callback that runs on neither the main thread
/// nor under any actor's isolation — `Task { @MainActor in }` is the same hop pattern
/// `AudioPlayerService` already uses elsewhere in this file's surrounding code for
/// crossing from a non-isolated callback into `@MainActor` state.
@MainActor
@Observable
final class AudioProcessingStatus {
    static let shared = AudioProcessingStatus()
    private init() {}
    /// True once any track this session has hit the tap's format-reject path. Sticky
    /// for the session (not reset per-track) since the underlying cause — a format
    /// Core Audio negotiated that this tap doesn't handle — isn't something the user
    /// did anything to fix by changing tracks.
    var formatUnsupportedThisSession = false
}


enum AudioProcessingChain {
    /// Builds an `AVMutableAudioMix` with a processing tap wired to `context`, scoped to
    /// `asset`'s first audio track. Returns nil if the asset has no audio track to
    /// attach to (shouldn't happen for anything already playable, but this is
    /// best-effort enrichment — never load-bearing for playback itself).
    static func makeAudioMix(for asset: AVAsset, context: AudioTapContext) async -> AVMutableAudioMix? {
        // Async `loadTracks(withMediaType:)` — the synchronous `tracks(withMediaType:)`
        // accessor is deprecated as of iOS 16 in favor of this.
        guard let trackID = try? await asset.loadTracks(withMediaType: .audio).first?.trackID else { return nil }

        // The tap owns `context` for as long as it exists — `clientInfo` is a `+1`
        // (`passRetained`) reference, released exactly once in `tapFinalize`. This is the
        // canonical MTAudioProcessingTap ownership pattern: Media Toolbox tears down the
        // outgoing `AVPlayerItem`/`AVAudioMix`/tap asynchronously on its own thread (see
        // `replaceCurrentItem` below), so `AudioPlayerService.audioTapContext` — a plain
        // `@MainActor` property — can be reassigned or nilled out on the main actor well
        // before Media Toolbox actually finalizes the old tap. If the tap only held an
        // `Unmanaged.passUnretained` reference, that window let `tapProcess` resurrect and
        // dereference an already-deallocated `AudioTapContext` (use-after-free) and free
        // its `lpStates` buffer a second time (double-free) on the real-time audio thread.
        // With a retained reference, the context stays alive until Media Toolbox itself
        // says it's done with it, regardless of what `AudioPlayerService` does in the
        // meantime. `AudioPlayerService.audioTapContext` remains solely for
        // `refreshAudioProcessing()` to reach the *currently active* context — it is no
        // longer the thing keeping the context alive.
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tapOut: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tapOut
        )
        guard status == noErr, let tapOut else {
            // Creation failed — Media Toolbox never took ownership, so the +1 from
            // `passRetained` above would otherwise leak (and `tapFinalize` will never run
            // to balance it).
            if let clientInfo = callbacks.clientInfo {
                Unmanaged<AudioTapContext>.fromOpaque(clientInfo).release()
            }
            return nil
        }

        let inputParams = AVMutableAudioMixInputParameters(track: nil)
        inputParams.trackID = trackID
        inputParams.audioTapProcessor = tapOut

        let mix = AVMutableAudioMix()
        mix.inputParameters = [inputParams]
        return mix
    }
}


// MARK: - MTAudioProcessingTap C callbacks
//
// These must be plain functions (not closures capturing state): Media Toolbox calls them via C
// function pointers. All per-track state lives in the `AudioTapContext` passed through
// `clientInfo` / tap storage.

private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    // Balances `Unmanaged.passRetained(context)` in `makeAudioMix` (CRIT-1): the tap's one owning
    // reference, released once, after `process` can no longer run.
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioTapContext>.fromOpaque(storage).release()
}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
    let channels = max(Int(processingFormat.pointee.mChannelsPerFrame), 1)
    // CRIT-1 addendum / P3-3: `tapProcess` reinterprets samples as Float32 and walks one buffer per
    // channel, so the negotiated format must be 32-bit float and (above one channel) non-interleaved.
    // Anything else is passed through untouched rather than turned into full-scale noise.
    let flags = processingFormat.pointee.mFormatFlags
    let isFloat = flags & kAudioFormatFlagIsFloat != 0
    let isThirtyTwoBit = processingFormat.pointee.mBitsPerChannel == 32
    let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
    let interleavingOK = channels <= 1 || isNonInterleaved
    context.isSampleFormatSupported = isFloat && isThirtyTwoBit && interleavingOK
    // Preallocate all DSP state here (not on the render thread): up to 8 channels.
    context.prepare(channelCount: channels, sampleRate: processingFormat.pointee.mSampleRate)
    if !context.isSampleFormatSupported {
        ShelfLog.error(.playback, "Unsupported tap processing format: float=\(isFloat) bitsPerChannel=\(processingFormat.pointee.mBitsPerChannel) channels=\(channels) nonInterleaved=\(isNonInterleaved), so audio processing is disabled for this playback session.")
        // L3: also surface it to the UI, not just the diagnostics log (see `AudioProcessingStatus`).
        Task { @MainActor in AudioProcessingStatus.shared.formatUnsupportedThisSession = true }
    }
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
    context.release()
}

private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    var timeRange = CMTimeRange.zero
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut)
    guard status == noErr else {
        numberFramesOut.pointee = 0
        return
    }
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
    guard context.isSampleFormatSupported,
          let processor = context.processor, let table = context.channelTable else { return }

    processor.apply(context.currentParameters())

    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    var frames = Int.max
    var count = 0
    for buffer in bufferList where count < AudioChainProcessor.maxChannels {
        guard let data = buffer.mData else { continue }
        table[count] = data.assumingMemoryBound(to: Float.self)
        frames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        count += 1
    }
    guard count > 0, frames > 0, frames != Int.max else { return }
    processor.process(channels: table, count: count, frames: frames)
}
