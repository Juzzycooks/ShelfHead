import XCTest
@testable import ShelfHead

/// Batch 438: pins the biquad maths, compressor curve, loudness leveller and the offline meter.
final class DialogueDSPTests: XCTestCase {
    private let fs = 48_000.0

    // MARK: Biquad

    func testKWeightingShelfMatchesBS1770At48k() {
        let c = BiquadCoefficients.kWeightingShelf(sampleRate: 48_000)
        XCTAssertEqual(c.b0, 1.53512485958697, accuracy: 1e-9)
        XCTAssertEqual(c.b1, -2.69169618940638, accuracy: 1e-9)
        XCTAssertEqual(c.b2, 1.19839281085285, accuracy: 1e-9)
        XCTAssertEqual(c.a1, -1.69065929318241, accuracy: 1e-9)
        XCTAssertEqual(c.a2, 0.73248077421585, accuracy: 1e-9)
        let hp = BiquadCoefficients.kWeightingHighPass(sampleRate: 48_000)
        XCTAssertEqual(hp.a1, -1.99004745483398, accuracy: 1e-9)
        XCTAssertEqual(hp.a2, 0.99007225036621, accuracy: 1e-9)
    }

    func testHighPassCoefficientsMatchCookbook() {
        // fc = fs/4 -> w0 = pi/2, cos = 0, sin = 1; Q = 1/sqrt2 -> alpha = 0.7071...
        let c = BiquadCoefficients.highPass(frequency: 12_000, q: 0.5.squareRoot(), sampleRate: 48_000)
        let a0 = 1 + 1 / (2 * 0.5.squareRoot())
        XCTAssertEqual(c.b0, 0.5 / a0, accuracy: 1e-12)
        XCTAssertEqual(c.b1, -1 / a0, accuracy: 1e-12)
        XCTAssertEqual(c.a1, 0, accuracy: 1e-12)
        XCTAssertEqual(c.a2, (1 - 1 / (2 * 0.5.squareRoot())) / a0, accuracy: 1e-12)
    }

    func testPeakingFilterMagnitudeAtCentreIsTheGain() {
        for gain in [-3.0, 4.0, 9.0] {
            let c = BiquadCoefficients.peaking(frequency: 2_800, q: 0.9, gainDB: gain, sampleRate: fs)
            let db = 20 * log10(c.magnitude(atFrequency: 2_800, sampleRate: fs))
            XCTAssertEqual(db, gain, accuracy: 0.01)
        }
        let c = BiquadCoefficients.peaking(frequency: 300, q: 1, gainDB: -3, sampleRate: fs)
        XCTAssertEqual(c.magnitude(atFrequency: 10, sampleRate: fs), 1, accuracy: 0.01)
        XCTAssertEqual(c.magnitude(atFrequency: 15_000, sampleRate: fs), 1, accuracy: 0.01)
    }

    func testHighPassAttenuatesLowAndPassesHigh() {
        let c = BiquadCoefficients.highPass(frequency: 90, q: 0.707, sampleRate: fs)
        XCTAssertLessThan(c.magnitude(atFrequency: 20, sampleRate: fs), 0.05)
        XCTAssertEqual(c.magnitude(atFrequency: 1_000, sampleRate: fs), 1, accuracy: 0.01)
        XCTAssertEqual(20 * log10(c.magnitude(atFrequency: 90, sampleRate: fs)), -3, accuracy: 0.1)
    }

    func testShelvesReachTheirGainAwayFromTheCorner() {
        let low = BiquadCoefficients.lowShelf(frequency: 120, gainDB: 6, sampleRate: fs)
        XCTAssertEqual(20 * log10(low.magnitude(atFrequency: 20, sampleRate: fs)), 6, accuracy: 0.2)
        XCTAssertEqual(20 * log10(low.magnitude(atFrequency: 10_000, sampleRate: fs)), 0, accuracy: 0.2)
        let high = BiquadCoefficients.highShelf(frequency: 6_000, gainDB: -5, sampleRate: fs)
        XCTAssertEqual(20 * log10(high.magnitude(atFrequency: 20_000, sampleRate: fs)), -5, accuracy: 0.4)
        XCTAssertEqual(20 * log10(high.magnitude(atFrequency: 200, sampleRate: fs)), 0, accuracy: 0.2)
    }

    func testBiquadStateMatchesFrequencyResponse() {
        // Steady-state amplitude of a 1 kHz sine through the 2.8 kHz peaking filter equals |H|.
        let c = BiquadCoefficients.peaking(frequency: 2_800, q: 0.9, gainDB: 4, sampleRate: fs)
        var s = BiquadState()
        var peak = 0.0
        for n in 0..<48_000 {
            let y = s.process(sin(2 * .pi * 1_000 * Double(n) / fs), c)
            if n > 24_000 { peak = max(peak, abs(y)) }
        }
        XCTAssertEqual(peak, c.magnitude(atFrequency: 1_000, sampleRate: fs), accuracy: 0.005)
    }

