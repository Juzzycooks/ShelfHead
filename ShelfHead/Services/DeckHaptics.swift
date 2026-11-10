import CoreHaptics
import UIKit

/// Batch 460: per-skin key haptics on Core Haptics, gated by the existing Haptics setting
/// and the hardware capability; falls back to the shared `Haptics` helper.
@MainActor
final class DeckHaptics {
    static let shared = DeckHaptics()
    private var engine: CHHapticEngine?

    private init() {}

    /// (intensity, sharpness, extra continuous tail seconds) per skin.
    nonisolated static func profile(for skin: DeckSkin) -> (intensity: Float, sharpness: Float, tail: Double) {
        switch skin {
        case .boombox: return (1.0, 0.2, 0.06)       // heavy clunk
        case .reelToReel: return (0.9, 0.3, 0.04)
        case .eightTrack: return (0.85, 0.35, 0.03)
        case .walkman: return (0.6, 0.9, 0)          // crisp tick
        case .classic, .fromTheCover: return (0.5, 0.5, 0)
        }
    }

    func key(_ skin: DeckSkin, heavy: Bool = false) {
        guard SettingsStore.hapticsEnabled else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, let engine = ensureEngine() else {
            Haptics.impact(heavy ? .medium : .light)
            return
        }
        let p = Self.profile(for: skin)
        let scale: Float = heavy ? 1.0 : 0.85
        var events = [CHHapticEvent(eventType: .hapticTransient,
                                    parameters: [.init(parameterID: .hapticIntensity, value: min(1, p.intensity * scale)),
                                                 .init(parameterID: .hapticSharpness, value: p.sharpness)],
                                    relativeTime: 0)]
        if p.tail > 0 {
            events.append(CHHapticEvent(eventType: .hapticContinuous,
                                        parameters: [.init(parameterID: .hapticIntensity, value: p.intensity * 0.35),
                                                     .init(parameterID: .hapticSharpness, value: 0.1)],
                                        relativeTime: 0.01, duration: p.tail))
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            Haptics.impact(heavy ? .medium : .light)
        }
    }

    private func ensureEngine() -> CHHapticEngine? {
        if let engine { return engine }
        do {
            let e = try CHHapticEngine()
            e.isAutoShutdownEnabled = true
            e.stoppedHandler = { [weak self] _ in Task { @MainActor in self?.engine = nil } }
            e.resetHandler = { [weak self] in Task { @MainActor in self?.engine = nil } }
            try e.start()
            engine = e
            return e
        } catch {
            return nil
        }
    }
}

/// One call for a transport key press: haptic (skin-specific for non-classic skins, the
/// plain helper for classic) plus the optional synthesised sound.
@MainActor
enum DeckFeedback {
    static func press(skin: DeckSkin, heavy: Bool = false) {
        if skin == .classic {
            Haptics.impact(heavy ? .medium : .light)
        } else {
            DeckHaptics.shared.key(skin, heavy: heavy)
        }
        DeckSoundEngine.shared.press(skin.keySound)
    }
}
