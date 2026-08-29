import Foundation

public enum TDRMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case lowpassStep
    case lowpassImpulse
    case bandpassImpulse
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .lowpassStep: return "Lowpass Step"
        case .lowpassImpulse: return "Lowpass Impulse"
        case .bandpassImpulse: return "Bandpass Impulse"
        }
    }
    public var isLowpass: Bool { self != .bandpassImpulse }
}

public struct TimeDomainSettings: Codable, Sendable, Equatable {
    public var mode: TDRMode = .lowpassStep
    public var window: WindowFunction = .hann
    public var kaiserBeta: Double = 6
    /// Cable velocity factor (fraction of c).
    public var velocityFactor: Double = 0.66
    /// Extra zero padding, improving time-axis interpolation. 1 = none.
    public var padFactor: Int = 4
    /// Extrapolate the missing DC point for lowpass modes.
    public var extrapolateDC: Bool = true
    public var z0: Double = 50

    public init() {}
}

public struct TimeDomainResult: Sendable {
    public var time: [Double] = []        // seconds, one-way round trip time axis
    public var distance: [Double] = []    // metres, one-way (already halved)
    public var impulse: [Double] = []     // real impulse (lowpass) or envelope magnitude (bandpass)
    public var step: [Double] = []        // step response in reflection coefficient
    public var impedance: [Double] = []   // ohms, from the step response
    public var complexResponse: [Complex] = []
    /// Approximate spatial resolution given the sweep bandwidth.
    public var resolution: Double = 0
    /// Unambiguous range before aliasing.
    public var maxDistance: Double = 0
    public var isEmpty: Bool { time.isEmpty }

    public static let empty = TimeDomainResult()
}

public enum TimeDomain {

    /// Transform one channel of a sweep into the time domain.
    public static func transform(frequencies: [Double],
                                 values: [Complex],
                                 settings: TimeDomainSettings) -> TimeDomainResult {
        let n = min(frequencies.count, values.count)
        guard n >= 4 else { return .empty }

        let fStart = frequencies[0]
        let fStop = frequencies[n - 1]
        let df = (fStop - fStart) / Double(n - 1)
        guard df > 0 else { return .empty }

        let pad = max(1, settings.padFactor)
        var result = TimeDomainResult()

        if settings.mode.isLowpass {
            // Build a harmonically related grid 0, df, 2df ... so the spectrum can be
            // made conjugate-symmetric and the impulse response comes out real.
            let k0 = max(0, Int((fStart / df).rounded()))
            let harmonicCount = k0 + n                     // indices 0 ... k0+n-1
            var oneSided = [Complex](repeating: .zero, count: harmonicCount)
            for i in 0..<n { oneSided[k0 + i] = values[i] }

            if k0 > 0 {
                let dc = settings.extrapolateDC ? extrapolatedDC(values: values) : Complex.zero
                oneSided[0] = dc
                // Fill the unmeasured low band by interpolating between DC and the first sample.
                if k0 > 1 {
                    for k in 1..<k0 {
                        let t = Double(k) / Double(k0)
                        oneSided[k] = dc.lerp(to: values[0], t)
                    }
                }
            } else {
                oneSided[0] = Complex(oneSided[0].re, 0)   // DC must be real
            }

            // Window, measured from DC outwards.
            let win = windowCoefficients(count: harmonicCount, settings: settings)
            for k in 0..<harmonicCount { oneSided[k] = oneSided[k] * win[k] }

            let size = FFT.nextPowerOfTwo(harmonicCount * 2 * pad)
            var spectrum = [Complex](repeating: .zero, count: size)
            spectrum[0] = Complex(oneSided[0].re, 0)
            for k in 1..<harmonicCount where k < size / 2 {
                spectrum[k] = oneSided[k]
                spectrum[size - k] = oneSided[k].conjugate
            }

            let td = FFT.inverse(spectrum)
            let usable = size / 2
            let dt = 1.0 / (Double(size) * df)

            var impulse = [Double](repeating: 0, count: usable)
            for i in 0..<usable { impulse[i] = td[i].re }

            var step = [Double](repeating: 0, count: usable)
            var running = 0.0
            for i in 0..<usable {
                running += impulse[i]
                step[i] = running
            }

            result.complexResponse = Array(td[0..<usable])
            result.impulse = impulse
            result.step = step
            result.impedance = step.map { impedanceFromRho($0, z0: settings.z0) }
            result.time = (0..<usable).map { Double($0) * dt }
        } else {
            // Bandpass: no DC assumption, the result is a complex envelope.
            let win = windowCoefficients(count: n, centred: true, settings: settings)
            let size = FFT.nextPowerOfTwo(n * 2 * pad)
            var spectrum = [Complex](repeating: .zero, count: size)
            for i in 0..<n { spectrum[i] = values[i] * win[i] }

            let td = FFT.inverse(spectrum)
            let usable = size / 2
            let dt = 1.0 / (Double(size) * df)
            // Bandpass responses are scaled so a full reflection reads 1.0.
            let gain = Double(size) / Double(max(1, n))
            result.complexResponse = Array(td[0..<usable]).map { $0 * gain }
            result.impulse = result.complexResponse.map { $0.magnitude }
            var running = 0.0
            result.step = result.impulse.map { v in running += v; return running }
            result.impedance = result.step.map { impedanceFromRho($0, z0: settings.z0) }
            result.time = (0..<usable).map { Double($0) * dt }
        }

        let v = speedOfLight * settings.velocityFactor
        result.distance = result.time.map { $0 * v / 2 }
        let bandwidth = settings.mode.isLowpass ? fStop : (fStop - fStart)
        result.resolution = bandwidth > 0 ? v / (2 * bandwidth) : 0
        result.maxDistance = result.distance.last ?? 0
        return result
    }

