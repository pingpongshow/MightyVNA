import XCTest
@testable import VNACore

/// Verifies the 12-term two-port correction by generating measurements from a known
/// error model and checking the maths inverts it exactly.
final class TwoPortCalibrationTests: XCTestCase {

    private let frequencies: [Double] = (0..<41).map { 1e6 + Double($0) * 25e6 }

    /// One frequency point's worth of forward and reverse error terms.
    private struct ErrorTerms {
        var edf: Complex, esf: Complex, erf: Complex, exf: Complex, etf: Complex, elf: Complex
        var edr: Complex, esr: Complex, err: Complex, exr: Complex, etr: Complex, elr: Complex
    }

    private func terms(at index: Int) -> ErrorTerms {
        let t = Double(index) / Double(frequencies.count)
        func rotate(_ magnitude: Double, _ turns: Double, _ phase: Double) -> Complex {
            Complex(magnitude: magnitude, angle: turns * t * 2 * .pi + phase)
        }
        return ErrorTerms(
            edf: rotate(0.03, 2, 0.3),
            esf: rotate(0.12, 3, 1.1),
            erf: rotate(0.92, 1, -0.4),
            exf: rotate(0.0008, 5, 0.2),
            etf: rotate(0.75, 2, 0.9),
            elf: rotate(0.10, 4, -0.7),
            edr: rotate(0.025, 2.5, -0.2),
            esr: rotate(0.14, 3.5, 0.6),
            err: rotate(0.88, 1.5, 1.4),
            exr: rotate(0.0006, 4.5, -1.0),
            etr: rotate(0.70, 2.5, -1.2),
            elr: rotate(0.09, 3.2, 0.4))
    }

    /// One-port reading of a standard through a set of reflection error terms.
    private func onePortMeasurement(_ gamma: Complex, ed: Complex, es: Complex, er: Complex) -> Complex {
        ed + er * gamma / (Complex.one - es * gamma)
    }

    /// The four readings a 12-term instrument produces for a known DUT.
    private func measure(dut: (s11: Complex, s21: Complex, s12: Complex, s22: Complex),
                         _ e: ErrorTerms) -> (Complex, Complex, Complex, Complex) {
        let gammaIn = dut.s11 + (dut.s21 * dut.s12 * e.elf) / (Complex.one - dut.s22 * e.elf)
        let s11m = e.edf + e.erf * gammaIn / (Complex.one - e.esf * gammaIn)

        let forwardDenominator = (Complex.one - e.esf * dut.s11) * (Complex.one - e.elf * dut.s22)
            - e.esf * e.elf * dut.s21 * dut.s12
        let s21m = e.exf + e.etf * dut.s21 / forwardDenominator

        let gammaOut = dut.s22 + (dut.s21 * dut.s12 * e.elr) / (Complex.one - dut.s11 * e.elr)
        let s22m = e.edr + e.err * gammaOut / (Complex.one - e.esr * gammaOut)

        let reverseDenominator = (Complex.one - e.esr * dut.s22) * (Complex.one - e.elr * dut.s11)
            - e.esr * e.elr * dut.s21 * dut.s12
        let s12m = e.exr + e.etr * dut.s12 / reverseDenominator

        return (s11m, s21m, s12m, s22m)
    }

    private func blank() -> SweepFrame {
        let n = frequencies.count
        return SweepFrame(frequencies: frequencies,
                          s11: [Complex](repeating: .zero, count: n),
                          s21: [Complex](repeating: .zero, count: n),
                          s12: [Complex](repeating: .zero, count: n),
                          s22: [Complex](repeating: .zero, count: n))
    }

    /// Build a calibration from synthetic standard measurements.
    private func calibratedInstrument() -> Calibration {
        var cal = Calibration()
        cal.kit = .ideal
        cal.z0 = 50

        var open1 = blank(), short1 = blank(), load1 = blank()
        var open2 = blank(), short2 = blank(), load2 = blank()
        var isolation = blank(), thru = blank()

        for i in frequencies.indices {
            let e = terms(at: i)
            open1.s11[i] = onePortMeasurement(.one, ed: e.edf, es: e.esf, er: e.erf)
            short1.s11[i] = onePortMeasurement(Complex(-1, 0), ed: e.edf, es: e.esf, er: e.erf)
            load1.s11[i] = onePortMeasurement(.zero, ed: e.edf, es: e.esf, er: e.erf)

            open2.s22[i] = onePortMeasurement(.one, ed: e.edr, es: e.esr, er: e.err)
            short2.s22[i] = onePortMeasurement(Complex(-1, 0), ed: e.edr, es: e.esr, er: e.err)
            load2.s22[i] = onePortMeasurement(.zero, ed: e.edr, es: e.esr, er: e.err)

            // Isolation: both ports terminated, so only the leakage terms remain.
            isolation.s21[i] = e.exf
            isolation.s12[i] = e.exr

            // An ideal zero-length through.
            let (t11, t21, t12, t22) = measure(dut: (.zero, .one, .one, .zero), e)
            thru.s11[i] = t11
            thru.s21[i] = t21
            thru.s12[i] = t12
            thru.s22[i] = t22
        }

        cal.record(step: .open, frame: open1)
        cal.record(step: .short, frame: short1)
        cal.record(step: .load, frame: load1)
        cal.record(step: .open2, frame: open2)
        cal.record(step: .short2, frame: short2)
        cal.record(step: .load2, frame: load2)
        cal.record(step: .isolation, frame: isolation)
        cal.record(step: .thru, frame: thru)
        return cal
    }

