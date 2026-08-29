import Foundation

/// Speed of light in vacuum (m/s).
public let speedOfLight = 299_792_458.0

public enum RF {

    // MARK: - Scalar conversions

    @inlinable public static func dB(_ linear: Double) -> Double {
        linear <= 0 ? -200 : 20 * log10(linear)
    }

    @inlinable public static func linear(fromDB db: Double) -> Double { pow(10, db / 20) }

    /// Voltage standing wave ratio from a reflection coefficient.
    @inlinable public static func swr(_ gamma: Complex) -> Double {
        let m = min(gamma.magnitude, 0.999999)
        return (1 + m) / (1 - m)
    }

    /// Return loss in dB (positive number).
    @inlinable public static func returnLoss(_ gamma: Complex) -> Double { -dB(gamma.magnitude) }

    /// Fraction of incident power reflected.
    @inlinable public static func reflectedPowerPercent(_ gamma: Complex) -> Double {
        min(gamma.magnitudeSquared, 1) * 100
    }

    /// Mismatch loss in dB.
    @inlinable public static func mismatchLoss(_ gamma: Complex) -> Double {
        let p = 1 - min(gamma.magnitudeSquared, 0.999999)
        return -10 * log10(p)
    }

    // MARK: - Impedance / admittance

    /// Series impedance from a reflection coefficient referenced to `z0`.
    @inlinable public static func impedance(_ gamma: Complex, z0: Double) -> Complex {
        let denom = Complex.one - gamma
        guard denom.magnitudeSquared > 1e-24 else { return Complex(1e12, 0) }
        return z0 * ((Complex.one + gamma) / denom)
    }

    @inlinable public static func reflection(fromImpedance z: Complex, z0: Double) -> Complex {
        (z - Complex(z0, 0)) / (z + Complex(z0, 0))
    }

    @inlinable public static func admittance(_ gamma: Complex, z0: Double) -> Complex {
        impedance(gamma, z0: z0).reciprocal
    }

    /// Quality factor |X| / R of the load.
    @inlinable public static func qFactor(_ gamma: Complex, z0: Double) -> Double {
        let z = impedance(gamma, z0: z0)
        guard abs(z.re) > 1e-12 else { return 1e6 }
        return abs(z.im) / abs(z.re)
    }

    /// Equivalent series capacitance (F). Negative reactance only; otherwise NaN.
    @inlinable public static func seriesCapacitance(_ gamma: Complex, z0: Double, frequency: Double) -> Double {
        let x = impedance(gamma, z0: z0).im
        guard x < 0, frequency > 0 else { return .nan }
        return -1 / (2 * .pi * frequency * x)
    }

    /// Equivalent series inductance (H). Positive reactance only; otherwise NaN.
    @inlinable public static func seriesInductance(_ gamma: Complex, z0: Double, frequency: Double) -> Double {
        let x = impedance(gamma, z0: z0).im
        guard x > 0, frequency > 0 else { return .nan }
        return x / (2 * .pi * frequency)
    }

    @inlinable public static func parallelCapacitance(_ gamma: Complex, z0: Double, frequency: Double) -> Double {
        let b = admittance(gamma, z0: z0).im
        guard b > 0, frequency > 0 else { return .nan }
        return b / (2 * .pi * frequency)
    }

    @inlinable public static func parallelInductance(_ gamma: Complex, z0: Double, frequency: Double) -> Double {
        let b = admittance(gamma, z0: z0).im
        guard b < 0, frequency > 0 else { return .nan }
        return -1 / (2 * .pi * frequency * b)
    }

    // MARK: - Shunt / series through-fixture impedance (measured with S21)

    /// Impedance of a DUT bridged across a 50 ohm through line: Z = z0/2 * S21/(1-S21).
    @inlinable public static func shuntThroughImpedance(_ s21: Complex, z0: Double) -> Complex {
        let d = Complex.one - s21
        guard d.magnitudeSquared > 1e-24 else { return Complex(1e12, 0) }
        return (z0 / 2) * (s21 / d)
    }

