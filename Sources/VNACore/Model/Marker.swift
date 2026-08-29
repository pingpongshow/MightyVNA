import Foundation

public enum MarkerTracking: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case maximum
    case minimum
    case peakLeft
    case peakRight
    case bandwidthLower
    case bandwidthUpper
    case resonance          // zero crossing of reactance
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: return "Fixed"
        case .maximum: return "Track maximum"
        case .minimum: return "Track minimum"
        case .peakLeft: return "Track peak (left)"
        case .peakRight: return "Track peak (right)"
        case .bandwidthLower: return "Track −3 dB lower"
        case .bandwidthUpper: return "Track −3 dB upper"
        case .resonance: return "Track resonance (X = 0)"
        }
    }
}

public struct Marker: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var number: Int
    public var enabled: Bool
    /// Position on the x axis: Hz in the frequency domain, metres in the time domain.
    public var frequency: Double
    public var distance: Double
    public var tracking: MarkerTracking
    /// Which trace drives tracking and the primary readout.
    public var boundTraceID: UUID?
    /// Show the difference from this marker instead of absolute values.
    public var deltaReferenceID: UUID?
    public var colorIndex: Int
    public var showsOnChart: Bool

    public init(number: Int, frequency: Double = 0) {
        self.id = UUID()
        self.number = number
        self.enabled = number == 1
        self.frequency = frequency
        self.distance = 0
        self.tracking = .none
        self.boundTraceID = nil
        self.deltaReferenceID = nil
        self.colorIndex = number - 1
        self.showsOnChart = true
    }

    public var label: String { "M\(number)" }
}

/// Peak / bandwidth analysis helpers used by marker tracking and the tool panels.
public enum TraceAnalysis {

    public static func indexOfMaximum(_ values: [Double]) -> Int? {
        guard !values.isEmpty else { return nil }
        var best = 0
        for i in values.indices where values[i] > values[best] && values[i].isFinite { best = i }
        return values[best].isFinite ? best : nil
    }

    public static func indexOfMinimum(_ values: [Double]) -> Int? {
        guard !values.isEmpty else { return nil }
        var best = 0
        for i in values.indices where values[i] < values[best] && values[i].isFinite { best = i }
        return values[best].isFinite ? best : nil
    }

    /// Local maxima ordered by prominence, most prominent first.
    public static func peaks(_ values: [Double], minimumProminence: Double = 0) -> [Int] {
        guard values.count > 2 else { return [] }
        var found: [(index: Int, prominence: Double)] = []
        for i in 1..<(values.count - 1) {
            guard values[i].isFinite, values[i] >= values[i - 1], values[i] > values[i + 1] else { continue }
            // Walk outwards to the nearest higher sample to estimate prominence.
            var left = values[i]
            var j = i
            while j > 0 && values[j] <= values[i] { left = min(left, values[j]); j -= 1 }
            var right = values[i]
            var k = i
            while k < values.count - 1 && values[k] <= values[i] { right = min(right, values[k]); k += 1 }
            let prominence = values[i] - max(left, right)
            if prominence >= minimumProminence { found.append((i, prominence)) }
        }
        return found.sorted { $0.prominence > $1.prominence }.map { $0.index }
    }

    /// Interpolated x where `values` crosses `level`, searching from `startIndex`.
    public static func crossing(_ values: [Double], x: [Double], level: Double,
                               from startIndex: Int, direction: Int) -> Double? {
        guard values.count == x.count, values.count > 1 else { return nil }
        var i = startIndex
        while i > 0 && i < values.count - 1 {
            let next = i + direction
            guard next >= 0, next < values.count else { return nil }
            let a = values[i], b = values[next]
            if (a - level) == 0 { return x[i] }
            if (a - level) * (b - level) < 0 {
                let t = (level - a) / (b - a)
                return x[i] + (x[next] - x[i]) * t
            }
            i = next
        }
        return nil
    }

    /// −n dB bandwidth around a resonance or passband.
    public struct BandwidthResult: Sendable {
        public var centerFrequency: Double
        public var lower: Double
        public var upper: Double
        public var bandwidth: Double
        public var q: Double
        public var peakValue: Double
        public var level: Double
    }

    /// Measure bandwidth around the extreme of `values`.
    /// For notches (dips) pass `searchMinimum: true`.
    public static func bandwidth(values: [Double], frequencies: [Double],
                                 dropDB: Double = 3, searchMinimum: Bool = false) -> BandwidthResult? {
        guard values.count == frequencies.count, values.count > 2 else { return nil }
        guard let peakIndex = searchMinimum ? indexOfMinimum(values) : indexOfMaximum(values) else { return nil }
        let peak = values[peakIndex]
        let level = searchMinimum ? peak + dropDB : peak - dropDB
        let lower = crossing(values, x: frequencies, level: level, from: peakIndex, direction: -1)
        let upper = crossing(values, x: frequencies, level: level, from: peakIndex, direction: +1)
        guard let lo = lower, let hi = upper, hi > lo else { return nil }
        let center = (lo + hi) / 2
        let bw = hi - lo
        return BandwidthResult(centerFrequency: center, lower: lo, upper: hi,
                               bandwidth: bw, q: bw > 0 ? center / bw : 0,
                               peakValue: peak, level: level)
    }

    /// Frequency where reactance crosses zero (series resonance), nearest the minimum |X|.
    public static func resonance(values: [Complex], frequencies: [Double], z0: Double) -> Double? {
        guard values.count == frequencies.count, values.count > 1 else { return nil }
        let reactance = values.map { RF.impedance($0, z0: z0).im }
        var bestIndex: Int? = nil
        var bestMagnitude = Double.infinity
        for i in 0..<(reactance.count - 1) {
            if reactance[i] == 0 { return frequencies[i] }
            if reactance[i] * reactance[i + 1] < 0 {
                let m = min(abs(reactance[i]), abs(reactance[i + 1]))
                if m < bestMagnitude { bestMagnitude = m; bestIndex = i }
            }
        }
        guard let i = bestIndex else { return nil }
        let a = reactance[i], b = reactance[i + 1]
        let t = a / (a - b)
        return frequencies[i] + (frequencies[i + 1] - frequencies[i]) * t
    }
}
