import Foundation

/// A single exported preference value. Mirrors the handful of scalar/array shapes
/// `SettingsKeys` actually uses in `UserDefaults` (see `SettingsExport.exportedKeys`).
/// Encoded/decoded as a bare single value (no type tag) so the exported JSON reads as
/// plain key/value pairs rather than a tagged-union shape.
enum SettingsExportValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case stringArray([String])
    /// Batch 490 (REVIEW 2026-11-11 D7): `seriesAutoDownload`'s `[seriesName: Bool]`,
    /// which was on `exportedKeys` but never written because no case could hold it.
    case boolDictionary([String: Bool])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: Bool decodes successfully from a JSON number container too on
        // some paths, and Int would happily truncate a Double, so try narrowest-first.
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([String].self) { self = .stringArray(v); return }
        if let v = try? container.decode([String: Bool].self) { self = .boolDictionary(v); return }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Unsupported SettingsExportValue")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .stringArray(let v): try container.encode(v)
        case .boolDictionary(let v): try container.encode(v)
        }
    }

    /// Maps a `UserDefaults.object(forKey:)` result into a typed export value, or nil for
    /// a shape this export format doesn't support. Batch 490 (REVIEW 2026-11-11 D7):
    /// `[String: Bool]` is supported now, so `seriesAutoDownload` round-trips.
    init?(any: Any) {
        if let arr = any as? [String] {
            self = .stringArray(arr)
            return
        }
        if let dict = any as? [String: Any] {
            // Only a dictionary whose every value is a real Bool (not a number).
            var out: [String: Bool] = [:]
            for (key, value) in dict {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
                out[key] = number.boolValue
            }
            self = .boolDictionary(out)
            return
        }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
                self = .int(number.intValue)
            } else {
                self = .double(number.doubleValue)
            }
            return
        }
        if let str = any as? String {
            self = .string(str)
            return
        }
        return nil
    }

    var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .stringArray(let v): return v
        case .boolDictionary(let v): return v
        }
    }
}

/// Top-level shape of an exported settings file. Versioned like `ConnectionExportFile`
/// so the format can grow without breaking older exports.
struct SettingsExportFile: Codable {
    let version: Int
    let exportedAt: Date
    let appVersion: String
    var settings: [String: SettingsExportValue]
}

/// Export/import of user *preferences* only — never credentials, tokens, per-account
/// headers, or per-device state. Mirrors `ConnectionExport`'s file-handling pattern
/// (pretty-printed/sorted JSON, a fresh temp file, cleanup of previous exports).
enum SettingsExport {
    static let currentVersion = 1

