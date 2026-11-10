import Foundation

/// Batch 439: the ambient sounds that can be mixed under the narration. Persisted by `rawValue`.
nonisolated enum AmbientBed: String, CaseIterable, Codable, Identifiable, Sendable {
    case rain
    case fireplace
    case trainCabin
    case brownNoise

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rain:       return String(localized: "Rain", comment: "Ambient sound name")
        case .fireplace:  return String(localized: "Fireplace", comment: "Ambient sound name")
        case .trainCabin: return String(localized: "Train Cabin", comment: "Ambient sound name")
        case .brownNoise: return String(localized: "Brown Noise", comment: "Ambient sound name")
        }
    }

    /// SF Symbols available since iOS 15 or earlier.
    var icon: String {
        switch self {
        case .rain:       return "cloud.rain"
        case .fireplace:  return "flame"
        case .trainCabin: return "tram"
        case .brownNoise: return "waveform"
        }
    }
}

/// Batch 439: small seeded generator (xorshift64*). Deterministic for a seed; no allocation.
nonisolated struct AmbientRNG: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        // Never zero (xorshift would stay at zero); mix so nearby seeds diverge.
        state = (seed &+ 0x9E37_79B9_7F4A_7C15) | 1
        for _ in 0..<4 { _ = nextUInt64() }
    }

    mutating func nextUInt64() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    /// Uniform in [-1, 1).
    mutating func nextSigned() -> Float {
        Float(Int32(truncatingIfNeeded: nextUInt64() >> 32)) / 2_147_483_648.0
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Float {
        Float(UInt32(truncatingIfNeeded: nextUInt64() >> 32)) / 4_294_967_296.0
    }
}

/// Batch 439: pure gain maths shared by the engine and its tests.
nonisolated enum AmbientMath {
    /// Slider position 0...1 to a linear gain. A power curve so the low end has fine control; the
    /// generators peak around 0.5, so even 1.0 stays well under full scale.
    static func gain(forLevel level: Double) -> Float {
        let clamped = Float(min(max(level, 0), 1))
        return clamped * clamped.squareRoot()
    }

    /// Whether the engine should be running at all.
    static func shouldRun(bed: AmbientBed?, isPlaying: Bool) -> Bool {
        bed != nil && isPlaying
    }

    /// Soft ceiling: monotonic, odd, always strictly inside ±0.85, and near-linear for small input.
    static func softLimit(_ x: Float) -> Float {
        0.85 * x / (1 + abs(x))
    }
}

/// Batch 439: slews a gain toward a target by a fixed per-second rate, so level changes, fades and
/// bed changes never step (no zipper noise).
nonisolated struct AmbientGainRamp: Sendable {
    private(set) var current: Float
    let riseStep: Float
    let fallStep: Float

    /// `fadeInSeconds` / `fadeOutSeconds`: time to travel 0 to 1 (and back).
    init(sampleRate: Double, fadeInSeconds: Double = 1.0, fadeOutSeconds: Double = 0.5, initial: Float = 0) {
        current = initial
        riseStep = Float(1.0 / (fadeInSeconds * sampleRate))
        fallStep = Float(1.0 / (fadeOutSeconds * sampleRate))
    }

    mutating func next(toward target: Float) -> Float {
        if current < target {
            current = min(current + riseStep, target)
        } else if current > target {
            current = max(current - fallStep, target)
        }
        return current
    }
}

