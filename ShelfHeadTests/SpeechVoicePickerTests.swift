import XCTest
@testable import ShelfHead

/// Batch 432: the "Read It to Me" voice picker.
final class SpeechVoicePickerTests: XCTestCase {
    private func voice(_ id: String, _ language: String, _ quality: Int, excluded: Bool = false) -> SpeechVoiceCandidate {
        SpeechVoiceCandidate(identifier: id, language: language, quality: quality, isExcluded: excluded)
    }

    func testPrefersPremiumOverEnhancedOverDefault() {
        let voices = [voice("compact", "en-US", 1), voice("enhanced", "en-US", 2), voice("premium", "en-US", 3)]
        XCTAssertEqual(SpeechVoicePicker.best(voices, localeIdentifier: "en-US", fallbackLanguage: "en")?.identifier, "premium")
    }

    func testQualityBeatsExactRegion() {
        let voices = [voice("us-compact", "en-US", 1), voice("au-enhanced", "en-AU", 2)]
        XCTAssertEqual(SpeechVoicePicker.best(voices, localeIdentifier: "en_US", fallbackLanguage: "en")?.identifier, "au-enhanced")
    }

    func testExactRegionBreaksQualityTie() {
        let voices = [voice("gb", "en-GB", 2), voice("au", "en-AU", 2), voice("us", "en-US", 2)]
        XCTAssertEqual(SpeechVoicePicker.best(voices, localeIdentifier: "en-AU", fallbackLanguage: "en")?.identifier, "au")
    }

    func testSystemPreferredBreaksRemainingTie() {
        let voices = [voice("a", "en-US", 1), voice("b", "en-US", 1), voice("c", "en-US", 1)]
        XCTAssertEqual(SpeechVoicePicker.best(voices, localeIdentifier: "en-US", fallbackLanguage: "en",
                                              preferredIdentifier: "b")?.identifier, "b")
    }

    func testNeverPicksNoveltyOrPersonalVoice() {
        let voices = [voice("novelty", "en-US", 3, excluded: true), voice("plain", "en-US", 1)]
        XCTAssertEqual(SpeechVoicePicker.best(voices, localeIdentifier: "en-US", fallbackLanguage: "en")?.identifier, "plain")
    }

    func testOtherLanguagesIgnored() {
        let voices = [voice("fr", "fr-FR", 3)]
        XCTAssertNil(SpeechVoicePicker.best(voices, localeIdentifier: "en-US", fallbackLanguage: "en"))
    }

    func testMandarinNeverGetsCantonese() {
        let voices = [voice("hk", "zh-HK", 3), voice("cn", "zh-CN", 1), voice("tw", "zh-TW", 2)]
        XCTAssertEqual(SpeechVoicePicker.best(voices, localeIdentifier: "zh-CN", fallbackLanguage: "en")?.identifier, "tw")
        XCTAssertEqual(SpeechVoicePicker.best(voices, localeIdentifier: "zh_HK", fallbackLanguage: "en")?.identifier, "hk")
    }

    func testMissingLocaleUsesFallbackLanguage() {
        let voices = [voice("en", "en-US", 2), voice("zh", "zh-CN", 3)]
        XCTAssertEqual(SpeechVoicePicker.best(voices, localeIdentifier: nil, fallbackLanguage: "zh")?.identifier, "zh")
        XCTAssertEqual(SpeechVoicePicker.best(voices, localeIdentifier: "", fallbackLanguage: "en")?.identifier, "en")
    }

    func testSuggestsBetterVoiceOnlyForCompact() {
        XCTAssertTrue(SpeechVoicePicker.shouldSuggestBetterVoice(nil))
        XCTAssertTrue(SpeechVoicePicker.shouldSuggestBetterVoice(voice("c", "en-US", 1)))
        XCTAssertFalse(SpeechVoicePicker.shouldSuggestBetterVoice(voice("e", "en-US", 2)))
        XCTAssertFalse(SpeechVoicePicker.shouldSuggestBetterVoice(voice("p", "en-US", 3)))
    }
}
