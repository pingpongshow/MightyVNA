import XCTest
@testable import VNACore

final class TouchstoneTests: XCTestCase {

    private func sampleFrame() -> SweepFrame {
        let frequencies = (0..<25).map { 1e6 + Double($0) * 10e6 }
        let s11 = frequencies.map { Complex(magnitude: 0.4, angle: -2 * .pi * $0 * 3e-9) }
        let s21 = frequencies.map { Complex(magnitude: 0.8, angle: -2 * .pi * $0 * 1e-9) }
        return SweepFrame(frequencies: frequencies, s11: s11, s21: s21, z0: 50)
    }

    func testRoundTripRealImaginary1Port() throws {
        let frame = sampleFrame()
        var options = Touchstone.WriteOptions()
        options.ports = 1
        options.format = .realImaginary
        let text = Touchstone.string(from: frame, options: options)
        let parsed = try Touchstone.parse(text)
        XCTAssertEqual(parsed.count, frame.count)
        for i in 0..<frame.count {
            XCTAssertEqual(parsed.frequencies[i], frame.frequencies[i], accuracy: 1)
            XCTAssertEqual(parsed.s11[i].re, frame.s11[i].re, accuracy: 1e-8)
            XCTAssertEqual(parsed.s11[i].im, frame.s11[i].im, accuracy: 1e-8)
        }
    }

    func testRoundTripMagnitudeAngle2Port() throws {
        let frame = sampleFrame()
        var options = Touchstone.WriteOptions()
        options.ports = 2
        options.format = .magnitudeAngle
        options.frequencyUnit = .mhz
        options.assumeReciprocal = true
        let text = Touchstone.string(from: frame, options: options)
        let parsed = try Touchstone.parse(text)
        XCTAssertEqual(parsed.count, frame.count)
        for i in 0..<frame.count {
            XCTAssertEqual(parsed.frequencies[i], frame.frequencies[i], accuracy: 10)
            XCTAssertEqual(parsed.s21[i].magnitude, frame.s21[i].magnitude, accuracy: 1e-7)
        }
    }

    func testParsesDecibelAngleAndComments() throws {
        let text = """
        ! A comment
        # MHz S DB R 50
        1.0 -20.0 45.0
        2.0 -10.0 -90.0
        """
        let frame = try Touchstone.parse(text)
        XCTAssertEqual(frame.count, 2)
        XCTAssertEqual(frame.frequencies[0], 1e6, accuracy: 1)
        XCTAssertEqual(RF.dB(frame.s11[0].magnitude), -20, accuracy: 1e-9)
        XCTAssertEqual(frame.s11[0].phase * 180 / .pi, 45, accuracy: 1e-9)
        XCTAssertEqual(frame.s11[1].phase * 180 / .pi, -90, accuracy: 1e-9)
    }

    func testMissingOptionLineThrows() {
        XCTAssertThrowsError(try Touchstone.parse("1.0 0.5 0.5\n"))
    }

    func testCSVHasOneRowPerPoint() {
        let frame = sampleFrame()
        let lines = Touchstone.csv(from: frame).split(separator: "\n")
        XCTAssertEqual(lines.count, frame.count + 1)   // header + data
        XCTAssertTrue(lines[0].contains("SWR"))
    }
}

final class MatchingTests: XCTestCase {

    func testLNetworksActuallyMatch() {
        let frequency = 145e6
        let loads = [Complex(25, 0), Complex(100, 0), Complex(20, 30), Complex(120, -60), Complex(8, -12)]
        for load in loads {
            let solutions = MatchingNetwork.lNetworks(load: load, z0: 50, frequency: frequency)
            XCTAssertFalse(solutions.isEmpty, "no solution for \(load)")
            for solution in solutions {
                let result = MatchingNetwork.resultingImpedance(load: load, solution: solution, frequency: frequency)
                XCTAssertEqual(result.re, 50, accuracy: 0.05, "topology \(solution.topology) for load \(load)")
                XCTAssertEqual(result.im, 0, accuracy: 0.05, "topology \(solution.topology) for load \(load)")
            }
        }
    }

