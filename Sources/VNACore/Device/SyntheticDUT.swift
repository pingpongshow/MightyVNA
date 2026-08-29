import Foundation

/// Shared synthetic devices under test, used by the built-in simulators.
///
/// The maths is deliberately physical rather than decorative: the filter is
/// energy-conserving, so |S11|² + |S21|² ≈ 1 and the Smith chart behaves sensibly.
public enum SyntheticDUT {

    // MARK: - Dual-band antenna on a short coax run

    /// A pair of series-RLC resonators at 145.5 MHz and 435 MHz behind 1.2 m of coax.
    public static func antennaS11(at frequency: Double, z0: Double = 50) -> Complex {
        guard frequency > 0 else { return Complex(-1, 0) }
        let branch1 = seriesRLC(f: frequency, r: 48, f0: 145.5e6, q: 18).reciprocal
        let branch2 = seriesRLC(f: frequency, r: 62, f0: 435e6, q: 26).reciprocal
        let z = (branch1 + branch2).reciprocal
        let gamma = RF.reflection(fromImpedance: z, z0: z0)
        let delay = 1.2 / (speedOfLight * 0.66)
        let loss = RF.linear(fromDB: -0.35 * (frequency / 1e9).squareRoot() * 2)
        return gamma * Complex.expj(-2 * 2 * .pi * frequency * delay) * loss
    }

    // MARK: - 300 MHz bandpass filter, as a proper two-port

    public static let filterCenter = 300e6
    public static let filterBandwidth = 60e6
    private static let filterOrder = 3.0
    private static let filterInsertionLoss = 1.4     // dB
    private static let filterGroupDelay = 8.0e-9

    /// Normalised detuning of the bandpass.
    private static func detuning(_ f: Double) -> Double {
        guard f > 0 else { return 1e6 }
        return (f / filterCenter - filterCenter / f) * (filterCenter / filterBandwidth)
    }

    public static func filterS21(at frequency: Double) -> Complex {
        let x = detuning(frequency)
        let magnitude = 1 / (1 + pow(x, 2 * filterOrder)).squareRoot()
        let loss = RF.linear(fromDB: -filterInsertionLoss)
        let floorLevel = RF.linear(fromDB: -85)
        let phase = -2 * Double.pi * frequency * filterGroupDelay - filterOrder * atan(x)
        return Complex(magnitude: max(magnitude * loss, floorLevel), angle: phase)
    }

    /// Input reflection derived from the *lossless* prototype: whatever the filter does not
    /// pass is reflected, while the insertion loss is dissipated rather than bounced back.
    /// This keeps the passband well matched, as a real filter is.
    public static func filterS11(at frequency: Double) -> Complex {
        let x = detuning(frequency)
        let losslessTransmission = 1 / (1 + pow(x, 2 * filterOrder))
        let magnitude = max(0, 1 - losslessTransmission).squareRoot()
        // Reflection phase rotates through resonance and adds the connector's delay.
        let phase = .pi - 2 * atan(x) - 2 * Double.pi * frequency * 0.35e-9
        return Complex(magnitude: min(magnitude, 0.999), angle: phase)
    }

    /// Port 2 sees a slightly different match, as a real filter would.
    public static func filterS22(at frequency: Double) -> Complex {
        let base = filterS11(at: frequency)
        let x = detuning(frequency)
        return Complex(magnitude: base.magnitude * 0.94,
                       angle: base.phase + 0.28 + 0.05 * atan(x))
    }

    /// Reciprocal, as any passive filter is.
    public static func filterS12(at frequency: Double) -> Complex { filterS21(at: frequency) }

    // MARK: - Helpers

    private static func seriesRLC(f: Double, r: Double, f0: Double, q: Double) -> Complex {
        let l = r * q / (2 * Double.pi * f0)
        let c = 1 / (l * pow(2 * Double.pi * f0, 2))
        let omega = 2 * Double.pi * f
        return Complex(r, omega * l - 1 / (omega * c))
    }

    /// Deterministic pseudo-random noise so screenshots stay stable between runs.
    public struct Noise {
        private var seed: UInt64
        public init(seed: UInt64 = 0x2545F4914F6CDD1D) { self.seed = seed }

        public mutating func next() -> Double {
            seed ^= seed >> 12
            seed ^= seed << 25
            seed ^= seed >> 27
            let value = seed &* 2685821657736338717
            return Double(value >> 11) / Double(UInt64(1) << 53)
        }

        public mutating func complex(amplitude: Double) -> Complex {
            Complex((next() - 0.5) * 2 * amplitude, (next() - 0.5) * 2 * amplitude)
        }
    }
}
