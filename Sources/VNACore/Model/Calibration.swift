import Foundation

/// Which raw standard measurements a calibration holds.
public enum CalStep: String, Codable, CaseIterable, Sendable, Identifiable {
    case open, short, load              // port 1
    case open2, short2, load2           // port 2 — only on instruments with a reverse path
    case isolation, thru

    public var id: String { rawValue }

    /// 1 or 2. Isolation and through involve both ports.
    public var port: Int {
        switch self {
        case .open2, .short2, .load2: return 2
        default: return 1
        }
    }

    public var isPortTwoStandard: Bool { port == 2 }

    public var displayName: String {
        switch self {
        case .open: return "Open (port 1)"
        case .short: return "Short (port 1)"
        case .load: return "Load (port 1)"
        case .open2: return "Open (port 2)"
        case .short2: return "Short (port 2)"
        case .load2: return "Load (port 2)"
        case .isolation: return "Isolation"
        case .thru: return "Through"
        }
    }

    /// The standard model this step measures against.
    public var standardKind: StandardKind {
        switch self {
        case .open, .open2: return .open
        case .short, .short2: return .short
        case .load, .load2, .isolation: return .load
        case .thru: return .thru
        }
    }

    public var instructions: String {
        switch self {
        case .open: return "Connect the OPEN standard to port 1 (CH0) and measure."
        case .short: return "Connect the SHORT standard to port 1 (CH0) and measure."
        case .load: return "Connect the LOAD (50 Ω) standard to port 1 (CH0) and measure."
        case .open2: return "Connect the OPEN standard to port 2 and measure. Needed for a full two-port calibration."
        case .short2: return "Connect the SHORT standard to port 2 and measure. Needed for a full two-port calibration."
        case .load2: return "Connect the LOAD standard to port 2 and measure. Needed for a full two-port calibration."
        case .isolation: return "Leave loads on both ports with no through connection. Optional, improves transmission dynamic range."
        case .thru: return "Connect port 1 to port 2 with the through standard and measure."
        }
    }

    public static let portOneStandards: [CalStep] = [.open, .short, .load]
    public static let portTwoStandards: [CalStep] = [.open2, .short2, .load2]

    public var isRequiredForReflection: Bool { Self.portOneStandards.contains(self) }
}

public enum TransmissionCorrection: String, Codable, CaseIterable, Sendable, Identifiable {
    case normalization
    case enhancedResponse
    public var id: String { rawValue }
    public var displayName: String {
        self == .normalization ? "Through normalisation" : "Enhanced response"
    }
    public var explanation: String {
        switch self {
        case .normalization:
            return "S21 is divided by the through measurement after removing isolation. Simple and robust."
        case .enhancedResponse:
            return "Additionally removes the port-1 source-match interaction using the reflection error terms. More accurate for mismatched DUTs, but a forward-only instrument has to estimate port-2 match from the through."
        }
    }
}

/// What the calibration is actually able to correct with the standards it holds.
public enum CorrectionMode: String, Sendable {
    case none
    case reflectionOnly
    case forwardResponse
    case fullTwoPort

    public var displayName: String {
        switch self {
        case .none: return "Not calibrated"
        case .reflectionOnly: return "One-port (S11)"
        case .forwardResponse: return "One-port + forward response"
        case .fullTwoPort: return "Full two-port (12-term)"
        }
    }

    public var explanation: String {
        switch self {
        case .none:
            return "No standards have been measured yet."
        case .reflectionOnly:
            return "Open, short and load on port 1 remove directivity, source match and reflection tracking from S11."
        case .forwardResponse:
            return "S11 is fully corrected. S21 is corrected for tracking and isolation, but the instrument does not measure the reverse direction, so port-2 match can only be estimated."
        case .fullTwoPort:
            return "All twelve error terms are solved from standards on both ports plus a through. S11, S21, S12 and S22 are corrected simultaneously, including the interaction between the DUT and both port matches."
        }
    }
}

/// Host-side SOLT calibration: raw standard measurements plus the solved error terms.
///
/// Only the raw measurements are persisted; the error terms are re-solved on load.
public struct Calibration: Codable, Sendable, Equatable, Identifiable {

    public var id: UUID = UUID()
    public var name: String = "Untitled"
    public var created: Date = Date()
    public var frequencies: [Double] = []
    public var kit: CalKit = .ideal
    public var z0: Double = 50
    public var transmissionCorrection: TransmissionCorrection = .normalization
    public var notes: String = ""

