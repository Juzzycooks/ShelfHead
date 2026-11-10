import XCTest
@testable import ShelfHead

final class Review6RecapEPUBTests: XCTestCase {
    func testLooseFileSweep() {
        XCTAssertTrue(RecapAudioRenderer.shouldSweepLooseFile(name: "recap-ABC.m4a", age: 7200))
        XCTAssertFalse(RecapAudioRenderer.shouldSweepLooseFile(name: "recap-ABC.m4a", age: 60))
        XCTAssertFalse(RecapAudioRenderer.shouldSweepLooseFile(name: "other.m4a", age: 7200))
    }

    @available(iOS 26.0, *)
    func testEPUBInjectionIncludesCSP() throws {
        let html = Data("<html><head></head><body></body></html>".utf8)
        let out = try XCTUnwrap(String(data: EPUBSchemeHandler.injectingStyle(into: html, css: "p{}"), encoding: .utf8))
        XCTAssertTrue(out.contains("Content-Security-Policy"))
        XCTAssertTrue(out.contains("img-src shelfhead-epub: data:"))
        XCTAssertTrue(out.contains("id=\"shelfhead-style\""))
    }
}
