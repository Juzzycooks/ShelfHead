//
//  Batch496DownloadsSelectionTests.swift
//  ShelfHeadTests
//
//  Batch 496 (REVIEW 2026-11-11 D5): pins the copy for removing several downloads at once
//  from the Downloads page (`DownloadsRemovalCopy`).
//

import XCTest
@testable import ShelfHead

final class Batch496DownloadsSelectionTests: XCTestCase {

    func testTotalBytesSumsOnlyTheSelectedKnownSizes() {
        let sizes: [String: Int64] = ["a": 100, "b": 250, "c": 0, "z": 9_999]
        XCTAssertEqual(DownloadsRemovalCopy.totalBytes(of: ["a", "b", "c", "missing"], sizes: sizes), 350)
    }

    func testTotalBytesIsNilWhenNoSizeIsKnown() {
        XCTAssertNil(DownloadsRemovalCopy.totalBytes(of: ["missing"], sizes: [:]))
        XCTAssertNil(DownloadsRemovalCopy.totalBytes(of: [], sizes: ["a": 1]))
    }

    func testButtonTitleWithNothingSelected() {
        XCTAssertEqual(DownloadsRemovalCopy.buttonTitle(count: 0, bytes: 123), "Remove")
    }

    func testButtonTitleWithCountAndSize() {
        let bytes: Int64 = 2_100_000_000
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        XCTAssertEqual(DownloadsRemovalCopy.buttonTitle(count: 3, bytes: bytes), "Remove (3) \u{00B7} \(size)")
    }

    func testButtonTitleWithoutAKnownSize() {
        XCTAssertEqual(DownloadsRemovalCopy.buttonTitle(count: 3, bytes: nil), "Remove (3)")
        XCTAssertEqual(DownloadsRemovalCopy.buttonTitle(count: 3, bytes: 0), "Remove (3)")
    }

    func testOneBookReusesTheSingleRemovalCopy() {
        XCTAssertEqual(DownloadsRemovalCopy.confirmationTitle(count: 1), "Remove This Download?")
        XCTAssertEqual(DownloadsRemovalCopy.confirmButton(count: 1), "Remove Download")
        XCTAssertEqual(DownloadsRemovalCopy.message(count: 1),
                       "The downloaded audio will be deleted from this device. Your progress is kept.")
    }

    func testSeveralBooksNameTheCount() {
        XCTAssertEqual(DownloadsRemovalCopy.confirmationTitle(count: 3), "Remove 3 Downloads?")
        XCTAssertEqual(DownloadsRemovalCopy.confirmButton(count: 3), "Remove 3 Downloads")
        XCTAssertEqual(DownloadsRemovalCopy.message(count: 3),
                       "The downloaded audio for these books will be deleted from this device. Your progress is kept.")
    }
}
