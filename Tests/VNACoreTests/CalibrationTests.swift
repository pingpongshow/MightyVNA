import XCTest
@testable import VNACore

final class CalibrationTests: XCTestCase {

    private let frequencies: [Double] = (0..<51).map { 1e6 + Double($0) * 20e6 }

    /// Forward one-port error model: what the instrument would read for a given load.
    private func measured(_ actual: Complex, ed: Complex, es: Complex, er: Complex) -> Complex {
        ed + (er * actual) / (Complex.one - es * actual)
    }

    func testSOLTRecoversKnownLoadsWithIdealStandards() {
        // A plausible, frequency-dependent set of error terms.
        var cal = Calibration()
        cal.kit = .ideal
        cal.z0 = 50

        var openFrame = SweepFrame(frequencies: frequencies,
                                   s11: [], s21: [Complex](repeating: .zero, count: frequencies.count))
        var shortFrame = openFrame
        var loadFrame = openFrame

        var terms: [(Complex, Complex, Complex)] = []
        for (i, _) in frequencies.enumerated() {
            let t = Double(i) / Double(frequencies.count)
            let ed = Complex(0.02 * cos(t * 3), 0.02 * sin(t * 3))
            let es = Complex(0.15 * cos(t * 5 + 1), 0.15 * sin(t * 5 + 1))
            let er = Complex(0.9 * cos(t * 2), 0.9 * sin(t * 2))
            terms.append((ed, es, er))
            openFrame.s11.append(measured(.one, ed: ed, es: es, er: er))
            shortFrame.s11.append(measured(Complex(-1, 0), ed: ed, es: es, er: er))
            loadFrame.s11.append(measured(.zero, ed: ed, es: es, er: er))
        }

        cal.record(step: .open, frame: openFrame)
        cal.record(step: .short, frame: shortFrame)
        cal.record(step: .load, frame: loadFrame)
        XCTAssertTrue(cal.isSolved)

        // Now synthesise a DUT and check the correction recovers it.
        let dut = Complex(0.31, -0.44)
        var dutFrame = SweepFrame(frequencies: frequencies, s11: [], s21: [Complex](repeating: .zero, count: frequencies.count))
        for (ed, es, er) in terms {
            dutFrame.s11.append(measured(dut, ed: ed, es: es, er: er))
        }
        let corrected = cal.apply(to: dutFrame)
        for value in corrected.s11 {
            XCTAssertEqual(value.re, dut.re, accuracy: 1e-9)
            XCTAssertEqual(value.im, dut.im, accuracy: 1e-9)
        }
    }

    func testCalibrationWithOffsetKitRecoversLoads() {
        // A kit whose open has real fringing capacitance and offset delay.
        var kit = CalKit(name: "Test kit")
        kit.open = CalStandard(kind: .open, offsetDelay: 30e-12, c0: 50e-15)
        kit.short = CalStandard(kind: .short, offsetDelay: 32e-12, l0: 2e-12)
        kit.load = CalStandard(kind: .load, loadResistance: 50)

        var cal = Calibration()
        cal.kit = kit
        cal.z0 = 50

        var openFrame = SweepFrame(frequencies: frequencies, s11: [], s21: [Complex](repeating: .zero, count: frequencies.count))
        var shortFrame = openFrame
        var loadFrame = openFrame
        var terms: [(Complex, Complex, Complex)] = []

        for (i, f) in frequencies.enumerated() {
            let t = Double(i) / Double(frequencies.count)
            let ed = Complex(0.03, -0.01 * t)
            let es = Complex(0.1 * cos(t * 4), 0.1 * sin(t * 4))
            let er = Complex(0.85, 0.2 * t)
            terms.append((ed, es, er))
            openFrame.s11.append(measured(kit.open.reflection(at: f, z0: 50), ed: ed, es: es, er: er))
            shortFrame.s11.append(measured(kit.short.reflection(at: f, z0: 50), ed: ed, es: es, er: er))
            loadFrame.s11.append(measured(kit.load.reflection(at: f, z0: 50), ed: ed, es: es, er: er))
        }

        cal.record(step: .open, frame: openFrame)
        cal.record(step: .short, frame: shortFrame)
        cal.record(step: .load, frame: loadFrame)
        XCTAssertTrue(cal.isSolved)

        let dut = RF.reflection(fromImpedance: Complex(75, 20), z0: 50)
        var dutFrame = SweepFrame(frequencies: frequencies, s11: [], s21: [Complex](repeating: .zero, count: frequencies.count))
        for (ed, es, er) in terms {
            dutFrame.s11.append(measured(dut, ed: ed, es: es, er: er))
        }
        for value in cal.apply(to: dutFrame).s11 {
            XCTAssertEqual(value.re, dut.re, accuracy: 1e-9)
            XCTAssertEqual(value.im, dut.im, accuracy: 1e-9)
        }
    }