    func testAlreadyMatchedLoadNeedsNoTransformation() {
        let solutions = MatchingNetwork.lNetworks(load: Complex(50, 0), z0: 50, frequency: 100e6)
        for solution in solutions {
            let result = MatchingNetwork.resultingImpedance(load: Complex(50, 0), solution: solution, frequency: 100e6)
            XCTAssertEqual(result.re, 50, accuracy: 0.05)
            XCTAssertEqual(result.im, 0, accuracy: 0.05)
        }
    }

    func testQuarterWaveImpedance() {
        let z = MatchingNetwork.quarterWaveImpedance(load: Complex(200, 0), z0: 50)
        XCTAssertEqual(z!, 100, accuracy: 1e-9)
        XCTAssertNil(MatchingNetwork.quarterWaveImpedance(load: Complex(50, 40), z0: 50),
                     "a strongly reactive load has no simple quarter-wave match")
    }
}

final class AnalysisTests: XCTestCase {

    /// A series RLC resonator seen as S11.
    private func resonator(f0: Double, q: Double, r: Double, frequencies: [Double]) -> [Complex] {
        let l = r * q / (2 * .pi * f0)
        let c = 1 / (l * pow(2 * .pi * f0, 2))
        return frequencies.map { f in
            let omega = 2 * .pi * f
            let z = Complex(r, omega * l - 1 / (omega * c))
            return RF.reflection(fromImpedance: z, z0: 50)
        }
    }

    func testAntennaAnalysisFindsResonance() {
        let frequencies = (0..<801).map { 100e6 + Double($0) * 0.2e6 }
        let s11 = resonator(f0: 145e6, q: 20, r: 50, frequencies: frequencies)
        let report = AntennaAnalysis.analyse(s11: s11, frequencies: frequencies, z0: 50, swrThreshold: 2)
        XCTAssertTrue(report.isValid)
        XCTAssertEqual(report.resonantFrequency, 145e6, accuracy: 0.5e6)
        XCTAssertEqual(report.minimumSWR, 1, accuracy: 0.05)
        XCTAssertGreaterThan(report.bandwidth, 0)
        // A Q of 20 with a matched feedpoint gives a broad SWR<2 window.
        XCTAssertEqual(report.impedanceAtResonance.re, 50, accuracy: 2)
        XCTAssertEqual(report.impedanceAtResonance.im, 0, accuracy: 3)
    }

    func testBandwidthOfSyntheticFilter() {
        let f0 = 300e6, bw = 60e6
        let frequencies = (0..<1001).map { 100e6 + Double($0) * 0.5e6 }
        let s21 = frequencies.map { f -> Complex in
            let x = (f / f0 - f0 / f) * (f0 / bw)
            return Complex(magnitude: 1 / (1 + pow(x, 6)).squareRoot(), angle: 0)
        }
        let report = FilterAnalysis.analyse(s21: s21, frequencies: frequencies)
        XCTAssertTrue(report.isValid)
        XCTAssertEqual(report.centerFrequency, f0, accuracy: 3e6)
        XCTAssertEqual(report.bandwidth3dB, bw, accuracy: 4e6)
        XCTAssertEqual(report.insertionLoss, 0, accuracy: 0.1)
    }

    func testPeakDetectionOrdersByProminence() {
        var values = [Double](repeating: 0, count: 100)
        values[20] = 1      // small peak
        values[60] = 5      // big peak
        let peaks = TraceAnalysis.peaks(values)
        XCTAssertEqual(peaks.first, 60)
        XCTAssertTrue(peaks.contains(20))
    }

    func testCableVelocityFactorFromKnownLength() {
        let vf = 0.66
        let length = 2.5
        let roundTrip = 2 * length / (speedOfLight * vf)
        let measured = CableTools.velocityFactor(physicalLength: length, roundTripDelay: roundTrip)
        XCTAssertEqual(measured!, vf, accuracy: 1e-9)
        XCTAssertEqual(CableTools.length(roundTripDelay: roundTrip, velocityFactor: vf), length, accuracy: 1e-9)
    }

