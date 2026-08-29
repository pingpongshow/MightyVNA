import SwiftUI
import VNACore

struct DisplayPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PanelSection(title: "Display", systemImage: "square.grid.2x2") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Layout", selection: Binding(
                    get: { model.workspace.layout },
                    set: { model.setLayout($0) }
                )) {
                    ForEach(ChartLayout.allCases) { layout in
                        Label(layout.displayName, systemImage: layout.systemImage).tag(layout)
                    }
                }
                .font(.system(size: 11))

                Picker("Frequency axis", selection: $model.workspace.frequencyAxisScale) {
                    ForEach(FrequencyAxisScale.allCases) { Text($0.displayName).tag($0) }
                }
                .font(.system(size: 11))

                Toggle("Minor grid lines", isOn: $model.workspace.showMinorGrid)
                    .toggleStyle(.checkbox).font(.system(size: 11))

                HStack {
                    NumericField(title: "Z₀", value: Binding(
                        get: { model.workspace.z0 },
                        set: { model.workspace.z0 = max(1, $0); model.reprocessCurrentFrame() }
                    ), unit: "Ω", format: "%.1f", width: 30)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.workspace.z0 },
                        set: { model.workspace.z0 = $0; model.reprocessCurrentFrame() }
                    )) {
                        Text("50 Ω").tag(50.0)
                        Text("75 Ω").tag(75.0)
                        Text("300 Ω").tag(300.0)
                        Text("450 Ω").tag(450.0)
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }

                HStack {
                    Text("Group delay aperture").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Stepper(value: $model.workspace.groupDelayAperture, in: 1...25) {
                        Text("±\(model.workspace.groupDelayAperture)").font(Theme.monospace)
                    }
                    .frame(width: 90)
                }

                PillButton(title: "Auto scale all traces", systemImage: "arrow.up.left.and.arrow.down.right") {
                    model.autoScaleAll()
                }
            }
        }
    }
}