    /// Preference keys eligible for export/import. Deliberately explicit rather than
    /// "everything in SettingsKeys minus a blocklist" so a newly-added key defaults to
    /// NOT being exported until someone decides it belongs here.
    static let exportedKeys: [String] = [
        SettingsKeys.defaultPlaybackSpeed,
        SettingsKeys.skipForwardInterval,
        SettingsKeys.skipBackwardInterval,
        SettingsKeys.autoDownloadContinueListening,
        SettingsKeys.wifiOnlyDownloads,
        SettingsKeys.smartRewind,
        SettingsKeys.sleepFadeOut,
        SettingsKeys.autoDeleteFinished,
        SettingsKeys.keepScreenAwake,
        SettingsKeys.allowCellularStreaming,
        SettingsKeys.hapticsEnabled,
        SettingsKeys.transcriptsEnabled,
        SettingsKeys.transcribeWhileCharging,
        SettingsKeys.transcriptDefaultLanguage,
        SettingsKeys.recapSpokenLinks,   // Batch 433
        SettingsKeys.recapAutoPlay,
        SettingsKeys.autoplayNext,
        SettingsKeys.autoContinueSeries,
        SettingsKeys.downloadWhileCharging,
        SettingsKeys.seriesAutoDownload,
        SettingsKeys.spotlightIndexing,
        SettingsKeys.liveActivities,
        SettingsKeys.appearance,
        SettingsKeys.accentColor,
        SettingsKeys.hiddenHomeSections,
        SettingsKeys.homeSectionOrder,
        SettingsKeys.chapterHaptics,
        SettingsKeys.libraryLayout,
        SettingsKeys.libraryGridDensity,
        SettingsKeys.dailyReminder,
        SettingsKeys.dailyReminderHour,
        SettingsKeys.dailyReminderMinute,
        SettingsKeys.notifyDownloadComplete,
        SettingsKeys.shakeAction,
        SettingsKeys.smartSleepTimer,
        SettingsKeys.librarySortOption,
        SettingsKeys.librarySortDescending,
        SettingsKeys.libraryProgressFilter,
        SettingsKeys.dailyListeningGoalMinutes,
        SettingsKeys.autoSkipIntroOutro,
        SettingsKeys.chapterSkipStart,
        SettingsKeys.chapterSkipEnd,
        SettingsKeys.scheduledSleepTimerEnabled,
        SettingsKeys.scheduledSleepTimerStartHour,
        SettingsKeys.scheduledSleepTimerStartMinute,
        SettingsKeys.scheduledSleepTimerEndHour,
        SettingsKeys.scheduledSleepTimerEndMinute,
        SettingsKeys.scheduledSleepTimerDurationMinutes,
        SettingsKeys.defaultSleepTimerMinutes,
        SettingsKeys.volumeBoostDB,
        SettingsKeys.bassBoostDB,
        SettingsKeys.trebleBoostDB,
        SettingsKeys.appLockEnabled,
        SettingsKeys.playerShowsCassette,
        SettingsKeys.playerShowsCaptions,
        SettingsKeys.captionTranslationLanguage,
        SettingsKeys.classicNowPlaying,
        // Batch 490 (REVIEW 2026-11-11 D7): keys added since this list was last audited.
        // `QuickWinsSettingsTests` now fails when a `SettingsKeys` constant is on neither list.
        SettingsKeys.deckSkin,                     // appearance only; an unknown value falls back to Classic
        SettingsKeys.releaseRadarRegion,           // harmless alone: Release Radar itself is excluded below
        SettingsKeys.readingSiteSyncProgress,      // only acts once Hardcover is connected, which isn't exported
        SettingsKeys.readingSiteMarkFinished,
        SettingsKeys.readingSiteAskRating,
        SettingsKeys.speedMode,                    // "wpm" or "multiplier" (sanitized below)
        SettingsKeys.targetWPM,                    // clamped to NarratorPace.targetRange below
        SettingsKeys.spatialAudioEnabled,          // changes how audio sounds, like the volume/EQ keys; starts nothing
        SettingsKeys.dialogueEnhance,              // same
        SettingsKeys.matchLoudness,                // same
        // Preference keys owned by other stores, not `SettingsKeys` itself.
        "shelfhead_favoriteAuthors",               // FavoritesStore: starred authors (global, not per-account)
        "shelfhead_favoriteNarrators",              // FavoritesStore: starred narrators (global, not per-account)
        "downloadsPageSortOrder",                  // DownloadsView sort; an unknown value falls back to Title
        "epubReader.fontScale",                    // EPUBReaderView text size (0 = automatic), clamped below
        "epubReader.serif",                        // EPUBReaderView typeface
        "settings_booksPerYearGoal",               // StatsView books-this-year goal (Batch 490 F27)
    ]

