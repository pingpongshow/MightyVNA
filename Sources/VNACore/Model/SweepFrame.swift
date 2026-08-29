import Foundation

/// One complete sweep: the frequency grid plus the two measured S-parameters.
public struct SweepFrame: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var frequencies: [Double]
    public var s11: [Complex]
    public var s21: [Complex]
    /// Reverse transmission. Empty on one-port-plus-response instruments (every NanoVNA).
    public var s12: [Complex]
    /// Port 2 reflection. Empty on one-port-plus-response instruments.
    public var s22: [Complex]
    public var timestamp: Date
    /// System reference impedance the data is normalised to.
    public var z0: Double
    /// Free-form label used when a frame is stored as a memory trace or a saved file.
    public var label: String

    public init(id: UUID = UUID(),
                frequencies: [Double],
                s11: [Complex],
                s21: [Complex],
                s12: [Complex] = [],
                s22: [Complex] = [],
                timestamp: Date = Date(),
                z0: Double = 50,
                label: String = "") {
        self.id = id
        self.frequencies = frequencies
        self.s11 = s11
        self.s21 = s21
        self.s12 = s12
        self.s22 = s22
        self.timestamp = timestamp
        self.z0 = z0
        self.label = label
    }

    // Sessions saved before reverse-direction support omit s12/s22.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        frequencies = try c.decode([Double].self, forKey: .frequencies)
        s11 = try c.decode([Complex].self, forKey: .s11)
        s21 = try c.decode([Complex].self, forKey: .s21)
        s12 = try c.decodeIfPresent([Complex].self, forKey: .s12) ?? []
        s22 = try c.decodeIfPresent([Complex].self, forKey: .s22) ?? []
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        z0 = try c.decode(Double.self, forKey: .z0)
        label = try c.decode(String.self, forKey: .label)
    }

    public static let empty = SweepFrame(frequencies: [], s11: [], s21: [])

    public var count: Int { frequencies.count }
    public var isEmpty: Bool { frequencies.isEmpty }
    public var startFrequency: Double { frequencies.first ?? 0 }
    public var stopFrequency: Double { frequencies.last ?? 0 }
    public var span: Double { stopFrequency - startFrequency }
    public var centerFrequency: Double { (startFrequency + stopFrequency) / 2 }

    /// True when the instrument measured the reverse direction as well.
    public var isFullTwoPort: Bool { s12.count == count && s22.count == count && count > 0 }

    /// Parameters that actually carry data for this frame.
    public var availableChannels: [Channel] {
        isFullTwoPort ? Channel.fullTwoPort : Channel.nanoVNASubset
    }

    public func values(for channel: Channel) -> [Complex] {
        switch channel {
        case .s11: return s11
        case .s21: return s21
        case .s12: return s12.isEmpty ? s21 : s12       // fall back so reciprocal DUTs still plot
        case .s22: return s22.isEmpty ? s11 : s22
        }
    }

    /// Whether this channel holds real measured data rather than a stand-in.
    public func hasMeasured(_ channel: Channel) -> Bool {
        switch channel {
        case .s11: return !s11.isEmpty
        case .s21: return !s21.isEmpty
        case .s12: return s12.count == count && count > 0
        case .s22: return s22.count == count && count > 0
        }
    }

    public mutating func setValues(_ values: [Complex], for channel: Channel) {
        switch channel {
        case .s11: s11 = values
        case .s21: s21 = values
        case .s12: s12 = values
        case .s22: s22 = values
        }
    }

    /// True when the grid is uniformly spaced (needed for exact TDR maths).
    public var isUniformGrid: Bool {
        guard frequencies.count > 2 else { return true }
        let step = (stopFrequency - startFrequency) / Double(frequencies.count - 1)
        guard step > 0 else { return false }
        for i in frequencies.indices {
            let expected = startFrequency + step * Double(i)
            if abs(frequencies[i] - expected) > max(1, step * 0.01) { return false }
        }
        return true
    }

    /// Index of the sample nearest a frequency.
    public func nearestIndex(to frequency: Double) -> Int {
        guard !frequencies.isEmpty else { return 0 }
        var best = 0
        var bestDelta = Double.infinity
        for (i, f) in frequencies.enumerated() {
            let d = abs(f - frequency)
            if d < bestDelta { bestDelta = d; best = i }
        }
        return best
    }

    /// Sanity check that two frames share a grid so they can be combined.
    public func hasSameGrid(as other: SweepFrame) -> Bool {
        guard count == other.count, count > 0 else { return false }
        return abs(startFrequency - other.startFrequency) < 1
            && abs(stopFrequency - other.stopFrequency) < 1
    }

    /// Resample onto another frame's grid (used by memory traces and stored calibrations).
    public func resampled(to grid: [Double]) -> SweepFrame {
        SweepFrame(id: id,
                   frequencies: grid,
                   s11: RF.interpolate(values: s11, from: frequencies, to: grid),
                   s21: RF.interpolate(values: s21, from: frequencies, to: grid),
                   s12: s12.isEmpty ? [] : RF.interpolate(values: s12, from: frequencies, to: grid),
                   s22: s22.isEmpty ? [] : RF.interpolate(values: s22, from: frequencies, to: grid),
                   timestamp: timestamp,
                   z0: z0,
                   label: label)
    }
}