    // MARK: Compressor

    func testCompressorCurve() {
        let t = -24.0, r = 4.0, w = 10.0
        // Below the knee: unchanged.
        XCTAssertEqual(SoftKneeCompressor.outputLevelDB(inputDB: -40, thresholdDB: t, ratio: r, kneeDB: w), -40, accuracy: 1e-9)
        // Above the knee: threshold + over/ratio.
        XCTAssertEqual(SoftKneeCompressor.outputLevelDB(inputDB: -4, thresholdDB: t, ratio: r, kneeDB: w), -24 + 20 / 4, accuracy: 1e-9)
        // At the threshold: inside the knee, reduced by (1/r-1)*(w/2)^2/(2w).
        let mid = SoftKneeCompressor.outputLevelDB(inputDB: -24, thresholdDB: t, ratio: r, kneeDB: w)
        XCTAssertEqual(mid, -24 + (1 / 4 - 1) * 25 / 20, accuracy: 1e-9)
        // Continuous at both knee edges.
        let lo = SoftKneeCompressor.outputLevelDB(inputDB: -29, thresholdDB: t, ratio: r, kneeDB: w)
        let hi = SoftKneeCompressor.outputLevelDB(inputDB: -19, thresholdDB: t, ratio: r, kneeDB: w)
        XCTAssertEqual(lo, -29, accuracy: 1e-9)
        XCTAssertEqual(hi, -24 + 5 / 4, accuracy: 1e-9)
    }

    func testCompressorSmoothingReducesLoudPeaksAndRecovers() {
        var comp = SoftKneeCompressor()
        let a = SoftKneeCompressor.smoothingCoefficient(seconds: comp.attackSeconds, sampleRate: fs)
        let r = SoftKneeCompressor.smoothingCoefficient(seconds: comp.releaseSeconds, sampleRate: fs)
        var g: Float = 1
        for _ in 0..<4_800 { g = comp.gain(forPeak: 1.0, attackCoeff: a, releaseCoeff: r) }
        XCTAssertLessThan(comp.smoothedGainDB, -8)       // 0 dBFS over a -24 dB threshold at 2.5:1
        XCTAssertLessThan(g, 1)
        for _ in 0..<(48_000 * 2) { g = comp.gain(forPeak: 0.001, attackCoeff: a, releaseCoeff: r) }
        XCTAssertEqual(comp.smoothedGainDB, 0, accuracy: 0.1)
    }

    // MARK: Leveller

    func testLevellerMovesTowardTargetAndIsLimited() {
        var l = LoudnessLeveller()
        let quiet = LoudnessLeveller.power(fromLUFS: -24)        // needs +6 dB
        var last = 0.0
        for _ in 0..<2_000 {                                     // 200 s of 100 ms blocks
            last = l.ingest(blockPower: quiet, blockSeconds: 0.1)
        }
        XCTAssertEqual(last, 6, accuracy: 0.05)
        var loud = LoudnessLeveller()
        for _ in 0..<2_000 { last = loud.ingest(blockPower: LoudnessLeveller.power(fromLUFS: -3), blockSeconds: 0.1) }
        XCTAssertEqual(last, -9, accuracy: 0.001)                // +15 needed -> clamped at -9
    }

    func testLevellerSlewIsLimited() {
        var l = LoudnessLeveller()
        let g = l.ingest(blockPower: LoudnessLeveller.power(fromLUFS: -28), blockSeconds: 0.1)
        XCTAssertEqual(g, 0.15, accuracy: 1e-9)                  // 1.5 dB/s * 0.1 s
    }

    func testLevellerFreezesInSilence() {
        var l = LoudnessLeveller()
        for _ in 0..<300 { l.ingest(blockPower: LoudnessLeveller.power(fromLUFS: -26), blockSeconds: 0.1) }
        let before = l.gainDB, measured = l.measuredLUFS
        XCTAssertGreaterThan(before, 1)
        for _ in 0..<600 { l.ingest(blockPower: LoudnessLeveller.power(fromLUFS: -70), blockSeconds: 0.1) }
        XCTAssertEqual(l.gainDB, before)
        XCTAssertEqual(l.measuredLUFS, measured)
    }

    func testLevellerSeedStartsMatched() {
        var l = LoudnessLeveller()
        l.seed(loudnessLUFS: -24)
        XCTAssertEqual(l.gainDB, 6, accuracy: 1e-9)
        XCTAssertEqual(LoudnessCache.startingGainDB(forLoudness: -40), 9)
        XCTAssertEqual(LoudnessCache.startingGainDB(forLoudness: -12), -6)
    }

