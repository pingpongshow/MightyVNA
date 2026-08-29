import SwiftUI
import VNACore

/// A trace paired with its evaluated samples and colour, ready to draw.
struct RenderedTrace: Identifiable {
    var id: UUID { trace.id }
    var trace: Trace
    var samples: TraceSamples
    var color: Color
    var isSelected: Bool
}

/// Cartesian plot used for both the frequency domain and the time domain.
struct RectangularChart: View {

    var traces: [RenderedTrace]
    var markers: [Marker]
    var activeMarkerID: UUID?
    var limits: [LimitSet]
    var domain: TraceDomain             // .frequency or .time
    var logarithmicX: Bool
    var showMinorGrid: Bool
    var xRange: ClosedRange<Double>
    var showsReadout: Bool = true

    var onMarkerMove: (Double) -> Void = { _ in }
    var onZoom: (ClosedRange<Double>) -> Void = { _ in }
    var onAutoScale: () -> Void = {}

    @State private var hoverLocation: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var isZoomDrag = false

    private let leftInset: CGFloat = 58
    private let rightInset: CGFloat = 12
    private let topInset: CGFloat = 10
    private let bottomInset: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(x: leftInset, y: topInset,
                              width: max(10, proxy.size.width - leftInset - rightInset),
                              height: max(10, proxy.size.height - topInset - bottomInset))
            let geometry = PlotGeometry(rect: rect, xMin: xRange.lowerBound, xMax: xRange.upperBound,
                                        logarithmic: logarithmicX && domain == .frequency)

