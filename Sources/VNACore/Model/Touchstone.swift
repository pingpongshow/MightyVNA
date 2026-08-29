import Foundation

/// Touchstone (.s1p / .s2p) reader and writer.
public enum Touchstone {

    public enum ParameterFormat: String, CaseIterable, Sendable, Identifiable {
        case realImaginary = "RI"
        case magnitudeAngle = "MA"
        case decibelAngle = "DB"
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .realImaginary: return "Real / Imaginary"
            case .magnitudeAngle: return "Magnitude / Angle"
            case .decibelAngle: return "dB / Angle"
            }
        }
    }

    public enum FrequencyUnit: String, CaseIterable, Sendable, Identifiable {
        case hz = "HZ", khz = "KHZ", mhz = "MHZ", ghz = "GHZ"
        public var id: String { rawValue }
        public var multiplier: Double {
            switch self {
            case .hz: return 1
            case .khz: return 1e3
            case .mhz: return 1e6
            case .ghz: return 1e9
            }
        }
        public var displayName: String {
            switch self {
            case .hz: return "Hz"
            case .khz: return "kHz"
            case .mhz: return "MHz"
            case .ghz: return "GHz"
            }
        }
    }

    public struct WriteOptions: Sendable {
        public var format: ParameterFormat = .realImaginary
        public var frequencyUnit: FrequencyUnit = .hz
        public var ports: Int = 1
        /// Fill S12 with the measured S21 (assumes a reciprocal DUT).
        public var assumeReciprocal: Bool = false
        public var comments: [String] = []
        public var digits: Int = 10
        public init() {}
    }

    public enum TouchstoneError: LocalizedError {
        case noOptionLine
        case malformed(String)
        case unsupportedPortCount(Int)

        public var errorDescription: String? {
            switch self {
            case .noOptionLine: return "The file has no Touchstone option line (a line starting with '#')."
            case .malformed(let detail): return "Malformed Touchstone data: \(detail)"
            case .unsupportedPortCount(let n): return "\(n)-port Touchstone files are not supported (1 and 2 ports only)."
            }
        }
    }

    // MARK: - Writing

    public static func string(from frame: SweepFrame, options: WriteOptions) -> String {
        var out = ""
        out += "! Created by MightyVNA\n"
        out += "! \(ISO8601DateFormatter().string(from: frame.timestamp))\n"
        if !frame.label.isEmpty { out += "! \(frame.label)\n" }
        for c in options.comments { out += "! \(c)\n" }
        out += "# \(options.frequencyUnit.rawValue) S \(options.format.rawValue) R \(Units.fixed(frame.z0, 1))\n"

        let mult = options.frequencyUnit.multiplier
        let fmt = "%.\(options.digits)g"

        if options.ports == 1 {
            out += "! freq S11\n"
            for i in 0..<frame.count {
                let pair = encode(frame.s11[i], format: options.format)
                out += String(format: "\(fmt) \(fmt) \(fmt)\n", frame.frequencies[i] / mult, pair.0, pair.1)
            }
        } else {
            out += "! freq S11 S21 S12 S22\n"
            let measuredReverse = frame.isFullTwoPort
            for i in 0..<frame.count {
                let s11 = encode(frame.s11[i], format: options.format)
                let s21 = encode(frame.s21[i], format: options.format)
                let reverse = measuredReverse ? frame.s12[i] : (options.assumeReciprocal ? frame.s21[i] : .zero)
                let port2 = measuredReverse ? frame.s22[i] : .zero
                let s12 = encode(reverse, format: options.format)
                let s22 = encode(port2, format: options.format)
                out += String(format: "\(fmt) \(fmt) \(fmt) \(fmt) \(fmt) \(fmt) \(fmt) \(fmt) \(fmt)\n",
                              frame.frequencies[i] / mult,
                              s11.0, s11.1, s21.0, s21.1, s12.0, s12.1, s22.0, s22.1)
            }
        }
        return out
    }

    private static func encode(_ v: Complex, format: ParameterFormat) -> (Double, Double) {
        switch format {
        case .realImaginary: return (v.re, v.im)
        case .magnitudeAngle: return (v.magnitude, v.phase * 180 / .pi)
        case .decibelAngle: return (RF.dB(v.magnitude), v.phase * 180 / .pi)
        }
    }

    // MARK: - Reading

    public static func parse(_ text: String, label: String = "") throws -> SweepFrame {
        var frequencyUnit = FrequencyUnit.ghz
        var format = ParameterFormat.magnitudeAngle
        var z0 = 50.0
        var sawOption = false

        var frequencies: [Double] = []
        var rows: [[Double]] = []
        var pending: [Double] = []
        var valuesPerRow = 0

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = String(rawLine)
            if let bang = line.firstIndex(of: "!") { line = String(line[line.startIndex..<bang]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                sawOption = true
                let tokens = line.dropFirst().uppercased()
                    .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                var i = 0
                while i < tokens.count {
                    let t = tokens[i]
                    if let u = FrequencyUnit(rawValue: t) { frequencyUnit = u }
                    else if let f = ParameterFormat(rawValue: t) { format = f }
                    else if t == "R", i + 1 < tokens.count, let r = Double(tokens[i + 1]) { z0 = r; i += 1 }
                    i += 1
                }
                continue
            }
            if line.hasPrefix("[") { continue }   // Touchstone 2.0 keywords, ignored

            let numbers = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
                .compactMap { Double($0) }
            guard !numbers.isEmpty else { continue }
            pending.append(contentsOf: numbers)

            // A row is complete once we know how wide rows are. The first data line
            // establishes the width (1 + 2·N² for N ports, allowing continuation lines).
            if valuesPerRow == 0 {
                if pending.count == 3 { valuesPerRow = 3 }            // 1-port
                else if pending.count == 9 { valuesPerRow = 9 }       // 2-port on one line
                else if pending.count > 9 { valuesPerRow = 9 }
                else { continue }
            }
            while pending.count >= valuesPerRow {
                let row = Array(pending.prefix(valuesPerRow))
                pending.removeFirst(valuesPerRow)
                frequencies.append(row[0] * frequencyUnit.multiplier)
                rows.append(Array(row.dropFirst()))
            }
        }

        guard sawOption else { throw TouchstoneError.noOptionLine }
        guard !frequencies.isEmpty else { throw TouchstoneError.malformed("no data rows") }

        var s11 = [Complex](repeating: .zero, count: frequencies.count)
        var s21 = [Complex](repeating: .zero, count: frequencies.count)
        var s12 = [Complex](repeating: .zero, count: frequencies.count)
        var s22 = [Complex](repeating: .zero, count: frequencies.count)
        var twoPort = false
        for (i, row) in rows.enumerated() {
            s11[i] = decode(row[0], row[1], format: format)
            if row.count >= 4 { s21[i] = decode(row[2], row[3], format: format) }
            if row.count >= 8 {
                s12[i] = decode(row[4], row[5], format: format)
                s22[i] = decode(row[6], row[7], format: format)
                twoPort = true
            }
        }
        return SweepFrame(frequencies: frequencies, s11: s11, s21: s21,
                          s12: twoPort ? s12 : [], s22: twoPort ? s22 : [],
                          z0: z0, label: label)
    }

    private static func decode(_ a: Double, _ b: Double, format: ParameterFormat) -> Complex {
        switch format {
        case .realImaginary: return Complex(a, b)
        case .magnitudeAngle: return Complex(magnitude: a, angle: b * .pi / 180)
        case .decibelAngle: return Complex(magnitude: RF.linear(fromDB: a), angle: b * .pi / 180)
        }
    }

    // MARK: - CSV

    public static func csv(from frame: SweepFrame, includeDerived: Bool = true) -> String {
        let twoPort = frame.isFullTwoPort
        var out = "Frequency(Hz),S11 Re,S11 Im,S21 Re,S21 Im"
        if twoPort { out += ",S12 Re,S12 Im,S22 Re,S22 Im" }
        if includeDerived {
            out += ",S11 dB,S11 Phase(deg),SWR,R(ohm),X(ohm),S21 dB,S21 Phase(deg)"
            if twoPort { out += ",S12 dB,S22 dB,SWR2" }
        }
        out += "\n"
        for i in 0..<frame.count {
            let a = frame.s11[i], b = frame.s21[i]
            out += "\(frame.frequencies[i]),\(a.re),\(a.im),\(b.re),\(b.im)"
            if twoPort {
                let c = frame.s12[i], d = frame.s22[i]
                out += ",\(c.re),\(c.im),\(d.re),\(d.im)"
            }
            if includeDerived {
                let z = RF.impedance(a, z0: frame.z0)
                out += ",\(RF.dB(a.magnitude)),\(a.phase * 180 / .pi),\(RF.swr(a)),\(z.re),\(z.im)"
                out += ",\(RF.dB(b.magnitude)),\(b.phase * 180 / .pi)"
                if twoPort {
                    out += ",\(RF.dB(frame.s12[i].magnitude)),\(RF.dB(frame.s22[i].magnitude)),\(RF.swr(frame.s22[i]))"
                }
            }
            out += "\n"
        }
        return out
    }
}
