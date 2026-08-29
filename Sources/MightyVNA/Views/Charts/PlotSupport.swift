import SwiftUI
import VNACore

/// Maps data coordinates to points inside a plot rectangle.
struct PlotGeometry {
    var rect: CGRect
    var xMin: Double
    var xMax: Double
    var logarithmic: Bool
    var divisions: Int = 10

    func x(_ value: Double) -> CGFloat {
        guard xMax > xMin else { return rect.minX }
        if logarithmic {
            let lo = log10(max(xMin, 1e-9))
            let hi = log10(max(xMax, 1e-9))
            guard hi > lo else { return rect.minX }
            let t = (log10(max(value, 1e-9)) - lo) / (hi - lo)
            return rect.minX + CGFloat(t) * rect.width
        }
        let t = (value - xMin) / (xMax - xMin)
        return rect.minX + CGFloat(t) * rect.width
    }

    func value(atX position: CGFloat) -> Double {
        guard rect.width > 0 else { return xMin }
        let t = Double((position - rect.minX) / rect.width)
        if logarithmic {
            let lo = log10(max(xMin, 1e-9))
            let hi = log10(max(xMax, 1e-9))
            return pow(10, lo + t * (hi - lo))
        }
        return xMin + t * (xMax - xMin)
    }

    /// y for a value inside a trace's own 10-division scale.
    func y(_ value: Double, range: ClosedRange<Double>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return rect.midY }
        let t = (value - range.lowerBound) / span
        return rect.maxY - CGFloat(t) * rect.height
    }

    func value(atY position: CGFloat, range: ClosedRange<Double>) -> Double {
        guard rect.height > 0 else { return range.lowerBound }
        let t = Double((rect.maxY - position) / rect.height)
        return range.lowerBound + t * (range.upperBound - range.lowerBound)
    }

    /// Evenly spaced x positions for the grid.
    func gridXPositions() -> [CGFloat] {
        guard divisions > 0 else { return [] }
        if logarithmic {
            return logTicks().map { x($0) }
        }
        return (0...divisions).map { rect.minX + rect.width * CGFloat($0) / CGFloat(divisions) }
    }

    func gridXValues() -> [Double] {
        if logarithmic { return logTicks() }
        guard divisions > 0 else { return [] }
        return (0...divisions).map { xMin + (xMax - xMin) * Double($0) / Double(divisions) }
    }

    private func logTicks() -> [Double] {
        guard xMin > 0, xMax > xMin else { return [] }
        var ticks: [Double] = []
        var decade = pow(10, floor(log10(xMin)))
        while decade <= xMax * 10 {
            for m in [1.0, 2, 3, 4, 5, 6, 7, 8, 9] {
                let v = decade * m
                if v >= xMin && v <= xMax { ticks.append(v) }
            }
            decade *= 10
        }
        if ticks.first != xMin { ticks.insert(xMin, at: 0) }
        if ticks.last != xMax { ticks.append(xMax) }
        return ticks
    }

    func gridYPositions() -> [CGFloat] {
        (0...divisions).map { rect.minY + rect.height * CGFloat($0) / CGFloat(divisions) }
    }
}

enum PlotDraw {

