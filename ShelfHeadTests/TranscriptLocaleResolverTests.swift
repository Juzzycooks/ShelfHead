import XCTest
@testable import ShelfHead

/// Phase 1, Batch 422: mapping ABS `metadata.language` onto transcriber locales.
final class TranscriptLocaleResolverTests: XCTestCase {
    private let fallback = Locale(identifier: "en-AU")

    private func candidate(_ language: String?) -> Locale {
        TranscriptLocaleResolver.candidateLocale(forBookLanguage: language, fallback: fallback)
    }

    private func languageCode(_ language: String?) -> String? {
        candidate(language).language.languageCode?.identifier
    }

    // MARK: candidateLocale

    func testEnglishSpellings() {
        for value in ["English", "english", "en", "eng", "EN"] {
            XCTAssertEqual(languageCode(value), "en", value)
        }
    }

    func testRegionedIdentifierKeepsRegion() {
        let locale = candidate("en-GB")
        XCTAssertEqual(locale.language.languageCode?.identifier, "en")
        XCTAssertEqual(locale.region?.identifier, "GB")
        XCTAssertEqual(candidate("en_gb").region?.identifier, "GB")
        XCTAssertEqual(candidate("eng-GB").region?.identifier, "GB")
    }

    func testChineseSpellings() {
        for value in ["Chinese", "中文", "zh", "Mandarin", "chi", "zho"] {
            XCTAssertEqual(languageCode(value), "zh", value)
        }
    }

    func testChineseScriptIdentifier() {
        let locale = candidate("zh-Hans")
        XCTAssertEqual(locale.language.languageCode?.identifier, "zh")
        XCTAssertEqual(locale.language.script?.identifier, "Hans")
        XCTAssertEqual(candidate("zh-hant").language.script?.identifier, "Hant")
    }

    func testOtherLanguagesByNameAndNativeName() {
        XCTAssertEqual(languageCode("French"), "fr")
        XCTAssertEqual(languageCode("Français"), "fr")
        XCTAssertEqual(languageCode("German"), "de")
        XCTAssertEqual(languageCode("Deutsch"), "de")
        XCTAssertEqual(languageCode("Spanish"), "es")
        XCTAssertEqual(languageCode("Español"), "es")
        XCTAssertEqual(languageCode("Japanese"), "ja")
        XCTAssertEqual(languageCode("日本語"), "ja")
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(languageCode("  German \n"), "de")
    }

    func testUnknownAndNilFallBack() {
        XCTAssertEqual(candidate("Klingon"), fallback)
        XCTAssertEqual(candidate(""), fallback)
        XCTAssertEqual(candidate("   "), fallback)
        XCTAssertEqual(candidate(nil), fallback)
        XCTAssertEqual(candidate("xx-YY"), fallback)
    }

    // MARK: bestSupported

    private func supported(_ ids: [String]) -> [Locale] { ids.map { Locale(identifier: $0) } }

    func testExactIdentifierWins() {
        let list = supported(["en-US", "en-GB", "en-AU"])
        let best = TranscriptLocaleResolver.bestSupported(Locale(identifier: "en-GB"), among: list, preferredRegion: "AU")
        XCTAssertEqual(best, Locale(identifier: "en-GB"))
    }

    func testPrefersFallbackRegionForBareLanguage() {
        let list = supported(["en-US", "en-GB", "en-AU"])
        let best = TranscriptLocaleResolver.bestSupported(Locale(identifier: "en"), among: list, preferredRegion: "AU")
        XCTAssertEqual(best, Locale(identifier: "en-AU"))
    }

    func testFallsBackToFirstSameLanguageInStableOrder() {
        let list = supported(["fr-CA", "fr-FR", "de-DE"])
        let best = TranscriptLocaleResolver.bestSupported(Locale(identifier: "fr"), among: list, preferredRegion: "AU")
        XCTAssertEqual(best, Locale(identifier: "fr-CA"))
        XCTAssertEqual(
            TranscriptLocaleResolver.bestSupported(Locale(identifier: "fr"), among: list, preferredRegion: nil),
            Locale(identifier: "fr-CA"))
    }

    func testNoLanguageMatchIsNil() {
        let list = supported(["en-US", "de-DE"])
        XCTAssertNil(TranscriptLocaleResolver.bestSupported(Locale(identifier: "ja"), among: list, preferredRegion: "US"))
        XCTAssertNil(TranscriptLocaleResolver.bestSupported(Locale(identifier: "ja"), among: [], preferredRegion: nil))
    }

    func testRequestedRegionBeatsPreferredRegionWhenNotExact() {
        // "es-MX" is not offered, but "es" regions are; requested region absent, so preferred region applies.
        let list = supported(["es-ES", "es-US"])
        let best = TranscriptLocaleResolver.bestSupported(Locale(identifier: "es-MX"), among: list, preferredRegion: "US")
        XCTAssertEqual(best, Locale(identifier: "es-US"))
    }

    func testSimplifiedChineseMapsToCN() {
        let list = supported(["zh-TW", "zh-HK", "zh-CN"])
        let best = TranscriptLocaleResolver.bestSupported(Locale(identifier: "zh-Hans"), among: list, preferredRegion: "TW")
        XCTAssertEqual(best, Locale(identifier: "zh-CN"))
    }

    func testTraditionalChineseMapsToTWOrHK() {
        let list = supported(["zh-CN", "zh-TW", "zh-HK"])
        XCTAssertEqual(
            TranscriptLocaleResolver.bestSupported(Locale(identifier: "zh-Hant"), among: list, preferredRegion: nil),
            Locale(identifier: "zh-TW"))
        XCTAssertEqual(
            TranscriptLocaleResolver.bestSupported(Locale(identifier: "zh-Hant"), among: list, preferredRegion: "HK"),
            Locale(identifier: "zh-HK"))
        let onlyHK = supported(["zh-CN", "zh-HK"])
        XCTAssertEqual(
            TranscriptLocaleResolver.bestSupported(Locale(identifier: "zh-Hant"), among: onlyHK, preferredRegion: nil),
            Locale(identifier: "zh-HK"))
    }

    func testBareChinesePicksPreferredRegion() {
        let list = supported(["zh-CN", "zh-TW"])
        XCTAssertEqual(
            TranscriptLocaleResolver.bestSupported(Locale(identifier: "zh"), among: list, preferredRegion: "TW"),
            Locale(identifier: "zh-TW"))
        XCTAssertEqual(
            TranscriptLocaleResolver.bestSupported(Locale(identifier: "zh"), among: list, preferredRegion: nil),
            Locale(identifier: "zh-CN"))
    }

    func testUnderscoreAndCaseInsensitiveExactMatch() {
        let list = supported(["en_US", "en_GB"])
        XCTAssertEqual(
            TranscriptLocaleResolver.bestSupported(Locale(identifier: "en-gb"), among: list, preferredRegion: "US"),
            Locale(identifier: "en_GB"))
    }
}
