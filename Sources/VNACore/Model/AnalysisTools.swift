import Foundation

// MARK: - L-network impedance matching

public struct MatchingComponent: Sendable, Hashable {
    public enum Kind: String, Sendable { case inductor, capacitor }
    public enum Placement: String, Sendable { case series, shunt }
    public var kind: Kind
    public var placement: Placement
    /// Henries or farads.
    public var value: Double
    /// Reactance (series) or susceptance (shunt) at the design frequency.
    public var immittance: Double

    public var description: String {
        let v = kind == .inductor ? Units.inductance(value) : Units.capacitance(value)
        return "\(placement == .series ? "Series" : "Shunt") \(kind == .inductor ? "L" : "C") = \(v)"
    }
}

public struct MatchingSolution: Identifiable, Sendable, Hashable {
    public var id = UUID()
    /// Ordered from the load towards the source.
    public var components: [MatchingComponent]
    public var topology: String
    public var loadedQ: Double
    /// Fractional bandwidth estimate, 1/Q.
    public var fractionalBandwidth: Double

    public var summary: String {
        components.map(\.description).joined(separator: "  →  ")
    }
}

public enum MatchingNetwork {

    /// All two-element L-network solutions that match `load` to a real `z0` at `frequency`.
    public static func lNetworks(load: Complex, z0: Double, frequency: Double) -> [MatchingSolution] {
        guard frequency > 0, z0 > 0, load.isFinite else { return [] }
        let omega = 2 * Double.pi * frequency
        var solutions: [MatchingSolution] = []

        let r = load.re
        let xl = load.im

        // Series element next to the load, then a shunt element. Needs R <= Z0.
        if r > 0, r <= z0 {
            let root = (r * z0 - r * r)
            if root >= 0 {
                for sign in [1.0, -1.0] {
                    let total = sign * root.squareRoot()      // XL + X
                    let x = total - xl
                    let b = total / (r * z0)
                    guard abs(x) > 1e-12 || abs(b) > 1e-15 else { continue }
                    let q = abs(total) / r
                    solutions.append(MatchingSolution(
                        components: [component(reactance: x, omega: omega, placement: .series),
                                     component(susceptance: b, omega: omega, placement: .shunt)],
                        topology: "Series → Shunt (steps R up)",
                        loadedQ: q,
                        fractionalBandwidth: q > 0 ? 1 / q : .infinity))
                }
            }
        }

        // Shunt element across the load, then a series element. Needs the parallel R >= Z0.
        let y = load.reciprocal
        let g = y.re
        let bl = y.im
        if g > 0, g <= 1 / z0 {
            let root = (g / z0 - g * g)
            if root >= 0 {
                for sign in [1.0, -1.0] {
                    let total = sign * root.squareRoot()     // BL + B
                    let b = total - bl
                    let x = total * z0 / g
                    guard abs(x) > 1e-12 || abs(b) > 1e-15 else { continue }
                    let q = abs(total) / g
                    solutions.append(MatchingSolution(
                        components: [component(susceptance: b, omega: omega, placement: .shunt),
                                     component(reactance: x, omega: omega, placement: .series)],
                        topology: "Shunt → Series (steps R down)",
                        loadedQ: q,
                        fractionalBandwidth: q > 0 ? 1 / q : .infinity))
                }
            }
        }

        return solutions
    }

    /// Ideal quarter-wave transformer impedance for a real load.
    public static func quarterWaveImpedance(load: Complex, z0: Double) -> Double? {
        guard load.re > 0, abs(load.im) < load.re * 0.05 else { return nil }
        return (z0 * load.re).squareRoot()
    }

    private static func component(reactance x: Double, omega: Double, placement: MatchingComponent.Placement) -> MatchingComponent {
        if x >= 0 {
            return MatchingComponent(kind: .inductor, placement: placement, value: x / omega, immittance: x)
        }
        return MatchingComponent(kind: .capacitor, placement: placement, value: -1 / (omega * x), immittance: x)
    }

    private static func component(susceptance b: Double, omega: Double, placement: MatchingComponent.Placement) -> MatchingComponent {
        if b >= 0 {
            return MatchingComponent(kind: .capacitor, placement: placement, value: b / omega, immittance: b)
        }
        return MatchingComponent(kind: .inductor, placement: placement, value: -1 / (omega * b), immittance: b)
    }

    /// Verify a solution by transforming the load through the network.
    public static func resultingImpedance(load: Complex, solution: MatchingSolution, frequency: Double) -> Complex {
        let omega = 2 * Double.pi * frequency
        var z = load
        for c in solution.components {
            switch c.placement {
            case .series:
                let x = c.kind == .inductor ? omega * c.value : -1 / (omega * c.value)
                z = z + Complex(0, x)
            case .shunt:
                let b = c.kind == .capacitor ? omega * c.value : -1 / (omega * c.value)
                let y = z.reciprocal + Complex(0, b)
                z = y.reciprocal
            }
        }
        return z
    }
}