    /// Rounded plot frame with the instrument grid.
    static func grid(_ context: inout GraphicsContext, geometry: PlotGeometry,
                     showMinor: Bool, logarithmic: Bool) {
        let rect = geometry.rect
        var majorPath = Path()
        var minorPath = Path()

        for y in geometry.gridYPositions() {
            majorPath.move(to: CGPoint(x: rect.minX, y: y))
            majorPath.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        if logarithmic {
            let values = geometry.gridXValues()
            for v in values {
                let px = geometry.x(v)
                let mantissa = v / pow(10, floor(log10(max(v, 1e-9))))
                var path = abs(mantissa - 1) < 0.001 ? majorPath : minorPath
                path.move(to: CGPoint(x: px, y: rect.minY))
                path.addLine(to: CGPoint(x: px, y: rect.maxY))
                if abs(mantissa - 1) < 0.001 { majorPath = path } else { minorPath = path }
            }
        } else {
            for x in geometry.gridXPositions() {
                majorPath.move(to: CGPoint(x: x, y: rect.minY))
                majorPath.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            if showMinor {
                let step = rect.width / CGFloat(geometry.divisions) / 2
                var x = rect.minX + step
                while x < rect.maxX {
                    minorPath.move(to: CGPoint(x: x, y: rect.minY))
                    minorPath.addLine(to: CGPoint(x: x, y: rect.maxY))
                    x += step * 2
                }
                let ystep = rect.height / CGFloat(geometry.divisions) / 2
                var y = rect.minY + ystep
                while y < rect.maxY {
                    minorPath.move(to: CGPoint(x: rect.minX, y: y))
                    minorPath.addLine(to: CGPoint(x: rect.maxX, y: y))
                    y += ystep * 2
                }
            }
        }

        if showMinor {
            context.stroke(minorPath, with: .color(Theme.gridMinor), lineWidth: 0.5)
        }
        context.stroke(majorPath, with: .color(Theme.gridMajor), lineWidth: 0.5)
        context.stroke(Path(rect), with: .color(Theme.gridBorder), lineWidth: 1)
    }

    /// Polyline through samples, skipping non-finite values.
    static func polyline(points: [CGPoint]) -> Path {
        var path = Path()
        var started = false
        for p in points {
            guard p.x.isFinite, p.y.isFinite else { started = false; continue }
            if started { path.addLine(to: p) } else { path.move(to: p); started = true }
        }
        return path
    }

    /// Small text label with a translucent plate behind it.
    static func label(_ context: inout GraphicsContext, text: String, at point: CGPoint,
                      color: Color, anchor: UnitPoint = .topLeading, font: Font = Theme.monospaceSmall,
                      background: Color = Color.black.opacity(0.55)) {
        let resolved = context.resolve(Text(text).font(font).foregroundColor(color))
        let size = resolved.measure(in: CGSize(width: 400, height: 100))
        var origin = point
        switch anchor {
        case .topTrailing: origin.x -= size.width
        case .center: origin.x -= size.width / 2; origin.y -= size.height / 2
        case .bottomLeading: origin.y -= size.height
        case .bottomTrailing: origin.x -= size.width; origin.y -= size.height
        default: break
        }
        let plate = CGRect(x: origin.x - 3, y: origin.y - 1, width: size.width + 6, height: size.height + 2)
        context.fill(Path(roundedRect: plate, cornerRadius: 3), with: .color(background))
        context.draw(resolved, at: origin, anchor: .topLeading)
    }

    static func textSize(_ context: GraphicsContext, _ text: String, font: Font) -> CGSize {
        context.resolve(Text(text).font(font)).measure(in: CGSize(width: 500, height: 100))
    }
}

/// Value formatting for marker readouts and axis labels.
enum Readout {
    static func format(_ value: Double, format: TraceFormat) -> String {
        guard value.isFinite else { return "—" }
        switch format {
        case .groupDelay: return Units.time(value)
        case .seriesCapacitance, .parallelCapacitance: return Units.capacitance(value)
        case .seriesInductance, .parallelInductance: return Units.inductance(value)
        case .conductance, .susceptance, .admittanceMagnitude:
            return Units.engineering(value, unit: "S", digits: 4)
        default:
            let unit = format.unit
            let text = String(format: "%.\(format.readoutDigits)f", value)
            return unit.isEmpty ? text : "\(text) \(unit)"
        }
    }

    static func axisLabel(_ value: Double, format: TraceFormat) -> String {
        guard value.isFinite else { return "" }
        switch format {
        case .groupDelay: return Units.engineering(value, unit: "s", digits: 3)
        case .seriesCapacitance, .parallelCapacitance: return Units.engineering(value, unit: "F", digits: 3)
        case .seriesInductance, .parallelInductance: return Units.engineering(value, unit: "H", digits: 3)
        case .conductance, .susceptance, .admittanceMagnitude: return Units.engineering(value, unit: "S", digits: 3)
        default:
            if abs(value) >= 1000 || (abs(value) < 0.01 && value != 0) {
                return Units.engineering(value, unit: "", digits: 3)
            }
            let decimals = abs(value) < 10 ? 2 : (abs(value) < 100 ? 1 : 0)
            return String(format: "%.\(decimals)f", value)
        }
    }
}