    /// Raw measurements keyed by step. Reflection steps store the reflection at their own
    /// port; isolation and through store forward transmission.
    public var measurements: [CalStep: [Complex]] = [:]
    /// S11 measured while the through was connected — gives forward load match.
    public var thruReflection: [Complex] = []
    /// S22 measured while the through was connected — gives reverse load match.
    public var thruReflectionPort2: [Complex] = []
    /// S12 measured while the through was connected.
    public var thruReverse: [Complex] = []
    /// S12 measured during the isolation step.
    public var isolationReverse: [Complex] = []

    // Solved forward error terms, one per frequency.
    public private(set) var directivity: [Complex] = []            // EDF
    public private(set) var sourceMatch: [Complex] = []            // ESF
    public private(set) var deltaE: [Complex] = []                 // EDF·ESF − ERF
    public private(set) var reflectionTracking: [Complex] = []     // ERF
    public private(set) var isolationTerm: [Complex] = []          // EXF
    public private(set) var transmissionTracking: [Complex] = []   // ETF
    public private(set) var loadMatch: [Complex] = []              // ELF

    // Solved reverse error terms.
    public private(set) var directivityReverse: [Complex] = []          // EDR
    public private(set) var sourceMatchReverse: [Complex] = []          // ESR
    public private(set) var deltaEReverse: [Complex] = []
    public private(set) var reflectionTrackingReverse: [Complex] = []   // ERR
    public private(set) var isolationTermReverse: [Complex] = []        // EXR
    public private(set) var transmissionTrackingReverse: [Complex] = [] // ETR
    public private(set) var loadMatchReverse: [Complex] = []            // ELR

    public private(set) var isSolved: Bool = false
    public private(set) var isReverseSolved: Bool = false

    public init() {}

    // Only the inputs are persisted; everything derived is recomputed on load.
    private enum CodingKeys: String, CodingKey {
        case id, name, created, frequencies, kit, z0, transmissionCorrection, notes
        case measurements, thruReflection, thruReflectionPort2, thruReverse, isolationReverse
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        frequencies = try c.decodeIfPresent([Double].self, forKey: .frequencies) ?? []
        kit = try c.decodeIfPresent(CalKit.self, forKey: .kit) ?? .ideal
        z0 = try c.decodeIfPresent(Double.self, forKey: .z0) ?? 50
        transmissionCorrection = try c.decodeIfPresent(TransmissionCorrection.self,
                                                       forKey: .transmissionCorrection) ?? .normalization
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        measurements = try c.decodeIfPresent([CalStep: [Complex]].self, forKey: .measurements) ?? [:]
        thruReflection = try c.decodeIfPresent([Complex].self, forKey: .thruReflection) ?? []
        thruReflectionPort2 = try c.decodeIfPresent([Complex].self, forKey: .thruReflectionPort2) ?? []
        thruReverse = try c.decodeIfPresent([Complex].self, forKey: .thruReverse) ?? []
        isolationReverse = try c.decodeIfPresent([Complex].self, forKey: .isolationReverse) ?? []
        solve()
    }

    // MARK: - Status

    public func has(_ step: CalStep) -> Bool { measurements[step]?.isEmpty == false }

    public var completedSteps: Set<CalStep> { Set(CalStep.allCases.filter { has($0) }) }

    public var canSolveReflection: Bool { has(.open) && has(.short) && has(.load) }
    public var canSolveReverseReflection: Bool { has(.open2) && has(.short2) && has(.load2) }
    public var canCorrectTransmission: Bool { has(.thru) }
    /// Everything needed for a 12-term correction.
    public var canCorrectFullTwoPort: Bool {
        canSolveReflection && canSolveReverseReflection && has(.thru)
            && thruReverse.count == frequencies.count
            && thruReflectionPort2.count == frequencies.count
    }

    public var mode: CorrectionMode {
        guard isSolved else { return .none }
        if canCorrectFullTwoPort && isReverseSolved { return .fullTwoPort }
        if canCorrectTransmission { return .forwardResponse }
        return .reflectionOnly
    }

    public var summary: String {
        let letters = CalStep.allCases.filter { has($0) }.map { step -> String in
            switch step {
            case .open: return "O"
            case .short: return "S"
            case .load: return "L"
            case .open2: return "o"
            case .short2: return "s"
            case .load2: return "l"
            case .isolation: return "I"
            case .thru: return "T"
            }
        }
        return letters.isEmpty ? "—" : letters.joined()
    }

    public var frequencyRangeDescription: String {
        guard let lo = frequencies.first, let hi = frequencies.last else { return "no data" }
        return "\(Units.frequencyShort(lo)) – \(Units.frequencyShort(hi)) · \(frequencies.count) pts"
    }