// MARK: - Cable measurements

public enum CableTools {

    public struct CableType: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public var name: String
        public var velocityFactor: Double
        public var impedance: Double
        /// Matched loss in dB per 100 m at 100 MHz, used for a rough loss estimate.
        public var lossPer100mAt100MHz: Double
        public init(name: String, velocityFactor: Double, impedance: Double, lossPer100mAt100MHz: Double) {
            self.name = name
            self.velocityFactor = velocityFactor
            self.impedance = impedance
            self.lossPer100mAt100MHz = lossPer100mAt100MHz
        }
    }

    public static let commonCables: [CableType] = [
        CableType(name: "RG-58 C/U", velocityFactor: 0.66, impedance: 50, lossPer100mAt100MHz: 16.0),
        CableType(name: "RG-58 (foam)", velocityFactor: 0.79, impedance: 50, lossPer100mAt100MHz: 13.5),
        CableType(name: "RG-59", velocityFactor: 0.66, impedance: 75, lossPer100mAt100MHz: 11.5),
        CableType(name: "RG-6", velocityFactor: 0.83, impedance: 75, lossPer100mAt100MHz: 6.6),
        CableType(name: "RG-8X", velocityFactor: 0.82, impedance: 50, lossPer100mAt100MHz: 10.5),
        CableType(name: "RG-213", velocityFactor: 0.66, impedance: 50, lossPer100mAt100MHz: 7.0),
        CableType(name: "RG-316", velocityFactor: 0.695, impedance: 50, lossPer100mAt100MHz: 26.0),
        CableType(name: "RG-174", velocityFactor: 0.66, impedance: 50, lossPer100mAt100MHz: 30.0),
        CableType(name: "LMR-240", velocityFactor: 0.84, impedance: 50, lossPer100mAt100MHz: 8.5),
        CableType(name: "LMR-400", velocityFactor: 0.85, impedance: 50, lossPer100mAt100MHz: 3.9),
        CableType(name: "LMR-600", velocityFactor: 0.87, impedance: 50, lossPer100mAt100MHz: 2.5),
        CableType(name: "Belden 9913", velocityFactor: 0.84, impedance: 50, lossPer100mAt100MHz: 4.0),
        CableType(name: "Hardline 1/2\"", velocityFactor: 0.88, impedance: 50, lossPer100mAt100MHz: 2.2),
        CableType(name: "Semi-rigid 0.141\"", velocityFactor: 0.695, impedance: 50, lossPer100mAt100MHz: 13.0),
        CableType(name: "Ladder line 450 Ω", velocityFactor: 0.91, impedance: 450, lossPer100mAt100MHz: 1.5),
        CableType(name: "Vacuum / air line", velocityFactor: 1.0, impedance: 50, lossPer100mAt100MHz: 0.5)
    ]

    /// Velocity factor implied by a known physical length and a measured round-trip delay.
    public static func velocityFactor(physicalLength: Double, roundTripDelay: Double) -> Double? {
        guard physicalLength > 0, roundTripDelay > 0 else { return nil }
        return (2 * physicalLength) / (roundTripDelay * speedOfLight)
    }

    /// Electrical length from a measured round-trip delay and a known velocity factor.
    public static func length(roundTripDelay: Double, velocityFactor: Double) -> Double {
        roundTripDelay * speedOfLight * velocityFactor / 2
    }

    /// One-way cable loss from a reflection measurement with the far end open or shorted.
    public static func lossFromReflection(_ s11: [Complex]) -> [Double] {
        s11.map { -RF.dB($0.magnitude) / 2 }
    }

    /// Estimated matched loss for a catalogue cable.
    public static func estimatedLoss(cable: CableType, lengthMetres: Double, frequency: Double) -> Double {
        guard frequency > 0 else { return 0 }
        // Loss scales roughly with the square root of frequency for skin-effect dominated cable.
        let scale = (frequency / 100e6).squareRoot()
        return cable.lossPer100mAt100MHz * scale * lengthMetres / 100
    }

    /// Characteristic impedance estimate from an open/short pair: Z0 = sqrt(Zoc · Zsc).
    public static func characteristicImpedance(open: Complex, short: Complex, z0: Double) -> Complex {
        let zoc = RF.impedance(open, z0: z0)
        let zsc = RF.impedance(short, z0: z0)
        return (zoc * zsc).squareRoot
    }
}

// MARK: - Filter and antenna analysis

public enum FilterAnalysis {