    /// Convenience wrapper for a whole frame.
    public static func transform(frame: SweepFrame,
                                 channel: Channel,
                                 settings: TimeDomainSettings) -> TimeDomainResult {
        var s = settings
        s.z0 = frame.z0
        return transform(frequencies: frame.frequencies, values: frame.values(for: channel), settings: s)
    }

    // MARK: - Helpers

    private static func windowCoefficients(count: Int, centred: Bool = false,
                                           settings: TimeDomainSettings) -> [Double] {
        guard count > 1 else { return [1] }
        if centred {
            // Symmetric window across the measured band.
            return (0..<count).map { i in
                let x = abs(Double(i) - Double(count - 1) / 2) / (Double(count - 1) / 2)
                return settings.window.value(at: x, kaiserBeta: settings.kaiserBeta)
            }
        }
        // Half window: full weight at DC, tapering to the highest harmonic.
        return (0..<count).map { i in
            let x = Double(i) / Double(count - 1)
            return settings.window.value(at: x, kaiserBeta: settings.kaiserBeta)
        }
    }

    /// Linear extrapolation of the first samples back to 0 Hz, forced real.
    private static func extrapolatedDC(values: [Complex]) -> Complex {
        guard values.count >= 2 else { return Complex(values.first?.re ?? 0, 0) }
        let take = min(5, values.count)
        // Least-squares slope of the real part over the first few points.
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        for i in 0..<take {
            let x = Double(i), y = values[i].re
            sumX += x; sumY += y; sumXY += x * y; sumXX += x * x
        }
        let nD = Double(take)
        let denom = nD * sumXX - sumX * sumX
        guard abs(denom) > 1e-12 else { return Complex(values[0].re, 0) }
        let slope = (nD * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / nD
        // Step back one sample interval below the first measured point.
        let dc = intercept - slope
        return Complex(min(max(dc, -1), 1), 0)
    }

    private static func impedanceFromRho(_ rho: Double, z0: Double) -> Double {
        let r = min(max(rho, -0.9999), 0.9999)
        return z0 * (1 + r) / (1 - r)
    }
}