    // MARK: - Recording

    public mutating func record(step: CalStep, frame: SweepFrame) {
        if frequencies != frame.frequencies {
            // A grid change invalidates everything captured so far.
            if !frequencies.isEmpty {
                measurements.removeAll()
                thruReflection = []
                thruReflectionPort2 = []
                thruReverse = []
                isolationReverse = []
            }
            frequencies = frame.frequencies
            z0 = frame.z0
        }

        switch step {
        case .open, .short, .load:
            measurements[step] = frame.s11
        case .open2, .short2, .load2:
            // Prefer the real port-2 reflection; fall back to S11 for one-port workflows
            // where the user moves the standards to the second port manually.
            measurements[step] = frame.hasMeasured(.s22) ? frame.s22 : frame.s11
        case .isolation:
            measurements[step] = frame.s21
            isolationReverse = frame.hasMeasured(.s12) ? frame.s12 : []
        case .thru:
            measurements[step] = frame.s21
            thruReflection = frame.s11
            thruReverse = frame.hasMeasured(.s12) ? frame.s12 : []
            thruReflectionPort2 = frame.hasMeasured(.s22) ? frame.s22 : []
        }
        solve()
    }

    public mutating func clear(step: CalStep) {
        measurements[step] = nil
        if step == .thru {
            thruReflection = []
            thruReverse = []
            thruReflectionPort2 = []
        }
        if step == .isolation { isolationReverse = [] }
        solve()
    }

    public mutating func clearAll() {
        measurements.removeAll()
        thruReflection = []
        thruReflectionPort2 = []
        thruReverse = []
        isolationReverse = []
        frequencies = []
        clearSolved()
    }

    private mutating func clearSolved() {
        isSolved = false
        isReverseSolved = false
        directivity = []; sourceMatch = []; deltaE = []; reflectionTracking = []
        isolationTerm = []; transmissionTracking = []; loadMatch = []
        directivityReverse = []; sourceMatchReverse = []; deltaEReverse = []
        reflectionTrackingReverse = []; isolationTermReverse = []
        transmissionTrackingReverse = []; loadMatchReverse = []
    }

    // MARK: - Solving

    /// Solve the three one-port terms at every frequency from three known standards.
    private func solveOnePort(open: [Complex], short: [Complex], load: [Complex],
                              openStandard: CalStandard, shortStandard: CalStandard,
                              loadStandard: CalStandard)
        -> (directivity: [Complex], sourceMatch: [Complex], delta: [Complex], tracking: [Complex])? {

        guard open.count == frequencies.count,
              short.count == frequencies.count,
              load.count == frequencies.count else { return nil }

        var ed = [Complex](repeating: .zero, count: frequencies.count)
        var es = [Complex](repeating: .zero, count: frequencies.count)
        var de = [Complex](repeating: .zero, count: frequencies.count)
        var er = [Complex](repeating: .one, count: frequencies.count)

        for i in frequencies.indices {
            let f = frequencies[i]
            let g1 = openStandard.reflection(at: f, z0: z0)
            let g2 = shortStandard.reflection(at: f, z0: z0)
            let g3 = loadStandard.reflection(at: f, z0: z0)
            let m1 = open[i], m2 = short[i], m3 = load[i]

            // M = e00 − Γ·Δe + M·Γ·e11
            let a: [[Complex]] = [
                [.one, -g1, m1 * g1],
                [.one, -g2, m2 * g2],
                [.one, -g3, m3 * g3]
            ]
            if let x = solve3x3(a, [m1, m2, m3]) {
                ed[i] = x[0]
                de[i] = x[1]
                es[i] = x[2]
            } else {
                ed[i] = .zero
                de[i] = -Complex.one
                es[i] = .zero
            }
            // ERF = EDF·ESF − ΔE
            er[i] = ed[i] * es[i] - de[i]
        }
        return (ed, es, de, er)
    }

