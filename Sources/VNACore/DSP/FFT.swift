import Foundation

/// Small self-contained radix-2 FFT. Sizes are always rounded up to a power of two
/// by the callers, so no mixed-radix path is needed.
public enum FFT {

    public static func nextPowerOfTwo(_ n: Int) -> Int {
        guard n > 1 else { return 1 }
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    /// In-place iterative Cooley-Tukey. `inverse` includes the 1/N scaling.
    public static func transform(_ buffer: inout [Complex], inverse: Bool) {
        let n = buffer.count
        guard n > 1 else { return }
        precondition(n & (n - 1) == 0, "FFT length must be a power of two")

        // Bit-reversal permutation.
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j { buffer.swapAt(i, j) }
        }

        var length = 2
        while length <= n {
            let angle = (inverse ? 2.0 : -2.0) * Double.pi / Double(length)
            let wl = Complex(cos(angle), sin(angle))
            var i = 0
            while i < n {
                var w = Complex.one
                for k in 0..<(length / 2) {
                    let u = buffer[i + k]
                    let v = buffer[i + k + length / 2] * w
                    buffer[i + k] = u + v
                    buffer[i + k + length / 2] = u - v
                    w = w * wl
                }
                i += length
            }
            length <<= 1
        }

        if inverse {
            let scale = 1.0 / Double(n)
            for i in 0..<n { buffer[i] = buffer[i] * scale }
        }
    }

    public static func forward(_ input: [Complex]) -> [Complex] {
        var b = input
        transform(&b, inverse: false)
        return b
    }

    public static func inverse(_ input: [Complex]) -> [Complex] {
        var b = input
        transform(&b, inverse: true)
        return b
    }
}
