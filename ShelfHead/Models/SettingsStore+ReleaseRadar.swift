import Foundation

/// Batch 442: release radar settings. Opt-in, off by default.
extension SettingsKeys {
    static let releaseRadarEnabled = "settings_releaseRadarEnabled"
    /// `AudibleRegion.rawValue`; empty = follow the device region.
    static let releaseRadarRegion = "settings_releaseRadarRegion"
}

extension SettingsStore {
    static var releaseRadarEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.releaseRadarEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.releaseRadarEnabled) }
    }

    static var releaseRadarRegion: AudibleRegion {
        get {
            UserDefaults.standard.string(forKey: SettingsKeys.releaseRadarRegion).flatMap(AudibleRegion.init(rawValue:))
                ?? AudibleRegion.default()
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.releaseRadarRegion) }
    }
}
