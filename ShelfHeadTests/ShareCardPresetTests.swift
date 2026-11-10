import XCTest
@testable import ShelfHead

// =============================================================================
// ShelfHead • ShareCardPresetTests
// =============================================================================
//
// P-11 (REVIEW_2026-09-14_DESIGN.md): the share composer used to require two
// separate decisions — a Style row (`ShareCardTheme`, 5-7 tiles) and a Card Type
// row (`ShareCardContent`, up to 7 chips) — collapsed here into one row of five
// named `SharePreset`s. `SharePreset.resolvedContent(for:available:)` and
// `.isAvailable(_:availableThemes:)` are the pure decision functions behind that
// row (which content a preset shows for a given book, and whether the preset is
// offered at all) — pulled out so they can be pinned directly, following this
// project's precedent of testing the decision rather than the stateful
// `ShareComposerSheet` (which talks to `PHPhotoLibrary`, does async rendering,
// etc. — see `AccountRemovalTests` for the same rationale).
final class ShareCardPresetTests: XCTestCase {

    // MARK: - resolvedContent: degrades to what the book actually has

    func testSpotlightPrefersQuoteWhenAvailable() {
        let resolved = SharePreset.resolvedContent(for: .spotlight, available: [.progress, .quote])
        XCTAssertEqual(resolved, .quote)
    }

    func testSpotlightFallsBackToProgressWithoutAQuote() {
        let resolved = SharePreset.resolvedContent(for: .spotlight, available: [.progress, .chapter])
        XCTAssertEqual(resolved, .progress)
    }

    func testChapterPrefersChapterContent() {
        let resolved = SharePreset.resolvedContent(for: .chapter, available: [.progress, .chapter])
        XCTAssertEqual(resolved, .chapter)
    }

    func testChapterFallsBackToProgressWithNoChapterData() {
        let resolved = SharePreset.resolvedContent(for: .chapter, available: [.progress, .quote])
        XCTAssertEqual(resolved, .progress)
    }

    func testRetroAlwaysResolvesToProgress() {
        let resolved = SharePreset.resolvedContent(for: .retro, available: ShareCardContent.allCases)
        XCTAssertEqual(resolved, .progress)
    }

    func testFinishedPrefersCompletionContent() {
        let resolved = SharePreset.resolvedContent(for: .finished, available: [.progress, .completion])
        XCTAssertEqual(resolved, .completion)
    }

    func testPersonaPrefersListeningPersonalityThenStreakThenBooksFinished() {
        XCTAssertEqual(
            SharePreset.resolvedContent(for: .persona, available: [.progress, .streak, .listeningPersonality]),
            .listeningPersonality
        )
        XCTAssertEqual(
            SharePreset.resolvedContent(for: .persona, available: [.progress, .streak, .booksFinished]),
            .streak
        )
        XCTAssertEqual(
            SharePreset.resolvedContent(for: .persona, available: [.progress, .booksFinished]),
            .booksFinished
        )
    }

    /// If NONE of a preset's preferences are available (shouldn't happen in practice —
    /// `.progress` is always available — but the function must still not crash/force-
    /// unwrap), it falls back to the first available content rather than trapping.
    func testFallsBackToFirstAvailableWhenNoPreferenceMatches() {
        let resolved = SharePreset.resolvedContent(for: .finished, available: [.booksFinished])
        XCTAssertEqual(resolved, .booksFinished)
    }

    // MARK: - isAvailable: mirrors the existing per-theme gating

    func testFinishedPresetRequiresCompletionBurstTheme() {
        XCTAssertTrue(SharePreset.isAvailable(.finished, availableThemes: [.spotlight, .completionBurst]))
        XCTAssertFalse(SharePreset.isAvailable(.finished, availableThemes: [.spotlight, .chapterWave]))
    }

    func testPersonaPresetRequiresListeningPersonalityTheme() {
        XCTAssertTrue(SharePreset.isAvailable(.persona, availableThemes: [.spotlight, .listeningPersonality]))
        XCTAssertFalse(SharePreset.isAvailable(.persona, availableThemes: [.spotlight, .retroPlayer]))
    }

    func testSpotlightChapterAndRetroPresetsAreAlwaysAvailable() {
        let minimalThemes: [ShareCardTheme] = [.spotlight, .kineticType, .collage, .chapterWave, .retroPlayer]
        XCTAssertTrue(SharePreset.isAvailable(.spotlight, availableThemes: minimalThemes))
        XCTAssertTrue(SharePreset.isAvailable(.chapter, availableThemes: minimalThemes))
        XCTAssertTrue(SharePreset.isAvailable(.retro, availableThemes: minimalThemes))
    }

    // MARK: - Every preset maps to a distinct theme

    func testEveryPresetMapsToADistinctTheme() {
        let themes = SharePreset.allCases.map(\.theme)
        XCTAssertEqual(Set(themes).count, SharePreset.allCases.count)
    }
}
