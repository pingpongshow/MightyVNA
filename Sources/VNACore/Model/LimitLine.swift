import Foundation

/// A pass/fail limit segment evaluated against one trace.
public struct LimitSegment: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case maximum, minimum
        public var id: String { rawValue }
        public var displayName: String { self == .maximum ? "Upper limit" : "Lower limit" }
    }

    public var id: UUID = UUID()
    public var kind: Kind = .maximum
    public var startFrequency: Double = 0
    public var stopFrequency: Double = 1e9
    public var startValue: Double = 0
    public var stopValue: Double = 0
    public var enabled: Bool = true

    public init() {}
    public init(kind: Kind, startFrequency: Double, stopFrequency: Double, startValue: Double, stopValue: Double) {
        self.kind = kind
        self.startFrequency = startFrequency
        self.stopFrequency = stopFrequency
        self.startValue = startValue
        self.stopValue = stopValue
    }

    public func value(at frequency: Double) -> Double? {
        guard enabled, frequency >= startFrequency, frequency <= stopFrequency else { return nil }
        guard stopFrequency > startFrequency else { return startValue }
        let t = (frequency - startFrequency) / (stopFrequency - startFrequency)
        return startValue + (stopValue - startValue) * t
    }
}

public struct LimitSet: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String = "Limits"
    public var enabled: Bool = false
    public var traceID: UUID?
    public var segments: [LimitSegment] = []

    public init() {}

    public struct Evaluation: Sendable {
        public var passed: Bool
        public var failingIndices: [Int]
        public var worstMargin: Double
    }

    public func evaluate(x: [Double], y: [Double]) -> Evaluation {
        guard enabled, !segments.isEmpty, x.count == y.count else {
            return Evaluation(passed: true, failingIndices: [], worstMargin: .infinity)
        }
        var failing: [Int] = []
        var worst = Double.infinity
        for i in x.indices {
            for segment in segments {
                guard let limit = segment.value(at: x[i]) else { continue }
                let margin = segment.kind == .maximum ? limit - y[i] : y[i] - limit
                worst = min(worst, margin)
                if margin < 0 { failing.append(i); break }
            }
        }
        return Evaluation(passed: failing.isEmpty, failingIndices: failing,
                          worstMargin: worst.isFinite ? worst : 0)
    }
}