    public struct Report: Sendable {
        public var insertionLoss: Double = 0        // dB, minimum loss in the passband
        public var centerFrequency: Double = 0
        public var lowerCutoff: Double = 0
        public var upperCutoff: Double = 0
        public var bandwidth3dB: Double = 0
        public var bandwidth6dB: Double = 0
        public var bandwidth60dB: Double = 0
        public var shapeFactor: Double = 0          // 60 dB BW / 3 dB BW
        public var passbandRipple: Double = 0
        public var q: Double = 0
        public var stopbandRejection: Double = 0
        public var isValid: Bool = false
    }

    public static func analyse(s21: [Complex], frequencies: [Double]) -> Report {
        var report = Report()
        guard s21.count == frequencies.count, s21.count > 4 else { return report }
        let db = s21.map { RF.dB($0.magnitude) }
        guard let peakIndex = TraceAnalysis.indexOfMaximum(db) else { return report }
        let peak = db[peakIndex]
        report.insertionLoss = -peak
        report.centerFrequency = frequencies[peakIndex]

        if let bw3 = TraceAnalysis.bandwidth(values: db, frequencies: frequencies, dropDB: 3) {
            report.lowerCutoff = bw3.lower
            report.upperCutoff = bw3.upper
            report.bandwidth3dB = bw3.bandwidth
            report.centerFrequency = bw3.centerFrequency
            report.q = bw3.q
            // Ripple across the passband.
            let inBand = zip(frequencies, db).filter { $0.0 >= bw3.lower && $0.0 <= bw3.upper }.map(\.1)
            if let lo = inBand.min(), let hi = inBand.max() { report.passbandRipple = hi - lo }
            report.isValid = true
        }
        if let bw6 = TraceAnalysis.bandwidth(values: db, frequencies: frequencies, dropDB: 6) {
            report.bandwidth6dB = bw6.bandwidth
        }
        if let bw60 = TraceAnalysis.bandwidth(values: db, frequencies: frequencies, dropDB: 60) {
            report.bandwidth60dB = bw60.bandwidth
            if report.bandwidth3dB > 0 { report.shapeFactor = bw60.bandwidth / report.bandwidth3dB }
        }
        // Worst rejection outside the 3 dB band.
        if report.bandwidth3dB > 0 {
            let out = zip(frequencies, db).filter { $0.0 < report.lowerCutoff || $0.0 > report.upperCutoff }.map(\.1)
            if let worst = out.max() { report.stopbandRejection = peak - worst }
        }
        return report
    }
}

public enum AntennaAnalysis {

    public struct Report: Sendable {
        public var resonantFrequency: Double = 0
        public var minimumSWRFrequency: Double = 0
        public var minimumSWR: Double = 0
        public var impedanceAtResonance: Complex = .zero
        public var impedanceAtMinimumSWR: Complex = .zero
        public var bandwidthLower: Double = 0
        public var bandwidthUpper: Double = 0
        public var bandwidth: Double = 0
        public var q: Double = 0
        public var returnLossAtMinimum: Double = 0
        public var swrThreshold: Double = 2
        public var isValid: Bool = false
    }

    public static func analyse(s11: [Complex], frequencies: [Double], z0: Double,
                               swrThreshold: Double = 2.0) -> Report {
        var report = Report()
        report.swrThreshold = swrThreshold
        guard s11.count == frequencies.count, s11.count > 3 else { return report }

        let swr = s11.map { RF.swr($0) }
        guard let minIndex = TraceAnalysis.indexOfMinimum(swr) else { return report }
        report.minimumSWR = swr[minIndex]
        report.minimumSWRFrequency = frequencies[minIndex]
        report.impedanceAtMinimumSWR = RF.impedance(s11[minIndex], z0: z0)
        report.returnLossAtMinimum = RF.returnLoss(s11[minIndex])

        if let res = TraceAnalysis.resonance(values: s11, frequencies: frequencies, z0: z0) {
            report.resonantFrequency = res
            let idx = frequencies.enumerated().min { abs($0.element - res) < abs($1.element - res) }?.offset ?? minIndex
            report.impedanceAtResonance = RF.impedance(s11[idx], z0: z0)
        } else {
            report.resonantFrequency = report.minimumSWRFrequency
            report.impedanceAtResonance = report.impedanceAtMinimumSWR
        }

        let lower = TraceAnalysis.crossing(swr, x: frequencies, level: swrThreshold, from: minIndex, direction: -1)
        let upper = TraceAnalysis.crossing(swr, x: frequencies, level: swrThreshold, from: minIndex, direction: +1)
        if let lo = lower, let hi = upper, hi > lo {
            report.bandwidthLower = lo
            report.bandwidthUpper = hi
            report.bandwidth = hi - lo
            report.q = report.bandwidth > 0 ? (lo + hi) / 2 / report.bandwidth : 0
        }
        report.isValid = true
        return report
    }
}
