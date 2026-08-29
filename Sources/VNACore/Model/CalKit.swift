import Foundation

public enum StandardKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case open, short, load, thru
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .open: return "Open"
        case .short: return "Short"
        case .load: return "Load"
        case .thru: return "Through"
        }
    }
}

/// A calibration standard described with the usual HP/Keysight coefficient model:
/// an offset transmission line terminated by a frequency-dependent lumped element.
public struct CalStandard: Codable, Sendable, Equatable, Hashable {
    public var kind: StandardKind
    /// One-way offset delay in seconds.
    public var offsetDelay: Double
    /// Offset loss in ohms/second at 1 GHz.
    public var offsetLoss: Double
    public var offsetZ0: Double

    /// Open fringing capacitance polynomial: C(f) = c0 + c1·f + c2·f² + c3·f³ (farads).
    public var c0: Double, c1: Double, c2: Double, c3: Double
    /// Short residual inductance polynomial: L(f) = l0 + l1·f + l2·f² + l3·f³ (henries).
    public var l0: Double, l1: Double, l2: Double, l3: Double
    /// Load termination.
    public var loadResistance: Double
    public var loadInductance: Double

    public init(kind: StandardKind,
                offsetDelay: Double = 0,
                offsetLoss: Double = 0,
                offsetZ0: Double = 50,
                c0: Double = 0, c1: Double = 0, c2: Double = 0, c3: Double = 0,
                l0: Double = 0, l1: Double = 0, l2: Double = 0, l3: Double = 0,
                loadResistance: Double = 50,
                loadInductance: Double = 0) {
        self.kind = kind
        self.offsetDelay = offsetDelay
        self.offsetLoss = offsetLoss
        self.offsetZ0 = offsetZ0
        self.c0 = c0; self.c1 = c1; self.c2 = c2; self.c3 = c3
        self.l0 = l0; self.l1 = l1; self.l2 = l2; self.l3 = l3
        self.loadResistance = loadResistance
        self.loadInductance = loadInductance
    }

    /// Reflection coefficient of this standard at `frequency`, referenced to `z0`.
    public func reflection(at frequency: Double, z0: Double) -> Complex {
        let omega = 2 * Double.pi * frequency
        var terminating: Complex

        switch kind {
        case .open:
            let c = c0 + c1 * frequency + c2 * frequency * frequency + c3 * pow(frequency, 3)
            if c <= 0 {
                terminating = .one
            } else {
                let y = Complex(0, omega * c)               // admittance of the fringing capacitance
                terminating = (Complex.one - z0 * y) / (Complex.one + z0 * y)
            }
        case .short:
            let l = l0 + l1 * frequency + l2 * frequency * frequency + l3 * pow(frequency, 3)
            let z = Complex(0, omega * l)
            terminating = (z - Complex(z0, 0)) / (z + Complex(z0, 0))
        case .load:
            let z = Complex(loadResistance, omega * loadInductance)
            terminating = (z - Complex(z0, 0)) / (z + Complex(z0, 0))
        case .thru:
            terminating = .zero
        }

        return applyOffset(to: terminating, frequency: frequency, roundTrip: true)
    }

    /// Transmission coefficient of a through standard.
    public func transmission(at frequency: Double) -> Complex {
        guard kind == .thru else { return .one }
        return applyOffset(to: .one, frequency: frequency, roundTrip: false)
    }

    private func applyOffset(to gamma: Complex, frequency: Double, roundTrip: Bool) -> Complex {
        guard offsetDelay != 0 || offsetLoss != 0 else { return gamma }
        let passes = roundTrip ? 2.0 : 1.0
        let beta = 2 * Double.pi * frequency * offsetDelay
        // HP offset loss model: alpha·l = (loss · delay) / (2 · Z0) · sqrt(f / 1 GHz)
        let alpha = offsetLoss > 0
            ? (offsetLoss * offsetDelay) / (2 * offsetZ0) * (frequency / 1e9).squareRoot()
            : 0
        let attenuation = exp(-passes * alpha)
        return gamma * Complex.expj(-passes * beta) * attenuation
    }
}

/// A named set of standards.
public struct CalKit: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var manufacturer: String
    public var open: CalStandard
    public var short: CalStandard
    public var load: CalStandard
    public var thru: CalStandard
    public var notes: String

    public init(id: UUID = UUID(),
                name: String,
                manufacturer: String = "",
                open: CalStandard = CalStandard(kind: .open),
                short: CalStandard = CalStandard(kind: .short),
                load: CalStandard = CalStandard(kind: .load),
                thru: CalStandard = CalStandard(kind: .thru),
                notes: String = "") {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.open = open
        self.short = short
        self.load = load
        self.thru = thru
        self.notes = notes
    }

    public func standard(_ kind: StandardKind) -> CalStandard {
        switch kind {
        case .open: return open
        case .short: return short
        case .load: return load
        case .thru: return thru
        }
    }

    public mutating func setStandard(_ standard: CalStandard) {
        switch standard.kind {
        case .open: open = standard
        case .short: short = standard
        case .load: load = standard
        case .thru: thru = standard
        }
    }

    // MARK: - Built-in kits

    /// Perfectly ideal standards: what the NanoVNA firmware itself assumes.
    public static let ideal = CalKit(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Ideal (no correction)",
        manufacturer: "Built-in",
        notes: "Open = +1, Short = −1, Load = 50 Ω, Through = lossless. Matches on-device calibration."
    )

    /// Typical inexpensive SMA kit shipped with NanoVNA units.
    public static let nanoVNASMA = CalKit(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "NanoVNA SMA kit (typical)",
        manufacturer: "Built-in",
        open: CalStandard(kind: .open, offsetDelay: 0, c0: 50e-15, c1: 0, c2: 0, c3: 0),
        short: CalStandard(kind: .short, offsetDelay: 0, l0: 0),
        load: CalStandard(kind: .load, loadResistance: 50),
        thru: CalStandard(kind: .thru, offsetDelay: 0),
        notes: "Nominal values for the SMA open/short/load supplied with most NanoVNA kits."
    )

    /// Coefficients close to a Keysight 85033E 3.5 mm kit — a good starting point for
    /// precision SMA standards.
    public static let precision35mm = CalKit(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "3.5 mm precision (85033E-like)",
        manufacturer: "Built-in",
        open: CalStandard(kind: .open, offsetDelay: 29.243e-12, offsetLoss: 2.2e9,
                          c0: 49.433e-15, c1: -310.13e-27, c2: 23.168e-36, c3: -0.15966e-45),
        short: CalStandard(kind: .short, offsetDelay: 31.785e-12, offsetLoss: 2.36e9,
                           l0: 2.0765e-12, l1: -108.54e-24, l2: 2.1705e-33, l3: -0.01e-42),
        load: CalStandard(kind: .load, offsetDelay: 0, loadResistance: 50),
        thru: CalStandard(kind: .thru, offsetDelay: 0, offsetLoss: 2.6e9),
        notes: "Approximate 3.5 mm coefficients. Replace with the values on your own kit's data sheet."
    )

    public static let builtIns: [CalKit] = [.ideal, .nanoVNASMA, .precision35mm]
}
