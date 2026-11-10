import Foundation

/// Batch 462: the pure timing model of the Year in Review video. 30 s at 30 fps is 900 frames
/// in six 5 s scenes; each scene hands over to the next with a 0.5 s eased cross-fade. No I/O
/// and no UI, so the frame count, the scene at a time and the fade weights are unit-tested
/// (`YearInReviewReelTests`).
nonisolated enum ReelTimeline {
    static let fps = 30
    static let duration: Double = 30
    static let sceneDuration: Double = 5
    static let crossFade: Double = 0.5
    static var frameCount: Int { Int(duration) * fps }

    /// The six scenes, in order.
    enum Scene: Int, CaseIterable, Sendable {
        case title, hours, topBooks, months, finished, closing

        var start: Double { Double(rawValue) * ReelTimeline.sceneDuration }
    }

    /// The scene a time falls in and how far through its own 5 s it is (0…1). Times outside
    /// 0…30 clamp to the first or last scene.
    static func scene(at t: Double) -> (scene: Scene, localProgress: Double) {
        let clamped = min(max(t, 0), duration)
        let index = min(Int(clamped / sceneDuration), Scene.allCases.count - 1)
        let scene = Scene(rawValue: index) ?? .closing
        let local = (clamped - scene.start) / sceneDuration
        return (scene, min(max(local, 0), 1))
    }

    /// Progress (0…1) of `scene` at time `t`, clamped, so a scene fading in reads as its start
    /// and one fading out as its end.
    static func progress(of scene: Scene, at t: Double) -> Double {
        min(max((t - scene.start) / sceneDuration, 0), 1)
    }

    /// The scenes visible at `t` with their opacity. One entry outside a hand-over; two inside
    /// it (the outgoing scene fading out, the incoming one in), weights summing to 1.
    static func weights(at t: Double) -> [(scene: Scene, weight: Double)] {
        let (scene, _) = scene(at: t)
        let clamped = min(max(t, 0), duration)
        let fadeStart = scene.start + sceneDuration - crossFade
        guard let next = Scene(rawValue: scene.rawValue + 1), clamped > fadeStart else {
            return [(scene, 1)]
        }
        let incoming = ease((clamped - fadeStart) / crossFade)
        return [(scene, 1 - incoming), (next, incoming)]
    }

    /// The presentation time of a frame, in seconds.
    static func time(forFrame index: Int) -> Double {
        Double(index) / Double(fps)
    }

    /// Smoothstep, clamped to 0…1.
    static func ease(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// An eased 0…1 reveal that starts at `delay` and takes `length` of a scene's progress,
    /// used to stagger elements inside a scene.
    static func reveal(_ progress: Double, delay: Double, length: Double) -> Double {
        guard length > 0 else { return progress >= delay ? 1 : 0 }
        return ease((progress - delay) / length)
    }
}