    public mutating func solve() {
        clearSolved()
        guard canSolveReflection,
              let mo = measurements[.open], let ms = measurements[.short], let ml = measurements[.load],
              let forward = solveOnePort(open: mo, short: ms, load: ml,
                                         openStandard: kit.open, shortStandard: kit.short,
                                         loadStandard: kit.load)
        else { return }

        directivity = forward.directivity
        sourceMatch = forward.sourceMatch
        deltaE = forward.delta
        reflectionTracking = forward.tracking

        isolationTerm = measurements[.isolation] ?? []
        if isolationTerm.count != frequencies.count {
            isolationTerm = [Complex](repeating: .zero, count: frequencies.count)
        }
        isolationTermReverse = isolationReverse.count == frequencies.count
            ? isolationReverse
            : [Complex](repeating: .zero, count: frequencies.count)

        // Reverse one-port terms, when port-2 standards exist.
        if canSolveReverseReflection,
           let mo2 = measurements[.open2], let ms2 = measurements[.short2], let ml2 = measurements[.load2],
           let reverse = solveOnePort(open: mo2, short: ms2, load: ml2,
                                      openStandard: kit.open, shortStandard: kit.short,
                                      loadStandard: kit.load) {
            directivityReverse = reverse.directivity
            sourceMatchReverse = reverse.sourceMatch
            deltaEReverse = reverse.delta
            reflectionTrackingReverse = reverse.tracking
        }

        // Through: load match and transmission tracking, in both directions.
        if let thru = measurements[.thru], thru.count == frequencies.count {
            transmissionTracking = [Complex](repeating: .one, count: frequencies.count)
            loadMatch = [Complex](repeating: .zero, count: frequencies.count)

            let haveReverse = !directivityReverse.isEmpty
            if haveReverse {
                transmissionTrackingReverse = [Complex](repeating: .one, count: frequencies.count)
                loadMatchReverse = [Complex](repeating: .zero, count: frequencies.count)
            }

            for i in frequencies.indices {
                let f = frequencies[i]
                let idealForward = kit.thru.transmission(at: f)

                // Forward load match: the through's port-1 reflection, one-port corrected.
                var elf = Complex.zero
                if thruReflection.count == frequencies.count {
                    elf = correctedReflection(thruReflection[i], index: i, reverse: false)
                }
                loadMatch[i] = elf

                let numerator = thru[i] - isolationTerm[i]
                var etf = numerator / idealForward
                if transmissionCorrection == .enhancedResponse || haveReverse {
                    // ETF = (S21m − EXF)·(1 − ESF·ELF) / S21_ideal
                    etf = numerator * (Complex.one - sourceMatch[i] * elf) / idealForward
                }
                transmissionTracking[i] = etf.magnitudeSquared > 1e-30 ? etf : .one

                if haveReverse, thruReverse.count == frequencies.count {
                    var elr = Complex.zero
                    if thruReflectionPort2.count == frequencies.count {
                        elr = correctedReflection(thruReflectionPort2[i], index: i, reverse: true)
                    }
                    loadMatchReverse[i] = elr
                    let reverseNumerator = thruReverse[i] - isolationTermReverse[i]
                    let etr = reverseNumerator * (Complex.one - sourceMatchReverse[i] * elr) / idealForward
                    transmissionTrackingReverse[i] = etr.magnitudeSquared > 1e-30 ? etr : .one
                }
            }
        }

        isSolved = true
        isReverseSolved = !directivityReverse.isEmpty
            && transmissionTrackingReverse.count == frequencies.count
            && loadMatchReverse.count == frequencies.count
    }

    // MARK: - Applying

    @inline(__always)
    private func correctedReflection(_ measured: Complex, index i: Int, reverse: Bool) -> Complex {
        let ed = reverse ? directivityReverse : directivity
        let es = reverse ? sourceMatchReverse : sourceMatch
        let de = reverse ? deltaEReverse : deltaE
        guard i < ed.count, i < es.count, i < de.count else { return measured }
        let denominator = measured * es[i] - de[i]
        guard denominator.magnitudeSquared > 1e-30 else { return measured }
        return (measured - ed[i]) / denominator
    }

