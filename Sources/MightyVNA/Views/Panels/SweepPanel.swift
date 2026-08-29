import SwiftUI
import VNACore

struct SweepPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var entryMode: EntryMode = .startStop

    enum EntryMode: String, CaseIterable, Identifiable {
        case startStop = "Start / Stop"
        case centerSpan = "Center / Span"
        var id: String { rawValue }
    }

    var body: some View {
        PanelSection(title: "Sweep", systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $entryMode) {
                    ForEach(EntryMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                if entryMode == .startStop {
                    FrequencyField(title: "Start", value: startBinding)
                    FrequencyField(title: "Stop", value: stopBinding)
                } else {
                    FrequencyField(title: "Center", value: centerBinding)
                    FrequencyField(title: "Span", value: spanBinding)
                }

                HStack(spacing: 8) {
                    Text("Points")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("", selection: pointsBinding) {
                        ForEach([51, 101, 201, 301, 401, 501, 801, 1001], id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 84)
                    Spacer()
                    Text(stepDescription)
                        .font(Theme.monospaceSmall)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 6) {
                    PillButton(title: model.isSweeping ? "Stop" : "Run",
                               systemImage: model.isSweeping ? "stop.fill" : "play.fill",
                               tint: model.isSweeping ? Theme.statusBad : Theme.statusGood,
                               isProminent: true) {
                        model.toggleSweeping()
                    }
                    PillButton(title: "Single", systemImage: "1.circle") { model.singleSweep() }
                    Toggle("Continuous", isOn: $model.continuousSweep)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }

                Divider()

                HStack(spacing: 8) {
                    Text("Averaging")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { model.workspace.averagingMode },
                        set: { model.workspace.averagingMode = $0; model.resetAveraging() }
                    )) {
                        ForEach(SweepAccumulator.Mode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                if model.workspace.averagingMode != .off {
                    HStack {
                        Text("Depth").font(.system(size: 11)).foregroundStyle(.secondary)
                        Stepper(value: Binding(
                            get: { model.workspace.averagingDepth },
                            set: { model.workspace.averagingDepth = max(2, min(256, $0)); model.resetAveraging() }
                        ), in: 2...256) {
                            Text("\(model.workspace.averagingDepth)").font(Theme.monospace)
                        }
                        Spacer()
                        PillButton(title: "Restart", systemImage: "arrow.counterclockwise") {
                            model.resetAveraging()
                        }
                    }
                }

                Divider()

                Menu {
                    ForEach(BandPresets.allGroups, id: \.0) { group in
                        Menu(group.0) {
                            ForEach(group.1) { preset in
                                Button(preset.name) { apply(preset) }
                            }
                        }
                    }
                    Divider()
                    Button("Full device range") { applyFullRange() }
                    Button("Zoom to markers") { zoomToMarkers() }
                        .disabled(model.workspace.markers.filter(\.enabled).count < 2)
                } label: {
                    Label("Presets", systemImage: "square.grid.2x2")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let info = model.deviceInfo {
                    let segments = model.workspace.sweep.segmentCount(for: info.model)
                    if segments > 1 {
                        Text("This sweep is split into \(segments) hardware passes of up to \(info.model.maxHardwarePoints) points. It takes about \(segments)× as long as a single pass.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.statusWarn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let fundamental = info.model.fundamentalMax, model.workspace.sweep.stop > fundamental {
                        Text("Above \(Units.frequencyShort(fundamental)) this hardware uses harmonic mixing: dynamic range and accuracy fall off.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private var startBinding: Binding<Double> {
        Binding(get: { model.workspace.sweep.start },
                set: { model.workspace.sweep.start = min($0, model.workspace.sweep.stop - 1) })
    }
    private var stopBinding: Binding<Double> {
        Binding(get: { model.workspace.sweep.stop },
                set: { model.workspace.sweep.stop = max($0, model.workspace.sweep.start + 1) })
    }
    private var centerBinding: Binding<Double> {
        Binding(get: { model.workspace.sweep.center },
                set: { center in
                    let span = model.workspace.sweep.span
                    model.workspace.sweep.start = max(1, center - span / 2)
                    model.workspace.sweep.stop = center + span / 2
                })
    }
    private var spanBinding: Binding<Double> {
        Binding(get: { model.workspace.sweep.span },
                set: { span in
                    let center = model.workspace.sweep.center
                    model.workspace.sweep.start = max(1, center - span / 2)
                    model.workspace.sweep.stop = center + span / 2
                })
    }
    private var pointsBinding: Binding<Int> {
        Binding(get: { model.workspace.sweep.points },
                set: { model.workspace.sweep.points = $0 })
    }

    private var stepDescription: String {
        "Δf \(Units.frequencyShort(model.workspace.sweep.stepSize))"
    }

    // MARK: - Actions

    private func apply(_ preset: BandPreset) {
        let (start, stop) = preset.padded
        model.workspace.sweep.start = start
        model.workspace.sweep.stop = stop
        model.statusMessage = "Sweep set to \(preset.name)"
    }

    private func applyFullRange() {
        guard let info = model.deviceInfo else { return }
        model.workspace.sweep.start = info.model.minFrequency
        model.workspace.sweep.stop = info.model.maxFrequency
    }

    private func zoomToMarkers() {
        let active = model.workspace.markers.filter(\.enabled).map(\.frequency).sorted()
        guard let lo = active.first, let hi = active.last, hi > lo else { return }
        model.workspace.sweep.start = lo
        model.workspace.sweep.stop = hi
    }
}