    // MARK: - Tests

    func testCalibrationReachesFullTwoPortMode() {
        let cal = calibratedInstrument()
        XCTAssertTrue(cal.isSolved)
        XCTAssertTrue(cal.isReverseSolved)
        XCTAssertTrue(cal.canCorrectFullTwoPort)
        XCTAssertEqual(cal.mode, .fullTwoPort)
        XCTAssertEqual(cal.summary, "OSLoslIT")
    }

    func testSolvedTermsMatchTheKnownErrorModel() {
        let cal = calibratedInstrument()
        for i in frequencies.indices {
            let e = terms(at: i)
            XCTAssertEqual(cal.directivity[i].re, e.edf.re, accuracy: 1e-9)
            XCTAssertEqual(cal.sourceMatch[i].im, e.esf.im, accuracy: 1e-9)
            XCTAssertEqual(cal.reflectionTracking[i].re, e.erf.re, accuracy: 1e-9)
            XCTAssertEqual(cal.loadMatch[i].re, e.elf.re, accuracy: 1e-9, "forward load match")
            XCTAssertEqual(cal.transmissionTracking[i].im, e.etf.im, accuracy: 1e-9, "forward tracking")
            XCTAssertEqual(cal.directivityReverse[i].re, e.edr.re, accuracy: 1e-9)
            XCTAssertEqual(cal.loadMatchReverse[i].re, e.elr.re, accuracy: 1e-9, "reverse load match")
            XCTAssertEqual(cal.transmissionTrackingReverse[i].im, e.etr.im, accuracy: 1e-9, "reverse tracking")
        }
    }

    /// The heart of it: a known DUT measured through the error model must come back exactly.
    private func assertRecovers(_ dut: (s11: Complex, s21: Complex, s12: Complex, s22: Complex),
                                _ label: String, accuracy: Double = 1e-8) {
        let cal = calibratedInstrument()
        var measured = blank()
        for i in frequencies.indices {
            let (m11, m21, m12, m22) = measure(dut: dut, terms(at: i))
            measured.s11[i] = m11
            measured.s21[i] = m21
            measured.s12[i] = m12
            measured.s22[i] = m22
        }
        let corrected = cal.apply(to: measured)
        XCTAssertTrue(corrected.isFullTwoPort)
        for i in frequencies.indices {
            XCTAssertEqual(corrected.s11[i].re, dut.s11.re, accuracy: accuracy, "\(label) S11 re")
            XCTAssertEqual(corrected.s11[i].im, dut.s11.im, accuracy: accuracy, "\(label) S11 im")
            XCTAssertEqual(corrected.s21[i].re, dut.s21.re, accuracy: accuracy, "\(label) S21 re")
            XCTAssertEqual(corrected.s21[i].im, dut.s21.im, accuracy: accuracy, "\(label) S21 im")
            XCTAssertEqual(corrected.s12[i].re, dut.s12.re, accuracy: accuracy, "\(label) S12 re")
            XCTAssertEqual(corrected.s12[i].im, dut.s12.im, accuracy: accuracy, "\(label) S12 im")
            XCTAssertEqual(corrected.s22[i].re, dut.s22.re, accuracy: accuracy, "\(label) S22 re")
            XCTAssertEqual(corrected.s22[i].im, dut.s22.im, accuracy: accuracy, "\(label) S22 im")
        }
    }

    func testRecoversMismatchedAttenuator() {
        assertRecovers((s11: Complex(magnitude: 0.20, angle: 0.52),
                        s21: Complex(magnitude: 0.50, angle: -0.79),
                        s12: Complex(magnitude: 0.50, angle: -0.79),
                        s22: Complex(magnitude: 0.15, angle: 2.09)), "attenuator")
    }

    func testRecoversNonReciprocalAmplifier() {
        // An active DUT: high forward gain, strong reverse isolation.
        assertRecovers((s11: Complex(magnitude: 0.35, angle: -1.2),
                        s21: Complex(magnitude: 3.20, angle: 0.65),
                        s12: Complex(magnitude: 0.01, angle: 2.5),
                        s22: Complex(magnitude: 0.28, angle: 0.9)), "amplifier", accuracy: 1e-7)
    }

    func testRecoversAThrough() {
        assertRecovers((s11: .zero, s21: .one, s12: .one, s22: .zero), "through")
    }

