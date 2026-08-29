import SwiftUI
import VNACore

/// Polar plot of a complex parameter, radius 1 at the outer circle.
struct PolarChart: View {

    var traces: [RenderedTrace]
    var markers: [Marker]
    var activeMarkerID: UUID?
    var onMarkerMove: (Double) -> Void = { _ in }

    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let side = max(20, min(proxy.size.width, proxy.size.height) - 24)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = side / 2

            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.plotBackground))
                drawGrid(&context, center: center, radius: radius)
                drawTraces(&context, center: center, radius: radius)
                drawMarkers(&context, center: center, radius: radius)
                drawHover(&context, center: center, radius: radius, size: size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p
                case .ended: hover = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                hover = value.location
                if let f = nearestFrequency(to: value.location, center: center, radius: radius) {
                    onMarkerMove(f)
                }
            })
        }
    }

    private func point(_ v: Complex, center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(v.re) * radius, y: center.y - CGFloat(v.im) * radius)
    }

    private func drawGrid(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        var minor = Path()
        for r in [0.2, 0.4, 0.6, 0.8] {
            let rad = radius * CGFloat(r)
            minor.addPath(Path(ellipseIn: CGRect(x: center.x - rad, y: center.y - rad, width: rad * 2, height: rad * 2)))
        }
        for degrees in stride(from: 0, to: 180, by: 30) {
            let a = Double(degrees) * .pi / 180
            minor.move(to: CGPoint(x: center.x - CGFloat(cos(a)) * radius, y: center.y + CGFloat(sin(a)) * radius))
            minor.addLine(to: CGPoint(x: center.x + CGFloat(cos(a)) * radius, y: center.y - CGFloat(sin(a)) * radius))
        }
        context.stroke(minor, with: .color(Theme.gridMinor), lineWidth: 0.5)
        let outer = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.stroke(outer, with: .color(Theme.gridBorder), lineWidth: 1.2)

        for (label, angle) in [("0°", 0.0), ("90°", 90.0), ("180°", 180.0), ("270°", 270.0)] {
            let a = angle * .pi / 180
            let p = CGPoint(x: center.x + CGFloat(cos(a)) * (radius + 12),
                            y: center.y - CGFloat(sin(a)) * (radius + 12))
            PlotDraw.label(&context, text: label, at: p, color: Theme.axisText,
                           anchor: .center, background: .clear)
        }
        PlotDraw.label(&context, text: "1.0", at: CGPoint(x: center.x + radius - 18, y: center.y + 3),
                       color: Theme.axisText, background: .clear)
    }

    private func drawTraces(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        for rendered in traces where rendered.trace.enabled {
            let values = rendered.samples.complex
            guard values.count > 1 else { continue }
            let path = PlotDraw.polyline(points: values.map { point($0, center: center, radius: radius) })
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
                guard let index = nearestIndex(rendered.samples.x, marker.frequency),
                      index < rendered.samples.complex.count else { continue }
                let p = point(rendered.samples.complex[index], center: center, radius: radius)
                let color = Theme.markerColor(marker.colorIndex)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                               with: .color(color), lineWidth: 1.6)
                PlotDraw.label(&context, text: marker.label, at: CGPoint(x: p.x + 7, y: p.y - 7), color: color)
                break
            }
        }
    }

    private func drawHover(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, size: CGSize) {
        guard let hover else { return }
        let v = Complex(Double((hover.x - center.x) / radius), Double((center.y - hover.y) / radius))
        guard v.magnitude <= 1.05 else { return }
        let text = "|Γ| \(Units.fixed(v.magnitude, 4))   ∠ \(Units.fixed(v.phase * 180 / .pi, 2))°\n\(Units.fixed(RF.dB(v.magnitude), 2)) dB"
        PlotDraw.label(&context, text: text, at: CGPoint(x: 8, y: size.height - 34),
                       color: .white, background: Color.black.opacity(0.7))
    }

    private func nearestIndex(_ xs: [Double], _ target: Double) -> Int? {
        guard !xs.isEmpty else { return nil }
        var best = 0
        var delta = Double.infinity
        for (i, x) in xs.enumerated() {
            let d = abs(x - target)
            if d < delta { delta = d; best = i }
        }
        return best
    }

    private func nearestFrequency(to location: CGPoint, center: CGPoint, radius: CGFloat) -> Double? {
        guard let rendered = traces.first(where: { $0.trace.enabled && $0.samples.complex.count > 1 }) else { return nil }
        var best: Int?
        var bestDistance = CGFloat.infinity
        for (i, v) in rendered.samples.complex.enumerated() {
            let p = point(v, center: center, radius: radius)
            let d = hypot(p.x - location.x, p.y - location.y)
            if d < bestDistance { bestDistance = d; best = i }
        }
        guard let index = best, index < rendered.samples.x.count, bestDistance < 60 else { return nil }
        return rendered.samples.x[index]
    }
}
