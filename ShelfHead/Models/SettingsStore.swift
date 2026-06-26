import Foundation

/// Keys + defaults for user playback preferences. `SettingsView` writes these via
/// `@AppStorage`; `AudioPlayerService` / `PlayerViewModel` read them here so the
/// settings actually take effect.
enum SettingsKeys {
    static let defaultPlaybackSpeed = "settings_defaultPlaybackSpeed"
    static let skipForwardInterval = "settings_skipForwardInterval"
    static let skipBackwardInterval = "settings_skipBackwardInterval"
    static let perBookSpeed = "settings_perBookSpeed"
    static let autoDownloadContinueListening = "settings_autoDownloadContinueListening"
    static let wifiOnlyDownloads = "settings_wifiOnlyDownloads"
    static let smartRewind = "settings_smartRewind"
    static let sleepFadeOut = "settings_sleepFadeOut"
    static let autoDeleteFinished = "settings_autoDeleteFinished"
    static let keepScreenAwake = "settings_keepScreenAwake"
    static let allowCellularStreaming = "settings_allowCellularStreaming"
}

enum SettingsStore {
    static var defaultPlaybackSpeed: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKeys.defaultPlaybackSpeed)
        return v > 0 ? v : 1.0
    }

    static var skipForwardInterval: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKeys.skipForwardInterval)
        return v > 0 ? v : 30
    }

    static var skipBackwardInterval: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKeys.skipBackwardInterval)
        return v > 0 ? v : 15
    }

    static var autoDownloadContinueListening: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.autoDownloadContinueListening)
    }

    static var wifiOnlyDownloads: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.wifiOnlyDownloads)
    }

    static var smartRewind: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.smartRewind) }
    static var sleepFadeOut: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.sleepFadeOut) }
    static var autoDeleteFinished: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.autoDeleteFinished) }
    static var keepScreenAwake: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.keepScreenAwake) }
    static var allowCellularStreaming: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.allowCellularStreaming) }

    /// Seconds to rewind on resume, scaled by how long playback was paused.
    static func smartRewindAmount(pausedFor seconds: TimeInterval) -> Double {
        guard smartRewind else { return 0 }
        switch seconds {
        case ..<10: return 0
        case ..<60: return 3
        case ..<600: return 5
        case ..<3600: return 10
        default: return 20
        }
    }

    // MARK: - Per-book speed memory

    /// The remembered speed for a specific book, if the user set one.
    static func speed(forItem itemId: String) -> Double? {
        let map = UserDefaults.standard.dictionary(forKey: SettingsKeys.perBookSpeed) as? [String: Double]
        return map?[itemId]
    }

    /// The speed to use when starting a book: its remembered speed, else the global default.
    static func resolvedSpeed(forItem itemId: String) -> Double {
        speed(forItem: itemId) ?? defaultPlaybackSpeed
    }

    static func setSpeed(_ speed: Double, forItem itemId: String) {
        var map = (UserDefaults.standard.dictionary(forKey: SettingsKeys.perBookSpeed) as? [String: Double]) ?? [:]
        map[itemId] = speed
        UserDefaults.standard.set(map, forKey: SettingsKeys.perBookSpeed)
    }

    /// Register defaults once at launch so first reads are correct everywhere.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKeys.defaultPlaybackSpeed: 1.0,
            SettingsKeys.skipForwardInterval: 30.0,
            SettingsKeys.skipBackwardInterval: 15.0,
            SettingsKeys.autoDownloadContinueListening: false,
            SettingsKeys.wifiOnlyDownloads: true,
            SettingsKeys.smartRewind: true,
            SettingsKeys.sleepFadeOut: true,
            SettingsKeys.autoDeleteFinished: false,
            SettingsKeys.keepScreenAwake: false,
            SettingsKeys.allowCellularStreaming: true
        ])
    }
}
