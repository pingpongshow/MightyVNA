import SwiftUI
import VNACore

/// One plot in the grid: header, chart and marker readout.
struct PlotPaneView: View {

    @EnvironmentObject var model: AppModel
    @Binding var pane: PlotPane

    @State private var isHovering = false

    private var renderedTraces: [RenderedTrace] {
        pane.traceIDs.compactMap { id in
            guard let trace = model.workspace.trace(id: id) else { return nil }
            return RenderedTrace(trace: trace,
                                 samples: model.samples(for: trace),
                                 color: Theme.traceColor(trace.colorIndex),
                                 isSelected: model.selectedTraceID == trace.id)
        }
    }

    private var domain: TraceDomain {
        switch pane.kind {
        case .timeDomain: return .time
        case .smith: return .smith
        case .polar: return .polar
        case .rectangular: return .frequency
        }
    }

    private var xRange: ClosedRange<Double> {
        if pane.kind == .timeDomain {
            let maxDistance = renderedTraces.compactMap { $0.samples.x.last }.max() ?? 1
            return 0...max(maxDistance, 0.01)
        }
        let sweep = model.workspace.sweep
        let lo = model.displayFrame.isEmpty ? sweep.start : model.displayFrame.startFrequency
        let hi = model.displayFrame.isEmpty ? sweep.stop : model.displayFrame.stopFrequency
        return min(lo, hi - 1)...max(hi, lo + 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if pane.showsMarkerReadout && !renderedTraces.isEmpty {
                MarkerReadoutStrip(traces: renderedTraces,
                                   markers: model.workspace.markers.filter(\.isEnabledOnChart),
                                   activeMarkerID: model.activeMarkerID,
                                   domain: domain)
            }
        }
        .background(Theme.panelBackground.opacity(0.4))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovering ? Theme.accent.opacity(0.5) : Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(PlotKind.allCases) { kind in
                    Button {
                        pane.kind = kind
                    } label: {
                        Label(kind.displayName, systemImage: kind.systemImage)
                    }
                }
                Divider()
                Toggle("Marker readout", isOn: $pane.showsMarkerReadout)
            } label: {
                Image(systemName: pane.kind.systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .help("Change what this pane displays")

            ForEach(renderedTraces) { rendered in
                traceChip(rendered)
            }

            Spacer(minLength: 0)

            Menu {
                Section("Add trace to this pane") {
                    ForEach(model.availableChannels) { channel in
                        Menu(channel.longName) {
                            ForEach(formats(for: channel), id: \.self) { format in
                                Button(format.displayName) {
                                    model.addTrace(channel: channel, format: format, toPane: pane.id)
                                }
                            }
                        }
                    }
                }
                if !model.workspace.traces.isEmpty {
                    Section("Show existing trace") {
                        ForEach(model.workspace.traces.filter { !pane.traceIDs.contains($0.id) }) { trace in
                            Button(trace.displayName) { pane.traceIDs.append(trace.id) }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .help("Add a trace")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
    }

    private func formats(for channel: Channel) -> [TraceFormat] {
        TraceFormat.allCases.filter { format in
            switch pane.kind {
            case .rectangular: return format.domain == .frequency && (channel.isReflection || !format.reflectionOnly)
            case .smith: return format == .smith || format == .admittanceSmith
            case .polar: return format == .polar
            case .timeDomain: return format.domain == .time && channel.isReflection
            }
        }
    }

    private func traceChip(_ rendered: RenderedTrace) -> some View {
        let trace = rendered.trace
        return Menu {
            Button(trace.enabled ? "Hide" : "Show") {
                model.binding(for: trace.id)?.wrappedValue.enabled.toggle()
            }
            Button("Select for editing") { model.selectedTraceID = trace.id }
            Button("Auto scale") { model.autoScale(traceID: trace.id) }
            Divider()
            Menu("Format") {
                ForEach(formats(for: trace.channel), id: \.self) { format in
                    Button(format.displayName) {
                        if let binding = model.binding(for: trace.id) {
                            binding.wrappedValue.format = format
                            binding.wrappedValue.applyDefaultScale()
                        }
                    }
                }
            }
            Menu("Channel") {
                ForEach(model.availableChannels) { channel in
                    Button(channel.longName) { model.binding(for: trace.id)?.wrappedValue.channel = channel }
                }
            }
            Divider()
            Button("Remove from pane") { pane.traceIDs.removeAll { $0 == trace.id } }
            Button("Delete trace", role: .destructive) { model.removeTrace(trace.id) }
        } label: {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(rendered.color)
                    .frame(width: 10, height: 3)
                Text(chipTitle(trace))
                    .font(.system(size: 10, weight: model.selectedTraceID == trace.id ? .bold : .regular,
                                  design: .monospaced))
                    .foregroundStyle(trace.enabled ? Color.primary : Color.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(trace.displayName)\n\(Units.engineering(trace.scalePerDivision, unit: trace.format.unit, digits: 3))/div · ref \(Readout.format(trace.referenceValue, format: trace.format))")
    }

    private func chipTitle(_ trace: Trace) -> String {
        let scale = Units.engineering(trace.scalePerDivision, unit: trace.format.unit, digits: 3)
        if pane.kind == .smith || pane.kind == .polar {
            return "\(trace.channel.shortName)"
        }
        return "\(trace.channel.shortName) \(trace.format.displayName)  \(scale)/div"
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        switch pane.kind {
        case .rectangular, .timeDomain:
            RectangularChart(traces: renderedTraces,
                             markers: model.workspace.markers,
                             activeMarkerID: model.activeMarkerID,
                             limits: model.workspace.limits,
                             domain: domain,
                             logarithmicX: model.workspace.frequencyAxisScale == .logarithmic,
                             showMinorGrid: model.workspace.showMinorGrid,
                             xRange: xRange,
                             onMarkerMove: { value in moveMarker(to: value) },
                             onZoom: { range in applyZoom(range) },
                             onAutoScale: { renderedTraces.forEach { model.autoScale(traceID: $0.id) } })
        case .smith:
            SmithChart(traces: renderedTraces,
                       markers: model.workspace.markers,
                       activeMarkerID: model.activeMarkerID,
                       frequencies: model.displayFrame.frequencies,
                       z0: model.workspace.z0,
                       showAdmittanceOverlay: renderedTraces.contains { $0.trace.format == .admittanceSmith },
                       admittanceMode: renderedTraces.allSatisfy { $0.trace.format == .admittanceSmith } && !renderedTraces.isEmpty,
                       onMarkerMove: { moveMarker(to: $0) })
        case .polar:
            PolarChart(traces: renderedTraces,
                       markers: model.workspace.markers,
                       activeMarkerID: model.activeMarkerID,
                       onMarkerMove: { moveMarker(to: $0) })
        }
    }

    private func moveMarker(to value: Double) {
        guard let index = model.activeMarkerIndex() else { return }
        if domain == .time {
            model.workspace.markers[index].distance = value
        } else {
            model.workspace.markers[index].frequency = value
            model.workspace.markers[index].tracking = .none
        }
        if !model.workspace.markers[index].enabled { model.workspace.markers[index].enabled = true }
    }

    private func applyZoom(_ range: ClosedRange<Double>) {
        guard domain == .frequency else { return }
        var sweep = model.workspace.sweep
        sweep.start = range.lowerBound
        sweep.stop = range.upperBound
        model.workspace.sweep = sweep
        model.statusMessage = "Zoomed to \(Units.frequencyShort(range.lowerBound)) – \(Units.frequencyShort(range.upperBound))"
    }
}

private extension Marker {
    var isEnabledOnChart: Bool { enabled && showsOnChart }
}

/// Compact table of trace values at each marker, shown under a plot.
struct MarkerReadoutStrip: View {
    var traces: [RenderedTrace]
    var markers: [Marker]
    var activeMarkerID: UUID?
    var domain: TraceDomain

    var body: some View {
        if markers.isEmpty || traces.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(markers) { marker in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Circle().fill(Theme.markerColor(marker.colorIndex)).frame(width: 6, height: 6)
                                Text(marker.label).font(.system(size: 9, weight: .bold, design: .monospaced))
                                Text(domain == .time ? Units.distance(marker.distance) : Units.frequency(marker.frequency))
                                    .font(Theme.monospaceSmall)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(traces.prefix(4)) { rendered in
                                if let value = value(of: rendered, at: marker) {
                                    Text(value)
                                        .font(Theme.monospaceSmall)
                                        .foregroundStyle(rendered.color)
                                }
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(marker.id == activeMarkerID ? Theme.accent.opacity(0.14) : Color.clear)
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .background(Color.primary.opacity(0.03))
        }
    }

    private func value(of rendered: RenderedTrace, at marker: Marker) -> String? {
        let s = rendered.samples
        guard !s.x.isEmpty else { return nil }
        let target = domain == .time ? marker.distance : marker.frequency
        var best = 0
        var delta = Double.infinity
        for (i, x) in s.x.enumerated() {
            let d = abs(x - target)
            if d < delta { delta = d; best = i }
        }
        if rendered.trace.format.domain == .smith || rendered.trace.format.domain == .polar {
            guard best < s.complex.count else { return nil }
            let g = s.complex[best]
            let z = RF.impedance(g, z0: 50)
            return String(format: "%.1f%+.1fj Ω  SWR %.2f", z.re, z.im, RF.swr(g))
        }
        guard best < s.y.count else { return nil }
        return Readout.format(s.y[best], format: rendered.trace.format)
    }
}