/// Batch 439: renders a bed into two channels. Owns all filter and event state; call `render`
/// from the audio thread. Never allocates or locks. Deterministic for a seed and a `sampleRate`.
nonisolated struct AmbientRenderer: Sendable {
    private struct Channel: Sendable {
        var rng: AmbientRNG
        /// Same seed on both channels: shared events (train clacks) stay aligned.
        var eventRng: AmbientRNG
        var brown: Float = 0
        var pink0: Float = 0, pink1: Float = 0, pink2: Float = 0
        var lp1: Float = 0, lp2: Float = 0
        var hp: Float = 0
        var env: Float = 0
        var envDecay: Float = 0.999
        var countdown: Int = 0
        var secondCountdown: Int = -1
        var secondAmp: Float = 0
        var lfoPhase: Float = 0
        var slowMod: Float = 1
        var slowTarget: Float = 1
        var slowCountdown: Int = 0
    }

    private var channels: (Channel, Channel)
    private(set) var bed: AmbientBed

    init(bed: AmbientBed, seed: UInt64) {
        self.bed = bed
        channels = (
            Channel(rng: AmbientRNG(seed: seed), eventRng: AmbientRNG(seed: seed ^ 0xA5A5)),
            Channel(rng: AmbientRNG(seed: seed &+ 0x1234_5678_9ABC), eventRng: AmbientRNG(seed: seed ^ 0xA5A5))
        )
    }

    /// Fills `left` and `right` with `frames` samples. Output is strictly inside ±0.85.
    mutating func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                         frames: Int, sampleRate: Double) {
        let bed = self.bed
        Self.fill(&channels.0, bed: bed, out: left, frames: frames, sampleRate: sampleRate)
        Self.fill(&channels.1, bed: bed, out: right, frames: frames, sampleRate: sampleRate)
    }

    private static func fill(_ c: inout Channel, bed: AmbientBed, out: UnsafeMutablePointer<Float>,
                             frames: Int, sampleRate: Double) {
        let sr = Float(sampleRate)
        for i in 0..<frames {
            let raw: Float
            switch bed {
            case .rain:       raw = rain(&c, sr)
            case .fireplace:  raw = fire(&c, sr)
            case .trainCabin: raw = train(&c, sr)
            case .brownNoise: raw = brownNoise(&c)
            }
            out[i] = AmbientMath.softLimit(raw)
        }
    }

    /// Leaky-integrated white noise, roughly std 0.58 before scaling.
    @inline(__always)
    private static func stepBrown(_ c: inout Channel, _ w: Float, leak: Float = 0.995, gain: Float = 0.1) -> Float {
        c.brown = c.brown * leak + w * gain
        return c.brown
    }

    /// Paul Kellet's economy pink filter (three poles), roughly unit std.
    @inline(__always)
    private static func stepPink(_ c: inout Channel, _ w: Float) -> Float {
        c.pink0 = 0.99765 * c.pink0 + w * 0.0990460
        c.pink1 = 0.96300 * c.pink1 + w * 0.2965164
        c.pink2 = 0.57000 * c.pink2 + w * 1.0526913
        return (c.pink0 + c.pink1 + c.pink2 + w * 0.1848) * 0.35
    }

    /// Slowly wandering gain in about 0.7...1.3, retargeted every 0.4-1.2 s and glided to.
    @inline(__always)
    private static func stepSlowMod(_ c: inout Channel, _ sr: Float) -> Float {
        if c.slowCountdown <= 0 {
            c.slowTarget = 0.7 + 0.6 * c.eventRng.nextUnit()
            c.slowCountdown = Int(sr * (0.4 + 0.8 * c.eventRng.nextUnit()))
        }
        c.slowCountdown -= 1
        c.slowMod += (c.slowTarget - c.slowMod) * (3.0 / sr)
        return c.slowMod
    }

    private static func brownNoise(_ c: inout Channel) -> Float {
        let w = c.rng.nextSigned()
        return stepBrown(&c, w) * 0.28
    }

    private static func rain(_ c: inout Channel, _ sr: Float) -> Float {
        let w = c.rng.nextSigned()
        let pink = stepPink(&c, w)
        // High-passed hiss: the "patter" texture.
        c.hp += (w - c.hp) * 0.25
        let hiss = w - c.hp
        let wander = stepSlowMod(&c, sr)
        var out = pink * 0.075 * wander + hiss * 0.02 * wander
        // Droplets: ~35 per second per channel, a short band-passed tick.
        if c.rng.nextUnit() < 35.0 / sr {
            c.env = 0.05 + 0.12 * c.rng.nextUnit()
            c.envDecay = 1 - 1 / (sr * (0.002 + 0.006 * c.rng.nextUnit()))
        }
        c.lp1 += (w - c.lp1) * 0.35
        out += (c.lp1 - c.lp2) * c.env
        c.lp2 += (c.lp1 - c.lp2) * 0.08
        c.env *= c.envDecay
        return out
    }

    private static func fire(_ c: inout Channel, _ sr: Float) -> Float {
        let w = c.rng.nextSigned()
        let low = stepBrown(&c, w, leak: 0.997, gain: 0.07)
        let flicker = stepSlowMod(&c, sr)
        var out = low * 0.22 * flicker
        // Crackles: ~9 per second, squared amplitude so most are small and a few are sharp.
        if c.rng.nextUnit() < 9.0 / sr {
            let a = c.rng.nextUnit()
            c.env = 0.04 + 0.5 * a * a
            c.envDecay = 1 - 1 / (sr * (0.003 + 0.012 * c.rng.nextUnit()))
        }
        c.hp += (w - c.hp) * 0.2
        out += (w - c.hp) * c.env
        c.env *= c.envDecay
        return out
    }

    private static func train(_ c: inout Channel, _ sr: Float) -> Float {
        let w = c.rng.nextSigned()
        let rumble = stepBrown(&c, w, leak: 0.998, gain: 0.05)
        // Sway: a slow ~0.23 Hz swell of the rumble.
        c.lfoPhase += 0.23 / sr
        if c.lfoPhase >= 1 { c.lfoPhase -= 1 }
        let sway = 1 + 0.15 * sinf(2 * .pi * c.lfoPhase)
        var out = rumble * 0.34 * sway

        // Clack-clack: pair at ~1.1 s with +-8% jitter, second knock 0.14 s later and softer.
        // Timing comes from the shared event stream so both channels agree.
        if c.countdown <= 0 {
            c.countdown = Int(sr * 1.1 * (0.92 + 0.16 * c.eventRng.nextUnit()))
            c.secondCountdown = Int(sr * 0.14)
            c.secondAmp = 0.7
            c.env = 0.3
            c.envDecay = 1 - 1 / (sr * 0.035)
        }
        c.countdown -= 1
        if c.secondCountdown >= 0 {
            if c.secondCountdown == 0 {
                c.env = 0.3 * c.secondAmp
                c.envDecay = 1 - 1 / (sr * 0.03)
            }
            c.secondCountdown -= 1
        }
        // Dull knock: low-passed noise.
        c.lp1 += (w - c.lp1) * 0.12
        out += c.lp1 * c.env
        c.env *= c.envDecay
        return out
    }
}
