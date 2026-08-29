import Foundation

/// Minimal double-precision complex number used throughout the RF math.
public struct Complex: Hashable, Sendable, Codable {
    public var re: Double
    public var im: Double

    @inlinable public init(_ re: Double = 0, _ im: Double = 0) {
        self.re = re
        self.im = im
    }

    public static let zero = Complex(0, 0)
    public static let one = Complex(1, 0)
    public static let i = Complex(0, 1)

    @inlinable public init(magnitude: Double, angle: Double) {
        self.re = magnitude * cos(angle)
        self.im = magnitude * sin(angle)
    }

    /// e^(j·theta)
    @inlinable public static func expj(_ theta: Double) -> Complex {
        Complex(cos(theta), sin(theta))
    }

    @inlinable public var magnitude: Double { (re * re + im * im).squareRoot() }
    @inlinable public var magnitudeSquared: Double { re * re + im * im }
    /// Phase in radians, (-pi, pi].
    @inlinable public var phase: Double { atan2(im, re) }
    @inlinable public var conjugate: Complex { Complex(re, -im) }
    @inlinable public var isFinite: Bool { re.isFinite && im.isFinite }

    @inlinable public var reciprocal: Complex {
        let d = magnitudeSquared
        guard d != 0 else { return Complex(.infinity, .infinity) }
        return Complex(re / d, -im / d)
    }

    @inlinable public static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    @inlinable public static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    @inlinable public static prefix func - (a: Complex) -> Complex { Complex(-a.re, -a.im) }

    @inlinable public static func * (a: Complex, b: Complex) -> Complex {
        Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
    }

    @inlinable public static func / (a: Complex, b: Complex) -> Complex {
        let d = b.magnitudeSquared
        guard d != 0 else { return Complex(.infinity, .infinity) }
        return Complex((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }

    @inlinable public static func * (a: Complex, s: Double) -> Complex { Complex(a.re * s, a.im * s) }
    @inlinable public static func * (s: Double, a: Complex) -> Complex { Complex(a.re * s, a.im * s) }
    @inlinable public static func / (a: Complex, s: Double) -> Complex { Complex(a.re / s, a.im / s) }
    @inlinable public static func + (a: Complex, s: Double) -> Complex { Complex(a.re + s, a.im) }
    @inlinable public static func - (a: Complex, s: Double) -> Complex { Complex(a.re - s, a.im) }
    @inlinable public static func - (s: Double, a: Complex) -> Complex { Complex(s - a.re, -a.im) }

    @inlinable public static func += (a: inout Complex, b: Complex) { a = a + b }
    @inlinable public static func -= (a: inout Complex, b: Complex) { a = a - b }
    @inlinable public static func *= (a: inout Complex, b: Complex) { a = a * b }
    @inlinable public static func /= (a: inout Complex, b: Complex) { a = a / b }

    @inlinable public var squareRoot: Complex {
        let m = magnitude.squareRoot()
        let a = phase / 2
        return Complex(m * cos(a), m * sin(a))
    }

    /// Natural logarithm (principal branch).
    @inlinable public var logarithm: Complex { Complex(log(magnitude), phase) }

    @inlinable public func lerp(to other: Complex, _ t: Double) -> Complex {
        Complex(re + (other.re - re) * t, im + (other.im - im) * t)
    }
}

extension Complex: CustomStringConvertible {
    public var description: String {
        String(format: "%.6g%@%.6gj", re, im < 0 ? "-" : "+", abs(im))
    }
}

/// Solve a 3x3 complex linear system by Gauss-Jordan elimination with partial pivoting.
/// Returns nil when the matrix is singular.
public func solve3x3(_ a: [[Complex]], _ b: [Complex]) -> [Complex]? {
    var m = a
    var v = b
    for col in 0..<3 {
        // Partial pivot on largest magnitude.
        var pivot = col
        for row in (col + 1)..<3 where m[row][col].magnitude > m[pivot][col].magnitude {
            pivot = row
        }
        guard m[pivot][col].magnitude > 1e-18 else { return nil }
        if pivot != col {
            m.swapAt(pivot, col)
            v.swapAt(pivot, col)
        }
        let d = m[col][col]
        for c in col..<3 { m[col][c] = m[col][c] / d }
        v[col] = v[col] / d
        for row in 0..<3 where row != col {
            let f = m[row][col]
            guard f.magnitudeSquared > 0 else { continue }
            for c in col..<3 { m[row][c] = m[row][c] - f * m[col][c] }
            v[row] = v[row] - f * v[col]
        }
    }
    return v
}
