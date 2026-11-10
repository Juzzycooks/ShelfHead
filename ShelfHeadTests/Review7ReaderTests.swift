import XCTest
@testable import ShelfHead

@available(iOS 26.0, *)
final class Review7ReaderTests: XCTestCase {
    private let block = "<B/>"

    func testInjectsRightAfterOpeningHead() {
        let out = EPUBSchemeHandler.injecting(block: block, into: "<html><HEAD lang=\"en\"><title>t</title></head><body/></html>")
        XCTAssertEqual(out, "<html><HEAD lang=\"en\"><B/><title>t</title></head><body/></html>")
    }

    func testSelfClosingHead() {
        let out = EPUBSchemeHandler.injecting(block: block, into: "<html><head/><body/></html>")
        XCTAssertEqual(out, "<html><head><B/></head><body/></html>")
    }

    func testNoHeadInsertsAfterHtml() {
        let src = "<?xml version=\"1.0\"?><!DOCTYPE html><html xmlns=\"x\"><body/></html>"
        let out = EPUBSchemeHandler.injecting(block: block, into: src)
        XCTAssertEqual(out, "<?xml version=\"1.0\"?><!DOCTYPE html><html xmlns=\"x\"><head><B/></head><body/></html>")
    }

    func testNoHeadNoHtmlGoesAfterDeclaration() {
        let out = EPUBSchemeHandler.injecting(block: block, into: "<?xml version=\"1.0\"?>\n<!DOCTYPE html><p>x</p>")
        XCTAssertTrue(out.hasPrefix("<?xml version=\"1.0\"?>\n<!DOCTYPE html><B/>"))
    }

    func testShouldApplyJobUpdate() {
        XCTAssertTrue(TranscriptionCenter.shouldApplyJobUpdate(jobScope: "a", currentScope: "a"))
        XCTAssertFalse(TranscriptionCenter.shouldApplyJobUpdate(jobScope: "a", currentScope: "b"))
    }

    func testSweepStillMatchesLooseNames() {
        XCTAssertTrue(RecapAudioRenderer.shouldSweepLooseFile(name: "recap-1.m4a", age: 7200))
        XCTAssertFalse(RecapAudioRenderer.shouldSweepLooseFile(name: "recap-1.m4a", age: 10))
    }
}
