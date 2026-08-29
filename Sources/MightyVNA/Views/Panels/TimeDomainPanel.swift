import SwiftUI
import VNACore

struct TimeDomainPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PanelSection(title: "Time domain / TDR", systemImage: "waveform.path",
                     subtitle: "Transforms the reflection sweep into distance. Wider sweeps give finer resolution; lower start frequencies give longer unambiguous range.") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Mode", selection: $model.workspace.timeDomain.mode) {
                    ForEach(TDRMode.allCases) { Text($0.displayName).tag($0) }
                }
                .font(.system(size: 11))

                Picker("Window", selection: $model.workspace.timeDomain.window) {
                    ForEach(WindowFunction.allCases) { Text($0.displayName).tag($0) }
                }
                .font(.system(size: 11))

                if model.workspace.timeDomain.window == .kaiser {
                    HStack {
                        Text("β").font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $model.workspace.timeDomain.kaiserBeta, in: 1...14)
                        Text(Units.fixed(model.workspace.timeDomain.kaiserBeta, 1)).font(Theme.monospace)
                    }
                }

                HStack(spacing: 8) {
                    NumericField(title: "VF", value: $model.workspace.timeDomain.velocityFactor,
                                 format: "%.4f", width: 24)
                    Menu {
                        ForEach(CableTools.commonCables) { cable in
                            Button("\(cable.name) — VF \(Units.fixed(cable.velocityFactor, 3))") {
                                model.workspace.timeDomain.velocityFactor = cable.velocityFactor
                            }
                        }
                    } label: {
                        Label("Cable", systemImage: "cable.coaxial").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 80)
                }

                HStack {
                    Text("Zero padding").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $model.workspace.timeDomain.padFactor) {
                        ForEach([1, 2, 4, 8, 16], id: \.self) { Text("×\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }

                Toggle("Extrapolate to DC", isOn: $model.workspace.timeDomain.extrapolateDC)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Lowpass modes need a DC point. When the sweep does not start near DC, MightyVNA extrapolates one from the lowest measured samples.")

                Divider()

                let result = currentResult
                if result.isEmpty {
                    Text("Run a sweep to see the time-domain summary.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ValueRow(label: "Resolution", value: Units.distance(result.resolution),
                             help: "Smallest distance between two discontinuities that can still be told apart.")
                    ValueRow(label: "Unambiguous range", value: Units.distance(result.maxDistance))
                    if let peak = peakDiscontinuity(result) {
                        ValueRow(label: "Largest discontinuity",
                                 value: "\(Units.distance(peak.distance))  ·  ρ \(Units.fixed(peak.magnitude, 3))",
                                 color: Theme.accent)
                        ValueRow(label: "Round-trip delay", value: Units.time(peak.time))
                    }
                }

                PillButton(title: "Add TDR pane", systemImage: "plus.rectangle") { addTDRPane() }
            }
        }
    }

    private var currentResult: TimeDomainResult {
        guard !model.displayFrame.isEmpty else { return .empty }
        return TimeDomain.transform(frame: model.displayFrame, channel: .s11,
                                    settings: model.workspace.timeDomain)
    }

    private func peakDiscontinuity(_ result: TimeDomainResult) -> (distance: Double, time: Double, magnitude: Double)? {
        let values = result.impulse.map { abs($0) }
        // Skip the first few bins, which hold the connector at the reference plane.
        guard values.count > 8 else { return nil }
        let searchRange = Array(values[3...])
        guard let localMax = TraceAnalysis.indexOfMaximum(searchRange) else { return nil }
        let index = localMax + 3
        guard index < result.distance.count else { return nil }
        return (result.distance[index], result.time[index], values[index])
    }

    private func addTDRPane() {
        var trace = Trace(channel: .s11, format: .tdrLowpassStep, colorIndex: model.workspace.traces.count)
        trace.applyDefaultScale()
        model.workspace.traces.append(trace)
        var pane = PlotPane(kind: .timeDomain, traceIDs: [trace.id], title: "TDR")
        pane.showsMarkerReadout = true
        model.workspace.panes.append(pane)
        if model.workspace.layout.paneCount < model.workspace.panes.count {
            model.setLayout(model.workspace.panes.count <= 4 ? .grid2x2 : .grid2x3)
        }
        model.selectedTraceID = trace.id
    }
}
