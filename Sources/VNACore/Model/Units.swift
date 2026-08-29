import Foundation

/// Engineering-notation helpers used by the axes, marker readouts and exports.
public enum Units {

    private static let prefixes: [(exp: Int, symbol: String)] = [
        (-15, "f"), (-12, "p"), (-9, "n"), (-6, "µ"), (-3, "m"),
        (0, ""), (3, "k"), (6, "M"), (9, "G"), (12, "T")
    ]

    /// Format a value in engineering notation with a unit suffix, e.g. `1.234 GHz`.
    public static func engineering(_ value: Double, unit: String, digits: Int = 4) -> String {
        guard value.isFinite else { return "—" }
        if value == 0 { return "0 " + unit }
        let magnitude = abs(value)
        var chosen = prefixes[5]
        for p in prefixes where magnitude >= pow(10, Double(p.exp)) {
            chosen = p
        }
        let scaled = value / pow(10, Double(chosen.exp))
        let integerDigits = max(1, Int(floor(log10(abs(scaled)))) + 1)
        let decimals = max(0, digits - integerDigits)
        return String(format: "%.\(decimals)f %@%@", scaled, chosen.symbol, unit)
    }

    public static func frequency(_ hz: Double, digits: Int = 7) -> String {
        engineering(hz, unit: "Hz", digits: digits)
    }

    /// Short frequency label for axis ticks.
    public static func frequencyShort(_ hz: Double) -> String {
        engineering(hz, unit: "Hz", digits: 5)
    }

    public static func time(_ seconds: Double) -> String { engineering(seconds, unit: "s", digits: 4) }
    public static func distance(_ metres: Double) -> String { engineering(metres, unit: "m", digits: 4) }
    public static func capacitance(_ farads: Double) -> String {
        farads.isFinite ? engineering(farads, unit: "F", digits: 4) : "—"
    }
    public static func inductance(_ henries: Double) -> String {
        henries.isFinite ? engineering(henries, unit: "H", digits: 4) : "—"
    }
    public static func ohms(_ value: Double) -> String { engineering(value, unit: "Ω", digits: 4) }

    /// Parse a user-entered frequency such as `144M`, `2.4 GHz`, `50k`, `1_000_000`.
    public static func parseFrequency(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s = s.replacingOccurrences(of: "_", with: "")
        s = s.replacingOccurrences(of: ",", with: "")
        s = s.replacingOccurrences(of: "hz", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var multiplier = 1.0
        if let last = s.last, let m = multiplierFor(last) {
            multiplier = m
            s.removeLast()
        }
        guard let value = Double(s.trimmingCharacters(in: .whitespaces)) else { return nil }
        return value * multiplier
    }

    private static func multiplierFor(_ c: Character) -> Double? {
        switch c {
        case "k": return 1e3
        case "m": return 1e6
        case "g": return 1e9
        case "t": return 1e12
        default: return nil
        }
    }

    /// Format with a fixed number of decimals, guarding against non-finite values.
    public static func fixed(_ value: Double, _ decimals: Int = 3) -> String {
        value.isFinite ? String(format: "%.\(decimals)f", value) : "—"
    }
}