    func testLimitEvaluation() {
        var set = LimitSet()
        set.enabled = true
        set.segments = [LimitSegment(kind: .maximum, startFrequency: 0, stopFrequency: 100,
                                     startValue: 2, stopValue: 2)]
        let pass = set.evaluate(x: [10, 50, 90], y: [1.2, 1.5, 1.9])
        XCTAssertTrue(pass.passed)
        let fail = set.evaluate(x: [10, 50, 90], y: [1.2, 2.5, 1.9])
        XCTAssertFalse(fail.passed)
        XCTAssertEqual(fail.failingIndices, [1])
    }
}

final class SweepFrameTests: XCTestCase {

    func testUniformGridDetection() {
        let uniform = SweepFrame(frequencies: [1e6, 2e6, 3e6], s11: [], s21: [])
        XCTAssertTrue(uniform.isUniformGrid)
        let irregular = SweepFrame(frequencies: [1e6, 2e6, 9e6], s11: [], s21: [])
        XCTAssertFalse(irregular.isUniformGrid)
    }

    func testAveragingConverges() {
        var accumulator = SweepAccumulator()
        accumulator.mode = .average
        accumulator.depth = 4
        let grid = [1e6, 2e6]
        var last = SweepFrame(frequencies: grid, s11: [], s21: [])
        for i in 0..<20 {
            // Alternate ±0.1 around 0.5; the average should approach 0.5.
            let offset = i % 2 == 0 ? 0.1 : -0.1
            let frame = SweepFrame(frequencies: grid,
                                   s11: [Complex(0.5 + offset, 0), Complex(0.5 + offset, 0)],
                                   s21: [.zero, .zero])
            last = accumulator.process(frame)
        }
        XCTAssertEqual(last.s11[0].re, 0.5, accuracy: 0.06)
    }

    func testMaxHoldKeepsLargest() {
        var accumulator = SweepAccumulator()
        accumulator.mode = .maxHold
        let grid = [1e6]
        _ = accumulator.process(SweepFrame(frequencies: grid, s11: [Complex(0.2, 0)], s21: [.zero]))
        _ = accumulator.process(SweepFrame(frequencies: grid, s11: [Complex(0.8, 0)], s21: [.zero]))
        let out = accumulator.process(SweepFrame(frequencies: grid, s11: [Complex(0.3, 0)], s21: [.zero]))
        XCTAssertEqual(out.s11[0].re, 0.8, accuracy: 1e-12)
    }

    func testResamplingOntoNewGrid() {
        let frame = SweepFrame(frequencies: [1e6, 2e6, 3e6],
                               s11: [Complex(1, 0), Complex(2, 0), Complex(3, 0)],
                               s21: [.zero, .zero, .zero])
        let resampled = frame.resampled(to: [1.5e6, 2.5e6])
        XCTAssertEqual(resampled.s11[0].re, 1.5, accuracy: 1e-9)
        XCTAssertEqual(resampled.s11[1].re, 2.5, accuracy: 1e-9)
    }

    func testSweepSegmentation() {
        var config = SweepConfiguration(start: 1e6, stop: 1e9, points: 1001)
        XCTAssertEqual(config.segmentCount(for: DeviceCatalog.nanoVNAFV2), 4)   // 301 per pass
        config.points = 201
        XCTAssertEqual(config.segmentCount(for: DeviceCatalog.nanoVNAFV2), 1)
    }

    func testConfigurationClampsToDeviceLimits() {
        let config = SweepConfiguration(start: 1, stop: 9e9, points: 201)
        let clamped = config.clamped(to: DeviceCatalog.nanoVNAFV2)
        XCTAssertEqual(clamped.start, DeviceCatalog.nanoVNAFV2.minFrequency)
        XCTAssertEqual(clamped.stop, DeviceCatalog.nanoVNAFV2.maxFrequency)
    }
}
