import Foundation

/// Where a trace's data comes from.
public enum TraceSource: Codable, Hashable, Sendable {
    case live
    case memory(UUID)
    /// live minus a stored memory frame (in dB / complex ratio)
    case liveDividedByMemory(UUID)
    case liveMinusMemory(UUID)

    public var memoryID: UUID? {
        switch self {
        case .live: return nil
        case .memory(let id), .liveDividedByMemory(let id), .liveMinusMemory(let id): return id
        }
    }

    public var displayName: String {
        switch self {
        case .live: return "Live"
        case .memory: return "Memory"
        case .liveDividedByMemory: return "Live ÷ Memory"
        case .liveMinusMemory: return "Live − Memory"
        }
    }
}

/// One displayed curve.
public struct Trace: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var channel: Channel
    public var format: TraceFormat
    public var source: TraceSource
    public var colorIndex: Int
    /// Vertical scale, in trace units per division.
    public var scalePerDivision: Double
    /// Which of the 10 divisions (0 = bottom) the reference value sits on.
    public var referencePosition: Double
    /// Value at the reference line.
    public var referenceValue: Double
    public var autoScaleOnLoad: Bool
    /// Boxcar smoothing width in points (1 = off).
    public var smoothing: Int
    /// Port extension in seconds.
    public var electricalDelay: Double
    /// Cable loss compensation in dB per GHz.
    public var lossPerGHz: Double
    public var lineWidth: Double
    public var customName: String

    public init(id: UUID = UUID(),
                channel: Channel = .s11,
                format: TraceFormat = .logMag,
                source: TraceSource = .live,
                colorIndex: Int = 0,
                enabled: Bool = true) {
        self.id = id
        self.enabled = enabled
        self.channel = channel
        self.format = format
        self.source = source
        self.colorIndex = colorIndex
        let defaults = format.defaultScale
        self.scalePerDivision = defaults.perDivision
        self.referencePosition = defaults.referencePosition
        self.referenceValue = 0
        self.autoScaleOnLoad = false
        self.smoothing = 1
        self.electricalDelay = 0
        self.lossPerGHz = 0
        self.lineWidth = 1.8
        self.customName = ""
    }

    public var displayName: String {
        if !customName.isEmpty { return customName }
        let prefix = source == .live ? "" : "\(source.displayName) · "
        return "\(prefix)\(channel.shortName) \(format.displayName)"
    }

    /// Reset scaling to the format's defaults.
    public mutating func applyDefaultScale() {
        let d = format.defaultScale
        scalePerDivision = d.perDivision
        referencePosition = d.referencePosition
        referenceValue = defaultReferenceValue
    }

    public var defaultReferenceValue: Double {
        switch format {
        case .logMag, .returnLoss: return 0
        case .swr: return 1
        case .phase, .unwrappedPhase, .impedancePhase: return 0
        case .resistance, .reactance, .impedanceMagnitude, .tdrImpedance: return 50
        default: return 0
        }
    }

    /// Value range currently displayed, given 10 divisions.
    public var displayRange: ClosedRange<Double> {
        let bottom = referenceValue - scalePerDivision * referencePosition
        let top = bottom + scalePerDivision * 10
        return bottom...max(top, bottom + 1e-12)
    }
}

/// Evaluated samples ready for drawing.
public struct TraceSamples: Sendable {
    public var x: [Double] = []          // Hz for frequency domain, metres for time domain
    public var y: [Double] = []          // scalar values in trace units
    public var complex: [Complex] = []   // for Smith / polar
    public var domain: TraceDomain = .frequency
    public var timeAxisSeconds: [Double] = []
    public var isEmpty: Bool { x.isEmpty }
    public static let empty = TraceSamples()
}

public enum TraceEvaluator {

    /// Resolve the complex data a trace should display, applying source maths,
    /// smoothing, electrical delay and loss compensation.
    public static func complexData(for trace: Trace,
                                   live: SweepFrame,
                                   memories: [UUID: SweepFrame]) -> (values: [Complex], frame: SweepFrame) {
        var frame = live
        var values: [Complex]

        switch trace.source {
        case .live:
            values = live.values(for: trace.channel)
        case .memory(let id):
            guard let mem = memories[id] else { return ([], live) }
            frame = live.isEmpty ? mem : mem.resampled(to: live.frequencies)
            values = frame.values(for: trace.channel)
        case .liveDividedByMemory(let id):
            guard let mem = memories[id], !live.isEmpty else { return ([], live) }
            let m = mem.resampled(to: live.frequencies).values(for: trace.channel)
            let l = live.values(for: trace.channel)
            values = zip(l, m).map { a, b in b.magnitudeSquared > 1e-30 ? a / b : .zero }
        case .liveMinusMemory(let id):
            guard let mem = memories[id], !live.isEmpty else { return ([], live) }
            let m = mem.resampled(to: live.frequencies).values(for: trace.channel)
            let l = live.values(for: trace.channel)
            values = zip(l, m).map { $0 - $1 }
        }

        guard !values.isEmpty else { return ([], frame) }

        if trace.electricalDelay != 0 || trace.lossPerGHz != 0 {
            values = RF.applyElectricalDelay(values, frequencies: frame.frequencies,
                                             delaySeconds: trace.electricalDelay,
                                             lossDBperGHz: trace.lossPerGHz,
                                             reflection: trace.channel.isReflection)
        }
        if trace.smoothing > 1 {
            values = RF.smooth(values, window: trace.smoothing)
        }
        return (values, frame)
    }