    func testThroughNormalisationRecoversTransmission() {
        var cal = Calibration()
        cal.kit = .ideal
        cal.transmissionCorrection = .normalization

        let n = frequencies.count
        var openFrame = SweepFrame(frequencies: frequencies,
                                   s11: [Complex](repeating: .one, count: n),
                                   s21: [Complex](repeating: .zero, count: n))
        var shortFrame = SweepFrame(frequencies: frequencies,
                                    s11: [Complex](repeating: Complex(-1, 0), count: n),
                                    s21: [Complex](repeating: .zero, count: n))
        var loadFrame = SweepFrame(frequencies: frequencies,
                                   s11: [Complex](repeating: .zero, count: n),
                                   s21: [Complex](repeating: .zero, count: n))
        openFrame.z0 = 50; shortFrame.z0 = 50; loadFrame.z0 = 50

        // Transmission tracking: a fixed gain and delay through the instrument.
        let tracking = frequencies.map { Complex(magnitude: 0.7, angle: -2 * .pi * $0 * 4e-9) }
        var thruFrame = SweepFrame(frequencies: frequencies,
                                   s11: [Complex](repeating: .zero, count: n),
                                   s21: tracking)

        cal.record(step: .open, frame: openFrame)
        cal.record(step: .short, frame: shortFrame)
        cal.record(step: .load, frame: loadFrame)
        cal.record(step: .thru, frame: thruFrame)
        XCTAssertTrue(cal.canCorrectTransmission)

        // A 10 dB attenuator under test.
        let dut = Complex(magnitude: RF.linear(fromDB: -10), angle: 0.3)
        var dutFrame = SweepFrame(frequencies: frequencies,
                                  s11: [Complex](repeating: .zero, count: n),
                                  s21: tracking.map { $0 * dut })
        let corrected = cal.apply(to: dutFrame)
        for value in corrected.s21 {
            XCTAssertEqual(RF.dB(value.magnitude), -10, accuracy: 1e-9)
            XCTAssertEqual(value.phase, 0.3, accuracy: 1e-9)
        }
        _ = thruFrame; _ = dutFrame
    }

    func testCalKitStandardsAreUnitMagnitudeWhenLossless() {
        let kit = CalKit.nanoVNASMA
        for f in [1e6, 100e6, 1e9] {
            XCTAssertEqual(kit.short.reflection(at: f, z0: 50).magnitude, 1, accuracy: 1e-9)
            XCTAssertEqual(kit.open.reflection(at: f, z0: 50).magnitude, 1, accuracy: 1e-9)
        }
    }

    func testIdealKitMatchesTextbookValues() {
        let kit = CalKit.ideal
        XCTAssertEqual(kit.open.reflection(at: 1e9, z0: 50).re, 1, accuracy: 1e-12)
        XCTAssertEqual(kit.short.reflection(at: 1e9, z0: 50).re, -1, accuracy: 1e-12)
        XCTAssertEqual(kit.load.reflection(at: 1e9, z0: 50).magnitude, 0, accuracy: 1e-12)
    }

    func testGridChangeDiscardsStaleStandards() {
        var cal = Calibration()
        let a = SweepFrame(frequencies: [1e6, 2e6], s11: [.one, .one], s21: [.zero, .zero])
        let b = SweepFrame(frequencies: [1e6, 2e6, 3e6],
                           s11: [Complex(-1, 0), Complex(-1, 0), Complex(-1, 0)],
                           s21: [.zero, .zero, .zero])
        cal.record(step: .open, frame: a)
        XCTAssertTrue(cal.has(.open))
        cal.record(step: .short, frame: b)
        XCTAssertFalse(cal.has(.open), "changing the sweep grid must invalidate earlier standards")
        XCTAssertTrue(cal.has(.short))
    }
}
