import XCTest
@testable import VNACore

final class ComplexTests: XCTestCase {

    func testArithmetic() {
        let a = Complex(3, 4)
        XCTAssertEqual(a.magnitude, 5, accuracy: 1e-12)
        XCTAssertEqual((a * a.reciprocal).re, 1, accuracy: 1e-12)
        XCTAssertEqual((a * a.reciprocal).im, 0, accuracy: 1e-12)
        let b = Complex(1, -2)
        XCTAssertEqual((a * b).re, 3 * 1 + 4 * 2, accuracy: 1e-12)
        XCTAssertEqual((a * b).im, 4 * 1 - 3 * 2, accuracy: 1e-12)
        XCTAssertEqual((a / b * b).re, a.re, accuracy: 1e-12)
    }

    func testSquareRoot() {
        let v = Complex(-4, 0).squareRoot
        XCTAssertEqual(v.re, 0, accuracy: 1e-12)
        XCTAssertEqual(abs(v.im), 2, accuracy: 1e-12)
    }

    func testSolve3x3RecoversKnownSolution() {
        let x = [Complex(1.5, -0.5), Complex(-0.25, 2), Complex(0.75, 0.125)]
        let a: [[Complex]] = [
            [Complex(2, 1), Complex(0, -1), Complex(1, 0)],
            [Complex(1, 0), Complex(3, 2), Complex(-1, 1)],
            [Complex(0, 2), Complex(1, 1), Complex(4, 0)]
        ]
        let b = (0..<3).map { row in
            a[row][0] * x[0] + a[row][1] * x[1] + a[row][2] * x[2]
        }
        let solved = solve3x3(a, b)
        XCTAssertNotNil(solved)
        for i in 0..<3 {
            XCTAssertEqual(solved![i].re, x[i].re, accuracy: 1e-10)
            XCTAssertEqual(solved![i].im, x[i].im, accuracy: 1e-10)
        }
    }

    func testSingularSystemReturnsNil() {
        let a: [[Complex]] = [
            [.one, .one, .one],
            [.one, .one, .one],
            [.one, .one, .one]
        ]
        XCTAssertNil(solve3x3(a, [.one, .one, .one]))
    }
}

final class RFMathTests: XCTestCase {

    func testSWRForKnownReflection() {
        XCTAssertEqual(RF.swr(Complex(0, 0)), 1, accuracy: 1e-9)
        XCTAssertEqual(RF.swr(Complex(1.0 / 3.0, 0)), 2, accuracy: 1e-9)
        XCTAssertEqual(RF.swr(Complex(0.5, 0)), 3, accuracy: 1e-9)
    }

    func testImpedanceRoundTrip() {
        for z in [Complex(50, 0), Complex(75, -30), Complex(12.5, 88), Complex(200, -400)] {
            let gamma = RF.reflection(fromImpedance: z, z0: 50)
            let back = RF.impedance(gamma, z0: 50)
            XCTAssertEqual(back.re, z.re, accuracy: 1e-9)
            XCTAssertEqual(back.im, z.im, accuracy: 1e-9)
        }
    }

    func testOpenAndShortReflection() {
        XCTAssertEqual(RF.reflection(fromImpedance: Complex(1e12, 0), z0: 50).re, 1, accuracy: 1e-6)
        XCTAssertEqual(RF.reflection(fromImpedance: Complex(0, 0), z0: 50).re, -1, accuracy: 1e-12)
    }

    func testReturnLossAndMismatchLoss() {
        // A 3:1 SWR corresponds to |Γ| = 0.5 → 6.02 dB return loss.
        XCTAssertEqual(RF.returnLoss(Complex(0.5, 0)), 6.0206, accuracy: 1e-3)
        XCTAssertEqual(RF.mismatchLoss(Complex(0.5, 0)), 1.2494, accuracy: 1e-3)
    }

