import SwiftUI
import VNACore

/// Impedance (or admittance) Smith chart.
struct SmithChart: View {

    var traces: [RenderedTrace]
    var markers: [Marker]
    var activeMarkerID: UUID?
    var frequencies: [Double]
    var z0: Double
    /// Draw the mirrored admittance grid on top of the impedance grid.
    var showAdmittanceOverlay: Bool = false
    /// Flip the whole chart into admittance coordinates.
    var admittanceMode: Bool = false

    var onMarkerMove: (Double) -> Void = { _ in }

    @State private var hover: CGPoint?

    private static let resistanceCircles: [Double] = [0, 0.2, 0.5, 1, 2, 5, 10]
    private static let reactanceArcs: [Double] = [0.2, 0.5, 1, 2, 5, 10]

    var body: some View {
        GeometryReader { proxy in
            let side = max(20, min(proxy.size.width, proxy.size.height) - 24)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = side / 2

            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.plotBackground))
                drawGrid(&context, center: center, radius: radius,
                         mirrored: admittanceMode, color: Theme.gridMajor)
                if showAdmittanceOverlay && !admittanceMode {
                    drawGrid(&context, center: center, radius: radius,
                             mirrored: true, color: Theme.accent.opacity(0.18))
                }
                drawTraces(&context, center: center, radius: radius)
                drawMarkers(&context, center: center, radius: radius)
                drawHover(&context, center: center, radius: radius, size: size)
                drawLegendScale(&context, center: center, radius: radius)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p
                case .ended: hover = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    hover = value.location
                    if let f = nearestFrequency(to: value.location, center: center, radius: radius) {
                        onMarkerMove(f)
                    }
                }
            )
        }
    }

    // MARK: - Geometry

    private func point(_ gamma: Complex, center: CGPoint, radius: CGFloat) -> CGPoint {
        let g = admittanceMode ? Complex(-gamma.re, -gamma.im) : gamma
        return CGPoint(x: center.x + CGFloat(g.re) * radius,
                       y: center.y - CGFloat(g.im) * radius)
    }

    private func gamma(at point: CGPoint, center: CGPoint, radius: CGFloat) -> Complex {
        let g = Complex(Double((point.x - center.x) / radius), Double((center.y - point.y) / radius))
        return admittanceMode ? Complex(-g.re, -g.im) : g
    }

    // MARK: - Grid

    private func drawGrid(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat,
                          mirrored: Bool, color: Color) {
        let sign: CGFloat = mirrored ? -1 : 1
        let unit = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2))
        context.drawLayer { layer in
            layer.clip(to: unit)

            var minor = Path()
            var major = Path()

            for r in Self.resistanceCircles {
                let cx = center.x + sign * CGFloat(r / (1 + r)) * radius
                let rad = CGFloat(1 / (1 + r)) * radius
                let circle = Path(ellipseIn: CGRect(x: cx - rad, y: center.y - rad, width: rad * 2, height: rad * 2))
                if r == 1 || r == 0 { major.addPath(circle) } else { minor.addPath(circle) }
            }

            for x in Self.reactanceArcs {
                for s in [1.0, -1.0] {
                    let cy = center.y - CGFloat(s / x) * radius
                    let rad = CGFloat(1 / x) * radius
                    let cx = center.x + sign * radius
                    let arc = Path(ellipseIn: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2))
                    if x == 1 { major.addPath(arc) } else { minor.addPath(arc) }
                }
            }

            // Real axis
            major.move(to: CGPoint(x: center.x - radius, y: center.y))
            major.addLine(to: CGPoint(x: center.x + radius, y: center.y))

            layer.stroke(minor, with: .color(color.opacity(0.55)), lineWidth: 0.5)
            layer.stroke(major, with: .color(color), lineWidth: 0.8)
        }
        context.stroke(unit, with: .color(Theme.gridBorder), lineWidth: 1.2)

        // Axis annotations
        if !mirrored || admittanceMode {
            let labelColor = Theme.axisText
            PlotDraw.label(&context, text: admittanceMode ? "0" : "0",
                           at: CGPoint(x: center.x - radius - 4, y: center.y - 7),
                           color: labelColor, anchor: .topTrailing, background: .clear)
            PlotDraw.label(&context, text: "∞",
                           at: CGPoint(x: center.x + radius + 4, y: center.y - 7),
                           color: labelColor, anchor: .topLeading, background: .clear)
            PlotDraw.label(&context, text: Units.fixed(z0, 0) + " Ω",
                           at: CGPoint(x: center.x, y: center.y + radius + 4),
                           color: labelColor, anchor: .center, background: .clear)
        }
    }

    private func drawLegendScale(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let text = admittanceMode ? "Admittance chart" : (showAdmittanceOverlay ? "Impedance + admittance" : "Impedance chart")
        PlotDraw.label(&context, text: text,
                       at: CGPoint(x: center.x - radius, y: center.y - radius - 14),
                       color: Theme.axisText, background: .clear)
    }

    // MARK: - Traces and markers

    private func drawTraces(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        for rendered in traces where rendered.trace.enabled {
            let values = rendered.samples.complex
            guard values.count > 1 else { continue }
            let points = values.map { point($0, center: center, radius: radius) }
            let path = PlotDraw.polyline(points: points)
            if rendered.isSelected {
                context.stroke(path, with: .color(rendered.color.opacity(0.25)),
                               style: StrokeStyle(lineWidth: rendered.trace.lineWidth + 4, lineJoin: .round))
            }
            context.stroke(path, with: .color(rendered.color),
                           style: StrokeStyle(lineWidth: rendered.trace.lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawMarkers(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        for marker in markers where marker.enabled && marker.showsOnChart {
            for rendered in traces where rendered.trace.enabled {
                guard let index = index(of: marker.frequency, in: rendered.samples.x),
                      index < rendered.samples.complex.count else { continue }
                let g = rendered.samples.complex[index]
                let p = point(g, center: center, radius: radius)
                let color = Theme.markerColor(marker.colorIndex)
                let ring = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                context.stroke(ring, with: .color(color), lineWidth: 1.6)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                             with: .color(color))
                PlotDraw.label(&context, text: marker.label,
                               at: CGPoint(x: p.x + 7, y: p.y - 7), color: color)
                break   // one annotation per marker is enough on a Smith chart
            }
        }
    }

    private func drawHover(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, size: CGSize) {
        guard let hover else { return }
        let g = gamma(at: hover, center: center, radius: radius)
        guard g.magnitude <= 1.02 else { return }
        let z = RF.impedance(g, z0: z0)
        let text = """
        Γ  \(Units.fixed(g.re, 3)) \(g.im < 0 ? "−" : "+") j\(Units.fixed(abs(g.im), 3))
        Z  \(Units.fixed(z.re, 2)) \(z.im < 0 ? "−" : "+") j\(Units.fixed(abs(z.im), 2)) Ω
        SWR \(Units.fixed(RF.swr(g), 3))   RL \(Units.fixed(RF.returnLoss(g), 2)) dB
        """
        PlotDraw.label(&context, text: text, at: CGPoint(x: 8, y: size.height - 52),
                       color: .white, background: Color.black.opacity(0.7))
    }

    // MARK: - Hit testing

    private func index(of frequency: Double, in xs: [Double]) -> Int? {
        guard !xs.isEmpty else { return nil }
        var best = 0
        var delta = Double.infinity
        for (i, x) in xs.enumerated() {
            let d = abs(x - frequency)
            if d < delta { delta = d; best = i }
        }
        return best
    }

    private func nearestFrequency(to location: CGPoint, center: CGPoint, radius: CGFloat) -> Double? {
        guard let rendered = traces.first(where: { $0.trace.enabled && $0.samples.complex.count > 1 }) else { return nil }
        var best: Int?
        var bestDistance = CGFloat.infinity
        for (i, g) in rendered.samples.complex.enumerated() {
            let p = point(g, center: center, radius: radius)
            let d = hypot(p.x - location.x, p.y - location.y)
            if d < bestDistance { bestDistance = d; best = i }
        }
        guard let index = best, index < rendered.samples.x.count, bestDistance < 60 else { return nil }
        return rendered.samples.x[index]
    }
}