    /// Impedance of a DUT in series with a through line: Z = 2*z0 * (1-S21)/S21.
    @inlinable public static func seriesThroughImpedance(_ s21: Complex, z0: Double) -> Complex {
        guard s21.magnitudeSquared > 1e-24 else { return Complex(1e12, 0) }
        return (2 * z0) * ((Complex.one - s21) / s21)
    }

    // MARK: - Array operations

    /// Continuous phase in degrees.
    public static func unwrappedPhaseDegrees(_ values: [Complex]) -> [Double] {
        guard !values.isEmpty else { return [] }
        var out = [Double](repeating: 0, count: values.count)
        var offset = 0.0
        var previous = values[0].phase * 180 / .pi
        out[0] = previous
        for i in 1..<values.count {
            let raw = values[i].phase * 180 / .pi
            let delta = raw - previous
            if delta > 180 { offset -= 360 } else if delta < -180 { offset += 360 }
            previous = raw
            out[i] = raw + offset
        }
        return out
    }

    /// Group delay in seconds: -dphi/domega, computed with a centred difference.
    public static func groupDelay(_ values: [Complex], frequencies: [Double], aperture: Int = 1) -> [Double] {
        let n = min(values.count, frequencies.count)
        guard n > 1 else { return [Double](repeating: 0, count: n) }
        let phase = unwrappedPhaseDegrees(values).map { $0 * .pi / 180 }
        let ap = max(1, aperture)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - ap)
            let hi = min(n - 1, i + ap)
            let df = frequencies[hi] - frequencies[lo]
            guard abs(df) > 0 else { continue }
            out[i] = -(phase[hi] - phase[lo]) / (2 * .pi * df)
        }
        return out
    }

    /// Boxcar smoothing over an odd-sized window, applied to complex data.
    public static func smooth(_ values: [Complex], window: Int) -> [Complex] {
        guard window > 1, values.count > 2 else { return values }
        let half = window / 2
        var out = [Complex](repeating: .zero, count: values.count)
        for i in values.indices {
            var acc = Complex.zero
            var count = 0.0
            for k in max(0, i - half)...min(values.count - 1, i + half) {
                acc += values[k]
                count += 1
            }
            out[i] = acc / count
        }
        return out
    }

    /// Apply an electrical delay (port extension) in seconds, plus optional loss in dB/sqrt(Hz).
    public static func applyElectricalDelay(_ values: [Complex], frequencies: [Double],
                                            delaySeconds: Double, lossDBperGHz: Double = 0,
                                            reflection: Bool) -> [Complex] {
        guard delaySeconds != 0 || lossDBperGHz != 0 else { return values }
        let factor = reflection ? 2.0 : 1.0
        return zip(values, frequencies).map { v, f in
            let rotated = v * Complex.expj(factor * 2 * .pi * f * delaySeconds)
            guard lossDBperGHz != 0 else { return rotated }
            let gain = RF.linear(fromDB: factor * lossDBperGHz * (f / 1e9))
            return rotated * gain
        }
    }

    // MARK: - Interpolation

    /// Linear interpolation of complex data onto a new frequency grid.
    /// Values outside the source range are clamped to the nearest endpoint.
    public static func interpolate(values: [Complex], from source: [Double], to target: [Double]) -> [Complex] {
        guard !values.isEmpty, source.count == values.count else {
            return [Complex](repeating: .one, count: target.count)
        }
        guard source.count > 1 else { return [Complex](repeating: values[0], count: target.count) }
        var out = [Complex]()
        out.reserveCapacity(target.count)
        var idx = 0
        for f in target {
            if f <= source[0] { out.append(values[0]); continue }
            if f >= source[source.count - 1] { out.append(values[values.count - 1]); continue }
            while idx < source.count - 2 && source[idx + 1] < f { idx += 1 }
            while idx > 0 && source[idx] > f { idx -= 1 }
            let f0 = source[idx], f1 = source[idx + 1]
            let t = f1 > f0 ? (f - f0) / (f1 - f0) : 0
            out.append(values[idx].lerp(to: values[idx + 1], t))
        }
        return out
    }
}
