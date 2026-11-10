import XCTest
@testable import ShelfHead

/// Batch 403 (Simplified Chinese, Phase 3): `LocalizedText` decides whether translated
/// text is written without spaces between sentences and without letter-spacing.
final class LocalizedTextTests: XCTestCase {

    func testChineseAndJapaneseAreSpaceless() {
        XCTAssertTrue(LocalizedText.isSpacelessScript("zh-Hans"))
        XCTAssertTrue(LocalizedText.isSpacelessScript("zh-Hant"))
        XCTAssertTrue(LocalizedText.isSpacelessScript("ja"))
    }

    func testOtherLanguagesKeepSpaces() {
        XCTAssertFalse(LocalizedText.isSpacelessScript("en"))
        XCTAssertFalse(LocalizedText.isSpacelessScript("en-AU"))
        XCTAssertFalse(LocalizedText.isSpacelessScript(nil))
    }

    func testSentencesJoinWithASpaceInEnglish() {
        XCTAssertEqual(LocalizedText.sentences(["About 4 GB.", "Respects your Wi-Fi-only setting."], spaceless: false),
                       "About 4 GB. Respects your Wi-Fi-only setting.")
    }

    func testSentencesJoinWithoutASpaceInChinese() {
        XCTAssertEqual(LocalizedText.sentences(["大约 4 GB。", "遵循“仅在 Wi-Fi 下下载”设置。"], spaceless: true),
                       "大约 4 GB。遵循“仅在 Wi-Fi 下下载”设置。")
    }

    func testTestHostRunsInEnglish() {
        // The unit-test host resolves to English, so letter-spacing is unchanged there.
        XCTAssertEqual(LocalizedText.tracking(1.5), 1.5)
    }
}
