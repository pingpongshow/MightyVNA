import SwiftUI
import VNACore

struct LimitsPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PanelSection(title: "Limits & pass/fail", systemImage: "checklist") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach($model.workspace.limits) { $set in
                    limitSetView($set)
                }

                HStack(spacing: 6) {
                    PillButton(title: "Add limit set", systemImage: "plus") { addSet() }
                    if !model.workspace.limits.isEmpty {
                        Menu {
                            Button("SWR ≤ 2 across the sweep") { addPreset(kind: .maximum, value: 2) }
                            Button("SWR ≤ 1.5 across the sweep") { addPreset(kind: .maximum, value: 1.5) }
                            Button("Return loss ≥ 10 dB") { addPreset(kind: .minimum, value: 10) }
                        } label: {
                            Label("Presets", systemImage: "wand.and.stars").font(.system(size: 11))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 80)
                    }
                }

                if model.workspace.limits.isEmpty {
                    Text("Limit lines mark a pass/fail band on a trace: for example SWR below 2 across an antenna's operating range.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func limitSetView(_ set: Binding<LimitSet>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Toggle("", isOn: set.enabled).toggleStyle(.checkbox).labelsHidden()
                TextField("Name", text: set.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if let verdict = verdict(for: set.wrappedValue) {
                    Text(verdict.passed ? "PASS" : "FAIL")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(verdict.passed ? Theme.statusGood : Theme.statusBad)
                    if verdict.worstMargin.isFinite {
                        Text(String(format: "%+.2f", verdict.worstMargin))
                            .font(Theme.monospaceSmall)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    model.workspace.limits.removeAll { $0.id == set.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Picker("Trace", selection: Binding(
                get: { set.wrappedValue.traceID ?? model.workspace.traces.first?.id ?? UUID() },
                set: { set.wrappedValue.traceID = $0 }
            )) {
                ForEach(model.workspace.traces) { Text($0.displayName).tag($0.id) }
            }
            .font(.system(size: 10))

            ForEach(set.segments) { $segment in
                HStack(spacing: 4) {
                    Picker("", selection: $segment.kind) {
                        ForEach(LimitSegment.Kind.allCases) { Text($0 == .maximum ? "≤" : "≥").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 54)
                    NumericField(title: "", value: $segment.startValue, format: "%.3g", width: 0)
                        .frame(width: 60)
                    NumericField(title: "→", value: $segment.stopValue, format: "%.3g", width: 12)
                        .frame(width: 74)
                    Button {
                        set.wrappedValue.segments.removeAll { $0.id == segment.id }
                    } label: {
                        Image(systemName: "minus.circle").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 4) {
                    FrequencyField(title: "From", value: $segment.startFrequency)
                    FrequencyField(title: "To", value: $segment.stopFrequency)
                }
            }

            Button {
                var segment = LimitSegment(kind: .maximum,
                                           startFrequency: model.workspace.sweep.start,
                                           stopFrequency: model.workspace.sweep.stop,
                                           startValue: 2, stopValue: 2)
                segment.enabled = true
                set.wrappedValue.segments.append(segment)
            } label: {
                Label("Add segment", systemImage: "plus").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
    }

    private func verdict(for set: LimitSet) -> LimitSet.Evaluation? {
        guard set.enabled,
              let traceID = set.traceID,
              let trace = model.workspace.trace(id: traceID) else { return nil }
        let samples = model.samples(for: trace)
        guard !samples.x.isEmpty else { return nil }
        return set.evaluate(x: samples.x, y: samples.y)
    }

    private func addSet() {
        var set = LimitSet()
        set.name = "Limit \(model.workspace.limits.count + 1)"
        set.enabled = true
        set.traceID = model.workspace.traces.first?.id
        model.workspace.limits.append(set)
    }

    private func addPreset(kind: LimitSegment.Kind, value: Double) {
        guard var last = model.workspace.limits.last else { return }
        last.segments.append(LimitSegment(kind: kind,
                                          startFrequency: model.workspace.sweep.start,
                                          stopFrequency: model.workspace.sweep.stop,
                                          startValue: value, stopValue: value))
        model.workspace.limits[model.workspace.limits.count - 1] = last
    }
}