    /// Keys deliberately left out of `exportedKeys`, each excluded for account/device
    /// state, one-time migration bookkeeping, or security. Exposed for tests.
    static let excludedKeys: Set<String> = [
        "settings_activeListeningProfile",                 // Review 7 Medium 10: import wrote only the default, never the profile's overrides or baseline
        "settings_carPlayAutoDrivingPreference",           // Review 7 Medium 10: answer to a per-device CarPlay prompt
        SettingsKeys.selectedLibraryId,                  // per-account/device, shared with CarPlay — not a portable preference
        SettingsKeys.storePassword,                       // security: whether a password is cached should never round-trip through a file
        SettingsKeys.streamWithURLToken,                   // security: opt-in token-in-URL behaviour shouldn't silently propagate
        SettingsKeys.perBookSpeed,                         // per-book state, not a global preference
        SettingsKeys.perBookChapterSkip,                   // per-book state, not a global preference
        SettingsKeys.scheduledSleepTimerSuppressedUntil,   // transient device-local timestamp, not a preference
        SettingsKeys.seenHomeBrowseSections,               // one-time Home migration bookkeeping
        SettingsKeys.homeBrowseSeenMigrated,                // one-time Home migration bookkeeping
        SettingsKeys.homeShelfSeedVersion,                   // one-time Home shelf seed/migration bookkeeping
        // Batch 490 (REVIEW 2026-11-11 D7): every remaining key, each with its reason.
        SettingsKeys.ambientBed,                           // sound: an import must never start sound
        SettingsKeys.ambientLevel,                         // sound: goes with the bed above
        SettingsKeys.deckButtonSounds,                     // sound: key clicks stay off until chosen on this device
        SettingsKeys.cloudPositionSync,                    // privacy: sends positions to iCloud; each device opts in
        SettingsKeys.releaseRadarEnabled,                  // privacy: contacts Audible; each device opts in
        SettingsKeys.readingSiteConnected,                 // account state: the Hardcover token is in this device's Keychain
        SettingsKeys.householdShareNowListening,           // privacy: publishes what you're playing to the household
        SettingsKeys.householdDisplayName,                 // personal: your name in a household, not a device preference
        SettingsKeys.householdAvatarSymbol,                // personal: as above
        SettingsKeys.householdAvatarColor,                 // personal: as above
        SettingsKeys.householdDismissedRecommendations,    // per-device inbox state
        SettingsKeys.householdNotifiedRecommendations,     // per-device inbox state
        SettingsKeys.showProfilePickerAtLaunch,            // goes with this device's child profiles, which aren't exported
        "settings_kidProfiles",                            // child profiles: keyed by this device's saved account ids
        "settings_listeningProfileBaseline",               // internal: the values a listening profile restores
        "settings_schemaVersion",                          // migration bookkeeping
        "settings_homeDefaultsV2Applied",                  // migration bookkeeping
        "settings_homeDefaultOrderV3Applied",              // migration bookkeeping
        "settings_alternateIconRevertApplied",             // migration bookkeeping
        "settings_iconVariant",                            // removed setting, only ever deleted now
        "settings_whatsNewLastSeenVersion",                // per-device: which What's New this device has shown
        "bookDetail.siriTipVisible",                       // per-device tip state
    ]

    /// Builds an export file from whatever `exportedKeys` currently have a stored value.
    /// Keys with no stored value (never touched, or on their built-in default) are
    /// skipped rather than exported as some placeholder.
    static func snapshot(defaults: UserDefaults = .standard, appVersion: String) -> SettingsExportFile {
        var settings: [String: SettingsExportValue] = [:]
        for key in exportedKeys {
            guard let raw = defaults.object(forKey: key),
                  let value = SettingsExportValue(any: raw) else { continue }
            settings[key] = value
        }
        // Review 7 Medium 10: with a profile active, export the user's own values, not the profile's.
        for (key, value) in ListeningProfileManager.exportBaselineValues(defaults: defaults) where settings[key] != nil {
            settings[key] = value
        }
        return SettingsExportFile(version: currentVersion, exportedAt: Date(), appVersion: appVersion, settings: settings)
    }

    /// Applies an imported file's settings back into `defaults`. Ignores any key not in
    /// `exportedKeys` (forward/backward compatible with a file carrying stray keys), and
    /// refuses a file from a newer format version outright (returns 0) so the caller can
    /// show a "this file is from a newer version" message rather than partially applying it.
    @discardableResult
    static func apply(_ file: SettingsExportFile, to defaults: UserDefaults = .standard) -> Int {
        guard file.version <= currentVersion else { return 0 }
        var applied = 0
        for (key, value) in file.settings where exportedKeys.contains(key) {
            // Review 7 Low (import clamp): wrong types are skipped, numbers pulled into range.
            guard let safe = sanitized(value, forKey: key) else { continue }
            defaults.set(safe.anyValue, forKey: key)
            applied += 1
        }
        return applied
    }

