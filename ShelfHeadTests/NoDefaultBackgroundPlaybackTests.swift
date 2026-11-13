import XCTest
@testable import ShelfHead

/// User rule (28 Oct 2026): nothing plays that the listener didn't choose. Pins the shipping
/// defaults of every setting that would otherwise start or add sound on its own.
final class NoDefaultBackgroundPlaybackTests: XCTestCase {

    private func registeredDefault(_ key: String) -> Any? {
        SettingsStore.registerDefaults()
        return UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)[key]
    }

    func testAutoContinueSeriesIsOffByDefault() {
        XCTAssertEqual(registeredDefault(SettingsKeys.autoContinueSeries) as? Bool, false)
    }

    /// Batch 460: deck button sounds play under `.playback`, which ignores the Silent switch,
    /// so they must stay off until the listener turns them on.
    func testDeckButtonSoundsAreOffByDefault() {
        let saved = UserDefaults.standard.object(forKey: SettingsKeys.deckButtonSounds)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.deckButtonSounds)
        defer { UserDefaults.standard.set(saved, forKey: SettingsKeys.deckButtonSounds) }
        XCTAssertNotEqual(registeredDefault(SettingsKeys.deckButtonSounds) as? Bool, true)
        XCTAssertFalse(SettingsStore.deckButtonSounds)
    }

    /// Batch 496 (P3): every control in the player's Sound sheet ships off or flat.
    func testSoundSheetControlsShipOff() {
        for key in [SettingsKeys.dialogueEnhance, SettingsKeys.matchLoudness, SettingsKeys.spatialAudioEnabled] {
            XCTAssertNotEqual(registeredDefault(key) as? Bool, true, key)
        }
        for key in [SettingsKeys.volumeBoostDB, SettingsKeys.bassBoostDB, SettingsKeys.trebleBoostDB] {
            XCTAssertEqual((registeredDefault(key) as? Double) ?? 0, 0, key)
        }
    }

    func testNoProfileStartsAnAmbientBed() {
        for profile in ListeningProfile.allCases {
            XCTAssertNil(profile.overrides.ambientBed, "\(profile)")
        }
    }

    /// Batch 471 (review 30 Oct 2026, High 4): a call, Siri or another app ending with
    /// `.shouldResume` must not start a book the listener had paused.
    func testInterruptionEndResumesOnlyWhatWasPlaying() {
        XCTAssertFalse(AudioPlayerService.shouldResumeAfterInterruption(wasPlaying: false, systemSaysResume: true))
        XCTAssertTrue(AudioPlayerService.shouldResumeAfterInterruption(wasPlaying: true, systemSaysResume: true))
        XCTAssertFalse(AudioPlayerService.shouldResumeAfterInterruption(wasPlaying: true, systemSaysResume: false))
        XCTAssertFalse(AudioPlayerService.shouldResumeAfterInterruption(wasPlaying: false, systemSaysResume: false))
    }
}
