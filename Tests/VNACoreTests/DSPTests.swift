import XCTest
@testable import VNACore

final class FFTTests: XCTestCase {

    private func naiveDFT(_ input: [Complex]) -> [Complex] {
        let n = input.count
        return (0..<n).map { k in
            var acc = Complex.zero
            for t in 0..<n {
                acc += input[t] * Complex.expj(-2 * .pi * Double(k * t) / Double(n))
            }
            return acc
        }
    }

    func testMatchesNaiveDFT() {
        var seed = 12345.0
        func next() -> Double { seed = fmod(seed * 16807, 2147483647); return seed / 2147483647 - 0.5 }
        let input = (0..<64).map { _ in Complex(next(), next()) }
        let fast = FFT.forward(input)
        let slow = naiveDFT(input)
        for i in input.indices {
            XCTAssertEqual(fast[i].re, slow[i].re, accuracy: 1e-9)
            XCTAssertEqual(fast[i].im, slow[i].im, accuracy: 1e-9)
        }
    }

    func testRoundTrip() {
        let input = (0..<128).map { Complex(sin(Double($0) * 0.3), cos(Double($0) * 0.11)) }
        let back = FFT.inverse(FFT.forward(input))
        for i in input.indices {
            XCTAssertEqual(back[i].re, input[i].re, accuracy: 1e-10)
            XCTAssertEqual(back[i].im, input[i].im, accuracy: 1e-10)
        }
    }

    func testNextPowerOfTwo() {
        XCTAssertEqual(FFT.nextPowerOfTwo(1), 1)
        XCTAssertEqual(FFT.nextPowerOfTwo(5), 8)
        XCTAssertEqual(FFT.nextPowerOfTwo(64), 64)
        XCTAssertEqual(FFT.nextPowerOfTwo(65), 128)
    }
}

final class TimeDomainTests: XCTestCase {

    /// An ideal lossless line of `length` metres terminated in an open circuit.
    private func openStub(length: Double, velocityFactor: Double, frequencies: [Double]) -> [Complex] {
        let oneWayDelay = length / (speedOfLight * velocityFactor)
        return frequencies.map { Complex.expj(-2 * 2 * .pi * $0 * oneWayDelay) }
    }

    func testLowpassStepFindsCableEnd() {
        let df = 10e6
        let frequencies = (1...101).map { Double($0) * df }
        let vf = 0.66
        let length = 1.0
        let s11 = openStub(length: length, velocityFactor: vf, frequencies: frequencies)

        var settings = TimeDomainSettings()
        settings.mode = .lowpassStep
        settings.window = .hann
        settings.velocityFactor = vf
        settings.padFactor = 8

        let result = TimeDomain.transform(frequencies: frequencies, values: s11, settings: settings)
        XCTAssertFalse(result.isEmpty)

        // The impulse response should peak at the open end of the line.
        let magnitudes = result.impulse.map { abs($0) }
        guard let peak = TraceAnalysis.indexOfMaximum(Array(magnitudes[2...])) else {
            return XCTFail("no discontinuity found")
        }
        let distance = result.distance[peak + 2]
        XCTAssertEqual(distance, length, accuracy: result.resolution,
                       "TDR located the open at \(distance) m, expected \(length) m")

        // The step response should settle towards a full positive reflection.
        let settled = result.step[(peak + 2)..<min(result.step.count, peak + 40)].max() ?? 0
        XCTAssertGreaterThan(settled, 0.5)
    }

    func testResolutionImprovesWithBandwidth() {
        let vf = 0.66
        func resolution(points: Int, step: Double) -> Double {
            let frequencies = (1...points).map { Double($0) * step }
            let s11 = openStub(length: 2, velocityFactor: vf, frequencies: frequencies)
            var settings = TimeDomainSettings()
            settings.velocityFactor = vf
            return TimeDomain.transform(frequencies: frequencies, values: s11, settings: settings).resolution
        }
        XCTAssertLessThan(resolution(points: 201, step: 10e6), resolution(points: 51, step: 10e6))
    }

    func testShortedStubGivesNegativeStep() {
        let df = 10e6
        let frequencies = (1...101).map { Double($0) * df }
        // A short at the far end inverts the reflection.
        let delay = 1.0 / (speedOfLight * 0.66)
        let s11 = frequencies.map { -Complex.expj(-2 * 2 * .pi * $0 * delay) }
        var settings = TimeDomainSettings()
        settings.mode = .lowpassStep
        settings.velocityFactor = 0.66
        settings.padFactor = 8
        let result = TimeDomain.transform(frequencies: frequencies, values: s11, settings: settings)
        let minimum = result.step.min() ?? 0
        XCTAssertLessThan(minimum, -0.5, "a shorted line should show a negative step")
    }

    func testBandpassModeProducesEnvelope() {
        let frequencies = (0..<201).map { 100e6 + Double($0) * 5e6 }
        let delay = 20e-9
        let values = frequencies.map { Complex.expj(-2 * .pi * $0 * delay) }
        var settings = TimeDomainSettings()
        settings.mode = .bandpassImpulse
        settings.velocityFactor = 1.0
        let result = TimeDomain.transform(frequencies: frequencies, values: values, settings: settings)
        guard let peak = TraceAnalysis.indexOfMaximum(result.impulse) else { return XCTFail("no peak") }
        XCTAssertEqual(result.time[peak], delay, accuracy: 2e-9)
        XCTAssertTrue(result.impulse.allSatisfy { $0 >= 0 }, "bandpass impulse is an envelope")
    }

    func testWindowsAreNormalisedAtCentre() {
        for window in WindowFunction.allCases {
            XCTAssertEqual(window.value(at: 0), 1, accuracy: 1e-9, "\(window) should be 1 at the centre")
            XCTAssertLessThanOrEqual(window.value(at: 1), window.value(at: 0) + 1e-9)
        }
    }
}
