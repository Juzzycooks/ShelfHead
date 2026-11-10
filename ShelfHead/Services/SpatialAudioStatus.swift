import AVFoundation
import Observation

/// Batch 440: opt-in Spatial Audio. Pure mapping from route facts to a status, plus the
/// `AVAudioSpatializationFormats` to apply per setting.
///
/// Apple documents the default `allowedAudioSpatializationFormats` for audio-only content
/// as `.multichannel`, which does NOT spatialise mono/stereo. So "off" is that default
/// (set explicitly only so turning the setting off again restores it); "on" is
/// `.monoStereoAndMultichannel`. Books are mixed stereo with no separate voices, so this
/// widens the sound; it cannot place individual voices.
nonisolated enum SpatialAudioStatus: Equatable {
    /// The current output can't do spatial audio (or nothing suitable is connected).
    case unavailable
    /// The output supports it, but the app setting is off.
    case availableOff
    /// The output supports it and the app setting is on.
    case on

    static func status(portSupportsSpatial: Bool, settingEnabled: Bool) -> SpatialAudioStatus {
        guard portSupportsSpatial else { return .unavailable }
        return settingEnabled ? .on : .availableOff
    }

    static func formats(forEnabled enabled: Bool) -> AVAudioSpatializationFormats {
        enabled ? .monoStereoAndMultichannel : .multichannel
    }
}

/// Observes the current route so the settings row can say whether the headphones support
/// Spatial Audio. `isSpatialAudioEnabled` on the output port is the documented query.
@MainActor @Observable
final class SpatialAudioObserver {
    static let shared = SpatialAudioObserver()

    private(set) var portSupportsSpatial = false
    private var tokens: [NSObjectProtocol] = []

    private init() {
        refresh()
        let center = NotificationCenter.default
        for name in [AVAudioSession.routeChangeNotification,
                     AVAudioSession.spatialPlaybackCapabilitiesChangedNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Route changes are posted on a secondary thread; queue .main hops here.
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        portSupportsSpatial = outputs.contains { $0.isSpatialAudioEnabled }
    }

    func status(settingEnabled: Bool) -> SpatialAudioStatus {
        SpatialAudioStatus.status(portSupportsSpatial: portSupportsSpatial, settingEnabled: settingEnabled)
    }
}

extension SettingsKeys {
    static let spatialAudioEnabled = "settings_spatialAudioEnabled"
}

extension SettingsStore {
    /// Batch 440: default off.
    static var spatialAudioEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.spatialAudioEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.spatialAudioEnabled) }
    }
}