    func testRecoversAnOpenOnBothPorts() {
        assertRecovers((s11: .one, s21: .zero, s12: .zero, s22: .one), "open/open")
    }

    func testForwardOnlyDataRecoversTheInputReflection() {
        // A NanoVNA-shaped frame (no S12/S22) through a full two-port calibration.
        // The 12-term path cannot run, so the one-port maths applies — and what a one-port
        // measurement can recover is the *input* reflection with port 2 terminated in the
        // instrument's own load match, not the DUT's isolated S11.
        let cal = calibratedInstrument()
        let dut = (s11: Complex(magnitude: 0.2, angle: 0.5),
                   s21: Complex(magnitude: 0.5, angle: -0.8),
                   s12: Complex(magnitude: 0.5, angle: -0.8),
                   s22: Complex(magnitude: 0.1, angle: 1.0))

        var measured = SweepFrame(frequencies: frequencies,
                                  s11: [Complex](repeating: .zero, count: frequencies.count),
                                  s21: [Complex](repeating: .zero, count: frequencies.count))
        var expectedInput = [Complex](repeating: .zero, count: frequencies.count)
        for i in frequencies.indices {
            let e = terms(at: i)
            let (m11, m21, _, _) = measure(dut: dut, e)
            measured.s11[i] = m11
            measured.s21[i] = m21
            expectedInput[i] = dut.s11 + (dut.s21 * dut.s12 * e.elf) / (Complex.one - dut.s22 * e.elf)
        }

        let corrected = cal.apply(to: measured)
        XCTAssertFalse(corrected.isFullTwoPort)
        for i in frequencies.indices {
            XCTAssertEqual(corrected.s11[i].re, expectedInput[i].re, accuracy: 1e-8)
            XCTAssertEqual(corrected.s11[i].im, expectedInput[i].im, accuracy: 1e-8)
        }
    }

    func testForwardOnlyDataIsExactForAReflectionOnlyDUT() {
        // With no transmission path there is nothing for port-2 match to interact with,
        // so a one-port correction is exact — this is the normal NanoVNA S11 case.
        let cal = calibratedInstrument()
        let dut = (s11: Complex(magnitude: 0.44, angle: -2.1),
                   s21: Complex.zero, s12: Complex.zero,
                   s22: Complex(magnitude: 0.3, angle: 0.2))
        var measured = SweepFrame(frequencies: frequencies,
                                  s11: [Complex](repeating: .zero, count: frequencies.count),
                                  s21: [Complex](repeating: .zero, count: frequencies.count))
        for i in frequencies.indices {
            measured.s11[i] = measure(dut: dut, terms(at: i)).0
        }
        let corrected = cal.apply(to: measured)
        for i in frequencies.indices {
            XCTAssertEqual(corrected.s11[i].re, dut.s11.re, accuracy: 1e-9)
            XCTAssertEqual(corrected.s11[i].im, dut.s11.im, accuracy: 1e-9)
        }
    }

    func testCalibrationSurvivesSaveAndLoad() throws {
        let cal = calibratedInstrument()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cal)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(Calibration.self, from: data)

        XCTAssertEqual(restored.mode, .fullTwoPort, "the error terms must be re-solved on load")
        XCTAssertTrue(restored.isReverseSolved)
        for i in frequencies.indices {
            XCTAssertEqual(restored.loadMatchReverse[i].re, cal.loadMatchReverse[i].re, accuracy: 1e-12)
        }
    }

    func testResidualDirectivityIsExcellentForPerfectData() throws {
        let cal = calibratedInstrument()
        let residual = try XCTUnwrap(cal.residualDirectivityDB)
        XCTAssertLessThan(residual, -100, "synthetic data should correct essentially perfectly")
    }

    func testModeDegradesGracefully() {
        var cal = Calibration()
        cal.kit = .ideal
        XCTAssertEqual(cal.mode, .none)

        var open1 = blank(), short1 = blank(), load1 = blank()
        for i in frequencies.indices {
            let e = terms(at: i)
            open1.s11[i] = onePortMeasurement(.one, ed: e.edf, es: e.esf, er: e.erf)
            short1.s11[i] = onePortMeasurement(Complex(-1, 0), ed: e.edf, es: e.esf, er: e.erf)
            load1.s11[i] = onePortMeasurement(.zero, ed: e.edf, es: e.esf, er: e.erf)
        }
        cal.record(step: .open, frame: open1)
        cal.record(step: .short, frame: short1)
        cal.record(step: .load, frame: load1)
        XCTAssertEqual(cal.mode, .reflectionOnly)

        var thru = blank()
        for i in frequencies.indices {
            let (t11, t21, t12, t22) = measure(dut: (.zero, .one, .one, .zero), terms(at: i))
            thru.s11[i] = t11; thru.s21[i] = t21; thru.s12[i] = t12; thru.s22[i] = t22
        }
        cal.record(step: .thru, frame: thru)
        XCTAssertEqual(cal.mode, .forwardResponse, "without port-2 standards it cannot reach 12-term")
    }
}