            Canvas { context, _ in
                context.fill(Path(rect), with: .color(Theme.plotBackground))
                PlotDraw.grid(&context, geometry: geometry, showMinor: showMinorGrid,
                              logarithmic: geometry.logarithmic)
                drawYAxis(&context, geometry: geometry)
                drawXAxis(&context, geometry: geometry)
                drawLimits(&context, geometry: geometry)
                drawTraces(&context, geometry: geometry)
                drawMarkers(&context, geometry: geometry)
                drawHover(&context, geometry: geometry)
                drawZoomSelection(&context, geometry: geometry)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverLocation = rect.contains(point) ? point : nil
                case .ended: hoverLocation = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .modifiers(.option)
                    .onChanged { value in
                        isZoomDrag = true
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        defer { dragStart = nil; dragCurrent = nil; isZoomDrag = false }
                        let a = geometry.value(atX: max(rect.minX, min(rect.maxX, value.startLocation.x)))
                        let b = geometry.value(atX: max(rect.minX, min(rect.maxX, value.location.x)))
                        guard abs(b - a) > 0 else { return }
                        onZoom(min(a, b)...max(a, b))
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !isZoomDrag else { return }
                        let clamped = max(rect.minX, min(rect.maxX, value.location.x))
                        onMarkerMove(geometry.value(atX: clamped))
                        hoverLocation = value.location
                    }
            )
            .onTapGesture(count: 2) { onAutoScale() }
        }
    }

    // MARK: - Drawing

    private func drawTraces(_ context: inout GraphicsContext, geometry: PlotGeometry) {
        for rendered in traces where rendered.trace.enabled {
            let s = rendered.samples
            guard s.x.count > 1, s.y.count == s.x.count else { continue }
            let range = rendered.trace.displayRange
            var points = [CGPoint]()
            points.reserveCapacity(s.x.count)
            for i in s.x.indices {
                let value = s.y[i]
                guard value.isFinite else { points.append(CGPoint(x: CGFloat.nan, y: CGFloat.nan)); continue }
                let py = geometry.y(value, range: range)
                // Clip vertically but keep the line continuous at the edges.
                let clamped = min(max(py, geometry.rect.minY - 2000), geometry.rect.maxY + 2000)
                points.append(CGPoint(x: geometry.x(s.x[i]), y: clamped))
            }
            let path = PlotDraw.polyline(points: points)
            context.drawLayer { layer in
                layer.clip(to: Path(geometry.rect.insetBy(dx: -1, dy: -1)))
                if rendered.isSelected {
                    layer.stroke(path, with: .color(rendered.color.opacity(0.25)),
                                 style: StrokeStyle(lineWidth: rendered.trace.lineWidth + 4, lineJoin: .round))
                }
                layer.stroke(path, with: .color(rendered.color),
                             style: StrokeStyle(lineWidth: rendered.trace.lineWidth,
                                                lineCap: .round, lineJoin: .round))
            }

            // Reference-line indicator on the left edge.
            let refY = geometry.y(rendered.trace.referenceValue, range: range)
            if refY >= geometry.rect.minY - 1 && refY <= geometry.rect.maxY + 1 {
                var arrow = Path()
                arrow.move(to: CGPoint(x: geometry.rect.minX - 7, y: refY))
                arrow.addLine(to: CGPoint(x: geometry.rect.minX - 1, y: refY - 4))
                arrow.addLine(to: CGPoint(x: geometry.rect.minX - 1, y: refY + 4))
                arrow.closeSubpath()
                context.fill(arrow, with: .color(rendered.color))
            }
        }
    }

    private func drawYAxis(_ context: inout GraphicsContext, geometry: PlotGeometry) {
        // Label the axis using the first enabled trace in the pane.
        guard let primary = traces.first(where: { $0.trace.enabled }) else { return }
        let range = primary.trace.displayRange
        for (index, y) in geometry.gridYPositions().enumerated() {
            let value = range.upperBound - (range.upperBound - range.lowerBound) * Double(index) / Double(geometry.divisions)
            let text = Readout.axisLabel(value, format: primary.trace.format)
            PlotDraw.label(&context, text: text,
                           at: CGPoint(x: geometry.rect.minX - 10, y: y - 6),
                           color: Theme.axisText, anchor: .topTrailing,
                           background: .clear)
        }
    }

    private func drawXAxis(_ context: inout GraphicsContext, geometry: PlotGeometry) {
        let values = geometry.gridXValues()
        guard !values.isEmpty else { return }

        // Lay the labels out left to right, dropping any that would collide with the
        // one before it or with the right-hand end label.
        struct Candidate { var text: String; var x: CGFloat; var width: CGFloat; var anchor: UnitPoint }
        var candidates: [Candidate] = []
        for (index, value) in values.enumerated() {
            let px = geometry.x(value)
            guard px >= geometry.rect.minX - 1, px <= geometry.rect.maxX + 1 else { continue }
            let text = domain == .time ? Units.distance(value) : Units.frequencyShort(value)
            let width = PlotDraw.textSize(context, text, font: Theme.monospaceSmall).width
            let anchor: UnitPoint = index == 0 ? .topLeading
                : (index == values.count - 1 ? .topTrailing : .center)
            candidates.append(Candidate(text: text, x: px, width: width, anchor: anchor))
        }
        guard !candidates.isEmpty else { return }

        let gap: CGFloat = 10
        let last = candidates.removeLast()
        let lastLeftEdge = last.x - last.width
        var placed: [Candidate] = []
        var cursor = geometry.rect.minX - 1000
        for candidate in candidates {
            let left = candidate.anchor == .topLeading ? candidate.x : candidate.x - candidate.width / 2
            let right = candidate.anchor == .topLeading ? candidate.x + candidate.width : candidate.x + candidate.width / 2
            guard left > cursor + gap, right < lastLeftEdge - gap else { continue }
            placed.append(candidate)
            cursor = right
        }
        placed.append(last)

        for candidate in placed {
            PlotDraw.label(&context, text: candidate.text,
                           at: CGPoint(x: candidate.x, y: geometry.rect.maxY + 5),
                           color: Theme.axisText, anchor: candidate.anchor, background: .clear)
        }
    }

    private func drawLimits(_ context: inout GraphicsContext, geometry: PlotGeometry) {
        guard let primary = traces.first(where: { $0.trace.enabled }) else { return }
        let range = primary.trace.displayRange
        for set in limits where set.enabled {
            guard set.traceID == nil || set.traceID == primary.trace.id else { continue }
            for segment in set.segments where segment.enabled {
                var path = Path()
                path.move(to: CGPoint(x: geometry.x(segment.startFrequency),
                                      y: geometry.y(segment.startValue, range: range)))
                path.addLine(to: CGPoint(x: geometry.x(segment.stopFrequency),
                                         y: geometry.y(segment.stopValue, range: range)))
                context.drawLayer { layer in
                    layer.clip(to: Path(geometry.rect))
                    layer.stroke(path, with: .color(Theme.statusBad.opacity(0.85)),
                                 style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                }
            }
        }
    }

    private func drawMarkers(_ context: inout GraphicsContext, geometry: PlotGeometry) {
        for marker in markers where marker.enabled && marker.showsOnChart {
            let position = domain == .time ? marker.distance : marker.frequency
            let px = geometry.x(position)
            guard px >= geometry.rect.minX - 0.5, px <= geometry.rect.maxX + 0.5 else { continue }
            let isActive = marker.id == activeMarkerID
            let color = Theme.markerColor(marker.colorIndex)

            var line = Path()
            line.move(to: CGPoint(x: px, y: geometry.rect.minY))
            line.addLine(to: CGPoint(x: px, y: geometry.rect.maxY))
            context.stroke(line, with: .color(color.opacity(isActive ? 0.75 : 0.4)),
                           style: StrokeStyle(lineWidth: isActive ? 1.4 : 1, dash: isActive ? [] : [3, 3]))

            // Diamond on each trace at the marker frequency.
            for rendered in traces where rendered.trace.enabled {
                guard let (x, y, value) = sample(rendered, at: position, geometry: geometry) else { continue }
                var diamond = Path()
                diamond.move(to: CGPoint(x: x, y: y - 4.5))
                diamond.addLine(to: CGPoint(x: x + 4.5, y: y))
                diamond.addLine(to: CGPoint(x: x, y: y + 4.5))
                diamond.addLine(to: CGPoint(x: x - 4.5, y: y))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(rendered.color))
                context.stroke(diamond, with: .color(.black.opacity(0.6)), lineWidth: 0.8)
                _ = value
            }

            PlotDraw.label(&context, text: marker.label,
                           at: CGPoint(x: px + 3, y: geometry.rect.minY + 2),
                           color: color, anchor: .topLeading)
        }
    }

    private func drawHover(_ context: inout GraphicsContext, geometry: PlotGeometry) {
        guard showsReadout, let hover = hoverLocation, geometry.rect.contains(hover) else { return }
        var line = Path()
        line.move(to: CGPoint(x: hover.x, y: geometry.rect.minY))
        line.addLine(to: CGPoint(x: hover.x, y: geometry.rect.maxY))
        context.stroke(line, with: .color(Color.primary.opacity(0.25)), lineWidth: 0.8)

        let value = geometry.value(atX: hover.x)
        var lines: [String] = [domain == .time ? Units.distance(value) : Units.frequency(value)]
        for rendered in traces.prefix(4) where rendered.trace.enabled {
            guard let (_, _, v) = sample(rendered, at: value, geometry: geometry) else { continue }
            lines.append("\(rendered.trace.channel.shortName) \(Readout.format(v, format: rendered.trace.format))")
        }
        let text = lines.joined(separator: "\n")
        let size = PlotDraw.textSize(context, text, font: Theme.monospaceSmall)
        var origin = CGPoint(x: hover.x + 10, y: geometry.rect.minY + 6)
        if origin.x + size.width + 10 > geometry.rect.maxX { origin.x = hover.x - size.width - 14 }
        PlotDraw.label(&context, text: text, at: origin, color: .white,
                       background: Color.black.opacity(0.75))
    }

    private func drawZoomSelection(_ context: inout GraphicsContext, geometry: PlotGeometry) {
        guard let start = dragStart, let current = dragCurrent else { return }
        let x0 = min(start.x, current.x), x1 = max(start.x, current.x)
        let rect = CGRect(x: max(x0, geometry.rect.minX), y: geometry.rect.minY,
                          width: min(x1, geometry.rect.maxX) - max(x0, geometry.rect.minX),
                          height: geometry.rect.height)
        context.fill(Path(rect), with: .color(Theme.accent.opacity(0.18)))
        context.stroke(Path(rect), with: .color(Theme.accent), lineWidth: 1)
    }

    /// Interpolated sample of a trace at an x value.
    private func sample(_ rendered: RenderedTrace, at xValue: Double,
                        geometry: PlotGeometry) -> (CGFloat, CGFloat, Double)? {
        let s = rendered.samples
        guard s.x.count > 1, s.y.count == s.x.count else { return nil }
        guard xValue >= s.x.first! - 1e-9, xValue <= s.x.last! + 1e-9 else { return nil }
        var index = 0
        while index < s.x.count - 2 && s.x[index + 1] < xValue { index += 1 }
        let x0 = s.x[index], x1 = s.x[index + 1]
        let t = x1 > x0 ? (xValue - x0) / (x1 - x0) : 0
        let value = s.y[index] + (s.y[index + 1] - s.y[index]) * t
        guard value.isFinite else { return nil }
        return (geometry.x(xValue), geometry.y(value, range: rendered.trace.displayRange), value)
    }
}
