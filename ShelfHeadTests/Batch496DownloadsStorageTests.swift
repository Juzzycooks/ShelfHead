//
//  Batch496DownloadsStorageTests.swift
//  ShelfHeadTests
//
//  Batch 496 (REVIEW 2026-11-11 D4): pins Settings › Downloads' storage bar
//  (`DownloadStorageBreakdown`): which segments show, their widths, and what VoiceOver reads.
//

import XCTest
@testable import ShelfHead

final class Batch496DownloadsStorageTests: XCTestCase {
    private typealias Breakdown = DownloadStorageBreakdown

    func testSegmentsKeepOrderAndSkipEmptyOrUnknownFigures() {
        let segments = Breakdown.segments(thisAccount: 500, otherAccounts: 0, signedOut: 20,
                                          transcripts: nil, covers: 30, free: 1_000)
        XCTAssertEqual(segments.map(\.kind), [.thisAccount, .signedOut, .covers, .free])
        XCTAssertEqual(segments.map(\.bytes), [500, 20, 30, 1_000])
    }

    func testNoFiguresMeansNoSegments() {
        XCTAssertTrue(Breakdown.segments(thisAccount: 0, otherAccounts: 0, signedOut: 0,
                                         transcripts: nil, covers: nil, free: nil).isEmpty)
    }

    func testFractionsAreProportionalAndSumToOne() {
        let segments = [Breakdown.Segment(kind: .thisAccount, bytes: 300),
                        Breakdown.Segment(kind: .free, bytes: 700)]
        let fractions = Breakdown.fractions(segments)
        XCTAssertEqual(fractions[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(fractions[1], 0.7, accuracy: 0.0001)
    }

    func testATinySegmentIsLiftedToTheMinimumAndTheTotalStaysOne() {
        let segments = [Breakdown.Segment(kind: .free, bytes: 1_000_000),
                        Breakdown.Segment(kind: .covers, bytes: 1)]
        let fractions = Breakdown.fractions(segments, minimumFraction: 0.02)
        XCTAssertEqual(fractions[1], 0.02, accuracy: 0.0001)
        XCTAssertEqual(fractions.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertGreaterThan(fractions[0], fractions[1])
    }

    func testManyTinySegmentsStillSumToOne() {
        let segments = Breakdown.Kind.allCases.map { Breakdown.Segment(kind: $0, bytes: 1) }
            + [Breakdown.Segment(kind: .free, bytes: 10_000_000)]
        let fractions = Breakdown.fractions(segments)
        XCTAssertEqual(fractions.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertTrue(fractions.allSatisfy { $0 > 0 })
    }

    func testEmptyAndZeroInputs() {
        XCTAssertEqual(Breakdown.fractions([]), [])
        XCTAssertEqual(Breakdown.fractions([Breakdown.Segment(kind: .free, bytes: 0)]), [0])
    }

    func testEveryKindHasALabel() {
        for kind in Breakdown.Kind.allCases {
            XCTAssertFalse(Breakdown.label(for: kind).isEmpty, "\(kind)")
        }
    }

    func testAccessibilitySummaryNamesEverySegmentWithItsSize() {
        let segments = [Breakdown.Segment(kind: .thisAccount, bytes: 2_000_000_000),
                        Breakdown.Segment(kind: .free, bytes: 50_000_000_000)]
        let summary = Breakdown.accessibilitySummary(segments)
        XCTAssertTrue(summary.contains(Breakdown.label(for: .thisAccount)), summary)
        XCTAssertTrue(summary.contains(Breakdown.label(for: .free)), summary)
        XCTAssertTrue(summary.contains(ByteCountFormatter.string(fromByteCount: 2_000_000_000, countStyle: .file)), summary)
        XCTAssertTrue(summary.contains(ByteCountFormatter.string(fromByteCount: 50_000_000_000, countStyle: .file)), summary)
    }

    func testAccessibilitySummaryWithNoSegmentsIsNotEmpty() {
        XCTAssertFalse(Breakdown.accessibilitySummary([]).isEmpty)
    }
}
