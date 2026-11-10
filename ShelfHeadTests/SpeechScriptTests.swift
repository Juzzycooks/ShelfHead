import AVFoundation
import XCTest
@testable import ShelfHead

/// Batch 435: recap speech written for the ear, paced with SSML, and the server stream layout used
/// to cut narrator clips from a streamed book that isn't loaded.
final class SpeechScriptTests: XCTestCase {

    // MARK: forListening

    func testDropsBracketedAsides() {
        XCTAssertEqual(SpeechScript.forListening("Holden (the lighthouse keeper) found the letter."),
                       "Holden found the letter.")
        XCTAssertEqual(SpeechScript.forListening("Mara left [chapter 3] at dawn."), "Mara left at dawn.")
        XCTAssertEqual(SpeechScript.forListening("他找到了信（第三章）。"), "他找到了信。")
    }

    func testDropsMarkdownAndListMarkers() {
        let text = """
        ## Previously
        - **Holden** found the letter.
        2. Mara *left* at dawn.
        """
        XCTAssertEqual(SpeechScript.forListening(text), "Previously Holden found the letter. Mara left at dawn.")
    }

    func testKeepsTextThatIsOnlyAnAside() {
        XCTAssertEqual(SpeechScript.forListening("  (Nothing else.) "), "(Nothing else.)")
    }

    // MARK: sentences

    func testSplitsSentencesButNotDecimals() {
        XCTAssertEqual(SpeechScript.sentences("It took 3.5 hours. Then the storm came! Did it end?"),
                       ["It took 3.5 hours.", "Then the storm came!", "Did it end?"])
    }

    func testKeepsClosingQuotesAndTrailingText() {
        XCTAssertEqual(SpeechScript.sentences("He said “stop.” She didn't"),
                       ["He said “stop.”", "She didn't"])
    }

    func testSplitsChineseWithoutSpaces() {
        XCTAssertEqual(SpeechScript.sentences("他找到了信。她走了！为什么？"), ["他找到了信。", "她走了！", "为什么？"])
    }

    // MARK: SSML

    func testSSMLHasProsodyBreaksAndEscaping() {
        let ssml = SpeechScript.ssml(for: "Tom & Jerry <ran>. Then \"stopped\".", ratePercent: 90, pauseMs: 300)
        XCTAssertEqual(ssml, "<speak><prosody rate=\"90%\">Tom &amp; Jerry &lt;ran&gt;.<break time=\"300ms\"/>"
                       + "Then &quot;stopped&quot;.</prosody></speak>")
    }

    func testSystemAcceptsTheSSML() {
        let text = "Holden found the letter. Mara's boat left at dawn & didn't return."
        XCTAssertNotNil(AVSpeechUtterance(ssmlRepresentation: SpeechScript.ssml(for: text)))
        XCTAssertNotNil(AVSpeechUtterance(ssmlRepresentation: SpeechScript.ssml(for: "他找到了信。她走了！")))
    }

    func testUtterancePrefersAssistiveSettings() {
        let utterance = SpeechScript.utterance(for: "One. Two.", voice: nil)
        XCTAssertTrue(utterance.prefersAssistiveTechnologySettings)
    }

    // MARK: Stream layout

    func testStreamLayoutIsCumulative() throws {
        let layout = try XCTUnwrap(RecapPlaybackController.streamLayout(durations: [100, 50.5, 20]))
        XCTAssertEqual(layout.map(\.index), [0, 1, 2])
        XCTAssertEqual(layout.map(\.startOffset), [0, 100, 150.5])
        XCTAssertEqual(layout.map(\.duration), [100, 50.5, 20])
    }

    func testStreamLayoutRefusesMissingDurations() {
        XCTAssertNil(RecapPlaybackController.streamLayout(durations: [100, nil]))
        XCTAssertNil(RecapPlaybackController.streamLayout(durations: [100, 0]))
        XCTAssertNil(RecapPlaybackController.streamLayout(durations: []))
    }
}
