import AVFoundation
import Observation
import os

extension SettingsKeys {
    static let ambientBed = "settings_ambientBed"
    static let ambientLevel = "settings_ambientLevel"
}

extension SettingsStore {
    /// Batch 439: the selected ambient bed; `nil` is off. Stored as the raw value ("" = none).
    static var ambientBed: AmbientBed? {
        get { AmbientBed(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.ambientBed) ?? "") }
        set { UserDefaults.standard.set(newValue?.rawValue ?? "", forKey: SettingsKeys.ambientBed) }
    }
    /// Batch 439: ambient level 0...1 (default 0.25).
    static var ambientLevel: Double {
        get {
            guard UserDefaults.standard.object(forKey: SettingsKeys.ambientLevel) != nil else { return 0.25 }
            return min(max(UserDefaults.standard.double(forKey: SettingsKeys.ambientLevel), 0), 1)
        }
        set { UserDefaults.standard.set(min(max(newValue, 0), 1), forKey: SettingsKeys.ambientLevel) }
    }
}

/// Batch 439: what the main thread publishes to the render block.
nonisolated struct AmbientParams: Sendable {
    var bed: AmbientBed?
    /// Linear gain already including the playing/paused state (0 while paused).
    var targetGain: Float = 0
    /// Sleep-timer fade multiplier, 0...1.
    var fade: Float = 1
}

/// Batch 439: render-thread state. Parameters come in through an unfair lock the audio thread only
/// ever tries (same pattern as `AudioTapContext`): if it loses the race it reuses the last values for
/// one buffer. Everything else is touched only by the render block.
nonisolated final class AmbientRenderState: @unchecked Sendable {
    private let params = OSAllocatedUnfairLock(initialState: AmbientParams())
    private var lastParams = AmbientParams()
    private var renderer: AmbientRenderer?
    private var ramp: AmbientGainRamp
    private let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        ramp = AmbientGainRamp(sampleRate: sampleRate)
    }

    func publish(_ update: @Sendable (inout AmbientParams) -> Void) {
        params.withLock { update(&$0) }
    }

    /// Audio thread only.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        if let value = params.withLockIfAvailable({ $0 }) { lastParams = value }
        let wanted = lastParams.bed
        // A bed change fades the old one out first, then swaps once it's inaudible.
        if renderer?.bed != wanted, ramp.current < 0.0005 {
            renderer = wanted.map { AmbientRenderer(bed: $0, seed: 0x5EED_0000 &+ UInt64($0.rawValue.count)) }
        }
        let active = renderer != nil && renderer?.bed == wanted
        let target: Float = active ? lastParams.targetGain * lastParams.fade : 0

        guard renderer != nil else {
            for i in 0..<frames { left[i] = 0; right[i] = 0 }
            return
        }
        renderer?.render(left: left, right: right, frames: frames, sampleRate: sampleRate)
        for i in 0..<frames {
            let g = ramp.next(toward: target)
            left[i] *= g
            right[i] *= g
        }
    }
}

/// Batch 439: quiet procedural ambience (rain, fireplace, train cabin, brown noise) mixed under the
/// narration. Its own `AVAudioEngine` plays inside the app's existing `.playback` session; the
/// session is never changed here. The engine only runs while a bed is selected AND the book plays,
/// and stops after the fade-out so it costs nothing while paused.
@MainActor
@Observable
final class AmbientBedEngine {
    static let shared = AmbientBedEngine()

    private(set) var bed: AmbientBed?
    private(set) var level: Double
    private(set) var isPlaying = false
    /// The player's ⋯ menu sets this; `AmbientSheetHost` presents the sheet.
    var pickerRequested = false

    @ObservationIgnored private var fadeFactor: Float = 1
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var renderState: AmbientRenderState?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        bed = SettingsStore.ambientBed
        level = SettingsStore.ambientLevel
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine, note.object as AnyObject? === engine else { return }
                self.rebuildAndRestartIfNeeded()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                // AudioPlayerService pauses on `.began` and calls `setPlaying(false)`; on `.ended`
                // the engine may have been stopped by the system, so restart if playback resumed.
                if type == .ended { self.startEngineIfNeeded() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tearDown()
                self.startEngineIfNeeded()
            }
        })
    }

    private var wantsRun: Bool {
        AmbientMath.shouldRun(bed: bed, isPlaying: isPlaying)
    }

    // MARK: - API

    func select(_ newBed: AmbientBed?) {
        bed = newBed
        SettingsStore.ambientBed = newBed
        publish()
        reconcile()
    }

    /// `level` 0...1, mapped perceptually by `AmbientMath.gain(forLevel:)`.
    func setLevel(_ newLevel: Double) {
        level = min(max(newLevel, 0), 1)
        SettingsStore.ambientLevel = level
        publish()
    }

    /// Follows the narration: fade in over ~1 s on play, out over ~0.5 s on pause, then stop the engine.
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        publish()
        reconcile()
    }

    /// The sleep-timer fade: multiplies the output by `factor` (0...1).
    func setFadeFactor(_ factor: Float) {
        fadeFactor = min(max(factor, 0), 1)
        publish()
    }

    // MARK: - Engine

    private func publish() {
        let gain = AmbientMath.gain(forLevel: level)
        let run = AmbientMath.shouldRun(bed: bed, isPlaying: isPlaying)
        let fade = fadeFactor
        let bed = bed
        renderState?.publish {
            $0.bed = bed
            $0.targetGain = run ? gain : 0
            $0.fade = fade
        }
    }

    private func reconcile() {
        if wantsRun {
            stopTask?.cancel()
            stopTask = nil
            startEngineIfNeeded()
        } else if engine?.isRunning == true {
            // Let the fade-out finish (0.5 s, or longer for a bed change), then stop.
            stopTask?.cancel()
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self else { return }
                if !self.wantsRun {
                    self.engine?.stop()
                }
            }
        }
    }

    private func startEngineIfNeeded() {
        guard wantsRun else { return }
        if engine == nil { buildEngine() }
        guard let engine, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            ShelfLog.error(.playback, "AmbientBedEngine: start failed: \(error.localizedDescription)")
        }
    }

    private func buildEngine() {
        let engine = AVAudioEngine()
        var sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 44_100 }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let state = AmbientRenderState(sampleRate: sampleRate)
        let node = Self.makeSourceNode(state: state, format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.engine = engine
        renderState = state
        publish()
    }

    /// Built outside the main-actor class so the render closure is not main-actor isolated.
    nonisolated private static func makeSourceNode(state: AmbientRenderState, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            state.render(frames: Int(frameCount), left: left, right: right)
            return noErr
        }
    }

    /// The route's sample rate can change (Bluetooth, CarPlay); rebuild so the format matches.
    private func rebuildAndRestartIfNeeded() {
        tearDown()
        startEngineIfNeeded()
    }

    private func tearDown() {
        engine?.stop()
        engine = nil
        renderState = nil
    }
}