    /// Full evaluation including the time-domain transform.
    public static func samples(for trace: Trace,
                               live: SweepFrame,
                               memories: [UUID: SweepFrame],
                               timeDomain: TimeDomainSettings,
                               groupDelayAperture: Int = 1) -> TraceSamples {
        let (values, frame) = complexData(for: trace, live: live, memories: memories)
        guard !values.isEmpty, !frame.isEmpty else { return .empty }

        var out = TraceSamples()
        out.domain = trace.format.domain

        switch trace.format.domain {
        case .smith, .polar:
            out.complex = values
            out.x = frame.frequencies
            out.y = values.map { $0.magnitude }
            return out

        case .time:
            var settings = timeDomain
            settings.z0 = frame.z0
            switch trace.format {
            case .tdrBandpassImpulse: settings.mode = .bandpassImpulse
            case .tdrLowpassImpulse: settings.mode = .lowpassImpulse
            case .tdrLowpassStep, .tdrImpedance:
                if settings.mode == .bandpassImpulse { settings.mode = .lowpassStep }
            default: break
            }
            let td = TimeDomain.transform(frequencies: frame.frequencies, values: values, settings: settings)
            out.x = td.distance
            out.timeAxisSeconds = td.time
            switch trace.format {
            case .tdrLowpassStep: out.y = td.step
            case .tdrImpedance: out.y = td.impedance
            default: out.y = td.impulse
            }
            out.complex = td.complexResponse
            return out

        case .frequency:
            out.x = frame.frequencies
            out.complex = values
            out.y = scalarValues(format: trace.format,
                                 values: values,
                                 frequencies: frame.frequencies,
                                 z0: frame.z0,
                                 groupDelayAperture: groupDelayAperture)
            return out
        }
    }

    /// Convert complex S-parameters into the scalar quantity a format displays.
    public static func scalarValues(format: TraceFormat,
                                    values: [Complex],
                                    frequencies: [Double],
                                    z0: Double,
                                    groupDelayAperture: Int = 1) -> [Double] {
        switch format {
        case .unwrappedPhase:
            return RF.unwrappedPhaseDegrees(values)
        case .groupDelay:
            return RF.groupDelay(values, frequencies: frequencies, aperture: groupDelayAperture)
        default:
            return values.indices.map { i in
                scalarValue(format: format, value: values[i],
                            frequency: i < frequencies.count ? frequencies[i] : 0, z0: z0)
            }
        }
    }

    /// Single-sample conversion, also used for marker readouts.
    public static func scalarValue(format: TraceFormat, value v: Complex,
                                   frequency: Double, z0: Double) -> Double {
        switch format {
        case .logMag: return RF.dB(v.magnitude)
        case .linMag: return v.magnitude
        case .phase: return v.phase * 180 / .pi
        case .unwrappedPhase: return v.phase * 180 / .pi
        case .groupDelay: return 0
        case .swr: return RF.swr(v)
        case .returnLoss: return RF.returnLoss(v)
        case .mismatchLoss: return RF.mismatchLoss(v)
        case .reflectedPower: return RF.reflectedPowerPercent(v)
        case .realPart: return v.re
        case .imagPart: return v.im
        case .resistance: return RF.impedance(v, z0: z0).re
        case .reactance: return RF.impedance(v, z0: z0).im
        case .impedanceMagnitude: return RF.impedance(v, z0: z0).magnitude
        case .impedancePhase: return RF.impedance(v, z0: z0).phase * 180 / .pi
        case .conductance: return RF.admittance(v, z0: z0).re
        case .susceptance: return RF.admittance(v, z0: z0).im
        case .admittanceMagnitude: return RF.admittance(v, z0: z0).magnitude
        case .seriesCapacitance: return RF.seriesCapacitance(v, z0: z0, frequency: frequency)
        case .seriesInductance: return RF.seriesInductance(v, z0: z0, frequency: frequency)
        case .parallelCapacitance: return RF.parallelCapacitance(v, z0: z0, frequency: frequency)
        case .parallelInductance: return RF.parallelInductance(v, z0: z0, frequency: frequency)
        case .qFactor: return RF.qFactor(v, z0: z0)
        case .shuntThroughR: return RF.shuntThroughImpedance(v, z0: z0).re
        case .shuntThroughX: return RF.shuntThroughImpedance(v, z0: z0).im
        case .seriesThroughR: return RF.seriesThroughImpedance(v, z0: z0).re
        case .seriesThroughX: return RF.seriesThroughImpedance(v, z0: z0).im
        case .smith, .admittanceSmith, .polar: return v.magnitude
        case .tdrLowpassImpulse, .tdrLowpassStep, .tdrBandpassImpulse, .tdrImpedance: return 0
        }
    }

    /// Nice round scale that fits the data into 10 divisions.
    public static func autoScale(values: [Double], format: TraceFormat) -> (perDivision: Double, referenceValue: Double, referencePosition: Double) {
        let finite = values.filter { $0.isFinite }
        guard let lo = finite.min(), let hi = finite.max(), hi > lo else {
            let d = format.defaultScale
            return (d.perDivision, values.first ?? 0, d.referencePosition)
        }
        let span = hi - lo
        let rawStep = span * 1.15 / 10
        let magnitude = pow(10, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let nice: Double
        switch normalized {
        case ..<1.5: nice = 1
        case ..<3.5: nice = 2
        case ..<7.5: nice = 5
        default: nice = 10
        }
        let step = nice * magnitude
        let mid = (hi + lo) / 2
        let centeredRef = (mid / step).rounded() * step
        return (step, centeredRef, 5)
    }
}