    func testSeriesEquivalents() {
        let f = 100e6
        let c = 10e-12
        let z = Complex(0, -1 / (2 * .pi * f * c))
        let gamma = RF.reflection(fromImpedance: z, z0: 50)
        XCTAssertEqual(RF.seriesCapacitance(gamma, z0: 50, frequency: f), c, accuracy: c * 1e-6)

        let l = 100e-9
        let zl = Complex(0, 2 * .pi * f * l)
        let gl = RF.reflection(fromImpedance: zl, z0: 50)
        XCTAssertEqual(RF.seriesInductance(gl, z0: 50, frequency: f), l, accuracy: l * 1e-6)
    }

    func testGroupDelayOfPureDelayLine() {
        let delay = 5e-9
        let frequencies = (0..<101).map { 100e6 + Double($0) * 1e6 }
        let values = frequencies.map { Complex.expj(-2 * .pi * $0 * delay) }
        let measured = RF.groupDelay(values, frequencies: frequencies, aperture: 2)
        for value in measured[3..<(measured.count - 3)] {
            XCTAssertEqual(value, delay, accuracy: delay * 1e-6)
        }
    }

    func testUnwrappedPhaseIsContinuous() {
        let frequencies = (0..<200).map { 1e6 + Double($0) * 1e6 }
        let values = frequencies.map { Complex.expj(-2 * .pi * $0 * 20e-9) }
        let phase = RF.unwrappedPhaseDegrees(values)
        for i in 1..<phase.count {
            XCTAssertLessThan(abs(phase[i] - phase[i - 1]), 180)
        }
        XCTAssertLessThan(phase.last!, -1000)   // many turns accumulated
    }

    func testInterpolationEndpointsAndMidpoints() {
        let source = [1.0, 2.0, 3.0]
        let values = [Complex(1, 0), Complex(2, 0), Complex(3, 0)]
        let out = RF.interpolate(values: values, from: source, to: [0.5, 1.5, 2.5, 3.5])
        XCTAssertEqual(out[0].re, 1, accuracy: 1e-12)     // clamped low
        XCTAssertEqual(out[1].re, 1.5, accuracy: 1e-12)
        XCTAssertEqual(out[2].re, 2.5, accuracy: 1e-12)
        XCTAssertEqual(out[3].re, 3, accuracy: 1e-12)     // clamped high
    }

    func testElectricalDelayRemovesPhaseSlope() {
        let delay = 3e-9
        let frequencies = (0..<64).map { 10e6 + Double($0) * 5e6 }
        // A reflection path travels the line twice.
        let values = frequencies.map { Complex.expj(-2 * 2 * .pi * $0 * delay) }
        let corrected = RF.applyElectricalDelay(values, frequencies: frequencies,
                                                delaySeconds: delay, reflection: true)
        for v in corrected {
            XCTAssertEqual(v.re, 1, accuracy: 1e-9)
            XCTAssertEqual(v.im, 0, accuracy: 1e-9)
        }
    }
}

final class UnitsTests: XCTestCase {

    func testParseFrequency() {
        XCTAssertEqual(Units.parseFrequency("144M")!, 144e6, accuracy: 1)
        XCTAssertEqual(Units.parseFrequency("2.4 GHz")!, 2.4e9, accuracy: 1)
        XCTAssertEqual(Units.parseFrequency("50k")!, 50e3, accuracy: 1)
        XCTAssertEqual(Units.parseFrequency("1_000_000")!, 1e6, accuracy: 1)
        XCTAssertEqual(Units.parseFrequency("145.500 MHz")!, 145.5e6, accuracy: 1)
        XCTAssertNil(Units.parseFrequency("banana"))
    }

    func testEngineeringFormatting() {
        XCTAssertTrue(Units.frequency(1.5e9).contains("GHz"))
        XCTAssertTrue(Units.frequency(1500).contains("kHz"))
        XCTAssertTrue(Units.capacitance(1e-12).contains("pF"))
        XCTAssertTrue(Units.inductance(1e-9).contains("nH"))
        XCTAssertEqual(Units.engineering(0, unit: "Hz"), "0 Hz")
    }
}