    // MARK: Loudness meter

    private func sine(_ freq: Double, dBFS: Double, seconds: Double) -> [Float] {
        let amp = pow(10, dBFS / 20)
        return (0..<Int(seconds * fs)).map { Float(amp * sin(2 * .pi * freq * Double($0) / fs)) }
    }

    func testKWeightingGainAt1kHzIsAboutPoint7dB() {
        let shelf = BiquadCoefficients.kWeightingShelf(sampleRate: fs)
        let hp = BiquadCoefficients.kWeightingHighPass(sampleRate: fs)
        let db = 20 * log10(shelf.magnitude(atFrequency: 1_000, sampleRate: fs) * hp.magnitude(atFrequency: 1_000, sampleRate: fs))
        XCTAssertEqual(db, 0.69, accuracy: 0.1)
    }

    func testStereoSineAtMinus20dBFSReadsAboutMinus20LUFS() {
        // BS.1770: LKFS = -0.691 + 10 log10(sum of channel mean-squares). A 1 kHz sine at -20 dBFS peak
        // has mean square 0.01/2 = -23.01 dB; two channels add 3.01 dB; K-weighting adds ~+0.69 dB at 1 kHz
        // and the -0.691 offset cancels it: expected -20.0 LUFS.
        var m = LoudnessMeter(sampleRate: fs, channelCount: 2)
        let s = sine(1_000, dBFS: -20, seconds: 10)
        m.append([s, s])
        XCTAssertEqual(m.integratedLoudness ?? -999, -20.0, accuracy: 0.3)
    }

    func testMonoCountsAsDualMono() {
        var mono = LoudnessMeter(sampleRate: fs, channelCount: 1)
        var stereo = LoudnessMeter(sampleRate: fs, channelCount: 2)
        let s = sine(1_000, dBFS: -20, seconds: 5)
        mono.append([s]); stereo.append([s, s])
        XCTAssertEqual(mono.integratedLoudness ?? -999, stereo.integratedLoudness ?? 999, accuracy: 0.01)
    }

    func testMeterTracksLevelChangesAndGatesSilence() {
        var a = LoudnessMeter(sampleRate: fs, channelCount: 1)
        var b = LoudnessMeter(sampleRate: fs, channelCount: 1)
        a.append([sine(1_000, dBFS: -20, seconds: 5)])
        b.append([sine(1_000, dBFS: -30, seconds: 5)])
        XCTAssertEqual((a.integratedLoudness ?? 0) - (b.integratedLoudness ?? 0), 10, accuracy: 0.05)
        // Silence around the tone is gated out: same reading as the tone alone.
        var c = LoudnessMeter(sampleRate: fs, channelCount: 1)
        c.append([[Float](repeating: 0, count: Int(3 * fs)) + sine(1_000, dBFS: -20, seconds: 5) + [Float](repeating: 0, count: Int(3 * fs))])
        XCTAssertEqual(c.integratedLoudness ?? -999, a.integratedLoudness ?? 999, accuracy: 0.3)
        // Pure silence: no reading.
        var d = LoudnessMeter(sampleRate: fs, channelCount: 1)
        d.append([[Float](repeating: 0, count: Int(2 * fs))])
        XCTAssertNil(d.integratedLoudness)
    }

    // MARK: Processor

    func testProcessorIsTransparentWhenEverythingIsOff() {
        let proc = AudioChainProcessor(channelCount: 1, sampleRate: fs)
        proc.apply(.init())
        var data = sine(440, dBFS: -12, seconds: 0.1)
        let original = data
        data.withUnsafeMutableBufferPointer { buf in
            let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 8)
            table.initialize(repeating: nil, count: 8)
            table[0] = buf.baseAddress
            proc.process(channels: table, count: 1, frames: buf.count)
            table.deallocate()
        }
        XCTAssertEqual(data, original)
    }

    func testProcessorLevellerLiftsAQuietSignal() {
        let proc = AudioChainProcessor(channelCount: 1, sampleRate: fs)
        var p = AudioChainProcessor.Parameters()
        p.level = true
        proc.apply(p)
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 8)
        table.initialize(repeating: nil, count: 8)
        defer { table.deallocate() }
        var tail: Float = 0
        for _ in 0..<600 {                                       // 600 x 4800 frames = 60 s
            var block = sine(1_000, dBFS: -30, seconds: 0.1)
            block.withUnsafeMutableBufferPointer { buf in
                table[0] = buf.baseAddress
                proc.process(channels: table, count: 1, frames: buf.count)
                tail = buf.map { abs($0) }.max() ?? 0
            }
        }
        XCTAssertGreaterThan(proc.leveller.gainDB, 5)
        XCTAssertGreaterThan(tail, Float(pow(10, -30.0 / 20)) * 1.8)
    }
}