/// Running average / peak hold accumulator applied to consecutive sweeps.
public struct SweepAccumulator {
    public enum Mode: String, CaseIterable, Codable, Sendable, Identifiable {
        case off, average, exponential, minHold, maxHold
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .off: return "Off"
            case .average: return "Average (N)"
            case .exponential: return "Exponential"
            case .minHold: return "Min Hold"
            case .maxHold: return "Max Hold"
            }
        }
    }

    public var mode: Mode = .off
    public var depth: Int = 8
    /// Running sum and running state, per measured channel.
    private var sums: [Channel: [Complex]] = [:]
    private var state: [Channel: [Complex]] = [:]
    private var grid: [Double] = []
    public private(set) var samples: Int = 0

    public init() {}

    public mutating func reset() {
        sums.removeAll()
        state.removeAll()
        grid = []
        samples = 0
    }

    /// Combine a new frame into the accumulator and return what should be displayed.
    public mutating func process(_ frame: SweepFrame) -> SweepFrame {
        guard mode != .off else { samples = 1; return frame }

        let channels = Channel.allCases.filter { frame.hasMeasured($0) }
        if grid != frame.frequencies || Set(state.keys) != Set(channels) {
            grid = frame.frequencies
            sums = [:]
            state = [:]
            for channel in channels {
                let values = frame.values(for: channel)
                sums[channel] = values
                state[channel] = values
            }
            samples = 1
            return frame
        }

        samples += 1
        var out = frame
        for channel in channels {
            let incoming = frame.values(for: channel)
            guard var accumulated = state[channel], accumulated.count == incoming.count else { continue }

            switch mode {
            case .off:
                continue
            case .average:
                if samples <= depth, var running = sums[channel], running.count == incoming.count {
                    for i in incoming.indices { running[i] += incoming[i] }
                    sums[channel] = running
                    accumulated = running.map { $0 / Double(samples) }
                } else {
                    let w = 1.0 / Double(max(1, depth))
                    for i in incoming.indices {
                        accumulated[i] = accumulated[i] * (1 - w) + incoming[i] * w
                    }
                }
            case .exponential:
                let w = 1.0 / Double(max(1, depth))
                for i in incoming.indices {
                    accumulated[i] = accumulated[i] * (1 - w) + incoming[i] * w
                }
            case .minHold:
                for i in incoming.indices where incoming[i].magnitude < accumulated[i].magnitude {
                    accumulated[i] = incoming[i]
                }
            case .maxHold:
                for i in incoming.indices where incoming[i].magnitude > accumulated[i].magnitude {
                    accumulated[i] = incoming[i]
                }
            }
            state[channel] = accumulated
            out.setValues(accumulated, for: channel)
        }
        return out
    }
}
