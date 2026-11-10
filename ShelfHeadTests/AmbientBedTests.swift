import XCTest
@testable import ShelfHead

/// Batch 439: ambient bed generators, gain maths and profile override decoding.
@MainActor
final class AmbientBedTests: XCTestCase {
    private func render(_ bed: AmbientBed, seed: UInt64, frames: Int, sampleRate: Double = 44_100) -> ([Float], [Float]) {
        var renderer = AmbientRenderer(bed: bed, seed: seed)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                // Render in uneven chunks, as the audio thread does.
                var done = 0
                let sizes = [512, 333, 1024, 77]
                var i = 0
                while done < frames {
                    let n = min(sizes[i % sizes.count], frames - done)
                    renderer.render(left: l.baseAddress! + done, right: r.baseAddress! + done,
                                    frames: n, sampleRate: sampleRate)
                    done += n; i += 1
                }
            }
        }
        return (left, right)
    }

    func testDeterministicForSeed() {
        for bed in AmbientBed.allCases {
            let a = render(bed, seed: 42, frames: 20_000)
            let b = render(bed, seed: 42, frames: 20_000)
            XCTAssertEqual(a.0, b.0, "\(bed)")
            XCTAssertEqual(a.1, b.1, "\(bed)")
            let c = render(bed, seed: 43, frames: 20_000)
            XCTAssertNotEqual(a.0, c.0, "\(bed) differs by seed")
        }
    }

    func testBoundedNonSilentFiniteAndStereoDecorrelated() {
        for bed in AmbientBed.allCases {
            let (l, r) = render(bed, seed: 7, frames: 44_100 * 6)
            for x in l + r {
                XCTAssertFalse(x.isNaN || x.isInfinite)
                XCTAssertLessThan(abs(x), 0.9, "\(bed)")
            }
            let rms = (l.reduce(0) { $0 + $1 * $1 } / Float(l.count)).squareRoot()
            XCTAssertGreaterThan(rms, 0.005, "\(bed) is audible")
            XCTAssertLessThan(rms, 0.4, "\(bed) is quiet")
            XCTAssertNotEqual(l, r, "\(bed) channels differ")
        }
    }

    func testRNGRanges() {
        var rng = AmbientRNG(seed: 1)
        for _ in 0..<10_000 {
            let s = rng.nextSigned(), u = rng.nextUnit()
            XCTAssertTrue(s >= -1 && s < 1)
            XCTAssertTrue(u >= 0 && u < 1)
        }
    }

    func testGainMapping() {
        XCTAssertEqual(AmbientMath.gain(forLevel: 0), 0)
        XCTAssertEqual(AmbientMath.gain(forLevel: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(AmbientMath.gain(forLevel: -3), 0)
        XCTAssertEqual(AmbientMath.gain(forLevel: 9), 1, accuracy: 1e-6)
        XCTAssertLessThan(AmbientMath.gain(forLevel: 0.25), 0.25)
        XCTAssertLessThan(AmbientMath.gain(forLevel: 0.4), AmbientMath.gain(forLevel: 0.5))
    }

    func testSoftLimitBound() {
        for x in stride(from: Float(-1000), through: 1000, by: 0.5) {
            XCTAssertLessThan(abs(AmbientMath.softLimit(x)), 0.85)
        }
        XCTAssertEqual(AmbientMath.softLimit(0), 0)
    }

    func testShouldRun() {
        XCTAssertFalse(AmbientMath.shouldRun(bed: nil, isPlaying: true))
        XCTAssertFalse(AmbientMath.shouldRun(bed: .rain, isPlaying: false))
        XCTAssertTrue(AmbientMath.shouldRun(bed: .rain, isPlaying: true))
    }

    func testRampFadesInOneSecondAndOutInHalf() {
        var ramp = AmbientGainRamp(sampleRate: 1000)
        var last: Float = 0
        for _ in 0..<500 {
            let v = ramp.next(toward: 1)
            XCTAssertGreaterThanOrEqual(v, last)
            XCTAssertLessThanOrEqual(v - last, 0.0011)
            last = v
        }
        XCTAssertEqual(last, 0.5, accuracy: 0.01)
        for _ in 0..<500 { last = ramp.next(toward: 1) }
        XCTAssertEqual(last, 1, accuracy: 0.01)
        for _ in 0..<500 { last = ramp.next(toward: 0) }
        XCTAssertEqual(last, 0, accuracy: 0.01)
    }

    func testRampDoesNotOvershoot() {
        var ramp = AmbientGainRamp(sampleRate: 100, initial: 0.5)
        for _ in 0..<1000 { XCTAssertEqual(ramp.next(toward: 0.5), 0.5) }
    }

    func testOverridesDecodeOldJSONWithoutAmbientFields() throws {
        let old = #"{"playbackSpeed":0.75,"keepScreenAwake":false,"sleepFadeOut":true,"armsSleepTimer":true}"#
        let decoded = try JSONDecoder().decode(ListeningProfile.Overrides.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.playbackSpeed, 0.75)
        XCTAssertNil(decoded.ambientBed)
        XCTAssertNil(decoded.ambientLevel)
        let new = try JSONDecoder().decode(ListeningProfile.Overrides.self, from: Data(#"{"ambientBed":"rain","ambientLevel":0.2}"#.utf8))
        XCTAssertEqual(new.ambientBed, .rain)
    }
}