    /// Apply the calibration to a frame, interpolating the error terms onto its grid.
    public func apply(to frame: SweepFrame) -> SweepFrame {
        guard isSolved, !frequencies.isEmpty, frame.count > 0 else { return frame }

        let sameGrid = frame.frequencies == frequencies
        func mapped(_ term: [Complex], _ fallback: Complex) -> [Complex] {
            guard term.count == frequencies.count else {
                return [Complex](repeating: fallback, count: frame.count)
            }
            return sameGrid ? term : RF.interpolate(values: term, from: frequencies, to: frame.frequencies)
        }

        let edf = mapped(directivity, .zero)
        let esf = mapped(sourceMatch, .zero)
        let erf = mapped(reflectionTracking, .one)
        let exf = mapped(isolationTerm, .zero)
        let etf = mapped(transmissionTracking, .one)
        let elf = mapped(loadMatch, .zero)

        var out = frame

        // Full 12-term correction when the reverse path was calibrated and measured.
        if mode == .fullTwoPort, frame.isFullTwoPort {
            let edr = mapped(directivityReverse, .zero)
            let esr = mapped(sourceMatchReverse, .zero)
            let err = mapped(reflectionTrackingReverse, .one)
            let exr = mapped(isolationTermReverse, .zero)
            let etr = mapped(transmissionTrackingReverse, .one)
            let elr = mapped(loadMatchReverse, .zero)

            var c11 = [Complex](repeating: .zero, count: frame.count)
            var c21 = [Complex](repeating: .zero, count: frame.count)
            var c12 = [Complex](repeating: .zero, count: frame.count)
            var c22 = [Complex](repeating: .zero, count: frame.count)

            for i in 0..<frame.count {
                let a = (frame.s11[i] - edf[i]) / erf[i]
                let b = (frame.s21[i] - exf[i]) / etf[i]
                let c = (frame.s22[i] - edr[i]) / err[i]
                let d = (frame.s12[i] - exr[i]) / etr[i]

                let denominator = (Complex.one + a * esf[i]) * (Complex.one + c * esr[i])
                    - b * d * elf[i] * elr[i]
                guard denominator.magnitudeSquared > 1e-30 else {
                    c11[i] = a; c21[i] = b; c12[i] = d; c22[i] = c
                    continue
                }
                c11[i] = (a * (Complex.one + c * esr[i]) - elf[i] * b * d) / denominator
                c21[i] = (b * (Complex.one + c * (esr[i] - elf[i]))) / denominator
                c12[i] = (d * (Complex.one + a * (esf[i] - elr[i]))) / denominator
                c22[i] = (c * (Complex.one + a * esf[i]) - elr[i] * b * d) / denominator
            }
            out.s11 = c11
            out.s21 = c21
            out.s12 = c12
            out.s22 = c22
            return out
        }

        // Otherwise: one-port correction on S11, response correction on S21.
        var corrected11 = [Complex](repeating: .zero, count: frame.count)
        for i in 0..<frame.count {
            let m = frame.s11[i]
            let a = (m - edf[i]) / erf[i]
            let denominator = Complex.one + a * esf[i]
            corrected11[i] = denominator.magnitudeSquared > 1e-30 ? a / denominator : m
        }
        out.s11 = corrected11

        if canCorrectTransmission {
            var corrected21 = [Complex](repeating: .zero, count: frame.count)
            for i in 0..<frame.count {
                var v = (frame.s21[i] - exf[i]) / etf[i]
                if transmissionCorrection == .enhancedResponse {
                    let denominator = Complex.one - esf[i] * corrected11[i]
                    if denominator.magnitudeSquared > 1e-12 {
                        v = v * ((Complex.one - esf[i] * elf[i]) / denominator)
                    }
                }
                corrected21[i] = v
            }
            out.s21 = corrected21
        }

        // Port-2 reflection is corrected whenever its standards exist, even without a through.
        if (isReverseSolved || canSolveReverseReflection) && frame.hasMeasured(.s22) {
            let edr = mapped(directivityReverse, .zero)
            let esr = mapped(sourceMatchReverse, .zero)
            let err = mapped(reflectionTrackingReverse, .one)
            if edr.count == frame.count {
                var corrected22 = [Complex](repeating: .zero, count: frame.count)
                for i in 0..<frame.count {
                    let a = (frame.s22[i] - edr[i]) / err[i]
                    let denominator = Complex.one + a * esr[i]
                    corrected22[i] = denominator.magnitudeSquared > 1e-30 ? a / denominator : frame.s22[i]
                }
                out.s22 = corrected22
            }
        }
        return out
    }

    /// True when a sweep lies inside the calibrated frequency range.
    public func covers(_ frame: SweepFrame) -> Bool {
        guard let lo = frequencies.first, let hi = frequencies.last, frame.count > 0 else { return false }
        return frame.startFrequency >= lo - 1 && frame.stopFrequency <= hi + 1
    }

    /// Residual error estimate: how well the load standard corrects back to its ideal value.
    public var residualDirectivityDB: Double? {
        guard isSolved, let ml = measurements[.load], ml.count == frequencies.count else { return nil }
        var worst = 0.0
        for i in frequencies.indices {
            let ideal = kit.load.reflection(at: frequencies[i], z0: z0)
            let got = correctedReflection(ml[i], index: i, reverse: false)
            worst = max(worst, (got - ideal).magnitude)
        }
        return RF.dB(worst)
    }
}
