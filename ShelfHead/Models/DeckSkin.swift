import SwiftUI

/// Batch 460: the player's "deck" face. `classic` is today's look and the default; the
/// other five redraw the artwork slot and restyle the transport keys as a piece of
/// hardware. Everything decision-shaped here is pure so it can be pinned by tests.
nonisolated enum DeckSkin: String, CaseIterable, Identifiable, Sendable {
    case classic
    case walkman
    case reelToReel
    case eightTrack
    case boombox
    case fromTheCover

    var id: String { rawValue }

    static let `default`: DeckSkin = .classic

    var displayName: LocalizedStringResource {
        switch self {
        case .classic: return "Classic"
        case .walkman: return "Walkman"
        case .reelToReel: return "Reel-to-Reel"
        case .eightTrack: return "8-Track"
        case .boombox: return "Boombox"
        case .fromTheCover: return "From the Cover"
        }
    }

    var symbolName: String {
        switch self {
        case .classic: return "recordingtape"
        case .walkman: return "headphones"
        case .reelToReel: return "opticaldisc"
        case .eightTrack: return "rectangle.split.3x1"
        case .boombox: return "hifispeaker.2"
        case .fromTheCover: return "paintpalette"
        }
    }


    /// Which synthesised one-shot this skin's keys make.
    var keySound: DeckSound {
        switch self {
        case .classic, .fromTheCover: return .click
        case .walkman, .boombox: return .keyDown
        case .reelToReel, .eightTrack: return .clunk
        }
    }

    // MARK: Pure presentation maths

    /// Reel angular speed in degrees per second. 60°/s at 1×, scaled by playback rate,
    /// clamped to the app's 0.5×–3.0× range so a stale rate can't spin it wildly.
    static func reelDegreesPerSecond(rate: Float) -> Double {
        60 * Double(min(max(rate, 0.5), 3.0))
    }

    /// 8-track program indicator, 1–4: the chapter index mod 4 (nil index = program 1).
    static func programNumber(chapterIndex: Int?) -> Int {
        guard let chapterIndex, chapterIndex >= 0 else { return 1 }
        return (chapterIndex % 4) + 1
    }
}

// MARK: - Settings

extension SettingsKeys {
    static let deckSkin = "settings_deckSkin"
    /// Batch 460: synthesised button sounds. Default OFF.
    static let deckButtonSounds = "settings_deckButtonSounds"
}

extension SettingsStore {
    static var deckSkin: DeckSkin {
        get { UserDefaults.standard.string(forKey: SettingsKeys.deckSkin).flatMap(DeckSkin.init(rawValue:)) ?? .classic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.deckSkin) }
    }

    static var deckButtonSounds: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.deckButtonSounds) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.deckButtonSounds) }
    }
}
