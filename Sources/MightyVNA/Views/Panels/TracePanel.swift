import SwiftUI
import VNACore

struct TracePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PanelSection(title: "Traces", systemImage: "chart.xyaxis.line") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.workspace.traces) { trace in
                    traceRow(trace)
                }

                HStack(spacing: 6) {
                    Menu {
                        ForEach(model.availableChannels) { channel in
                            Menu(channel.longName) {
                                ForEach(TraceFormat.allCases.filter { channel.isReflection || !$0.reflectionOnly }, id: \.self) { format in
                                    Button(format.displayName) { model.addTrace(channel: channel, format: format) }
                                }
                            }
                        }
                        if !model.memories.isEmpty {
                            Divider()
                            Menu("Memory trace") {
                                ForEach(model.memories) { memory in
                                    Button(memory.label) { addMemoryTrace(memory.id) }
                                }
                            }
                        }
                    } label: {
                        Label("Add trace", systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 90)
                }

                if let id = model.selectedTraceID, let binding = model.binding(for: id) {
                    Divider()
                    TraceInspector(trace: binding)
                }
            }
        }
    }

    private func traceRow(_ trace: Trace) -> some View {
        HStack(spacing: 6) {
            Button {
                model.binding(for: trace.id)?.wrappedValue.enabled.toggle()
            } label: {
                Image(systemName: trace.enabled ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(trace.enabled ? Theme.traceColor(trace.colorIndex) : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 16)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.traceColor(trace.colorIndex))
                .frame(width: 12, height: 3)

            Text(trace.displayName)
                .font(.system(size: 11, weight: model.selectedTraceID == trace.id ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Button {
                model.removeTrace(trace.id)
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(model.selectedTraceID == trace.id ? Theme.accent.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTraceID = trace.id }
    }

    private func addMemoryTrace(_ id: UUID) {
        var trace = Trace(channel: .s11, format: .logMag, source: .memory(id),
                          colorIndex: model.workspace.traces.count)
        trace.source = .memory(id)
        trace.applyDefaultScale()
        model.workspace.traces.append(trace)
        if let first = model.workspace.panes.indices.first {
            model.workspace.panes[first].traceIDs.append(trace.id)
        }
        model.selectedTraceID = trace.id
    }
}

/// Detailed editor for the selected trace.
struct TraceInspector: View {
    @EnvironmentObject var model: AppModel
    @Binding var trace: Trace

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Picker("", selection: $trace.channel) {
                    ForEach(model.availableChannels) { Text($0.shortName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 74)

                Picker("", selection: Binding(
                    get: { trace.format },
                    set: { trace.format = $0; trace.applyDefaultScale() }
                )) {
                    ForEach(TraceFormat.allCases.filter { trace.channel.isReflection || !$0.reflectionOnly }, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
            }

            Picker("Source", selection: sourceBinding) {
                Text("Live").tag(0)
                if !model.memories.isEmpty {
                    Text("Memory").tag(1)
                    Text("Live ÷ Memory").tag(2)
                    Text("Live − Memory").tag(3)
                }
            }
            .font(.system(size: 11))

            if trace.source.memoryID != nil {
                Picker("Memory", selection: memoryBinding) {
                    ForEach(model.memories) { memory in
                        Text(memory.label).tag(memory.id)
                    }
                }
                .font(.system(size: 11))
            }

            if trace.format.domain == .frequency || trace.format.domain == .time {
                HStack(spacing: 8) {
                    NumericField(title: "Scale", value: $trace.scalePerDivision,
                                 unit: trace.format.unit + "/div", format: "%.4g", width: 34)
                    NumericField(title: "Ref", value: $trace.referenceValue,
                                 unit: trace.format.unit, format: "%.4g", width: 24)
                }
                HStack(spacing: 8) {
                    Text("Ref line").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: $trace.referencePosition, in: 0...10, step: 1)
                    Text("\(Int(trace.referencePosition))").font(Theme.monospace).frame(width: 16)
                }
                PillButton(title: "Auto scale", systemImage: "arrow.up.left.and.arrow.down.right") {
                    model.autoScale(traceID: trace.id)
                }
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Smoothing").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Stepper(value: $trace.smoothing, in: 1...51, step: 2) {
                            Text(trace.smoothing == 1 ? "off" : "\(trace.smoothing) pts").font(Theme.monospace)
                        }
                        .frame(width: 110)
                    }
                    HStack(spacing: 6) {
                        NumericField(title: "Delay", value: delayPicoseconds, unit: "ps", format: "%.1f", width: 36)
                        Button {
                            autoElectricalDelay()
                        } label: {
                            Image(systemName: "wand.and.stars").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("Fit an electrical delay that flattens the phase across the sweep")
                    }
                    NumericField(title: "Loss", value: $trace.lossPerGHz, unit: "dB/GHz", format: "%.3f", width: 36)
                    HStack {
                        Text("Line width").font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $trace.lineWidth, in: 0.8...4)
                    }
                    TextField("Custom name", text: $trace.customName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
                .padding(.top, 4)
            } label: {
                Text("Correction & style").font(.system(size: 11, weight: .medium))
            }
        }
    }

    private var delayPicoseconds: Binding<Double> {
        Binding(get: { trace.electricalDelay * 1e12 },
                set: { trace.electricalDelay = $0 * 1e-12 })
    }

    private var sourceBinding: Binding<Int> {
        Binding(
            get: {
                switch trace.source {
                case .live: return 0
                case .memory: return 1
                case .liveDividedByMemory: return 2
                case .liveMinusMemory: return 3
                }
            },
            set: { newValue in
                let id = trace.source.memoryID ?? model.memories.first?.id
                switch newValue {
                case 1: if let id { trace.source = .memory(id) }
                case 2: if let id { trace.source = .liveDividedByMemory(id) }
                case 3: if let id { trace.source = .liveMinusMemory(id) }
                default: trace.source = .live
                }
            }
        )
    }

    private var memoryBinding: Binding<UUID> {
        Binding(
            get: { trace.source.memoryID ?? model.memories.first?.id ?? UUID() },
            set: { id in
                switch trace.source {
                case .memory: trace.source = .memory(id)
                case .liveDividedByMemory: trace.source = .liveDividedByMemory(id)
                case .liveMinusMemory: trace.source = .liveMinusMemory(id)
                case .live: break
                }
            }
        )
    }

    /// Least-squares fit of a linear phase slope, applied as a port extension.
    private func autoElectricalDelay() {
        let (values, frame) = TraceEvaluator.complexData(
            for: Trace(id: trace.id, channel: trace.channel, format: trace.format, source: trace.source),
            live: model.displayFrame, memories: model.memoryLookup)
        guard values.count > 2, frame.frequencies.count == values.count else { return }
        let phase = RF.unwrappedPhaseDegrees(values).map { $0 * .pi / 180 }
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        for i in values.indices {
            let x = frame.frequencies[i]
            sumX += x; sumY += phase[i]; sumXY += x * phase[i]; sumXX += x * x
        }
        let n = Double(values.count)
        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > 0 else { return }
        let slope = (n * sumXY - sumX * sumY) / denom      // rad per Hz
        let passes = trace.channel.isReflection ? 2.0 : 1.0
        trace.electricalDelay = -slope / (passes * 2 * .pi)
        model.statusMessage = "Electrical delay set to \(Units.time(trace.electricalDelay))"
    }
}
