import Foundation

/// Which raw measurement a trace is derived from.
public enum Channel: String, Codable, CaseIterable, Sendable, Identifiable {
    case s11
    case s21
    case s12
    case s22
    public var id: String { rawValue }

    public var shortName: String { rawValue.uppercased() }

    public var longName: String {
        switch self {
        case .s11: return "S11 · Port 1 reflection"
        case .s21: return "S21 · Forward transmission"
        case .s12: return "S12 · Reverse transmission"
        case .s22: return "S22 · Port 2 reflection"
        }
    }

    /// S11 and S22 are reflection measurements, so impedance formats apply to them.
    public var isReflection: Bool { self == .s11 || self == .s22 }

    /// Which port is driven for this parameter (1-based).
    public var excitedPort: Int { (self == .s11 || self == .s21) ? 1 : 2 }

    /// Parameters a one-port-plus-response instrument (every NanoVNA) can measure.
    public static let nanoVNASubset: [Channel] = [.s11, .s21]
    public static let fullTwoPort: [Channel] = [.s11, .s21, .s12, .s22]
}

/// The x-axis a trace lives on.
public enum TraceDomain: Equatable, Sendable {
    case frequency
    case time      // TDR / distance-to-fault
    case smith
    case polar
}

/// Every display conversion the app can apply to a measured S-parameter.
public enum TraceFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    // Magnitude / phase
    case logMag
    case linMag
    case phase
    case unwrappedPhase
    case groupDelay
    case swr
    case returnLoss
    case mismatchLoss
    case reflectedPower
    case realPart
    case imagPart

    // Impedance domain
    case resistance
    case reactance
    case impedanceMagnitude
    case impedancePhase
    case conductance
    case susceptance
    case admittanceMagnitude
    case seriesCapacitance
    case seriesInductance
    case parallelCapacitance
    case parallelInductance
    case qFactor

    // Fixture impedance derived from S21
    case shuntThroughR
    case shuntThroughX
    case seriesThroughR
    case seriesThroughX

    // Charts
    case smith
    case admittanceSmith
    case polar

    // Time domain
    case tdrLowpassImpulse
    case tdrLowpassStep
    case tdrBandpassImpulse
    case tdrImpedance

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .logMag: return "Log Mag"
        case .linMag: return "Lin Mag"
        case .phase: return "Phase"
        case .unwrappedPhase: return "Phase (unwrapped)"
        case .groupDelay: return "Group Delay"
        case .swr: return "SWR"
        case .returnLoss: return "Return Loss"
        case .mismatchLoss: return "Mismatch Loss"
        case .reflectedPower: return "Reflected Power"
        case .realPart: return "Real"
        case .imagPart: return "Imag"
        case .resistance: return "Resistance R"
        case .reactance: return "Reactance X"
        case .impedanceMagnitude: return "|Z|"
        case .impedancePhase: return "∠Z"
        case .conductance: return "Conductance G"
        case .susceptance: return "Susceptance B"
        case .admittanceMagnitude: return "|Y|"
        case .seriesCapacitance: return "Series C"
        case .seriesInductance: return "Series L"
        case .parallelCapacitance: return "Parallel C"
        case .parallelInductance: return "Parallel L"
        case .qFactor: return "Q Factor"
        case .shuntThroughR: return "Shunt-thru R"
        case .shuntThroughX: return "Shunt-thru X"
        case .seriesThroughR: return "Series-thru R"
        case .seriesThroughX: return "Series-thru X"
        case .smith: return "Smith Chart"
        case .admittanceSmith: return "Smith (admittance)"
        case .polar: return "Polar"
        case .tdrLowpassImpulse: return "TDR Lowpass Impulse"
        case .tdrLowpassStep: return "TDR Lowpass Step"
        case .tdrBandpassImpulse: return "TDR Bandpass Impulse"
        case .tdrImpedance: return "TDR Impedance"
        }
    }

    public var unit: String {
        switch self {
        case .logMag, .returnLoss, .mismatchLoss: return "dB"
        case .phase, .unwrappedPhase, .impedancePhase: return "°"
        case .groupDelay: return "s"
        case .reflectedPower: return "%"
        case .resistance, .reactance, .impedanceMagnitude,
             .shuntThroughR, .shuntThroughX, .seriesThroughR, .seriesThroughX,
             .tdrImpedance:
            return "Ω"
        case .conductance, .susceptance, .admittanceMagnitude: return "S"
        case .seriesCapacitance, .parallelCapacitance: return "F"
        case .seriesInductance, .parallelInductance: return "H"
        default: return ""
        }
    }

    public var domain: TraceDomain {
        switch self {
        case .smith, .admittanceSmith: return .smith
        case .polar: return .polar
        case .tdrLowpassImpulse, .tdrLowpassStep, .tdrBandpassImpulse, .tdrImpedance: return .time
        default: return .frequency
        }
    }

    /// Formats that only make sense on a reflection measurement.
    public var reflectionOnly: Bool {
        switch self {
        case .swr, .returnLoss, .mismatchLoss, .reflectedPower,
             .resistance, .reactance, .impedanceMagnitude, .impedancePhase,
             .conductance, .susceptance, .admittanceMagnitude,
             .seriesCapacitance, .seriesInductance, .parallelCapacitance, .parallelInductance,
             .qFactor, .smith, .admittanceSmith,
             .tdrLowpassImpulse, .tdrLowpassStep, .tdrBandpassImpulse, .tdrImpedance:
            return true
        default:
            return false
        }
    }

    /// (value per division, reference division from the bottom of 10 divisions)
    public var defaultScale: (perDivision: Double, referencePosition: Double) {
        switch self {
        case .logMag: return (10, 9)
        case .linMag: return (0.1, 0)
        case .phase, .impedancePhase: return (45, 5)
        case .unwrappedPhase: return (90, 5)
        case .groupDelay: return (1e-9, 5)
        case .swr: return (1, 0)
        case .returnLoss: return (10, 0)
        case .mismatchLoss: return (1, 0)
        case .reflectedPower: return (10, 0)
        case .realPart, .imagPart: return (0.25, 5)
        case .resistance, .reactance, .impedanceMagnitude,
             .shuntThroughR, .shuntThroughX, .seriesThroughR, .seriesThroughX:
            return (50, 5)
        case .tdrImpedance: return (25, 4)
        case .conductance, .susceptance, .admittanceMagnitude: return (0.01, 5)
        case .seriesCapacitance, .parallelCapacitance: return (1e-11, 0)
        case .seriesInductance, .parallelInductance: return (1e-8, 0)
        case .qFactor: return (10, 0)
        case .tdrLowpassImpulse, .tdrBandpassImpulse: return (0.1, 5)
        case .tdrLowpassStep: return (0.1, 5)
        case .smith, .admittanceSmith, .polar: return (1, 5)
        }
    }

    /// Digits used in marker readouts.
    public var readoutDigits: Int {
        switch self {
        case .swr, .qFactor: return 3
        case .logMag, .returnLoss, .phase, .unwrappedPhase: return 2
        default: return 3
        }
    }

    public static var frequencyFormats: [TraceFormat] {
        allCases.filter { $0.domain == .frequency }
    }
    public static var timeFormats: [TraceFormat] {
        allCases.filter { $0.domain == .time }
    }
}
