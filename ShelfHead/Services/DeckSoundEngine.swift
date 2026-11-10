import AVFoundation

/// Batch 460: the synthesised one-shots the deck skins use (and Batch 461 reuses for the
/// clunk on stop, until Tape realism was parked in Batch 465).
nonisolated enum DeckSound: String, CaseIterable, Sendable {
    case click, keyDown, clunk
}

/// Pure sample generator. Batch 466: a mechanical key click, not a tone. The old recipe was a
/// decaying sine plus a little noise, which rang like a beep (device feedback: "sound more like a
/// clicking of the button"). A real key makes two transients: the switch contact snaps, then the
/// key bottoms out a few milliseconds later. Each transient here is a ~1 ms noise burst rung
/// through a damped two-pole resonator (the plastic's own ring), plus a little of the raw burst
/// for the snap. No assets, no randomness beyond a fixed-seed xorshift, so the output is
/// deterministic, and it is peak-normalised so every sample is within -1…1.
nonisolated enum DeckSynth {
    /// One transient of the click.
    struct Transient: Sendable {
        var delay: Double       // seconds after the press
        var gain: Double        // relative level
        var resonance: Double   // the ring's pitch, Hz
        var ring: Double        // how fast the ring dies, 1/s (higher = drier)
        var snap: Double        // 0…1 share of raw noise (the contact's edge)
    }

    struct Recipe: Sendable {
        var transients: [Transient]
        var duration: Double    // seconds
        var gain: Double        // peak level after normalising
    }

    static func recipe(for sound: DeckSound) -> Recipe {
        switch sound {
        // A small tactile switch: a bright tick, then a lighter tock.
        case .click:
            return Recipe(transients: [
                Transient(delay: 0, gain: 1, resonance: 3_400, ring: 900, snap: 0.45),
                Transient(delay: 0.006, gain: 0.55, resonance: 2_100, ring: 700, snap: 0.25),
            ], duration: 0.04, gain: 0.45)
        // A cassette piano key: a plastic clack as the latch catches, then the key landing.
        case .keyDown:
            return Recipe(transients: [
                Transient(delay: 0, gain: 0.8, resonance: 1_900, ring: 420, snap: 0.35),
                Transient(delay: 0.011, gain: 1, resonance: 1_050, ring: 260, snap: 0.15),
                Transient(delay: 0.012, gain: 0.35, resonance: 210, ring: 70, snap: 0),
            ], duration: 0.08, gain: 0.55)
        // A heavy deck key: a dull mechanical knock with a low body.
        case .clunk:
            return Recipe(transients: [
                Transient(delay: 0, gain: 0.6, resonance: 1_200, ring: 380, snap: 0.2),
                Transient(delay: 0.016, gain: 1, resonance: 520, ring: 160, snap: 0.08),
                Transient(delay: 0.017, gain: 0.7, resonance: 130, ring: 45, snap: 0),
            ], duration: 0.16, gain: 0.6)
        }
    }

    static func samples(for sound: DeckSound, sampleRate: Double = 44_100) -> [Float] {
        let r = recipe(for: sound)
        let count = max(1, Int(r.duration * sampleRate))
        var mix = [Double](repeating: 0, count: count)
        var state: UInt32 = 0x9E3779B9
        for t in r.transients {
            let start = Int(t.delay * sampleRate)
            let burst = max(1, Int(0.001 * sampleRate))
            // Two-pole resonator: pole radius from the ring time, angle from the pitch.
            let radius = exp(-t.ring / sampleRate)
            let omega = 2 * .pi * t.resonance / sampleRate
            let a1 = 2 * radius * cos(omega), a2 = -radius * radius
            var y1 = 0.0, y2 = 0.0
            for i in start..<count {
                var x = 0.0
                let n = i - start
                if n < burst {
                    state ^= state << 13; state ^= state >> 17; state ^= state << 5
                    let white = Double(state) / Double(UInt32.max) * 2 - 1
                    x = white * (1 - Double(n) / Double(burst))   // the burst fades out over 1 ms
                }
                let y = x + a1 * y1 + a2 * y2
                y2 = y1; y1 = y
                mix[i] += t.gain * ((1 - t.snap) * y * (1 - radius) * 4 + t.snap * x)
            }
        }
        // Peak-normalise to the recipe's level, with a 2 ms fade at the end so it never pops.
        let peak = mix.map(abs).max() ?? 0
        let scale = peak > 0 ? r.gain / peak : 0
        let fade = max(1, Int(0.002 * sampleRate))
        return mix.enumerated().map { i, v in
            let tail = i >= count - fade ? Double(count - i) / Double(fade) : 1
            return Float(min(1, max(-1, v * scale * tail)))
        }
    }
}

/// Batch 460: plays the one-shots on a small `AVAudioEngine`. Buffers are pre-synthesised
/// and scheduled on an `AVAudioPlayerNode`, so there is no render callback of ours (no
/// locks or allocations on the audio thread). Lazy-starts on the first press and stops
/// after about 5 s idle. It never configures or activates the audio session: the app's
/// player sets `.playback`, and the engine shares that session, so it mixes with the book.
/// If the session isn't `.playback` yet (nothing has been played), it stays silent.
@MainActor
final class DeckSoundEngine {
    static let shared = DeckSoundEngine()
    private static let sampleRate = 44_100.0
    private static let idleSeconds: Duration = .seconds(5)

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffers: [DeckSound: AVAudioPCMBuffer] = [:]
    private var idleTask: Task<Void, Never>?

    private init() {}

    /// Plays `sound` if the user enabled Button sounds. Call only from a user button press.
    func press(_ sound: DeckSound) {
        guard SettingsStore.deckButtonSounds else { return }
        playOneShot(sound)
    }

    /// Plays `sound` unconditionally (callers gate on their own setting).
    func playOneShot(_ sound: DeckSound) {
        guard AVAudioSession.sharedInstance().category == .playback else { return }
        guard let (engine, player) = ensureEngine(), let buffer = buffer(for: sound) else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { teardown(); return }
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        scheduleIdleStop()
    }

    private func ensureEngine() -> (AVAudioEngine, AVAudioPlayerNode)? {
        if let engine, let player { return (engine, player) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else { return nil }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardown() }
        }
        self.engine = engine
        self.player = player
        return (engine, player)
    }

    private func buffer(for sound: DeckSound) -> AVAudioPCMBuffer? {
        if let cached = buffers[sound] { return cached }
        let samples = DeckSynth.samples(for: sound, sampleRate: Self.sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buf.floatChannelData?[0] else { return nil }
        for (i, s) in samples.enumerated() { channel[i] = s }
        buf.frameLength = AVAudioFrameCount(samples.count)
        buffers[sound] = buf
        return buf
    }

    private func scheduleIdleStop() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleSeconds)
            guard !Task.isCancelled else { return }
            self?.teardown()
        }
    }

    private func teardown() {
        idleTask?.cancel()
        idleTask = nil
        player?.stop()
        engine?.stop()
        if let engine { NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine) }
        engine = nil
        player = nil
    }
}