    /// Review 7 Low (import clamp): pure. Returns the value to store, or nil to reject it.
    /// Keys without a rule pass through unchanged.
    nonisolated static func sanitized(_ value: SettingsExportValue, forKey key: String) -> SettingsExportValue? {
        func number() -> Double? {
            switch value {
            case .int(let v): return Double(v)
            case .double(let v): return v.isFinite ? v : nil
            default: return nil
            }
        }
        func clamped(_ range: ClosedRange<Double>) -> SettingsExportValue? {
            guard let n = number() else { return nil }
            return .double(min(max(n, range.lowerBound), range.upperBound))
        }
        func clampedInt(_ range: ClosedRange<Int>) -> SettingsExportValue? {
            guard let n = number() else { return nil }
            return .int(min(max(Int(n.rounded()), range.lowerBound), range.upperBound))
        }
        switch key {
        case SettingsKeys.defaultPlaybackSpeed: return clamped(0.5...3.0)
        case SettingsKeys.volumeBoostDB: return clamped(0...12)
        case SettingsKeys.bassBoostDB, SettingsKeys.trebleBoostDB: return clamped(-6...6)
        case SettingsKeys.skipForwardInterval, SettingsKeys.skipBackwardInterval: return clamped(10...60)
        case SettingsKeys.chapterSkipStart, SettingsKeys.chapterSkipEnd: return clampedInt(0...120)
        case SettingsKeys.dailyReminderHour, SettingsKeys.scheduledSleepTimerStartHour,
             SettingsKeys.scheduledSleepTimerEndHour: return clampedInt(0...23)
        case SettingsKeys.dailyReminderMinute, SettingsKeys.scheduledSleepTimerStartMinute,
             SettingsKeys.scheduledSleepTimerEndMinute: return clampedInt(0...59)
        case SettingsKeys.defaultSleepTimerMinutes: return clampedInt(1...180)
        case SettingsKeys.dailyListeningGoalMinutes: return clampedInt(0...1440)
        // Batch 490 (REVIEW 2026-11-11 D7): rules for the keys newly on `exportedKeys`.
        case SettingsKeys.targetWPM: return clampedInt(NarratorPace.targetRange)
        case "epubReader.fontScale": return clamped(0...2.5)
        case SettingsKeys.speedMode:
            if case .string(let mode) = value, mode == "wpm" || mode == "multiplier" { return value }
            return nil
        case SettingsKeys.seriesAutoDownload:
            if case .boolDictionary = value { return value }
            return nil
        case SettingsKeys.spatialAudioEnabled, SettingsKeys.dialogueEnhance, SettingsKeys.matchLoudness,
             SettingsKeys.readingSiteSyncProgress, SettingsKeys.readingSiteMarkFinished,
             SettingsKeys.readingSiteAskRating, "epubReader.serif":
            if case .bool = value { return value }
            return nil
        case SettingsKeys.dailyReminder, SettingsKeys.appLockEnabled, SettingsKeys.wifiOnlyDownloads,
             SettingsKeys.smartRewind, SettingsKeys.keepScreenAwake:
            if case .bool = value { return value }
            return nil
        default: return value
        }
    }

    /// Writes the export file's JSON to a fresh temp file, ready for `ShareLink`/
    /// `UIActivityViewController`. Mirrors `ConnectionExport.writeExportFile`.
    static func writeExportFile(_ file: SettingsExportFile) -> URL? {
        cleanupTempFiles()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfHead-settings-\(UUID().uuidString).json")
        do { try data.write(to: url); return url } catch { return nil }
    }

    /// Parses a previously exported file. Returns nil for unparseable content so the
    /// caller can distinguish "not a ShelfHead settings export" from an empty-but-valid one.
    static func parseImportFile(at url: URL) -> SettingsExportFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SettingsExportFile.self, from: data)
    }

    private static func cleanupTempFiles() {
        let dir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("ShelfHead-settings-") {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
