import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ShelfHead

/// Batch 496 (REVIEW 2026-11-11 Y6): Spotlight thumbnail source choice and the change signature.
final class Batch496SpotlightThumbnailTests: XCTestCase {
    private func u(_ s: String) -> URL { URL(string: s)! }

    private func item(_ id: String) throws -> ShelfHead.LibraryItem {
        try JSONDecoder().decode(ShelfHead.LibraryItem.self, from: Data(#"{"id":"\#(id)"}"#.utf8))
    }

    func testNoCoverKeepsTheAppIcon() {
        XCTAssertNil(SpotlightIndexer.chooseThumbnailSource(downloadedCover: nil, cached: []))
    }

    func testDownloadedCoverWinsOverCache() {
        let local = u("file:///d/cover.jpg")
        let pick = SpotlightIndexer.chooseThumbnailSource(downloadedCover: local, cached: [(600, u("https://a/600"))])
        XCTAssertEqual(pick, local)
    }

    func testSmallestWidthThatIsBigEnoughIsChosen() {
        let pick = SpotlightIndexer.chooseThumbnailSource(
            downloadedCover: nil, cached: [(900, u("https://a/900")), (300, u("https://a/300")), (80, u("https://a/80"))])
        XCTAssertEqual(pick, u("https://a/300"))
    }

    func testFallsBackToLargestWhenAllAreTooSmall() {
        let pick = SpotlightIndexer.chooseThumbnailSource(
            downloadedCover: nil, cached: [(80, u("https://a/80")), (120, u("https://a/120"))])
        XCTAssertEqual(pick, u("https://a/120"))
    }

    func testSignatureChangesWhenCoverAppearsForAnItem() throws {
        let items = try [item("1"), item("2")]
        let none = SpotlightIndexer.signature(for: items, thumbnailIDs: [])
        let one = SpotlightIndexer.signature(for: items, thumbnailIDs: ["2"])
        let same = SpotlightIndexer.signature(for: items, thumbnailIDs: ["2"])
        XCTAssertNotEqual(none, one)
        XCTAssertEqual(one, same)
        XCTAssertNotEqual(one, SpotlightIndexer.signature(for: items, thumbnailIDs: ["1"]))
        XCTAssertFalse(SpotlightIndexer.shouldIndex(newSignature: one, lastSignature: same))
        XCTAssertTrue(SpotlightIndexer.shouldIndex(newSignature: one, lastSignature: none))
    }

    func testDownscaleShrinksLargeImage() throws {
        let size = 800
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let thumb = try XCTUnwrap(SpotlightIndexer.downscaledJPEG(from: out as Data, maxPixel: 256))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(thumb as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertLessThanOrEqual(props?[kCGImagePropertyPixelWidth] as? Int ?? 9999, 256)
        XCTAssertNil(SpotlightIndexer.downscaledJPEG(from: Data([1, 2, 3]), maxPixel: 256))
    }
}
