import Foundation

/// Window functions used by the time-domain transform.
public enum WindowFunction: String, CaseIterable, Codable, Sendable, Identifiable {
    case rectangular
    case hann
    case hamming
    case blackman
    case blackmanHarris
    case kaiser

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rectangular: return "Rectangular (minimum)"
        case .hann: return "Hann (normal)"
        case .hamming: return "Hamming"
        case .blackman: return "Blackman"
        case .blackmanHarris: return "Blackman-Harris (maximum)"
        case .kaiser: return "Kaiser"
        }
    }

    /// Half-window coefficients for a one-sided spectrum of `count` points:
    /// index 0 sits at the centre of the equivalent symmetric window.
    public func halfWindow(count: Int, kaiserBeta: Double = 6) -> [Double] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [1] }
        return (0..<count).map { i in
            // Map [0, count-1] onto the right half of a symmetric window.
            let x = Double(i) / Double(count - 1)      // 0 at centre, 1 at edge
            return value(at: x, kaiserBeta: kaiserBeta)
        }
    }

    /// `x` is the normalised distance from the window centre in [0, 1].
    public func value(at x: Double, kaiserBeta: Double = 6) -> Double {
        let clamped = min(max(x, 0), 1)
        // Convert to the usual 0...1 index of a symmetric window of unit length.
        let t = 0.5 * (1 + clamped)
        switch self {
        case .rectangular:
            return 1
        case .hann:
            return 0.5 - 0.5 * cos(2 * .pi * (1 - t))
        case .hamming:
            return 0.54 - 0.46 * cos(2 * .pi * (1 - t))
        case .blackman:
            let a = 2 * Double.pi * (1 - t)
            return 0.42 - 0.5 * cos(a) + 0.08 * cos(2 * a)
        case .blackmanHarris:
            let a = 2 * Double.pi * (1 - t)
            return 0.35875 - 0.48829 * cos(a) + 0.14128 * cos(2 * a) - 0.01168 * cos(3 * a)
        case .kaiser:
            let arg = 1 - clamped * clamped
            return besselI0(kaiserBeta * max(0, arg).squareRoot()) / besselI0(kaiserBeta)
        }
    }

    /// Modified Bessel function of the first kind, order zero (series expansion).
    private func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let halfX = x / 2
        for k in 1...30 {
            term *= (halfX / Double(k)) * (halfX / Double(k))
            sum += term
            if term < sum * 1e-16 { break }
        }
        return sum
    }
}
